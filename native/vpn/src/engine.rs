//! 单线程事件循环管理 TLS、用户态网络栈及回环桥接，避免每包跨 FFI。

use crate::{frame, link::IpLink};
use mio::{Events, Interest, Poll, Token, Waker};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
use serde_json::{json, Value};
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::{dns, tcp};
use smoltcp::time::{Duration as NetDuration, Instant as NetInstant};
use smoltcp::wire::{DnsQueryType, HardwareAddress, IpAddress, IpCidr};
use socket2::{SockRef, TcpKeepalive};
use std::collections::VecDeque;
use std::io::{self, Read, Write};
#[cfg(test)]
use std::net::TcpListener;
use std::net::{Ipv4Addr, Shutdown, TcpStream, ToSocketAddrs};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const MAX_CONNECTIONS: usize = 64;
const BUFFER_SIZE: usize = 64 * 1024;
const IO_BUFFER_SIZE: usize = 16 * 1024;
const TCP_OPEN_TIMEOUT: Duration = Duration::from_secs(8);
const DNS_OPEN_TIMEOUT: Duration = Duration::from_secs(3);
const BLACKHOLE_IDLE: Duration = Duration::from_secs(3);
const BLACKHOLE_PROBE_TIMEOUT: Duration = Duration::from_millis(2500);
const IO_BUDGET: usize = 16;
const OUTPUT_CAPACITY: usize = 256;
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const TUNNEL: Token = Token(0);
const LISTENER: Token = Token(1);
const CONTROL: Token = Token(2);
// 原客户端为 500ms；测试阶段放宽到 10s，网关兼容性仍需实网验证。
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const RECEIVE_TIMEOUT: Duration = Duration::from_secs(30);
const PROGRESS_TIMEOUT: Duration = Duration::from_secs(5);
const RECOVERY_TIMEOUT: Duration = Duration::from_secs(10);
const TERMINAL_DRAIN_TIMEOUT: Duration = Duration::from_secs(1);
const START_TIMEOUT: Duration = Duration::from_secs(25);
static RESOLVERS: AtomicUsize = AtomicUsize::new(0);

/// 启动控制与安全阶段信息；取消时关闭握手 Socket，不等待阻塞的解析器。
pub struct StartControl {
    cancelled: AtomicBool,
    socket: Mutex<Option<TcpStream>>,
    progress: Mutex<StartProgress>,
}

struct StartProgress {
    started: Instant,
    changed: Instant,
    stage: &'static str,
    timings: Vec<(&'static str, u128)>,
}

impl StartControl {
    pub fn new() -> Self {
        let now = Instant::now();
        Self {
            cancelled: AtomicBool::new(false),
            socket: Mutex::new(None),
            progress: Mutex::new(StartProgress {
                started: now,
                changed: now,
                stage: "等待调用",
                timings: Vec::new(),
            }),
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        if let Ok(socket) = self.socket.lock() {
            if let Some(socket) = socket.as_ref() {
                let _ = socket.shutdown(Shutdown::Both);
            }
        }
    }

    pub fn check(&self, deadline: Instant) -> io::Result<()> {
        if self.cancelled.load(Ordering::Acquire) {
            // rustls 会重试 Interrupted；取消必须返回不可重试的连接错误。
            return Err(error(io::ErrorKind::ConnectionAborted, "VPN 启动已取消"));
        }
        if Instant::now() >= deadline {
            return Err(error(io::ErrorKind::TimedOut, "VPN 启动整体超时"));
        }
        Ok(())
    }

    fn stage(&self, stage: &'static str) {
        if let Ok(mut progress) = self.progress.lock() {
            let previous = progress.stage;
            let elapsed = progress.changed.elapsed().as_millis();
            progress.timings.push((previous, elapsed));
            progress.stage = stage;
            progress.changed = Instant::now();
        }
    }

    pub fn status(&self) -> Value {
        let progress = self.progress.lock().unwrap_or_else(|e| e.into_inner());
        json!({"stage": progress.stage, "stageElapsedMs": progress.changed.elapsed().as_millis(),
            "elapsedMs": progress.started.elapsed().as_millis(), "timings": progress.timings})
    }
}

/// 每次 I/O 都使用同一 deadline，分段响应也不能无限延长握手。
struct DeadlineTcp {
    stream: TcpStream,
    control: Arc<StartControl>,
    deadline: Instant,
}

impl Read for DeadlineTcp {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        loop {
            self.control.check(self.deadline)?;
            self.stream.set_read_timeout(Some(
                self.deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_millis(200))
                    .max(Duration::from_millis(1)),
            ))?;
            match self.stream.read(bytes) {
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) => {}
                result => return result,
            }
        }
    }
}

impl Write for DeadlineTcp {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        loop {
            self.control.check(self.deadline)?;
            self.stream.set_write_timeout(Some(
                self.deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_millis(200))
                    .max(Duration::from_millis(1)),
            ))?;
            match self.stream.write(bytes) {
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) => {}
                result => return result,
            }
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        self.control.check(self.deadline)?;
        self.stream.flush()
    }
}

fn resolve(
    host: String,
    port: u16,
    control: &StartControl,
    deadline: Instant,
) -> io::Result<Vec<std::net::SocketAddr>> {
    // 数字地址无需系统解析线程，避免无意义占用不可取消 getaddrinfo 保护槽。
    if let Ok(address) = host.parse::<std::net::IpAddr>() {
        control.check(deadline)?;
        return Ok(vec![std::net::SocketAddr::new(address, port)]);
    }
    // 系统 getaddrinfo 本身不能取消；限制残留解析线程数量，调用方仍有期限。
    RESOLVERS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < 4).then_some(count + 1)
        })
        .map_err(|_| error(io::ErrorKind::WouldBlock, "VPN DNS 解析任务已达上限"))?;
    let (sender, receiver) = mpsc::sync_channel(1);
    if let Err(e) = thread::Builder::new()
        .name("nuist-vpn-dns".into())
        .spawn(move || {
            let result = (host.as_str(), port)
                .to_socket_addrs()
                .map(|addresses| addresses.collect());
            RESOLVERS.fetch_sub(1, Ordering::AcqRel);
            let _ = sender.send(result);
        })
    {
        RESOLVERS.fetch_sub(1, Ordering::AcqRel);
        return Err(e);
    }
    loop {
        control.check(deadline)?;
        match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(result) => return result,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => return Err(error(io::ErrorKind::BrokenPipe, "VPN DNS 解析线程已退出")),
        }
    }
}

struct Health {
    progress: Instant,
    received: Instant,
    heartbeats: u32,
    received_bytes: u64,
    recovering: bool,
    draining: bool,
    dns_timeouts: u64,
    tcp_timeouts: u64,
    loop_iterations: u64,
}

fn error(kind: io::ErrorKind, message: &str) -> io::Error {
    io::Error::new(kind, message)
}

fn random<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut bytes)
        .map_err(|_| error(io::ErrorKind::Other, "安全随机数不可用"))?;
    Ok(bytes)
}

#[derive(Clone)]
struct ExitEvent {
    reason: String,
    diagnostic: Option<Value>,
}

fn publish_exit(id: &AtomicU64, emitted: &AtomicBool, event: &Mutex<Option<ExitEvent>>) {
    let id = id.load(Ordering::Acquire);
    if id == 0 {
        return;
    }
    let event = event.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(event) = event {
        if !emitted.swap(true, Ordering::AcqRel) {
            crate::emit_event_with_diagnostic(id, "exited", &event.reason, event.diagnostic);
        }
    }
}

/// 老旧内核不支持完整 keepalive 参数时，只退回 idle 时间；所有降级都不阻断握手。
fn configure_keepalive(mut apply: impl FnMut(&TcpKeepalive) -> io::Result<()>) {
    let complete = TcpKeepalive::new()
        .with_time(Duration::from_secs(15))
        .with_interval(Duration::from_secs(5))
        .with_retries(3);
    if apply(&complete).is_err() {
        let _ = apply(&TcpKeepalive::new().with_time(Duration::from_secs(15)));
    }
}

enum Command {
    Probe(String, Duration, SyncSender<io::Result<()>>),
    #[cfg(test)]
    SimulateSuspend(SyncSender<()>),
}

#[derive(Clone)]
pub struct Handle {
    commands: SyncSender<Command>,
    running: Arc<AtomicBool>,
    exit_reason: Arc<Mutex<Option<String>>>,
    health: Arc<Mutex<Health>>,
    socket: Arc<TcpStream>,
    waker: Arc<Waker>,
    engine_id: Arc<AtomicU64>,
    exited_emitted: Arc<AtomicBool>,
    exit_event: Arc<Mutex<Option<ExitEvent>>>,
    pub proxy_port: u16,
    pub proxy_token: String,
}

impl Handle {
    pub fn alive(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }
    pub fn exit_reason(&self) -> Option<String> {
        self.exit_reason
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
    pub fn set_id(&self, id: u64) {
        self.engine_id.store(id, Ordering::Release);
        publish_exit(&self.engine_id, &self.exited_emitted, &self.exit_event);
    }
    pub fn stop(&self) {
        self.running.store(false, Ordering::Release);
        let _ = self.socket.shutdown(Shutdown::Both);
        let _ = self.waker.wake();
    }
    pub fn status(&self) -> Value {
        let health = self.health.lock().unwrap_or_else(|e| e.into_inner());
        let alive = self.alive();
        json!({"alive": alive, "healthy": alive && !health.recovering && !health.draining,
            "needsProbe": alive && (health.received.elapsed() >= RECEIVE_TIMEOUT || health.recovering),
            "exitReason": self.exit_reason(), "loopIdleMs": health.progress.elapsed().as_millis(),
            "rxIdleMs": health.received.elapsed().as_millis(), "heartbeats": health.heartbeats,
            "receivedBytes": health.received_bytes, "recovering": health.recovering, "draining": health.draining,
            "dnsTimeouts": health.dns_timeouts, "tcpTimeouts": health.tcp_timeouts,
            "loopIterations": health.loop_iterations})
    }
    pub fn probe(&self, host: String, timeout: Duration) -> io::Result<()> {
        if !self.alive() {
            return Err(error(io::ErrorKind::NotConnected, "VPN 隧道已关闭"));
        }
        let (sender, receiver) = mpsc::sync_channel(1);
        self.commands
            .try_send(Command::Probe(host, timeout, sender))
            .map_err(|_| error(io::ErrorKind::WouldBlock, "VPN 探测队列不可用"))?;
        self.waker.wake()?;
        receiver
            .recv_timeout(timeout + Duration::from_secs(1))
            .map_err(|e| {
                error(
                    if matches!(e, mpsc::RecvTimeoutError::Timeout) {
                        io::ErrorKind::TimedOut
                    } else {
                        io::ErrorKind::ConnectionAborted
                    },
                    "VPN 探测未完成",
                )
            })?
    }
}

fn build_client_config(roots: RootCertStore) -> io::Result<Arc<ClientConfig>> {
    let tls = ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(io::Error::other)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Arc::new(tls))
}

fn default_client_config() -> io::Result<Arc<ClientConfig>> {
    static DEFAULT_TLS_CONFIG: OnceLock<Arc<ClientConfig>> = OnceLock::new();
    if let Some(config) = DEFAULT_TLS_CONFIG.get() {
        return Ok(Arc::clone(config));
    }
    let roots = RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = build_client_config(roots)?;
    Ok(Arc::clone(DEFAULT_TLS_CONFIG.get_or_init(|| config)))
}

pub fn start_controlled(
    value: &Value,
    control: Arc<StartControl>,
) -> io::Result<(Handle, frame::AuthInfo)> {
    start_inner(value, None, control, START_TIMEOUT)
}

#[cfg(test)]
fn start_with_roots(value: &Value, roots: RootCertStore) -> io::Result<(Handle, frame::AuthInfo)> {
    static START_TEST: Mutex<()> = Mutex::new(());
    let _starting = START_TEST.lock().unwrap_or_else(|error| error.into_inner());
    start_with_control(value, roots, Arc::new(StartControl::new()))
}

#[cfg(test)]
fn start_with_control(
    value: &Value,
    roots: RootCertStore,
    control: Arc<StartControl>,
) -> io::Result<(Handle, frame::AuthInfo)> {
    start_with_deadline(value, roots, control, START_TIMEOUT)
}

#[cfg(test)]
fn start_with_deadline(
    value: &Value,
    roots: RootCertStore,
    control: Arc<StartControl>,
    timeout: Duration,
) -> io::Result<(Handle, frame::AuthInfo)> {
    start_inner(value, Some(roots), control, timeout)
}

fn start_inner(
    value: &Value,
    roots: Option<RootCertStore>,
    control: Arc<StartControl>,
    timeout: Duration,
) -> io::Result<(Handle, frame::AuthInfo)> {
    let deadline = Instant::now() + timeout;
    control.check(deadline)?;
    control.stage("配置");
    let field = |key: &str| {
        value[key]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| error(io::ErrorKind::InvalidInput, "VPN 配置缺少必要字段"))
    };
    let host = field("host")?;
    let probe_host = field("probeHost")?;
    let user = field("user")?;
    let token = field("token")?;
    let port = value["port"]
        .as_u64()
        .filter(|p| (1..=65535).contains(p))
        .ok_or_else(|| error(io::ErrorKind::InvalidInput, "VPN 网关端口不合法"))?
        as u16;
    let server_name = rustls::pki_types::ServerName::try_from(host.to_owned())
        .map_err(|_| error(io::ErrorKind::InvalidInput, "VPN 网关主机名不合法"))?;
    let tls = match roots {
        Some(roots) => build_client_config(roots)?,
        None => default_client_config()?,
    };
    control.stage("DNS");
    let addresses = resolve(
        host.to_owned(),
        port,
        &control,
        (Instant::now() + Duration::from_secs(5)).min(deadline),
    )?;
    control.stage("TCP");
    let tcp_deadline = (Instant::now() + Duration::from_secs(10)).min(deadline);
    let mut raw = None;
    for address in addresses.into_iter().take(4) {
        control.check(deadline)?;
        let remaining = tcp_deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        if let Ok(stream) =
            TcpStream::connect_timeout(&address, remaining.min(Duration::from_secs(3)))
        {
            raw = Some(stream);
            break;
        }
    }
    let raw = raw.ok_or_else(|| error(io::ErrorKind::NotConnected, "无法连接 VPN 网关"))?;
    raw.set_nodelay(true)?;
    configure_keepalive(|options| SockRef::from(&raw).set_tcp_keepalive(options));
    *control.socket.lock().unwrap_or_else(|e| e.into_inner()) = Some(raw.try_clone()?);
    control.check(deadline)?;
    let mut connection = ClientConnection::new(tls, server_name).map_err(io::Error::other)?;
    connection.set_buffer_limit(Some(BUFFER_SIZE * 4));
    control.stage("TLS");
    let mut tunnel = StreamOwned::new(
        connection,
        DeadlineTcp {
            stream: raw,
            control: control.clone(),
            deadline,
        },
    );
    while tunnel.conn.is_handshaking() {
        tunnel.conn.complete_io(&mut tunnel.sock)?;
    }
    control.stage("协议鉴权");
    let info = frame::authenticate(&mut tunnel, user, token)?;
    control.check(deadline)?;
    control
        .socket
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take();
    let tunnel = StreamOwned::new(tunnel.conn, tunnel.sock.stream);
    tunnel.sock.set_read_timeout(None)?;
    tunnel.sock.set_write_timeout(None)?;
    tunnel.sock.set_nonblocking(true)?;

    let (sender, receiver) = mpsc::sync_channel(MAX_CONNECTIONS);
    let running = Arc::new(AtomicBool::new(true));
    let exit_reason = Arc::new(Mutex::new(None));
    let now = Instant::now();
    let health = Arc::new(Mutex::new(Health {
        progress: now,
        received: now,
        heartbeats: 0,
        received_bytes: 0,
        recovering: false,
        draining: false,
        dns_timeouts: 0,
        tcp_timeouts: 0,
        loop_iterations: 0,
    }));
    let control_socket = Arc::new(tunnel.sock.try_clone()?);
    let tunnel = StreamOwned::new(tunnel.conn, mio::net::TcpStream::from_std(tunnel.sock));
    let mut runner = Runner::new(
        tunnel,
        &info,
        receiver,
        running.clone(),
        health.clone(),
        probe_host.to_owned(),
    )?;
    let exited_emitted = Arc::new(AtomicBool::new(false));
    let exit_event = Arc::new(Mutex::new(None));
    let engine_id = runner.engine_id.clone();
    let handle = Handle {
        commands: sender,
        running: running.clone(),
        exit_reason: exit_reason.clone(),
        health,
        socket: control_socket,
        waker: runner.waker.clone(),
        engine_id: engine_id.clone(),
        exited_emitted: exited_emitted.clone(),
        exit_event: exit_event.clone(),
        proxy_port: runner
            .listener
            .as_ref()
            .expect("启动时代理监听存在")
            .local_addr()?
            .port(),
        proxy_token: runner.proxy_token.clone(),
    };
    thread::Builder::new()
        .name("nuist-vpn".into())
        .spawn(move || {
            let outcome = catch_unwind(AssertUnwindSafe(|| runner.run())).unwrap_or_else(|_| {
                runner.exit_code = Some("native_engine_panic".into());
                Err(io::Error::other("VPN 引擎线程发生 panic"))
            });
            let reason = runner.exit_code.take().unwrap_or_else(|| match &outcome {
                Ok(()) => "stopped".to_owned(),
                Err(error) => format!("{:?}", error.kind()),
            });
            *exit_reason.lock().unwrap_or_else(|e| e.into_inner()) = Some(reason.clone());
            let diagnostic = outcome
                .as_ref()
                .err()
                .map(|error| crate::NativeFailure::io_details(error, &reason, "native.engine"));
            *exit_event.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(ExitEvent { reason, diagnostic });
            running.store(false, Ordering::Release);
            publish_exit(&engine_id, &exited_emitted, &exit_event);
        })?;
    control.stage("完成");
    Ok((handle, info))
}

struct Flow {
    query: Option<dns::QueryHandle>,
    tcp: Option<SocketHandle>,
    port: u16,
    deadline: Instant,
    connect_started: Option<Instant>,
    local: mio::net::TcpStream,
    token: Token,
    interest: Interest,
    headers: Vec<u8>,
    pending: Vec<u8>,
    pending_offset: usize,
    ingress: Vec<u8>,
    authorized: bool,
    established: bool,
    reject: bool,
    local_eof: bool,
    remote_eof: bool,
    touched: Instant,
}

struct Probe {
    query: dns::QueryHandle,
    deadline: Instant,
    replies: Vec<SyncSender<io::Result<()>>>,
    blackhole: bool,
    recovery: bool,
    observed_frames: u64,
}

struct Runner {
    tunnel: StreamOwned<ClientConnection, mio::net::TcpStream>,
    tunnel_interest: Interest,
    poll: Poll,
    events: Events,
    waker: Arc<Waker>,
    listener: Option<mio::net::TcpListener>,
    probe_host: String,
    proxy_token: String,
    proxy_authorization: String,
    next_token: usize,
    engine_id: Arc<AtomicU64>,
    device: IpLink,
    interface: Interface,
    sockets: SocketSet<'static>,
    dns: SocketHandle,
    commands: Receiver<Command>,
    running: Arc<AtomicBool>,
    flows: Vec<Flow>,
    local_port: u16,
    decoder: frame::Decoder,
    output: VecDeque<Vec<u8>>,
    output_offset: usize,
    io_buffer: Box<[u8]>,
    started: Instant,
    last_received: Instant,
    last_heartbeat: Instant,
    heartbeat: u32,
    health: Arc<Mutex<Health>>,
    last_progress: Instant,
    recovery_deadline: Option<Instant>,
    io_progress: u64,
    terminal: Option<io::Error>,
    drain_deadline: Option<Instant>,
    probe: Option<Probe>,
    consecutive_timeouts: u32,
    exit_code: Option<String>,
    budget_exhausted: bool,
    tls_write_blocked: bool,
    #[cfg(test)]
    io_budget: usize,
    #[cfg(test)]
    io_chunk_limit: usize,
}

/// CONNECT 凭据固定为 VPN 会话的随机口令，比较时不提前返回。
fn authorization(token: &str) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let input = format!("vpn:{token}");
    let mut encoded = String::new();
    for bytes in input.as_bytes().chunks(3) {
        let a = bytes[0] as usize;
        let b = bytes.get(1).copied().unwrap_or(0) as usize;
        let c = bytes.get(2).copied().unwrap_or(0) as usize;
        encoded.push(TABLE[a >> 2] as char);
        encoded.push(TABLE[((a & 3) << 4) | (b >> 4)] as char);
        encoded.push(if bytes.len() > 1 {
            TABLE[((b & 15) << 2) | (c >> 6)] as char
        } else {
            '='
        });
        encoded.push(if bytes.len() > 2 {
            TABLE[c & 63] as char
        } else {
            '='
        });
    }
    format!("Basic {encoded}")
}

fn parse_connect(headers: &[u8], expected: &str) -> Result<(String, u16), u16> {
    let text = std::str::from_utf8(headers).map_err(|_| 400u16)?;
    let mut lines = text.split("\r\n");
    let mut request = lines.next().ok_or(400u16)?.split_whitespace();
    if request.next() != Some("CONNECT") {
        return Err(405);
    }
    let authority = request.next().ok_or(400u16)?;
    if request.next() != Some("HTTP/1.1") || request.next().is_some() {
        return Err(400);
    }
    let mut credential = None;
    for line in lines.filter(|line| !line.is_empty()) {
        let (name, value) = line.split_once(':').ok_or(400u16)?;
        if name.eq_ignore_ascii_case("proxy-authorization") {
            if credential.is_some() {
                return Err(407);
            }
            credential = Some(value.trim());
        }
    }
    let credential = credential.ok_or(407u16)?;
    if credential.len() != expected.len()
        || credential
            .as_bytes()
            .iter()
            .zip(expected.as_bytes())
            .fold(0u8, |diff, (a, b)| diff | (a ^ b))
            != 0
    {
        return Err(407);
    }
    let (host, port) = authority.rsplit_once(':').ok_or(400u16)?;
    if host.is_empty()
        || host.len() > 253
        || !host.is_ascii()
        || host.contains(':')
        || host
            .bytes()
            .any(|b| b.is_ascii_whitespace() || b == b'/' || b == b'@')
    {
        return Err(400);
    }
    let port = port
        .parse::<u16>()
        .ok()
        .filter(|port| *port > 0)
        .ok_or(400u16)?;
    Ok((host.to_owned(), port))
}

impl Runner {
    fn new(
        mut tunnel: StreamOwned<ClientConnection, mio::net::TcpStream>,
        info: &frame::AuthInfo,
        commands: Receiver<Command>,
        running: Arc<AtomicBool>,
        health: Arc<Mutex<Health>>,
        probe_host: String,
    ) -> io::Result<Self> {
        let mut device = IpLink::default();
        let mut config = Config::new(HardwareAddress::Ip);
        config.random_seed = u64::from_le_bytes(random()?);
        let mut interface = Interface::new(config, &mut device, NetInstant::from_millis(0));
        interface.update_ip_addrs(|addresses| {
            addresses
                .push(IpCidr::new(IpAddress::Ipv4(info.address), 32))
                .expect("固定单地址容量足够");
        });
        interface
            .routes_mut()
            .add_default_ipv4_route(info.address)
            .map_err(|_| error(io::ErrorKind::Other, "无法设置隧道路由"))?;
        let mut sockets = SocketSet::new(Vec::new());
        let queries: Vec<_> = (0..MAX_CONNECTIONS + 1).map(|_| None).collect();
        let dns = sockets.add(dns::Socket::new(&[IpAddress::Ipv4(info.dns)], queries));
        let poll = Poll::new()?;
        poll.registry()
            .register(&mut tunnel.sock, TUNNEL, Interest::READABLE)?;
        let mut listener = mio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0).into())?;
        poll.registry()
            .register(&mut listener, LISTENER, Interest::READABLE)?;
        let waker = Arc::new(Waker::new(poll.registry(), CONTROL)?);
        let proxy_token: String = random::<32>()?.iter().map(|b| format!("{b:02x}")).collect();
        let proxy_authorization = authorization(&proxy_token);
        let now = Instant::now();
        Ok(Self {
            tunnel,
            tunnel_interest: Interest::READABLE,
            poll,
            events: Events::with_capacity(128),
            waker,
            listener: Some(listener),
            probe_host,
            proxy_token,
            proxy_authorization,
            next_token: 3,
            engine_id: Arc::new(AtomicU64::new(0)),
            device,
            interface,
            sockets,
            dns,
            commands,
            running,
            flows: Vec::new(),
            local_port: 49152 + (u16::from_le_bytes(random()?) % 16384),
            decoder: frame::Decoder::default(),
            output: VecDeque::new(),
            output_offset: 0,
            io_buffer: vec![0; IO_BUFFER_SIZE].into_boxed_slice(),
            started: now,
            last_received: now,
            last_heartbeat: now - HEARTBEAT_INTERVAL,
            heartbeat: 0,
            health,
            last_progress: now,
            recovery_deadline: None,
            io_progress: 0,
            terminal: None,
            drain_deadline: None,
            probe: None,
            consecutive_timeouts: 0,
            exit_code: None,
            budget_exhausted: false,
            tls_write_blocked: false,
            #[cfg(test)]
            io_budget: IO_BUDGET,
            #[cfg(test)]
            io_chunk_limit: usize::MAX,
        })
    }

    fn io_budget(&self) -> usize {
        #[cfg(test)]
        {
            self.io_budget
        }
        #[cfg(not(test))]
        {
            IO_BUDGET
        }
    }

    fn io_chunk_limit(&self) -> usize {
        #[cfg(test)]
        {
            self.io_chunk_limit
        }
        #[cfg(not(test))]
        {
            usize::MAX
        }
    }

    fn connect_tcp(&mut self, ip: IpAddress, port: u16) -> io::Result<SocketHandle> {
        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
            tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
        );
        socket.set_timeout(Some(NetDuration::from_secs(60)));
        socket.set_keep_alive(Some(NetDuration::from_secs(20)));
        // 长连接可能跨越一次端口环绕，必须检查整个 socket 集合（含 TIME_WAIT）。
        loop {
            self.local_port = if self.local_port == 65535 {
                49152
            } else {
                self.local_port + 1
            };
            if !self.sockets.iter().any(|(_, existing)| matches!(existing,
                smoltcp::socket::Socket::Tcp(existing) if existing.local_endpoint().is_some_and(|e| e.port == self.local_port))) {
                break;
            }
        }
        socket
            .connect(self.interface.context(), (ip, port), self.local_port)
            .map_err(|_| error(io::ErrorKind::ConnectionRefused, "无法创建隧道内 TCP 连接"))?;
        Ok(self.sockets.add(socket))
    }

    fn accept_clients(&mut self) -> io::Result<()> {
        if self.terminal.is_some() {
            return Ok(());
        }
        loop {
            let Some(listener) = self.listener.as_mut() else {
                return Ok(());
            };
            match listener.accept() {
                Ok((mut local, _)) => {
                    if self.flows.len() >= MAX_CONNECTIONS {
                        let _ = local.write_all(
                            b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n",
                        );
                        continue;
                    }
                    local.set_nodelay(true)?;
                    let token = Token(self.next_token);
                    self.next_token = self.next_token.wrapping_add(1).max(3);
                    self.poll
                        .registry()
                        .register(&mut local, token, Interest::READABLE)?;
                    self.flows.push(Flow {
                        query: None,
                        tcp: None,
                        port: 0,
                        deadline: Instant::now() + TCP_OPEN_TIMEOUT,
                        connect_started: None,
                        local,
                        token,
                        interest: Interest::READABLE,
                        headers: Vec::new(),
                        pending: Vec::new(),
                        pending_offset: 0,
                        ingress: Vec::new(),
                        authorized: false,
                        established: false,
                        reject: false,
                        local_eof: false,
                        remote_eof: false,
                        touched: Instant::now(),
                    });
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    fn respond(flow: &mut Flow, status: u16) {
        let phrase = match status {
            200 => "Connection Established",
            407 => "Proxy Authentication Required",
            504 => "Gateway Timeout",
            405 => "Method Not Allowed",
            400 => "Bad Request",
            _ => "Bad Gateway",
        };
        let challenge = if status == 407 {
            "Proxy-Authenticate: Basic realm=\"vpn\"\r\n"
        } else {
            ""
        };
        flow.pending = format!("HTTP/1.1 {status} {phrase}\r\n{challenge}\r\n").into_bytes();
        flow.pending_offset = 0;
        flow.reject = status != 200;
    }

    fn start_probe(
        &mut self,
        host: &str,
        timeout: Duration,
        reply: Option<SyncSender<io::Result<()>>>,
        blackhole: bool,
        recovery: bool,
    ) -> io::Result<()> {
        if self.terminal.is_some() {
            if let Some(reply) = reply {
                let _ = reply.send(Err(error(
                    io::ErrorKind::ConnectionAborted,
                    "VPN 已进入排空",
                )));
            }
            return Ok(());
        }
        if let Some(probe) = self.probe.as_mut() {
            probe.blackhole |= blackhole;
            probe.recovery |= recovery;
            if let Some(reply) = reply {
                probe.replies.push(reply);
            }
            return Ok(());
        }
        match self.sockets.get_mut::<dns::Socket>(self.dns).start_query(
            self.interface.context(),
            host,
            DnsQueryType::A,
        ) {
            Ok(query) => {
                self.probe = Some(Probe {
                    query,
                    deadline: Instant::now() + timeout,
                    replies: reply.into_iter().collect(),
                    blackhole,
                    recovery,
                    observed_frames: self.decoder.completed_frames(),
                })
            }
            Err(_) => {
                if let Some(reply) = reply {
                    let _ = reply.send(Err(error(
                        io::ErrorKind::InvalidInput,
                        "VPN 探活主机或查询槽不可用",
                    )));
                }
                if blackhole || recovery {
                    self.exit_code = Some(
                        if blackhole {
                            "blackhole_detected"
                        } else {
                            "recovery_timeout"
                        }
                        .into(),
                    );
                    return Err(error(io::ErrorKind::TimedOut, "VPN 内置 DNS 探活无法启动"));
                }
            }
        }
        Ok(())
    }

    /// 黑洞判定属于引擎主循环，不能被单条目标连接的错误处理吞掉。
    fn check_blackhole(&mut self) -> io::Result<()> {
        let now = Instant::now();
        let stalled_connection = self.flows.iter().any(|flow| {
            flow.authorized
                && !flow.established
                && !flow.reject
                && flow
                    .connect_started
                    .is_some_and(|started| now.duration_since(started) >= BLACKHOLE_IDLE)
        });
        if self.probe.is_none()
            && self.last_received.elapsed() >= BLACKHOLE_IDLE
            && (stalled_connection || self.consecutive_timeouts >= 2)
        {
            self.start_probe(
                &self.probe_host.clone(),
                BLACKHOLE_PROBE_TIMEOUT,
                None,
                true,
                false,
            )?;
        }
        Ok(())
    }

    fn advance(&mut self, flow: &mut Flow) -> io::Result<bool> {
        let now = Instant::now();
        let budget = self.io_budget();
        let chunk_limit = self.io_chunk_limit();
        if !flow.established && !flow.reject && now >= flow.deadline {
            if flow.authorized {
                let mut health = self.health.lock().unwrap_or_else(|e| e.into_inner());
                if flow.query.is_some() {
                    health.dns_timeouts += 1;
                } else {
                    health.tcp_timeouts += 1;
                }
                drop(health);
                self.consecutive_timeouts += 1;
            }
            Self::respond(flow, 504);
        }
        if self.terminal.is_some() && !flow.established {
            return Ok(false);
        }
        if !flow.authorized && !flow.reject {
            let mut bytes = [0u8; 1024];
            loop {
                match flow.local.read(&mut bytes) {
                    Ok(0) => return Ok(false),
                    Ok(count) => flow.headers.extend_from_slice(&bytes[..count]),
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => return Err(e),
                }
                if let Some(end) = flow
                    .headers
                    .windows(4)
                    .position(|bytes| bytes == b"\r\n\r\n")
                {
                    let end = end + 4;
                    match parse_connect(&flow.headers[..end], &self.proxy_authorization) {
                        Ok((host, port)) => {
                            flow.port = port;
                            flow.authorized = true;
                            flow.connect_started = Some(now);
                            flow.ingress = flow.headers.split_off(end);
                            flow.headers.fill(0);
                            flow.headers.clear();
                            if let Ok(ip) = host.parse::<Ipv4Addr>() {
                                flow.deadline = now + TCP_OPEN_TIMEOUT;
                                match self.connect_tcp(ip.into(), port) {
                                    Ok(tcp) => flow.tcp = Some(tcp),
                                    Err(_) => Self::respond(flow, 502),
                                }
                            } else {
                                flow.deadline = now + DNS_OPEN_TIMEOUT;
                                match self.sockets.get_mut::<dns::Socket>(self.dns).start_query(
                                    self.interface.context(),
                                    &host,
                                    DnsQueryType::A,
                                ) {
                                    Ok(query) => flow.query = Some(query),
                                    Err(_) => Self::respond(flow, 502),
                                }
                            }
                        }
                        Err(status) => Self::respond(flow, status),
                    }
                    break;
                }
                if flow.headers.len() >= 8192 {
                    Self::respond(flow, 400);
                    break;
                }
            }
        }
        if flow.authorized && !flow.established && !flow.reject {
            let mut bytes = [0u8; 1024];
            while flow.ingress.len() < BUFFER_SIZE {
                match flow.local.read(&mut bytes) {
                    Ok(0) => return Ok(false),
                    Ok(count) => flow.ingress.extend_from_slice(&bytes[..count]),
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => return Err(e),
                }
            }
        }
        if !flow.reject {
            if let Some(query) = flow.query {
                match self
                    .sockets
                    .get_mut::<dns::Socket>(self.dns)
                    .get_query_result(query)
                {
                    Ok(addresses) => {
                        flow.query = None;
                        if let Some(ip) = addresses.first() {
                            flow.deadline = now + TCP_OPEN_TIMEOUT;
                            match self.connect_tcp(*ip, flow.port) {
                                Ok(tcp) => flow.tcp = Some(tcp),
                                Err(_) => Self::respond(flow, 502),
                            }
                        } else {
                            Self::respond(flow, 502);
                        }
                    }
                    Err(dns::GetQueryResultError::Pending) => {}
                    Err(_) => {
                        flow.query = None;
                        Self::respond(flow, 502);
                    }
                }
            }
            if let Some(tcp) = flow.tcp {
                let socket = self.sockets.get_mut::<tcp::Socket>(tcp);
                if socket.state() == tcp::State::Closed
                    && self.terminal.is_none()
                    && (!flow.established || !socket.can_recv())
                {
                    if flow.established {
                        // 已切换为原始字节流，远端 RST 只能关闭连接，不能把 HTTP 错误混进正文。
                        return Err(error(io::ErrorKind::ConnectionAborted, "隧道内 TCP 已关闭"));
                    }
                    Self::respond(flow, 502);
                } else if !flow.established && socket.state() == tcp::State::Established {
                    flow.established = true;
                    self.consecutive_timeouts = 0;
                    Self::respond(flow, 200);
                }
            }
        }
        while flow.pending_offset < flow.pending.len() {
            match flow.local.write(&flow.pending[flow.pending_offset..]) {
                Ok(0) => return Ok(false),
                Ok(count) => {
                    flow.pending_offset += count;
                    self.io_progress = self.io_progress.wrapping_add(1);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        if flow.pending_offset == flow.pending.len() {
            flow.pending.clear();
            flow.pending_offset = 0;
            if flow.reject {
                return Ok(false);
            }
        }
        if flow.established && flow.pending.is_empty() {
            let socket = self
                .sockets
                .get_mut::<tcp::Socket>(flow.tcp.expect("建连后 TCP 存在"));
            if self.terminal.is_none() && !flow.local_eof {
                if !flow.ingress.is_empty() && socket.can_send() {
                    let sent = socket
                        .send_slice(&flow.ingress)
                        .map_err(|_| error(io::ErrorKind::BrokenPipe, "隧道发送失败"))?;
                    flow.ingress.drain(..sent);
                }
                let mut read_rounds = 0;
                for _ in 0..budget {
                    if !flow.ingress.is_empty() || !socket.can_send() {
                        break;
                    }
                    let bytes = &mut self.io_buffer;
                    let capacity = (socket.send_capacity() - socket.send_queue())
                        .min(bytes.len())
                        .min(chunk_limit);
                    if capacity == 0 {
                        break;
                    }
                    match flow.local.read(&mut bytes[..capacity]) {
                        Ok(0) => {
                            flow.local_eof = true;
                            socket.close();
                            break;
                        }
                        Ok(count) => {
                            read_rounds += 1;
                            socket
                                .send_slice(&bytes[..count])
                                .map_err(|_| error(io::ErrorKind::BrokenPipe, "隧道发送失败"))?;
                            flow.touched = now;
                            self.io_progress = self.io_progress.wrapping_add(1);
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => return Err(e),
                    }
                }
                if read_rounds == budget {
                    self.budget_exhausted = true;
                }
            }
            let mut write_rounds = 0;
            for _ in 0..budget {
                if !socket.can_recv() {
                    break;
                }
                let written = socket
                    .recv(
                        |bytes| match flow.local.write(&bytes[..bytes.len().min(chunk_limit)]) {
                            Ok(count) => (count, Ok(count)),
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => (0, Ok(0)),
                            Err(e) => (0, Err(e)),
                        },
                    )
                    .map_err(|_| error(io::ErrorKind::BrokenPipe, "隧道接收失败"))??;
                if written == 0 {
                    break;
                }
                write_rounds += 1;
                flow.touched = now;
                self.io_progress = self.io_progress.wrapping_add(1);
            }
            if write_rounds == budget {
                self.budget_exhausted = true;
            }
            if !socket.may_recv() && !socket.can_recv() && !flow.remote_eof {
                let _ = flow.local.shutdown(Shutdown::Write);
                flow.remote_eof = true;
            }
            if self.terminal.is_some() && !socket.can_recv() {
                let _ = flow.local.shutdown(Shutdown::Write);
                if Self::drain_local(flow, &mut self.io_buffer) {
                    return Ok(false);
                }
                self.budget_exhausted = true;
            }
            if socket.state() == tcp::State::Closed && !socket.can_recv() {
                return Ok(false);
            }
        }
        let wants_write = !flow.pending.is_empty()
            || flow
                .tcp
                .is_some_and(|tcp| self.sockets.get::<tcp::Socket>(tcp).can_recv());
        let interest = if wants_write {
            Interest::READABLE.add(Interest::WRITABLE)
        } else {
            Interest::READABLE
        };
        if interest != flow.interest {
            self.poll
                .registry()
                .reregister(&mut flow.local, flow.token, interest)?;
            flow.interest = interest;
        }
        Ok(now.duration_since(flow.touched) < Duration::from_secs(180))
    }

    /// 关闭前抽干已经到达本地 Socket 的数据，减少有未读请求时内核 RST 冲掉响应尾部。
    fn drain_local(flow: &mut Flow, bytes: &mut [u8]) -> bool {
        for _ in 0..IO_BUDGET {
            match flow.local.read(bytes) {
                Ok(0) => return true,
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return true,
            }
        }
        false
    }

    fn remove(&mut self, mut flow: Flow) {
        if self.terminal.is_some() {
            let _ = Self::drain_local(&mut flow, &mut self.io_buffer);
        }
        let _ = self.poll.registry().deregister(&mut flow.local);
        if let Some(query) = flow.query.take() {
            self.sockets
                .get_mut::<dns::Socket>(self.dns)
                .cancel_query(query);
        }
        if let Some(handle) = flow.tcp.take() {
            self.sockets.get_mut::<tcp::Socket>(handle).abort();
            self.sockets.remove(handle);
        }
    }

    fn pump_tls(&mut self) -> io::Result<()> {
        if self.terminal.is_some() {
            return Ok(());
        }
        // 每轮设上限，防止一条大下载饿死连接命令和心跳。
        let budget = self.io_budget();
        let mut read_rounds = 0;
        for _ in 0..budget {
            // 先消耗已解密的数据：握手读取可能已把后续报文一并收进 rustls。
            loop {
                // 最小 IPv4 帧为 8 字节头 + 20 字节包。为 Decoder 中可能
                // 已有的半帧预留一个槽，不从可靠 TLS 流主动读出随后要丢弃的包。
                let capacity = self.device.receive_capacity();
                if capacity < 2 {
                    break;
                }
                let limit = self.io_buffer.len().min((capacity - 1) * 28);
                match self.tunnel.conn.reader().read(&mut self.io_buffer[..limit]) {
                    // 非空缓冲读到 0 表示已收到 close_notify；即使 TCP 仍保持
                    // 打开，TLS 也不会再有数据，不能继续把它报告为健康隧道。
                    Ok(0) => {
                        self.receive_terminal(error(
                            io::ErrorKind::UnexpectedEof,
                            "VPN 网关已关闭 TLS",
                        ));
                        return Ok(());
                    }
                    Ok(count) => {
                        self.io_progress = self.io_progress.wrapping_add(1);
                        let completed = self.decoder.completed_frames();
                        for packet in self.decoder.push(&self.io_buffer[..count])? {
                            self.device.inject(packet);
                        }
                        let mut health = self.health.lock().unwrap_or_else(|e| e.into_inner());
                        health.received_bytes += count as u64;
                        if completed != self.decoder.completed_frames() {
                            self.last_received = Instant::now();
                            health.received = self.last_received;
                            let recovered = health.recovering;
                            health.recovering = false;
                            self.recovery_deadline = None;
                            drop(health);
                            if recovered {
                                crate::emit_event(
                                    self.engine_id.load(Ordering::Acquire),
                                    "healthy",
                                    "complete_frame_received",
                                );
                            }
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {
                        self.receive_terminal(e);
                        return Ok(());
                    }
                    Err(e) => return Err(e),
                }
            }
            if self.device.receive_capacity() < 2 {
                break;
            }
            match self.tunnel.conn.read_tls(&mut self.tunnel.sock) {
                Ok(0) => {
                    self.receive_terminal(error(io::ErrorKind::UnexpectedEof, "VPN 网关已断开"));
                    return Ok(());
                }
                Ok(_) => {
                    read_rounds += 1;
                    self.io_progress = self.io_progress.wrapping_add(1);
                    self.tunnel
                        .conn
                        .process_new_packets()
                        .map_err(io::Error::other)?;
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        if read_rounds == budget {
            self.budget_exhausted = true;
        }
        // 部分合法网关不回复保活帧；空闲无数据不等于关闭，留待请求/前台
        // 发起一次有界 DNS 探测。真正 TLS/TCP EOF 仍走终态清理。
        if self.last_heartbeat.elapsed() >= HEARTBEAT_INTERVAL {
            if self.output.len() < OUTPUT_CAPACITY {
                self.heartbeat = self.heartbeat.wrapping_add(1);
                self.health
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .heartbeats = self.heartbeat;
                self.output
                    .push_back(frame::heartbeat(self.heartbeat).to_vec());
            }
            // 背压跳过保活时也推迟下次检查，不能让已经过去的心跳截止时间造成 poll(0)。
            self.last_heartbeat = Instant::now();
        }
        while self.output.len() < OUTPUT_CAPACITY {
            let Some(packet) = self.device.outgoing.pop_front() else {
                break;
            };
            self.output.push_back(frame::data(&packet)?);
        }
        while let Some(bytes) = self.output.front() {
            let count = self
                .tunnel
                .conn
                .writer()
                .write(&bytes[self.output_offset..])?;
            if count == 0 {
                break;
            }
            self.output_offset += count;
            if self.output_offset == bytes.len() {
                self.output.pop_front();
                self.output_offset = 0;
            }
        }
        self.tls_write_blocked = false;
        let mut write_rounds = 0;
        for _ in 0..budget * 2 {
            if !self.tunnel.conn.wants_write() {
                break;
            }
            match self.tunnel.conn.write_tls(&mut self.tunnel.sock) {
                Ok(0) => return Err(error(io::ErrorKind::WriteZero, "VPN 写入中断")),
                Ok(_) => {
                    write_rounds += 1;
                    self.io_progress = self.io_progress.wrapping_add(1);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    self.tls_write_blocked = true;
                    break;
                }
                Err(e) => return Err(e),
            }
        }
        if write_rounds == budget * 2
            || (!self.tls_write_blocked
                && (!self.output.is_empty() || self.tunnel.conn.wants_write()))
        {
            self.budget_exhausted = true;
        }
        Ok(())
    }

    fn receive_terminal(&mut self, failure: io::Error) {
        if self.terminal.is_some() {
            return;
        }
        self.terminal = Some(failure);
        self.output.clear();
        self.output_offset = 0;
        self.device.enter_draining();
        // 进入终态前耗尽的TLS预算已无意义，不能用它继续零期限轮询。
        self.budget_exhausted = false;
        let _ = self.poll.registry().deregister(&mut self.tunnel.sock);
        if let Some(mut listener) = self.listener.take() {
            let _ = self.poll.registry().deregister(&mut listener);
        }
        self.drain_deadline = Some(Instant::now() + TERMINAL_DRAIN_TIMEOUT);
        let mut health = self.health.lock().unwrap_or_else(|e| e.into_inner());
        health.draining = true;
        health.recovering = false;
        self.recovery_deadline = None;
        drop(health);
        crate::emit_diagnostic_event(
            self.engine_id.load(Ordering::Acquire),
            "draining",
            "receive_terminal",
            self.terminal.as_ref(),
        );
    }

    fn update_progress(&mut self) -> io::Result<()> {
        let now = Instant::now();
        if self.terminal.is_none()
            && now.duration_since(self.last_progress) > PROGRESS_TIMEOUT
            && self.recovery_deadline.is_none()
        {
            self.recovery_deadline = Some(now + RECOVERY_TIMEOUT);
            self.last_heartbeat = now - HEARTBEAT_INTERVAL;
            self.health
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .recovering = true;
            // 合法网关可以不回心跳；恢复必须发起实际 DNS 探活，不能仅等待心跳回复。
            self.start_probe(&self.probe_host.clone(), PROBE_TIMEOUT, None, false, true)?;
            crate::emit_event(
                self.engine_id.load(Ordering::Acquire),
                "unhealthy",
                "scheduler_stall",
            );
        }
        self.last_progress = now;
        let mut health = self.health.lock().unwrap_or_else(|e| e.into_inner());
        health.progress = now;
        health.loop_iterations = health.loop_iterations.saturating_add(1);
        Ok(())
    }

    fn poll_finished(&mut self, expected: Instant, interrupted: bool) {
        if interrupted || Instant::now() <= expected + PROGRESS_TIMEOUT {
            self.last_progress = Instant::now();
        }
    }

    fn command(&mut self, command: Command) -> io::Result<()> {
        match command {
            Command::Probe(host, timeout, reply) => {
                self.start_probe(&host, timeout, Some(reply), false, false)
            }
            #[cfg(test)]
            Command::SimulateSuspend(reply) => {
                self.last_received = Instant::now() - Duration::from_secs(40);
                self.last_progress = self.last_received;
                self.health
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .received = self.last_received;
                self.update_progress()?;
                let _ = reply.send(());
                Ok(())
            }
        }
    }

    fn advance_probe(&mut self) -> io::Result<()> {
        if self.terminal.is_some() {
            if let Some(probe) = self.probe.take() {
                self.sockets
                    .get_mut::<dns::Socket>(self.dns)
                    .cancel_query(probe.query);
                for reply in probe.replies {
                    let _ = reply.send(Err(error(
                        io::ErrorKind::ConnectionAborted,
                        "VPN 已进入排空",
                    )));
                }
            }
            return Ok(());
        }
        if let Some(probe) = self.probe.as_ref() {
            let result = self
                .sockets
                .get_mut::<dns::Socket>(self.dns)
                .get_query_result(probe.query);
            let pending = matches!(result, Err(dns::GetQueryResultError::Pending));
            // 完整的隧道数据或有效 DNS 拒绝响应都能证明链路活着，避免只因某个目标 DNS 失败误杀。
            let answered = !pending || self.decoder.completed_frames() > probe.observed_frames;
            if answered || Instant::now() >= probe.deadline {
                let probe = self.probe.take().expect("探活存在");
                if pending {
                    self.sockets
                        .get_mut::<dns::Socket>(self.dns)
                        .cancel_query(probe.query);
                }
                for reply in probe.replies {
                    let _ = reply.send(if answered {
                        Ok(())
                    } else {
                        Err(error(io::ErrorKind::TimedOut, "VPN DNS 探活超时"))
                    });
                }
                if !answered && (probe.blackhole || probe.recovery) {
                    self.exit_code = Some(
                        if probe.blackhole {
                            "blackhole_detected"
                        } else {
                            "recovery_timeout"
                        }
                        .into(),
                    );
                    return Err(error(io::ErrorKind::TimedOut, "VPN 内置 DNS 探活失败"));
                }
                if answered {
                    self.consecutive_timeouts = 0;
                }
            }
        }
        Ok(())
    }

    fn poll_timeout(&mut self, timestamp: NetInstant) -> Duration {
        if self.budget_exhausted {
            return Duration::ZERO;
        }
        let now = Instant::now();
        let mut deadline = if self.terminal.is_some() {
            self.drain_deadline.expect("终态排空期限存在")
        } else {
            self.last_heartbeat + HEARTBEAT_INTERVAL
        };
        if let Some(recovery) = self.recovery_deadline {
            deadline = deadline.min(recovery);
        }
        if let Some(probe) = self.probe.as_ref() {
            deadline = deadline.min(probe.deadline);
        }
        for flow in &self.flows {
            deadline = deadline.min(if flow.established || flow.reject {
                flow.touched + Duration::from_secs(180)
            } else {
                flow.deadline
            });
            if self.terminal.is_none()
                && self.probe.is_none()
                && flow.authorized
                && !flow.established
                && !flow.reject
            {
                if let Some(started) = flow.connect_started {
                    deadline = deadline
                        .min((started + BLACKHOLE_IDLE).max(self.last_received + BLACKHOLE_IDLE));
                }
            }
        }
        let timer = deadline.saturating_duration_since(now);
        // 终态无心跳、无发送；写背压时协议栈立即重发也只能等 OS 写就绪，不能 poll(0) 空转。
        if self.terminal.is_some() || !self.device.can_transmit() {
            return timer;
        }
        self.interface
            .poll_delay(timestamp, &self.sockets)
            .map(|delay| Duration::from_millis(delay.total_millis()).min(timer))
            .unwrap_or(timer)
    }

    fn run(&mut self) -> io::Result<()> {
        while self.running.load(Ordering::Acquire) {
            self.budget_exhausted = false;
            self.update_progress()?;
            if self
                .recovery_deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
            {
                self.exit_code = Some("recovery_timeout".into());
                return Err(error(io::ErrorKind::TimedOut, "VPN 恢复期限耗尽"));
            }
            for _ in 0..MAX_CONNECTIONS {
                match self.commands.try_recv() {
                    Ok(command) => self.command(command)?,
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
                }
            }
            self.accept_clients()?;
            self.pump_tls()?;
            let timestamp = NetInstant::from_millis(self.started.elapsed().as_millis() as i64);
            self.interface
                .poll(timestamp, &mut self.device, &mut self.sockets);
            self.advance_probe()?;
            self.check_blackhole()?;
            let mut flows = std::mem::take(&mut self.flows);
            for index in (0..flows.len()).rev() {
                match self.advance(&mut flows[index]) {
                    Ok(true) => {}
                    Ok(false) | Err(_) => self.remove(flows.swap_remove(index)),
                }
            }
            self.flows = flows;
            self.interface
                .poll(timestamp, &mut self.device, &mut self.sockets);
            self.pump_tls()?;
            if self.terminal.is_some()
                && (self.flows.is_empty()
                    || self
                        .drain_deadline
                        .is_some_and(|deadline| Instant::now() >= deadline))
            {
                return Err(self.terminal.take().expect("终态存在"));
            }
            let interest = if self.tunnel.conn.wants_write() {
                Interest::READABLE.add(Interest::WRITABLE)
            } else {
                Interest::READABLE
            };
            if self.terminal.is_none() && interest != self.tunnel_interest {
                self.poll
                    .registry()
                    .reregister(&mut self.tunnel.sock, TUNNEL, interest)?;
                self.tunnel_interest = interest;
            }
            // 接收队列还可被协议栈消费时继续驱动，不能把已解密的尾包留到下一次OS边沿。
            if !self.device.incoming.is_empty() && self.device.can_transmit() {
                self.budget_exhausted = true;
            }
            let timeout = self.poll_timeout(timestamp);
            let expected = Instant::now() + timeout;
            match self.poll.poll(&mut self.events, Some(timeout)) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                    self.poll_finished(expected, true);
                    continue;
                }
                Err(e) => return Err(e),
            }
            // 正常 Poll 和 EINTR 均补偿等待时间，真正超出预计期限才触发调度恢复。
            self.poll_finished(expected, false);
        }
        Ok(())
    }
}

impl Drop for Runner {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Release);
        for flow in &mut self.flows {
            let _ = Self::drain_local(flow, &mut self.io_buffer);
        }
        let _ = self.tunnel.sock.shutdown(Shutdown::Both);
    }
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
