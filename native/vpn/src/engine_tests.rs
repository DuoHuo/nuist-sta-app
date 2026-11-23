//! 合成 TLS 网关和第二个用户态 IP 栈，验证真实 DNS/TCP/回环数据通路。
use super::*;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{ServerConfig, ServerConnection};
use serde_json::json;
use smoltcp::socket::udp;

const CERT: &[u8] = include_bytes!("../../../test/fixtures/vpn/certificate.der");
const KEY: &[u8] = include_bytes!("../../../test/fixtures/vpn/private_key.der");

fn proxy_request(
    handle: &Handle,
    host: &str,
    port: u16,
    auth: &str,
) -> io::Result<(TcpStream, u16)> {
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, handle.proxy_port))?;
    stream.set_read_timeout(Some(Duration::from_secs(12)))?;
    stream.set_write_timeout(Some(Duration::from_secs(12)))?;
    stream.write_all(format!("CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\nProxy-Authorization: {auth}\r\n\r\n").as_bytes())?;
    let mut headers = Vec::new();
    while !headers.ends_with(b"\r\n\r\n") {
        let mut byte = [0u8];
        stream
            .read_exact(&mut byte)
            .map_err(|_| error(io::ErrorKind::ConnectionAborted, "代理连接已关闭"))?;
        headers.push(byte[0]);
        if headers.len() > 8192 {
            return Err(error(io::ErrorKind::InvalidData, "代理响应过长"));
        }
    }
    let status = std::str::from_utf8(&headers)
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    Ok((stream, status))
}

fn connect(handle: &Handle, host: &str, port: u16) -> io::Result<TcpStream> {
    let (stream, status) = proxy_request(handle, host, port, &authorization(&handle.proxy_token))?;
    if status != 200 {
        return Err(error(io::ErrorKind::ConnectionAborted, "代理拒绝目标连接"));
    }
    Ok(stream)
}

const TARGET: Ipv4Addr = Ipv4Addr::new(10, 20, 30, 40);
const CLIENT: Ipv4Addr = Ipv4Addr::new(10, 20, 30, 41);

struct Gateway {
    port: u16,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<(usize, bool)>>,
}

impl Gateway {
    fn new() -> Self {
        Self::with_terminal_after(None)
    }

    fn without_heartbeat_replies() -> Self {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker = thread::spawn(move || serve(listener, stopped, None, false, false, false));
        Self {
            port,
            stop,
            worker: Some(worker),
        }
    }

    fn with_terminal_after(terminal_after: Option<(usize, bool)>) -> Self {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker =
            thread::spawn(move || serve(listener, stopped, terminal_after, true, false, false));
        Self {
            port,
            stop,
            worker: Some(worker),
        }
    }

    fn blackhole() -> Self {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker = thread::spawn(move || serve(listener, stopped, None, false, true, false));
        Self {
            port,
            stop,
            worker: Some(worker),
        }
    }

    fn tcp_blackhole() -> Self {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker = thread::spawn(move || serve(listener, stopped, None, false, false, true));
        Self {
            port,
            stop,
            worker: Some(worker),
        }
    }

    fn finish(mut self) -> (usize, bool) {
        self.stop.store(true, Ordering::Release);
        self.worker.take().unwrap().join().unwrap()
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn serve(
    listener: TcpListener,
    stop: Arc<AtomicBool>,
    terminal_after: Option<(usize, bool)>,
    heartbeat_replies: bool,
    blackhole: bool,
    tcp_blackhole: bool,
) -> (usize, bool) {
    listener.set_nonblocking(true).unwrap();
    let raw = loop {
        if stop.load(Ordering::Acquire) {
            return (0, false);
        }
        match listener.accept() {
            Ok((raw, _)) => break raw,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(2))
            }
            Err(e) => panic!("{e}"),
        }
    };
    raw.set_nonblocking(false).unwrap();
    raw.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    raw.set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let config =
        ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(CERT)],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(KEY)),
            )
            .unwrap();
    let mut tls = StreamOwned::new(ServerConnection::new(Arc::new(config)).unwrap(), raw);
    let mut header = [0; 12];
    tls.read_exact(&mut header).unwrap();
    let mut body = vec![0; u16::from_be_bytes([header[2], header[3]]) as usize - 12];
    tls.read_exact(&mut body).unwrap();
    assert_eq!(
        [header.as_slice(), &body].concat(),
        frame::handshake("synthetic", "test-token").unwrap()
    );
    let mut response = vec![1, 2, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 11, 0, 4];
    response.extend_from_slice(&CLIENT.octets());
    response.extend_from_slice(&[36, 0, 9]);
    response.extend_from_slice(b"127.0.0.1");
    response.push(255);
    let length = response.len() as u16;
    response[2..4].copy_from_slice(&length.to_be_bytes());
    // 将控制帧与握手合并发送，覆盖 rustls 已缓存明文的情形。
    response.extend_from_slice(&[1, 2, 0, 8, 0, 0, 0, 0]);
    tls.write_all(&response).unwrap();
    tls.flush().unwrap();
    tls.sock.set_read_timeout(None).unwrap();
    tls.sock.set_nonblocking(true).unwrap();

    let mut device = IpLink::default();
    let mut config = Config::new(HardwareAddress::Ip);
    config.random_seed = 123;
    let mut iface = Interface::new(config, &mut device, NetInstant::from_millis(0));
    iface.update_ip_addrs(|ips| {
        ips.push(IpCidr::new(TARGET.into(), 24)).unwrap();
        ips.push(IpCidr::new(Ipv4Addr::LOCALHOST.into(), 8))
            .unwrap();
    });
    let mut sockets = SocketSet::new(Vec::new());
    let mut tcp = tcp::Socket::new(
        tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
        tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
    );
    tcp.listen((TARGET, 8080)).unwrap();
    let echo = sockets.add(tcp);
    let buffer = || udp::PacketBuffer::new(vec![udp::PacketMetadata::EMPTY; 4], vec![0; 2048]);
    let mut dns = udp::Socket::new(buffer(), buffer());
    dns.bind((Ipv4Addr::LOCALHOST, 53)).unwrap();
    let dns = sockets.add(dns);
    let started = Instant::now();
    let mut wire = Vec::new();
    let mut dropped_syn = false;
    let mut received = 0;
    let mut graceful = false;
    while !stop.load(Ordering::Acquire) && started.elapsed() < Duration::from_secs(70) {
        match tls.conn.read_tls(&mut tls.sock) {
            Ok(0) => break,
            Ok(_) => {
                tls.conn.process_new_packets().unwrap();
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(_) => break,
        }
        let mut bytes = [0; 16384];
        loop {
            match tls.conn.reader().read(&mut bytes) {
                Ok(0) => break,
                Ok(n) => wire.extend_from_slice(&bytes[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("{e}"),
            }
        }
        while wire.len() >= 12 {
            let size = u16::from_be_bytes([wire[2], wire[3]]) as usize;
            assert!(size >= 12);
            if wire.len() < size {
                break;
            }
            match wire[1] {
                4 => {
                    let packet = &wire[12..size];
                    // 丢掉第一个 TCP SYN，验证客户端能重传，而不是靠理想链路通过。
                    if blackhole
                        || (tcp_blackhole && packet[9] == 6)
                        || (packet[9] == 17 && packet.windows(7).any(|bytes| bytes == b"blocked"))
                    {
                        // 合成黑洞 DNS，用于验证 stop 能释放全部在途目标连接。
                    } else if !dropped_syn && packet[9] == 6 {
                        dropped_syn = true;
                    } else {
                        device.inject(packet.to_vec());
                    }
                }
                1 if heartbeat_replies => {
                    tls.conn
                        .writer()
                        .write_all(&[1, 2, 0, 8, 0, 0, 0, 0])
                        .unwrap();
                }
                1 => {}
                kind => panic!("未知帧 {kind}"),
            }
            wire.drain(..size);
        }
        let now = NetInstant::from_millis(started.elapsed().as_millis() as i64);
        iface.poll(now, &mut device, &mut sockets);
        let dns = sockets.get_mut::<udp::Socket>(dns);
        if dns.can_recv() {
            let (query, meta) = dns.recv().unwrap();
            let mut answer = query.to_vec();
            assert!(answer.windows(6).any(|s| s == b"campus"));
            answer[2..4].copy_from_slice(&[0x81, 0x80]);
            answer[6..8].copy_from_slice(&[0, 1]);
            answer.extend_from_slice(&[0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4]);
            answer.extend_from_slice(&TARGET.octets());
            dns.send_slice(&answer, meta.endpoint).unwrap();
        }
        let socket = sockets.get_mut::<tcp::Socket>(echo);
        if socket.can_recv() && socket.can_send() {
            let size = (socket.send_capacity() - socket.send_queue()).min(bytes.len());
            let count = socket.recv_slice(&mut bytes[..size]).unwrap();
            assert_eq!(socket.send_slice(&bytes[..count]).unwrap(), count);
            received += count;
        }
        if !socket.may_recv() && !socket.can_recv() && socket.state() == tcp::State::CloseWait {
            socket.close();
        }
        if socket.state() == tcp::State::Closed && received > 0 {
            graceful = true;
        }
        iface.poll(now, &mut device, &mut sockets);
        while let Some(packet) = device.outgoing.pop_front() {
            let mut header = [1, 4, 0, 0, 0, 0, 0, 0];
            header[2..4].copy_from_slice(&((packet.len() + 8) as u16).to_be_bytes());
            tls.conn.writer().write_all(&header).unwrap();
            tls.conn.writer().write_all(&packet).unwrap();
        }
        while tls.conn.wants_write() {
            match tls.conn.write_tls(&mut tls.sock) {
                Ok(0) => break,
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => return (received, graceful),
            }
        }
        if let Some((target, orderly)) = terminal_after {
            if received >= target && sockets.get::<tcp::Socket>(echo).send_queue() == 0 {
                if orderly {
                    tls.conn.send_close_notify();
                    // close_notify 和最后一批数据包同次写入，再保持 TCP 开放。
                    while tls.conn.wants_write() {
                        match tls.conn.write_tls(&mut tls.sock) {
                            Ok(_) => {}
                            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                                thread::sleep(Duration::from_millis(1));
                            }
                            Err(_) => break,
                        }
                    }
                    while !stop.load(Ordering::Acquire) {
                        thread::sleep(Duration::from_millis(2));
                    }
                }
                return (received, graceful);
            }
        }
        thread::sleep(Duration::from_millis(2));
    }
    (received, graceful)
}

#[test]
fn tls_terminal_keeps_final_tcp_bytes_for_loopback_reader() {
    for orderly in [false, true] {
        let expected: Vec<_> = (0..32 * 1024).map(|i| (i % 251) as u8).collect();
        let gateway = Gateway::with_terminal_after(Some((expected.len(), orderly)));
        let mut roots = RootCertStore::empty();
        roots.add(CertificateDer::from(CERT)).unwrap();
        let (handle, _) = start_with_roots(
            &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
            roots,
        ).unwrap();
        let mut stream = connect(&handle, "campus.test", 8080).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream.write_all(&expected).unwrap();
        // 对端关闭时接收者尚未读取，确保终态不是只靠 TCP 已交付的字节通过。
        thread::sleep(Duration::from_millis(100));
        let mut actual = Vec::new();
        stream.read_to_end(&mut actual).unwrap();
        assert_eq!(actual, expected, "TLS 终态不能吞掉已解密的 TCP 尾字节");
        let waiting = Instant::now();
        while handle.alive() && waiting.elapsed() < Duration::from_secs(2) {
            thread::sleep(Duration::from_millis(2));
        }
        assert!(!handle.alive());
        handle.stop();
        let (received, _) = gateway.finish();
        assert_eq!(received, expected.len());
    }
}

#[test]
fn tunnel_dns_tcp_connect_authorization_backpressure_and_half_close() {
    let gateway = Gateway::new();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, info) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    assert_eq!(info.dns, Ipv4Addr::LOCALHOST);
    // 单条非法连接不能杀死已有隧道。
    assert!(connect(&handle, "0.0.0.0", 8080).is_err());
    assert!(handle.alive());
    // 以陈旧时钟模拟调度停顿；恢复后应收到心跳回复并继续使用同一隧道。
    thread::sleep(Duration::from_millis(100));
    let (sender, receiver) = mpsc::sync_channel(1);
    handle
        .commands
        .send(Command::SimulateSuspend(sender))
        .unwrap();
    handle.waker.wake().unwrap();
    receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    let (mut intruder, status) =
        proxy_request(&handle, "campus.test", 8080, "Basic invalid").unwrap();
    assert_eq!(status, 407);
    let result = intruder.read(&mut [0; 1]);
    assert!(
        matches!(result, Ok(0))
            || result.is_err_and(|e| e.kind() == io::ErrorKind::ConnectionReset)
    );
    drop(intruder);
    let mut stream = connect(&handle, "campus.test", 8080).unwrap();
    assert_eq!(handle.status()["healthy"], true);
    assert!(handle.status()["heartbeats"].as_u64().unwrap() >= 2);
    // 保持已鉴权的空闲连接，连接池不应让事件循环继续固定 200 Hz 轮询。
    thread::sleep(Duration::from_millis(200));
    let iterations = handle.status()["loopIterations"].as_u64().unwrap();
    thread::sleep(Duration::from_millis(500));
    let idle_iterations = handle.status()["loopIterations"].as_u64().unwrap() - iterations;
    assert!(idle_iterations < 60, "空闲连接轮询过密：{idle_iterations}");
    let expected: Vec<_> = (0..512 * 1024).map(|i| (i % 251) as u8).collect();
    let data = expected.clone();
    let mut writer = stream.try_clone().unwrap();
    let writing = thread::spawn(move || {
        writer.write_all(&data).unwrap();
        writer.shutdown(Shutdown::Write).unwrap();
    });
    // 故意延迟读取，让数据量超过协议栈缓冲区。
    thread::sleep(Duration::from_millis(150));
    let mut actual = Vec::new();
    stream.read_to_end(&mut actual).unwrap();
    writing.join().unwrap();
    assert_eq!(actual, expected);
    thread::sleep(Duration::from_millis(200));
    handle.stop();
    let (received, graceful) = gateway.finish();
    assert_eq!(received, expected.len());
    assert!(graceful, "对端必须收到正常关闭的最终 ACK");
    assert!(!handle.alive());
}

#[test]
fn idle_tunnel_survives_receive_timeout_with_protocol_heartbeats() {
    let gateway = Gateway::without_heartbeat_replies();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    let started = Instant::now();
    while started.elapsed() < RECEIVE_TIMEOUT + Duration::from_secs(2) {
        thread::sleep(Duration::from_millis(250));
        assert!(handle.alive(), "真实空闲期间隧道意外关闭");
    }
    let status = handle.status();
    assert_eq!(status["needsProbe"], true);
    assert!(status["heartbeats"].as_u64().unwrap() >= 4);
    handle.probe("campus.test".into(), PROBE_TIMEOUT).unwrap();
    assert_eq!(handle.status()["healthy"], true);
    let mut stream = connect(&handle, "campus.test", 8080).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream.write_all(b"after-long-idle").unwrap();
    let mut response = [0; 15];
    stream.read_exact(&mut response).unwrap();
    assert_eq!(&response, b"after-long-idle");
    handle.stop();
    gateway.finish();
}

#[test]
fn stopping_tunnel_releases_all_inflight_open_waiters() {
    let gateway = Gateway::new();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    let (sender, receiver) = mpsc::sync_channel(8);
    for _ in 0..8 {
        let handle = handle.clone();
        let sender = sender.clone();
        thread::spawn(move || {
            let _ = sender.send(connect(&handle, "blocked.campus.test", 8080));
        });
    }
    thread::sleep(Duration::from_millis(100));
    let started = Instant::now();
    handle.stop();
    for _ in 0..8 {
        let result = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(result.is_err_and(|error| error.kind() == io::ErrorKind::ConnectionAborted));
    }
    assert!(started.elapsed() < Duration::from_secs(1));
    gateway.finish();
}

#[test]
fn cancelling_local_connect_keeps_tunnel_and_releases_flow() {
    let gateway = Gateway::new();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    let mut cancelled = TcpStream::connect((Ipv4Addr::LOCALHOST, handle.proxy_port)).unwrap();
    cancelled
        .write_all(
            format!(
                "CONNECT blocked.campus.test:8080 HTTP/1.1\r\nProxy-Authorization: {}\r\n\r\n",
                authorization(&handle.proxy_token)
            )
            .as_bytes(),
        )
        .unwrap();
    cancelled.shutdown(Shutdown::Both).unwrap();
    drop(cancelled);
    let mut stream = connect(&handle, "campus.test", 8080).unwrap();
    stream.write_all(b"after-cancel").unwrap();
    let mut reply = [0; 12];
    stream.read_exact(&mut reply).unwrap();
    assert_eq!(&reply, b"after-cancel");
    assert!(handle.alive());
    handle.stop();
    gateway.finish();
}

#[test]
fn cancelled_tls_start_returns_without_waiting_for_peer() {
    let listener = TcpListener::bind(("localhost", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let control = Arc::new(StartControl::new());
    let worker_control = control.clone();
    let worker = thread::spawn(move || {
        start_with_control(
            &json!({"host":"localhost", "port":port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
            RootCertStore::empty(),
            worker_control,
        )
    });
    let (peer, _) = listener.accept().unwrap();
    let waiting = Instant::now();
    while control.status()["stage"] != "TLS" && waiting.elapsed() < Duration::from_secs(2) {
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(control.status()["stage"], "TLS");
    let started = Instant::now();
    control.cancel();
    let result = worker.join().unwrap();
    assert!(result.is_err());
    assert!(started.elapsed() < Duration::from_secs(1));
    drop(peer);
}

#[test]
fn protocol_handshake_has_total_deadline_after_partial_response() {
    let listener = TcpListener::bind(("localhost", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let worker = thread::spawn(move || {
        let (raw, _) = listener.accept().unwrap();
        raw.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let config =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![CertificateDer::from(CERT)],
                    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(KEY)),
                )
                .unwrap();
        let mut tls = StreamOwned::new(ServerConnection::new(Arc::new(config)).unwrap(), raw);
        let mut header = [0; 12];
        tls.read_exact(&mut header).unwrap();
        let mut body = vec![0; u16::from_be_bytes([header[2], header[3]]) as usize - 12];
        tls.read_exact(&mut body).unwrap();
        tls.write_all(&[1, 2, 0, 20, 0, 0, 0, 0, 1, 0, 0, 0])
            .unwrap();
        tls.flush().unwrap();
        thread::sleep(Duration::from_millis(600));
    });
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let started = Instant::now();
    let control = Arc::new(StartControl::new());
    let client_control = control.clone();
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let result = start_with_deadline(
            &json!({"host":"localhost", "port":port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
            roots,
            client_control,
            Duration::from_millis(300),
        );
        let _ = sender.send(result);
    });
    let result = receiver
        .recv_timeout(Duration::from_secs(2))
        .unwrap_or_else(|_| {
            control.cancel();
            panic!("握手未按期限返回");
        });
    assert!(result.is_err_and(|error| error.kind() == io::ErrorKind::TimedOut));
    assert!(started.elapsed() < Duration::from_millis(550));
    worker.join().unwrap();
}

#[test]
fn running_flag_does_not_hide_draining_or_recovery() {
    let gateway = Gateway::new();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    assert_eq!(handle.status()["healthy"], true);
    handle.health.lock().unwrap().recovering = true;
    assert_eq!(handle.status()["healthy"], false);
    handle.health.lock().unwrap().recovering = false;
    handle.health.lock().unwrap().draining = true;
    assert_eq!(handle.status()["healthy"], false);
    handle.stop();
    gateway.finish();
}

#[test]
fn coalesced_tls_burst_keeps_packets_until_ip_queue_has_capacity() {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let packets: Vec<_> = (0..1024u16)
        .map(|index| {
            let mut packet = vec![0; 20];
            packet[0] = 0x45;
            packet[2..4].copy_from_slice(&20u16.to_be_bytes());
            packet[4..6].copy_from_slice(&index.to_be_bytes());
            packet
        })
        .collect();
    let expected = packets.clone();
    let (release, wait) = mpsc::sync_channel(1);
    let (partial, partial_received) = mpsc::sync_channel(1);
    let (closing, closed) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || {
        let (raw, _) = listener.accept().unwrap();
        raw.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let config =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![CertificateDer::from(CERT)],
                    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(KEY)),
                )
                .unwrap();
        let mut tls = StreamOwned::new(ServerConnection::new(Arc::new(config)).unwrap(), raw);
        let mut request = [0; 1];
        tls.read_exact(&mut request).unwrap();
        // 持续更新 TLS 字节但不完成协议帧，不能刷新健康接收时间。
        tls.write_all(&[1, 2, 0]).unwrap();
        tls.flush().unwrap();
        partial.send(()).unwrap();
        wait.recv_timeout(Duration::from_secs(2)).unwrap();
        tls.write_all(&[8, 0, 0, 0, 0]).unwrap();
        let mut wire = Vec::new();
        for packet in packets {
            wire.extend_from_slice(&[1, 4, 0, 28, 0, 0, 0, 0]);
            wire.extend_from_slice(&packet);
        }
        tls.write_all(&wire).unwrap();
        tls.flush().unwrap();
        let _ = wait.recv_timeout(Duration::from_secs(5));
        tls.conn.send_close_notify();
        tls.flush().unwrap();
        let _ = closing.send(());
        // TLS 已关闭，但 TCP 故意保持开放，不能等到底层 EOF 或心跳超时。
        let _ = wait.recv_timeout(Duration::from_secs(2));
    });
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let config =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
    let raw = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
    let conn = ClientConnection::new(Arc::new(config), "localhost".try_into().unwrap()).unwrap();
    let mut tls = StreamOwned::new(conn, raw);
    tls.write_all(&[1]).unwrap();
    tls.flush().unwrap();
    tls.sock.set_nonblocking(true).unwrap();
    let (_sender, receiver) = mpsc::sync_channel(MAX_CONNECTIONS);
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
    let tls = StreamOwned::new(tls.conn, mio::net::TcpStream::from_std(tls.sock));
    let mut runner = Runner::new(
        tls,
        &frame::AuthInfo {
            address: CLIENT,
            dns: Ipv4Addr::LOCALHOST,
        },
        receiver,
        Arc::new(AtomicBool::new(true)),
        health,
        "campus.test".to_owned(),
    )
    .unwrap();
    // 只有 TLS 字节、尚无完整帧不能恢复活性。
    partial_received
        .recv_timeout(Duration::from_secs(2))
        .unwrap();
    let healthy_at = runner.health.lock().unwrap().received;
    let started_partial = Instant::now();
    while runner.health.lock().unwrap().received_bytes < 3 {
        runner.pump_tls().unwrap();
        assert!(started_partial.elapsed() < Duration::from_secs(1));
        thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(runner.decoder.completed_frames(), 0);
    assert_eq!(runner.health.lock().unwrap().received, healthy_at);
    release.send(()).unwrap();
    let mut actual = Vec::new();
    let started = Instant::now();
    while actual.len() < expected.len() && started.elapsed() < Duration::from_secs(3) {
        runner.pump_tls().unwrap();
        // 模拟协议栈每轮只消费一部分，持续施加有界接收背压。
        for _ in 0..64 {
            if let Some(packet) = runner.device.incoming.pop_front() {
                actual.push(packet);
            }
        }
        thread::sleep(Duration::from_millis(2));
    }
    let _ = release.send(());
    assert_eq!(actual.len(), expected.len(), "合并突发数据包必须完整保留");
    assert!(actual == expected, "数据包顺序与内容必须保持不变");
    closed.recv_timeout(Duration::from_secs(2)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    let failure = loop {
        runner.pump_tls().unwrap();
        if let Some(error) = runner.terminal.take() {
            break error;
        }
        assert!(Instant::now() < deadline, "TLS 关闭未及时终止隧道");
        thread::sleep(Duration::from_millis(2));
    };
    assert_eq!(failure.kind(), io::ErrorKind::UnexpectedEof);
    assert!(runner.health.lock().unwrap().draining);
    assert!(!runner.health.lock().unwrap().recovering);
    let _ = release.send(());
    worker.join().unwrap();
}

static PUSHED_EVENTS: Mutex<Vec<Value>> = Mutex::new(Vec::new());
extern "C" fn collect_event(pointer: *mut std::ffi::c_char, length: usize, _: u64) {
    unsafe {
        let bytes = std::slice::from_raw_parts(pointer as *const u8, length);
        let mut value: Value = serde_json::from_slice(bytes).unwrap();
        value["registry_unlocked"] = Value::Bool(
            crate::ENGINES
                .get_or_init(|| Mutex::new(std::collections::HashMap::new()))
                .try_lock()
                .is_ok(),
        );
        PUSHED_EVENTS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(value);
        crate::nuist_vpn_result_free(pointer);
    }
}

#[test]
fn normal_poll_idle_beyond_progress_timeout_does_not_push_unhealthy() {
    crate::nuist_vpn_set_event_callback(Some(collect_event));
    let gateway = Gateway::without_heartbeat_replies();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    handle.set_id(93001);
    // 跨过一次完整的十秒 Poll 等待，避免只验证尚未醒来的事件循环。
    thread::sleep(HEARTBEAT_INTERVAL + Duration::from_secs(1));
    assert!(handle.alive());
    assert!(handle.status()["heartbeats"].as_u64().unwrap() >= 2);
    assert_eq!(handle.status()["recovering"], false);
    assert!(!PUSHED_EVENTS
        .lock()
        .unwrap()
        .iter()
        .any(|event| { event["engineId"] == 93001 && event["event"] == "unhealthy" }));
    handle.stop();
    gateway.finish();
}

#[test]
fn recovery_timeout_exits_and_pushes_event_without_status_polling() {
    crate::nuist_vpn_set_event_callback(Some(collect_event));
    let gateway = Gateway::blackhole();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    handle.set_id(91001);
    thread::sleep(Duration::from_millis(100));
    let (sender, receiver) = mpsc::sync_channel(1);
    handle
        .commands
        .send(Command::SimulateSuspend(sender))
        .unwrap();
    handle.waker.wake().unwrap();
    receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    let started = Instant::now();
    loop {
        let exited = PUSHED_EVENTS.lock().unwrap().iter().any(|event| {
            event["engineId"] == 91001
                && event["event"] == "exited"
                && event["reason"] == "recovery_timeout"
        });
        if exited {
            break;
        }
        assert!(
            started.elapsed() < RECOVERY_TIMEOUT + Duration::from_secs(2),
            "恢复超时没有主动推送退出事件"
        );
        thread::sleep(Duration::from_millis(10));
    }
    assert!(!handle.alive());
    assert_eq!(handle.exit_reason().as_deref(), Some("recovery_timeout"));
    gateway.finish();
}

#[test]
fn two_connect_timeouts_trigger_builtin_dns_probe_and_blackhole_exit() {
    let gateway = Gateway::blackhole();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}),
        roots,
    )
    .unwrap();
    let (sender, receiver) = mpsc::sync_channel(2);
    for _ in 0..2 {
        let sender = sender.clone();
        let handle = handle.clone();
        thread::spawn(move || {
            sender
                .send(
                    proxy_request(
                        &handle,
                        "blocked.campus.test",
                        8080,
                        &authorization(&handle.proxy_token),
                    )
                    .map(|(_, status)| status),
                )
                .unwrap();
        });
    }
    for _ in 0..2 {
        assert_eq!(
            receiver
                .recv_timeout(DNS_OPEN_TIMEOUT + Duration::from_secs(2))
                .unwrap()
                .unwrap(),
            504
        );
    }
    let started = Instant::now();
    while handle.alive() {
        assert!(
            started.elapsed() < PROBE_TIMEOUT + Duration::from_secs(2),
            "黑洞探活失败没有退出引擎"
        );
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(handle.exit_reason().as_deref(), Some("blackhole_detected"));
    assert_eq!(handle.status()["dnsTimeouts"], 2);
    gateway.finish();
}

#[test]
fn connect_parser_rejects_missing_duplicate_credentials_and_invalid_target() {
    let auth = authorization("123456");
    assert_eq!(
        parse_connect(b"CONNECT campus.test:80 HTTP/1.1\r\n\r\n", &auth),
        Err(407)
    );
    assert_eq!(parse_connect(format!("CONNECT campus.test:80 HTTP/1.1\r\nProxy-Authorization: {auth}\r\nProxy-Authorization: {auth}\r\n\r\n").as_bytes(), &auth), Err(407));
    assert_eq!(
        parse_connect(
            format!("CONNECT [::1]:80 HTTP/1.1\r\nProxy-Authorization: {auth}\r\n\r\n").as_bytes(),
            &auth
        ),
        Err(400)
    );
    assert_eq!(
        parse_connect(
            format!("CONNECT campus.test:80 HTTP/1.1\r\nProxy-Authorization: {auth}\r\n\r\n")
                .as_bytes(),
            &auth
        ),
        Ok(("campus.test".into(), 80))
    );
}

#[test]
fn stopping_registered_engines_releases_slots_before_next_start() {
    let _registry_test = crate::REGISTRY_TEST_LOCK.lock().unwrap();
    for cycle in 0..4u64 {
        let gateway = Gateway::new();
        let mut roots = RootCertStore::empty();
        roots.add(CertificateDer::from(CERT)).unwrap();
        let (handle, _) = start_with_roots(&json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token", "probeHost":"campus.test"}), roots).unwrap();
        let id = 92001 + cycle;
        crate::ENGINES
            .get_or_init(|| Mutex::new(std::collections::HashMap::new()))
            .lock()
            .unwrap()
            .insert(id, handle.clone());
        crate::dispatch(json!({"method": "stop", "id": id})).unwrap();
        assert!(!crate::ENGINES
            .get()
            .unwrap()
            .lock()
            .unwrap()
            .contains_key(&id));
        assert!(!handle.alive());
        gateway.finish();
    }
}

/// 不启动 Runner 主循环的真实 TLS 通道，允许精确构造 IO 边界及协议栈状态。
struct Harness {
    runner: Runner,
    send: mpsc::Sender<Option<(Vec<u8>, bool)>>,
    worker: Option<thread::JoinHandle<()>>,
    _commands: SyncSender<Command>,
}

impl Harness {
    fn new() -> Self {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let (send, receive) = mpsc::channel::<Option<(Vec<u8>, bool)>>();
        let worker = thread::spawn(move || {
            let (raw, _) = listener.accept().unwrap();
            SockRef::from(&raw).set_recv_buffer_size(1024).unwrap();
            raw.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
            let config = ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(CERT)],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(KEY)),
            )
            .unwrap();
            let mut tls = StreamOwned::new(ServerConnection::new(Arc::new(config)).unwrap(), raw);
            let mut request = [0u8];
            tls.read_exact(&mut request).unwrap();
            tls.write_all(&[1, 2, 0, 8, 0, 0, 0, 0]).unwrap();
            tls.flush().unwrap();
            while let Ok(Some((bytes, close))) = receive.recv() {
                if tls.write_all(&bytes).and_then(|_| tls.flush()).is_err() {
                    break;
                }
                if close {
                    tls.conn.send_close_notify();
                    if tls.flush().is_err() {
                        break;
                    }
                }
            }
        });
        let mut roots = RootCertStore::empty();
        roots.add(CertificateDer::from(CERT)).unwrap();
        let config =
            ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_root_certificates(roots)
                .with_no_client_auth();
        let raw = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        let conn =
            ClientConnection::new(Arc::new(config), "localhost".try_into().unwrap()).unwrap();
        let mut tls = StreamOwned::new(conn, raw);
        tls.write_all(&[1]).unwrap();
        tls.flush().unwrap();
        tls.sock.set_nonblocking(true).unwrap();
        let tls = StreamOwned::new(tls.conn, mio::net::TcpStream::from_std(tls.sock));
        let (commands, receiver) = mpsc::sync_channel(MAX_CONNECTIONS);
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
        let mut runner = Runner::new(
            tls,
            &frame::AuthInfo {
                address: CLIENT,
                dns: Ipv4Addr::LOCALHOST,
            },
            receiver,
            Arc::new(AtomicBool::new(true)),
            health,
            "campus.test".into(),
        )
        .unwrap();
        while runner.decoder.completed_frames() == 0 {
            runner
                .poll
                .poll(&mut runner.events, Some(Duration::from_millis(50)))
                .unwrap();
            runner.pump_tls().unwrap();
        }
        Self {
            runner,
            send,
            worker: Some(worker),
            _commands: commands,
        }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = self.runner.tunnel.sock.shutdown(Shutdown::Both);
        let _ = self.send.send(None);
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap();
        }
    }
}

struct Peer {
    device: IpLink,
    interface: Interface,
    sockets: SocketSet<'static>,
    tcp: SocketHandle,
}

impl Peer {
    fn pump(&mut self, runner: &mut Runner) {
        let now = NetInstant::from_millis(runner.started.elapsed().as_millis() as i64);
        runner
            .interface
            .poll(now, &mut runner.device, &mut runner.sockets);
        while let Some(packet) = runner.device.outgoing.pop_front() {
            self.device.inject(packet);
        }
        self.interface
            .poll(now, &mut self.device, &mut self.sockets);
        while let Some(packet) = self.device.outgoing.pop_front() {
            runner.device.inject(packet);
        }
        runner
            .interface
            .poll(now, &mut runner.device, &mut runner.sockets);
    }
}

fn established_flow(runner: &mut Runner) -> (Flow, TcpStream, Peer) {
    let mut device = IpLink::default();
    let mut config = Config::new(HardwareAddress::Ip);
    config.random_seed = 17;
    let mut interface = Interface::new(config, &mut device, NetInstant::from_millis(0));
    interface.update_ip_addrs(|ips| {
        ips.push(IpCidr::new(TARGET.into(), 24)).unwrap();
    });
    let mut sockets = SocketSet::new(Vec::new());
    let mut remote = tcp::Socket::new(
        tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
        tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
    );
    remote.listen((TARGET, 8080)).unwrap();
    let peer_tcp = sockets.add(remote);
    let local_tcp = runner.connect_tcp(TARGET.into(), 8080).unwrap();
    let mut peer = Peer {
        device,
        interface,
        sockets,
        tcp: peer_tcp,
    };
    let deadline = Instant::now() + Duration::from_secs(2);
    while runner.sockets.get::<tcp::Socket>(local_tcp).state() != tcp::State::Established {
        peer.pump(runner);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    peer.pump(runner);
    assert_eq!(
        peer.sockets.get::<tcp::Socket>(peer_tcp).state(),
        tcp::State::Established
    );
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (local, _) = listener.accept().unwrap();
    local.set_nonblocking(true).unwrap();
    let mut local = mio::net::TcpStream::from_std(local);
    let token = Token(runner.next_token);
    runner.next_token += 1;
    runner
        .poll
        .registry()
        .register(&mut local, token, Interest::READABLE)
        .unwrap();
    let flow = Flow {
        query: None,
        tcp: Some(local_tcp),
        port: 8080,
        deadline: Instant::now() + TCP_OPEN_TIMEOUT,
        connect_started: None,
        local,
        token,
        interest: Interest::READABLE,
        headers: Vec::new(),
        pending: Vec::new(),
        pending_offset: 0,
        ingress: Vec::new(),
        authorized: true,
        established: true,
        reject: false,
        local_eof: false,
        remote_eof: false,
        touched: Instant::now(),
    };
    (flow, client, peer)
}

#[test]
fn remote_fin_with_short_writes_delivers_entire_buffer_before_eof() {
    let mut h = Harness::new();
    let (mut flow, mut client, mut peer) = established_flow(&mut h.runner);
    let expected: Vec<_> = (0..32 * 1024).map(|i| (i % 251) as u8).collect();
    peer.sockets
        .get_mut::<tcp::Socket>(peer.tcp)
        .send_slice(&expected)
        .unwrap();
    peer.sockets.get_mut::<tcp::Socket>(peer.tcp).close();
    let deadline = Instant::now() + Duration::from_secs(2);
    while h
        .runner
        .sockets
        .get::<tcp::Socket>(flow.tcp.unwrap())
        .state()
        != tcp::State::CloseWait
    {
        peer.pump(&mut h.runner);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    h.runner.io_chunk_limit = 1;
    h.runner.advance(&mut flow).unwrap();
    assert!(h
        .runner
        .sockets
        .get::<tcp::Socket>(flow.tcp.unwrap())
        .can_recv());
    assert!(!flow.remote_eof, "远端FIN不能越过未交付的接收缓冲");
    h.runner.io_chunk_limit = usize::MAX;
    client
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        client.read_to_end(&mut bytes).unwrap();
        bytes
    });
    while !flow.remote_eof {
        h.runner.advance(&mut flow).unwrap();
        peer.pump(&mut h.runner);
        assert!(Instant::now() < deadline);
    }
    assert_eq!(reader.join().unwrap(), expected);
    h.runner.remove(flow);
}

#[test]
fn local_read_budget_exhaustion_continues_without_another_socket_edge() {
    let mut h = Harness::new();
    let (mut flow, mut client, _peer) = established_flow(&mut h.runner);
    client.write_all(&[7u8; 32]).unwrap();
    h.runner
        .poll
        .poll(&mut h.runner.events, Some(Duration::from_millis(100)))
        .unwrap();
    h.runner.io_chunk_limit = 1;
    h.runner.budget_exhausted = false;
    h.runner.advance(&mut flow).unwrap();
    assert_eq!(
        h.runner
            .sockets
            .get::<tcp::Socket>(flow.tcp.unwrap())
            .send_queue(),
        IO_BUDGET
    );
    assert_eq!(
        h.runner.poll_timeout(NetInstant::from_millis(0)),
        Duration::ZERO
    );
    h.runner.budget_exhausted = false;
    h.runner.advance(&mut flow).unwrap();
    assert_eq!(
        h.runner
            .sockets
            .get::<tcp::Socket>(flow.tcp.unwrap())
            .send_queue(),
        32
    );
    h.runner.remove(flow);
}

#[test]
fn tls_read_budget_with_only_control_frames_does_not_wait_for_new_edge() {
    let mut h = Harness::new();
    h.runner.io_budget = 1;
    h.send
        .send(Some(([1, 2, 0, 8, 0, 0, 0, 0].repeat(8), false)))
        .unwrap();
    h.runner
        .poll
        .poll(&mut h.runner.events, Some(Duration::from_millis(500)))
        .unwrap();
    h.runner.budget_exhausted = false;
    h.runner.pump_tls().unwrap();
    assert!(h.runner.device.incoming.is_empty() && h.runner.device.outgoing.is_empty());
    assert_eq!(
        h.runner.poll_timeout(NetInstant::from_millis(0)),
        Duration::ZERO
    );
    h.runner.pump_tls().unwrap();
    assert_eq!(h.runner.decoder.completed_frames(), 9);
}

#[test]
fn tls_partial_output_without_write_block_continues_until_queue_drained() {
    let mut h = Harness::new();
    h.runner.tunnel.conn.set_buffer_limit(Some(1));
    h.runner.output.push_back(frame::heartbeat(1).to_vec());
    h.runner.budget_exhausted = false;
    h.runner.pump_tls().unwrap();
    assert!(!h.runner.output.is_empty());
    assert!(!h.runner.tls_write_blocked);
    assert_eq!(
        h.runner.poll_timeout(NetInstant::from_millis(0)),
        Duration::ZERO
    );
    let deadline = Instant::now() + Duration::from_secs(2);
    while !h.runner.output.is_empty() {
        h.runner.pump_tls().unwrap();
        assert!(Instant::now() < deadline);
    }
}

#[test]
fn terminal_past_heartbeat_clears_outgoing_unregisters_listener_and_consumes_tail() {
    let mut h = Harness::new();
    let port = h
        .runner
        .listener
        .as_ref()
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    h.runner.last_heartbeat = Instant::now() - HEARTBEAT_INTERVAL * 2;
    h.runner
        .device
        .outgoing
        .extend((0..256).map(|_| vec![0u8; 20]));
    h.runner.device.inject(vec![0x45u8; 20]);
    h.runner
        .receive_terminal(error(io::ErrorKind::UnexpectedEof, "合成终态"));
    assert!(h.runner.device.outgoing.is_empty());
    assert!(h.runner.listener.is_none());
    assert!(h.runner.poll_timeout(NetInstant::from_millis(0)) > Duration::ZERO);
    assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err());
    h.runner.interface.poll(
        NetInstant::from_millis(0),
        &mut h.runner.device,
        &mut h.runner.sockets,
    );
    assert!(
        h.runner.device.incoming.is_empty(),
        "排空不能被无法发送的ACK阻塞"
    );
    assert!(h.runner.device.outgoing.is_empty());
    h.runner
        .poll
        .poll(&mut h.runner.events, Some(Duration::from_millis(20)))
        .unwrap();
    assert!(!h
        .runner
        .events
        .iter()
        .any(|event| event.token() == TUNNEL || event.token() == LISTENER));
}

#[test]
fn draining_reads_local_pending_request_before_closing_response() {
    let mut h = Harness::new();
    let (mut flow, mut client, _peer) = established_flow(&mut h.runner);
    client.write_all(&vec![5u8; 64 * 1024]).unwrap();
    thread::sleep(Duration::from_millis(10));
    h.runner
        .receive_terminal(error(io::ErrorKind::UnexpectedEof, "合成终态"));
    assert!(!h.runner.advance(&mut flow).unwrap());
    let mut byte = [0u8];
    assert!(
        matches!(flow.local.read(&mut byte),Err(error)if error.kind()==io::ErrorKind::WouldBlock)
    );
    client
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    assert_eq!(
        client.read(&mut byte).unwrap(),
        0,
        "未读请求不能使响应端收到RST"
    );
    h.runner.remove(flow);
}

#[test]
fn blackhole_probe_start_failure_is_fatal_in_main_loop() {
    let mut h = Harness::new();
    h.runner.probe_host = "invalid..campus.test".into();
    h.runner.consecutive_timeouts = 2;
    h.runner.last_received = Instant::now() - BLACKHOLE_IDLE;
    let running = h.runner.running.clone();
    let waker = h.runner.waker.clone();
    let stop = thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        running.store(false, Ordering::Release);
        waker.wake().unwrap();
    });
    assert!(
        h.runner.run().is_err(),
        "内置探活启动失败不能作为单流错误吞掉"
    );
    assert_eq!(h.runner.exit_code.as_deref(), Some("blackhole_detected"));
    stop.join().unwrap();
}

#[test]
fn interrupted_poll_does_not_turn_waiting_time_into_scheduler_stall() {
    let mut h = Harness::new();
    h.runner.last_progress = Instant::now() - Duration::from_secs(20);
    h.runner
        .poll_finished(Instant::now() - Duration::from_secs(10), true);
    h.runner.update_progress().unwrap();
    assert!(h.runner.recovery_deadline.is_none());
    assert!(h.runner.probe.is_none());
    assert!(!h.runner.health.lock().unwrap().recovering);
}

#[test]
fn unsupported_keepalive_parameters_fall_back_without_rejecting_start() {
    let mut attempts = 0;
    configure_keepalive(|_| {
        attempts += 1;
        if attempts == 1 {
            Err(error(
                io::ErrorKind::Unsupported,
                "合成旧内核不支持keepalive参数",
            ))
        } else {
            Ok(())
        }
    });
    assert_eq!(attempts, 2);
    configure_keepalive(|_| {
        Err(error(
            io::ErrorKind::Unsupported,
            "合成全部keepalive选项被拒绝",
        ))
    });
}

#[test]
fn one_silent_tcp_connect_is_detected_by_parallel_probe_in_less_than_six_seconds() {
    let gateway = Gateway::blackhole();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let(handle,_)=start_with_roots(&json!({"host":"localhost","port":gateway.port,"user":"synthetic","token":"test-token","probeHost":"campus.test"}),roots).unwrap();
    let connecting = handle.clone();
    let started = Instant::now();
    let request = thread::spawn(move || connect(&connecting, &TARGET.to_string(), 8080));
    while handle.alive() {
        assert!(
            started.elapsed() < Duration::from_secs(6),
            "不能等待8秒TCP超时后才探活"
        );
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(handle.exit_reason().as_deref(), Some("blackhole_detected"));
    assert_eq!(handle.status()["tcpTimeouts"], 0);
    assert!(request.join().unwrap().is_err());
    gateway.finish();
}

#[test]
fn scheduler_stall_recovers_legal_idle_tunnel_through_dns_without_heartbeat_reply() {
    let gateway = Gateway::without_heartbeat_replies();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let(handle,_)=start_with_roots(&json!({"host":"localhost","port":gateway.port,"user":"synthetic","token":"test-token","probeHost":"campus.test"}),roots).unwrap();
    let (sender, receiver) = mpsc::sync_channel(1);
    handle
        .commands
        .send(Command::SimulateSuspend(sender))
        .unwrap();
    handle.waker.wake().unwrap();
    receiver.recv_timeout(Duration::from_secs(1)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    while handle.status()["recovering"] == true {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(2));
    }
    thread::sleep(PROBE_TIMEOUT + Duration::from_millis(50));
    assert!(handle.alive());
    let mut stream = connect(&handle, "campus.test", 8080).unwrap();
    stream.write_all(b"recovered").unwrap();
    let mut bytes = [0u8; 9];
    stream.read_exact(&mut bytes).unwrap();
    assert_eq!(&bytes, b"recovered");
    handle.stop();
    gateway.finish();
}

#[test]
fn full_tls_output_backpressure_defers_heartbeat_and_avoids_poll_zero() {
    let mut h = Harness::new();
    SockRef::from(&h.runner.tunnel.sock)
        .set_send_buffer_size(1024)
        .unwrap();
    h.runner.tunnel.conn.set_buffer_limit(Some(4096));
    let mut packet = vec![0u8; 1500];
    packet[0] = 0x45;
    let frame = frame::data(&packet).unwrap();
    h.runner
        .output
        .extend((0..OUTPUT_CAPACITY).map(|_| frame.clone()));
    h.runner.last_heartbeat = Instant::now() - HEARTBEAT_INTERVAL * 2;
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        h.runner.budget_exhausted = false;
        h.runner.pump_tls().unwrap();
        if h.runner.tls_write_blocked && !h.runner.budget_exhausted {
            break;
        }
        assert!(Instant::now() < deadline, "未构造出真实OS写背压");
    }
    assert!(h.runner.last_heartbeat.elapsed() < HEARTBEAT_INTERVAL);
    h.runner
        .device
        .outgoing
        .extend((0..256 - h.runner.device.outgoing.len()).map(|_| vec![0u8; 20]));
    assert!(h.runner.poll_timeout(NetInstant::from_millis(0)) > Duration::ZERO);
}

#[test]
fn dns_target_timeout_is_three_seconds_without_killing_live_tunnel() {
    let gateway = Gateway::without_heartbeat_replies();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let(handle,_)=start_with_roots(&json!({"host":"localhost","port":gateway.port,"user":"synthetic","token":"test-token","probeHost":"campus.test"}),roots).unwrap();
    let started = Instant::now();
    let (_, status) = proxy_request(
        &handle,
        "blocked.campus.test",
        8080,
        &authorization(&handle.proxy_token),
    )
    .unwrap();
    assert_eq!(status, 504);
    assert!(started.elapsed() < Duration::from_secs(4));
    thread::sleep(BLACKHOLE_PROBE_TIMEOUT + Duration::from_millis(50));
    assert!(handle.alive());
    assert_eq!(handle.status()["dnsTimeouts"], 1);
    handle.stop();
    gateway.finish();
}

#[test]
fn slow_target_tcp_keeps_eight_second_deadline_when_parallel_dns_proves_tunnel_alive() {
    let gateway = Gateway::tcp_blackhole();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let(handle,_)=start_with_roots(&json!({"host":"localhost","port":gateway.port,"user":"synthetic","token":"test-token","probeHost":"campus.test"}),roots).unwrap();
    let started = Instant::now();
    let (_, status) = proxy_request(
        &handle,
        &TARGET.to_string(),
        8080,
        &authorization(&handle.proxy_token),
    )
    .unwrap();
    assert_eq!(status, 504);
    assert!(started.elapsed() >= Duration::from_secs(7));
    assert!(started.elapsed() < Duration::from_secs(9));
    assert!(handle.alive());
    assert_eq!(handle.status()["tcpTimeouts"], 1);
    handle.stop();
    gateway.finish();
}

#[test]
fn exited_event_is_once_only_and_publication_callback_runs_outside_registry_lock() {
    let _registry_test = crate::REGISTRY_TEST_LOCK.lock().unwrap();
    crate::nuist_vpn_set_event_callback(Some(collect_event));
    let gateway = Gateway::new();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let(handle,info)=start_with_roots(&json!({"host":"localhost","port":gateway.port,"user":"synthetic","token":"test-token","probeHost":"campus.test"}),roots).unwrap();
    handle.stop();
    let deadline = Instant::now() + Duration::from_secs(1);
    while handle.exit_event.lock().unwrap().is_none() {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    let result = crate::register_engine(handle.clone(), &info, json!({})).unwrap();
    let id = result["engineId"].as_u64().unwrap();
    let threads: Vec<_> = (0..16)
        .map(|_| {
            let handle = handle.clone();
            thread::spawn(move || handle.set_id(id))
        })
        .collect();
    for worker in threads {
        worker.join().unwrap();
    }
    let events = PUSHED_EVENTS.lock().unwrap();
    let exited: Vec<_> = events
        .iter()
        .filter(|event| event["engineId"] == id && event["event"] == "exited")
        .collect();
    assert_eq!(exited.len(), 1);
    assert_eq!(exited[0]["registry_unlocked"], true);
    drop(events);
    crate::dispatch(json!({"method":"stop","id":id})).unwrap();
    gateway.finish();
}
#[test]
fn default_tls_config_is_shared_between_starts() {
    let first = default_client_config().unwrap();
    let second = default_client_config().unwrap();
    assert!(Arc::ptr_eq(&first, &second));
}
