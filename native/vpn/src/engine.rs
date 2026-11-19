//! 单线程事件循环管理 TLS、用户态网络栈及回环桥接，避免每包跨 FFI。

use crate::{frame, link::IpLink};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
use serde_json::{json, Value};
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::{dns, tcp};
use smoltcp::time::{Duration as NetDuration, Instant as NetInstant};
use smoltcp::wire::{DnsQueryType, HardwareAddress, IpAddress, IpCidr};
use std::collections::{HashMap, VecDeque};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, Shutdown, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const MAX_CONNECTIONS: usize = 64;
const BUFFER_SIZE: usize = 64 * 1024;
const OPEN_TIMEOUT: Duration = Duration::from_secs(20);
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
        let progress = self.progress.lock().unwrap();
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
        match receiver.recv_timeout(Duration::from_millis(50)) {
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

pub struct Bridge {
    pub port: u16,
    pub secret: String,
}

enum Command {
    Open(
        String,
        u16,
        Arc<OpenControl>,
        SyncSender<io::Result<Bridge>>,
    ),
    Probe(String, SyncSender<io::Result<()>>),
    #[cfg(test)]
    SimulateSuspend(SyncSender<()>),
}

struct OpenControl {
    cancelled: AtomicBool,
    created: Instant,
}

#[derive(Clone)]
pub struct Handle {
    commands: SyncSender<Command>,
    running: Arc<AtomicBool>,
    exit_reason: Arc<Mutex<Option<String>>>,
    health: Arc<Mutex<Health>>,
    socket: Arc<TcpStream>,
    opens: Arc<Mutex<HashMap<u64, Arc<OpenControl>>>>,
    next_open: Arc<AtomicUsize>,
}

impl Handle {
    pub fn alive(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    pub fn exit_reason(&self) -> Option<String> {
        self.exit_reason
            .lock()
            .ok()
            .and_then(|reason| reason.clone())
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::Release);
        let _ = self.socket.shutdown(Shutdown::Both);
    }

    pub fn status(&self) -> Value {
        let health = self.health.lock().unwrap();
        let alive = self.alive();
        json!({"alive": alive, "healthy": alive && health.progress.elapsed() < PROGRESS_TIMEOUT
            && health.received.elapsed() < RECEIVE_TIMEOUT && !health.recovering,
            "needsProbe": alive && (health.received.elapsed() >= RECEIVE_TIMEOUT || health.recovering
                || health.progress.elapsed() >= PROGRESS_TIMEOUT),
            "exitReason": self.exit_reason(), "loopIdleMs": health.progress.elapsed().as_millis(),
            "rxIdleMs": health.received.elapsed().as_millis(), "heartbeats": health.heartbeats,
            "receivedBytes": health.received_bytes, "recovering": health.recovering,
            "dnsTimeouts": health.dns_timeouts, "tcpTimeouts": health.tcp_timeouts,
            "loopIterations": health.loop_iterations})
    }

    pub fn probe(&self, host: String) -> io::Result<()> {
        let (sender, receiver) = mpsc::sync_channel(1);
        self.commands
            .try_send(Command::Probe(host, sender))
            .map_err(|_| error(io::ErrorKind::WouldBlock, "VPN 探测队列不可用"))?;
        receiver
            .recv_timeout(Duration::from_secs(4))
            .map_err(|_| error(io::ErrorKind::TimedOut, "VPN 恢复探测超时"))?
    }

    pub fn prepare_open(&self) -> io::Result<u64> {
        let mut opens = self.opens.lock().unwrap();
        opens.retain(|_, control| {
            if control.created.elapsed() < Duration::from_secs(30) {
                return true;
            }
            control.cancelled.store(true, Ordering::Release);
            false
        });
        if opens.len() >= MAX_CONNECTIONS {
            return Err(error(io::ErrorKind::WouldBlock, "VPN 目标连接登记已达上限"));
        }
        let id = self.next_open.fetch_add(1, Ordering::Relaxed) as u64;
        opens.insert(
            id,
            Arc::new(OpenControl {
                cancelled: AtomicBool::new(false),
                created: Instant::now(),
            }),
        );
        Ok(id)
    }

    pub fn cancel_open(&self, id: u64) {
        if let Some(control) = self.opens.lock().unwrap().remove(&id) {
            control.cancelled.store(true, Ordering::Release);
        }
    }

    pub fn release_open(&self, id: u64) {
        self.opens.lock().unwrap().remove(&id);
    }

    pub fn open(&self, host: String, port: u16) -> io::Result<Bridge> {
        let id = self.prepare_open()?;
        let result = self.open_reserved(host, port, id);
        // 旧 ABI 不暴露取消编号，Flow 自行保留控制token，注册表不保留孤立编号。
        self.opens.lock().unwrap().remove(&id);
        result
    }

    pub fn open_reserved(&self, host: String, port: u16, id: u64) -> io::Result<Bridge> {
        if !self.alive() {
            return Err(error(io::ErrorKind::NotConnected, "VPN 隧道已断开"));
        }
        if host.is_empty() || host.len() > 253 || !host.is_ascii() || host.contains(':') {
            return Err(error(
                io::ErrorKind::InvalidInput,
                "VPN 仅支持 IPv4 地址和 ASCII 域名",
            ));
        }
        let control = self
            .opens
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| error(io::ErrorKind::ConnectionAborted, "VPN 目标连接已取消"))?;
        if control.cancelled.load(Ordering::Acquire) {
            return Err(error(
                io::ErrorKind::ConnectionAborted,
                "VPN 目标连接已取消",
            ));
        }
        let (sender, receiver) = mpsc::sync_channel(1);
        self.commands
            .try_send(Command::Open(host, port, control, sender))
            .map_err(|_| error(io::ErrorKind::WouldBlock, "VPN 连接队列已满或隧道已关闭"))?;
        receiver
            .recv_timeout(OPEN_TIMEOUT + Duration::from_secs(1))
            .map_err(|failure| match failure {
                mpsc::RecvTimeoutError::Timeout => {
                    error(io::ErrorKind::TimedOut, "VPN 建立目标连接超时")
                }
                mpsc::RecvTimeoutError::Disconnected => {
                    error(io::ErrorKind::ConnectionAborted, "VPN 隧道已断开")
                }
            })?
    }
}

pub fn start_controlled(
    value: &Value,
    control: Arc<StartControl>,
) -> io::Result<(Handle, frame::AuthInfo)> {
    start_with_control(
        value,
        RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned()),
        control,
    )
}

#[cfg(test)]
fn start_with_roots(value: &Value, roots: RootCertStore) -> io::Result<(Handle, frame::AuthInfo)> {
    static START_TEST: Mutex<()> = Mutex::new(());
    let _starting = START_TEST.lock().unwrap_or_else(|error| error.into_inner());
    start_with_control(value, roots, Arc::new(StartControl::new()))
}

fn start_with_control(
    value: &Value,
    roots: RootCertStore,
    control: Arc<StartControl>,
) -> io::Result<(Handle, frame::AuthInfo)> {
    start_with_deadline(value, roots, control, START_TIMEOUT)
}

fn start_with_deadline(
    value: &Value,
    roots: RootCertStore,
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
    let user = field("user")?;
    let token = field("token")?;
    let port = value["port"]
        .as_u64()
        .filter(|p| (1..=65535).contains(p))
        .ok_or_else(|| error(io::ErrorKind::InvalidInput, "VPN 网关端口不合法"))?
        as u16;
    let server_name = rustls::pki_types::ServerName::try_from(host.to_owned())
        .map_err(|_| error(io::ErrorKind::InvalidInput, "VPN 网关主机名不合法"))?;
    let tls =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(io::Error::other)?
            .with_root_certificates(roots)
            .with_no_client_auth();
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
    *control.socket.lock().unwrap() = Some(raw.try_clone()?);
    control.check(deadline)?;
    let mut connection =
        ClientConnection::new(Arc::new(tls), server_name).map_err(io::Error::other)?;
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
    control.socket.lock().unwrap().take();
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
        dns_timeouts: 0,
        tcp_timeouts: 0,
        loop_iterations: 0,
    }));
    let handle = Handle {
        commands: sender,
        running: running.clone(),
        exit_reason: exit_reason.clone(),
        health: health.clone(),
        socket: Arc::new(tunnel.sock.try_clone()?),
        opens: Arc::new(Mutex::new(HashMap::new())),
        next_open: Arc::new(AtomicUsize::new(1)),
    };
    let mut runner = Runner::new(tunnel, &info, receiver, running.clone(), health)?;
    thread::Builder::new()
        .name("nuist-vpn".into())
        .spawn(move || {
            // 仅保留错误类别，绝不保存服务端数据；Dart 下次检查状态时输出 debug 日志。
            let outcome = runner.run();
            if let Ok(mut reason) = exit_reason.lock() {
                *reason = Some(match outcome {
                    Ok(()) => "Stopped".to_owned(),
                    Err(error) => format!("{:?}", error.kind()),
                });
            }
            running.store(false, Ordering::Release);
        })?;
    control.stage("完成");
    Ok((handle, info))
}

struct Flow {
    control: Arc<OpenControl>,
    query: Option<dns::QueryHandle>,
    tcp: Option<SocketHandle>,
    port: u16,
    reply: Option<SyncSender<io::Result<Bridge>>>,
    deadline: Instant,
    listener: Option<TcpListener>,
    local: Option<TcpStream>,
    secret: [u8; 32],
    received_secret: Vec<u8>,
    authenticated: bool,
    local_eof: bool,
    remote_eof: bool,
    accepted_at: Instant,
    touched: Instant,
}

struct Runner {
    tunnel: StreamOwned<ClientConnection, TcpStream>,
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
    probe: Option<(dns::QueryHandle, Instant, u64, SyncSender<io::Result<()>>)>,
}

impl Runner {
    fn new(
        tunnel: StreamOwned<ClientConnection, TcpStream>,
        info: &frame::AuthInfo,
        commands: Receiver<Command>,
        running: Arc<AtomicBool>,
        health: Arc<Mutex<Health>>,
    ) -> io::Result<Self> {
        let mut device = IpLink::default();
        let mut config = Config::new(HardwareAddress::Ip);
        config.random_seed = u64::from_le_bytes(random()?);
        let mut interface = Interface::new(config, &mut device, NetInstant::from_millis(0));
        interface.update_ip_addrs(|addresses| {
            addresses
                .push(IpCidr::new(IpAddress::Ipv4(info.address), 32))
                .unwrap();
        });
        // medium-ip 不需要 ARP；此路由使所有目标交给唯一的隧道链路。
        interface
            .routes_mut()
            .add_default_ipv4_route(info.address)
            .map_err(|_| error(io::ErrorKind::Other, "无法设置隧道路由"))?;
        let mut sockets = SocketSet::new(Vec::new());
        // 这里的 127.0.0.1 属于隧道对端，绝不交给系统解析器。
        let queries: Vec<_> = (0..MAX_CONNECTIONS).map(|_| None).collect();
        let dns = sockets.add(dns::Socket::new(&[IpAddress::Ipv4(info.dns)], queries));
        let now = Instant::now();
        Ok(Self {
            tunnel,
            device,
            interface,
            sockets,
            dns,
            commands,
            running,
            flows: Vec::new(),
            // 不同隧道避免从完全相同的源端口序列开始，仍检查存活 socket。
            local_port: 49152 + (u16::from_le_bytes(random()?) % 16384),
            decoder: frame::Decoder::default(),
            output: VecDeque::new(),
            output_offset: 0,
            started: now,
            last_received: now,
            // 握手后首轮立即发送，之后按固定周期保活。
            last_heartbeat: now - HEARTBEAT_INTERVAL,
            heartbeat: 0,
            health,
            last_progress: now,
            recovery_deadline: None,
            io_progress: 0,
            terminal: None,
            drain_deadline: None,
            probe: None,
        })
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

    fn accept_command(
        &mut self,
        host: String,
        port: u16,
        control: Arc<OpenControl>,
        reply: SyncSender<io::Result<Bridge>>,
    ) -> io::Result<()> {
        if self.flows.len() >= MAX_CONNECTIONS {
            let _ = reply.send(Err(error(
                io::ErrorKind::WouldBlock,
                "VPN 并发连接数已达上限",
            )));
            return Ok(());
        }
        let mut flow = Flow {
            control,
            query: None,
            tcp: None,
            port,
            reply: Some(reply),
            deadline: Instant::now() + OPEN_TIMEOUT,
            listener: None,
            local: None,
            secret: random()?,
            received_secret: Vec::new(),
            authenticated: false,
            local_eof: false,
            remote_eof: false,
            accepted_at: Instant::now(),
            touched: Instant::now(),
        };
        if let Ok(ip) = host.parse::<Ipv4Addr>() {
            match self.connect_tcp(IpAddress::Ipv4(ip), port) {
                Ok(tcp) => flow.tcp = Some(tcp),
                Err(e) => {
                    self.remove(flow, Some(e));
                    return Ok(());
                }
            }
        } else {
            match self.sockets.get_mut::<dns::Socket>(self.dns).start_query(
                self.interface.context(),
                &host,
                DnsQueryType::A,
            ) {
                Ok(query) => flow.query = Some(query),
                Err(_) => {
                    let _ = flow.reply.take().unwrap().send(Err(error(
                        io::ErrorKind::InvalidInput,
                        "无法创建隧道 DNS 查询",
                    )));
                    return Ok(());
                }
            }
        }
        self.flows.push(flow);
        Ok(())
    }

    fn advance(&mut self, flow: &mut Flow) -> io::Result<bool> {
        let now = Instant::now();
        if !flow.authenticated && flow.control.cancelled.load(Ordering::Acquire) {
            return Err(error(
                io::ErrorKind::ConnectionAborted,
                "VPN 目标连接已取消",
            ));
        }
        if self.terminal.is_some() && !flow.authenticated {
            return Ok(false);
        }
        if !flow.authenticated && now >= flow.deadline {
            let mut health = self.health.lock().unwrap();
            let stage = if flow.query.is_some() {
                health.dns_timeouts += 1;
                "VPN 目标 DNS 超时"
            } else if flow.reply.is_some() {
                health.tcp_timeouts += 1;
                "VPN 目标 TCP 握手超时"
            } else {
                "VPN 回环鉴权超时"
            };
            return Err(error(io::ErrorKind::TimedOut, stage));
        }
        if let Some(query) = flow.query {
            match self
                .sockets
                .get_mut::<dns::Socket>(self.dns)
                .get_query_result(query)
            {
                Ok(addresses) => {
                    flow.query = None;
                    let ip = *addresses
                        .first()
                        .ok_or_else(|| error(io::ErrorKind::NotFound, "隧道 DNS 未返回 IPv4"))?;
                    flow.tcp = Some(self.connect_tcp(ip, flow.port)?);
                }
                Err(dns::GetQueryResultError::Pending) => return Ok(true),
                Err(_) => {
                    flow.query = None;
                    return Err(error(io::ErrorKind::NotFound, "隧道 DNS 查询失败"));
                }
            }
        }
        let socket = self.sockets.get_mut::<tcp::Socket>(flow.tcp.unwrap());
        if socket.state() == tcp::State::Closed && self.terminal.is_none() {
            return Err(error(
                io::ErrorKind::ConnectionAborted,
                "隧道内 TCP 连接已关闭",
            ));
        }
        if flow.reply.is_some() && socket.state() == tcp::State::Established {
            let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
            listener.set_nonblocking(true)?;
            let bridge = Bridge {
                port: listener.local_addr()?.port(),
                secret: flow
                    .secret
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
            };
            flow.listener = Some(listener);
            flow.deadline = now + Duration::from_secs(10);
            if flow.reply.take().unwrap().send(Ok(bridge)).is_err() {
                return Ok(false);
            }
        }
        if flow.local.is_none() {
            if let Some(listener) = &flow.listener {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(true)?;
                        stream.set_nodelay(true)?;
                        flow.local = Some(stream);
                        flow.accepted_at = now;
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                    Err(e) => return Err(e),
                }
            }
        }
        let Some(local) = &mut flow.local else {
            return Ok(true);
        };
        if !flow.authenticated {
            let mut bytes = [0; 32];
            match local.read(&mut bytes[..32 - flow.received_secret.len()]) {
                Ok(0) => {
                    flow.local = None;
                    flow.received_secret.clear();
                    return Ok(true);
                }
                Ok(count) => flow.received_secret.extend_from_slice(&bytes[..count]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => {
                    flow.local = None;
                    flow.received_secret.clear();
                    return Ok(true);
                }
            }
            if flow.received_secret.len() == 32 {
                let difference = flow
                    .received_secret
                    .iter()
                    .zip(flow.secret)
                    .fold(0u8, |diff, (a, b)| diff | (a ^ b));
                if difference != 0 {
                    flow.local = None;
                    flow.received_secret.clear();
                    return Ok(true);
                }
                flow.authenticated = true;
                flow.listener = None;
                flow.secret.fill(0);
                flow.received_secret.fill(0);
            } else {
                if now.duration_since(flow.accepted_at) > Duration::from_secs(2) {
                    flow.local = None;
                    flow.received_secret.clear();
                }
                return Ok(true);
            }
        }
        if self.terminal.is_none() && !flow.local_eof && socket.can_send() {
            let mut bytes = [0; 16 * 1024];
            let capacity = (socket.send_capacity() - socket.send_queue()).min(bytes.len());
            match local.read(&mut bytes[..capacity]) {
                Ok(0) => {
                    flow.local_eof = true;
                    socket.close();
                }
                Ok(count) => {
                    let sent = socket
                        .send_slice(&bytes[..count])
                        .map_err(|_| error(io::ErrorKind::BrokenPipe, "隧道写入失败"))?;
                    if sent != count {
                        return Err(error(io::ErrorKind::WriteZero, "隧道发送缓冲不足"));
                    }
                    flow.touched = now;
                    self.io_progress = self.io_progress.wrapping_add(1);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e),
            }
        }
        if socket.can_recv() {
            let written = socket
                .recv(|bytes| match local.write(bytes) {
                    Ok(count) => (count, Ok(count)),
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => (0, Ok(0)),
                    Err(e) => (0, Err(e)),
                })
                .map_err(|_| error(io::ErrorKind::BrokenPipe, "隧道读取失败"))??;
            if written > 0 {
                flow.touched = now;
                self.io_progress = self.io_progress.wrapping_add(1);
            }
        }
        if !socket.may_recv() && !flow.remote_eof {
            let _ = local.shutdown(Shutdown::Write);
            flow.remote_eof = true;
        }
        if self.terminal.is_some() && !socket.can_recv() {
            // 所有已收的尾字节交付后关闭回环，不能在外层 TLS 已断时等待远端 FIN。
            let _ = local.shutdown(Shutdown::Write);
            return Ok(false);
        }
        // 保留 socket 到 FIN 握手完成；过早 abort/remove 会丢掉尚未发出的 FIN/ACK。
        Ok(now.duration_since(flow.touched) < Duration::from_secs(180))
    }

    fn remove(&mut self, mut flow: Flow, failure: Option<io::Error>) {
        if let Some(query) = flow.query.take() {
            self.sockets
                .get_mut::<dns::Socket>(self.dns)
                .cancel_query(query);
        }
        if let Some(handle) = flow.tcp.take() {
            self.sockets.get_mut::<tcp::Socket>(handle).abort();
            self.sockets.remove(handle);
        }
        if let Some(reply) = flow.reply.take() {
            let _ = reply.send(Err(failure.unwrap_or_else(|| {
                error(io::ErrorKind::ConnectionAborted, "VPN 连接已关闭")
            })));
        }
    }

    fn pump_tls(&mut self) -> io::Result<()> {
        if self.terminal.is_some() {
            return Ok(());
        }
        // 每轮设上限，防止一条大下载饿死连接命令和心跳。
        for _ in 0..16 {
            // 先消耗已解密的数据：握手读取可能已把后续报文一并收进 rustls。
            let mut bytes = [0; 16 * 1024];
            loop {
                // 最小 IPv4 帧为 8 字节头 + 20 字节包。为 Decoder 中可能
                // 已有的半帧预留一个槽，不从可靠 TLS 流主动读出随后要丢弃的包。
                let capacity = self.device.receive_capacity();
                if capacity < 2 {
                    break;
                }
                let limit = bytes.len().min((capacity - 1) * 28);
                match self.tunnel.conn.reader().read(&mut bytes[..limit]) {
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
                        for packet in self.decoder.push(&bytes[..count])? {
                            self.device.inject(packet);
                        }
                        let mut health = self.health.lock().unwrap();
                        health.received_bytes += count as u64;
                        if completed != self.decoder.completed_frames() {
                            self.last_received = Instant::now();
                            health.received = self.last_received;
                            health.recovering = false;
                            self.recovery_deadline = None;
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
        // 部分合法网关不回复保活帧；空闲无数据不等于关闭，留待请求/前台
        // 发起一次有界 DNS 探测。真正 TLS/TCP EOF 仍走终态清理。
        if self.last_heartbeat.elapsed() >= HEARTBEAT_INTERVAL && self.output.len() < 256 {
            self.heartbeat = self.heartbeat.wrapping_add(1);
            self.health.lock().unwrap().heartbeats = self.heartbeat;
            self.output
                .push_back(frame::heartbeat(self.heartbeat).to_vec());
            self.last_heartbeat = Instant::now();
        }
        while self.output.len() < 256 {
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
        for _ in 0..32 {
            if !self.tunnel.conn.wants_write() {
                break;
            }
            match self.tunnel.conn.write_tls(&mut self.tunnel.sock) {
                Ok(0) => return Err(error(io::ErrorKind::WriteZero, "VPN 写入中断")),
                Ok(_) => self.io_progress = self.io_progress.wrapping_add(1),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    fn receive_terminal(&mut self, error: io::Error) {
        self.terminal = Some(error);
        self.drain_deadline = Some(Instant::now() + TERMINAL_DRAIN_TIMEOUT);
        self.health.lock().unwrap().recovering = true;
    }

    fn update_progress(&mut self) {
        let now = Instant::now();
        if now.duration_since(self.last_progress) > PROGRESS_TIMEOUT
            && self.recovery_deadline.is_none()
        {
            // 调度停顿不能直接当成网关死亡；先读缓存并发一次心跳探测。
            self.recovery_deadline = Some(now + RECOVERY_TIMEOUT);
            self.last_heartbeat = now - HEARTBEAT_INTERVAL;
            self.health.lock().unwrap().recovering = true;
        }
        self.last_progress = now;
        let mut health = self.health.lock().unwrap();
        health.progress = now;
        health.loop_iterations = health.loop_iterations.saturating_add(1);
    }

    fn command(&mut self, command: Command) -> io::Result<()> {
        match command {
            Command::Open(host, port, control, reply) => {
                self.accept_command(host, port, control, reply)
            }
            Command::Probe(host, reply) => {
                if self.terminal.is_some() || self.probe.is_some() {
                    let _ = reply.send(Err(error(io::ErrorKind::WouldBlock, "VPN 探测不可用")));
                    return Ok(());
                }
                match self.sockets.get_mut::<dns::Socket>(self.dns).start_query(
                    self.interface.context(),
                    &host,
                    DnsQueryType::A,
                ) {
                    Ok(query) => {
                        self.probe = Some((
                            query,
                            Instant::now() + Duration::from_secs(3),
                            self.decoder.completed_frames(),
                            reply,
                        ));
                    }
                    Err(_) => {
                        let _ = reply.send(Err(error(
                            io::ErrorKind::InvalidInput,
                            "VPN 探测主机不合法",
                        )));
                    }
                }
                Ok(())
            }
            #[cfg(test)]
            Command::SimulateSuspend(reply) => {
                self.last_received = Instant::now() - Duration::from_secs(40);
                self.last_progress = self.last_received;
                self.health.lock().unwrap().received = self.last_received;
                self.update_progress();
                let _ = reply.send(());
                Ok(())
            }
        }
    }

    fn run(&mut self) -> io::Result<()> {
        let mut idle_rounds = 0u32;
        let mut pending_command = None;
        while self.running.load(Ordering::Acquire) {
            self.update_progress();
            let progress = self.io_progress;
            if let Some(command) = pending_command.take() {
                match command {
                    Command::Open(_, _, _, reply) if self.terminal.is_some() => {
                        let _ = reply.send(Err(error(
                            io::ErrorKind::ConnectionAborted,
                            "VPN 隧道已断开",
                        )));
                    }
                    command => self.command(command)?,
                }
            }
            for _ in 0..MAX_CONNECTIONS {
                match self.commands.try_recv() {
                    Ok(Command::Open(_, _, _, reply)) if self.terminal.is_some() => {
                        let _ = reply.send(Err(error(
                            io::ErrorKind::ConnectionAborted,
                            "VPN 隧道已断开",
                        )));
                    }
                    Ok(command) => self.command(command)?,
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
                }
            }
            self.pump_tls()?;
            if let Some((query, deadline, completed, _)) = self.probe.as_ref() {
                let success = self.decoder.completed_frames() != *completed;
                if success || Instant::now() >= *deadline || self.terminal.is_some() {
                    let query = *query;
                    let (_, _, _, reply) = self.probe.take().unwrap();
                    self.sockets
                        .get_mut::<dns::Socket>(self.dns)
                        .cancel_query(query);
                    let _ = reply.send(if success {
                        Ok(())
                    } else {
                        Err(error(io::ErrorKind::TimedOut, "VPN DNS 恢复探测超时"))
                    });
                }
            }
            let timestamp = NetInstant::from_millis(self.started.elapsed().as_millis() as i64);
            self.interface
                .poll(timestamp, &mut self.device, &mut self.sockets);
            let mut flows = std::mem::take(&mut self.flows);
            // 倒序删除保留原有 Vec 容量，避免每轮重建所有存活连接的数组。
            for index in (0..flows.len()).rev() {
                match self.advance(&mut flows[index]) {
                    Ok(true) => {}
                    Ok(false) => self.remove(flows.swap_remove(index), None),
                    Err(e) => self.remove(flows.swap_remove(index), Some(e)),
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
                return Err(self.terminal.take().unwrap());
            }
            if self.io_progress != progress {
                idle_rounds = 0;
                // 有数据进展时继续搬运，协议栈和 TLS 的缓冲负责背压。
                // 每轮已限制工作量；让出调度机会，避免固定休眠限制上传吞吐。
                thread::yield_now();
                continue;
            }
            idle_rounds = idle_rounds.saturating_add(1).min(6);
            let ceiling = if self.flows.is_empty() { 50 } else { 25 };
            let mut wait = Duration::from_millis((1u64 << idle_rounds).min(ceiling));
            let now = NetInstant::from_millis(self.started.elapsed().as_millis() as i64);
            if let Some(delay) = self.interface.poll_delay(now, &self.sockets) {
                // poll_at 为 Now 却无法推进时，链路可能正在背压，继续退避。
                // 正数期限仍需准时处理，避免延迟 ACK、重传与 keepalive。
                if delay.total_millis() > 0 {
                    wait = wait.min(Duration::from_millis(delay.total_millis()));
                }
            }
            // 连接命令直接唤醒等待，无需等下一次轮询。
            match self.commands.recv_timeout(wait) {
                Ok(command) => pending_command = Some(command),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
            }
        }
        Ok(())
    }
}

impl Drop for Runner {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Release);
        let _ = self.tunnel.sock.shutdown(Shutdown::Both);
    }
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
