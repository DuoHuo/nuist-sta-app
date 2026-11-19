//! 合成 TLS 网关和第二个用户态 IP 栈，验证真实 DNS/TCP/回环数据通路。
use super::*;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{ServerConfig, ServerConnection};
use serde_json::json;
use smoltcp::socket::udp;

const CERT: &[u8] = include_bytes!("../../../test/fixtures/vpn/certificate.der");
const KEY: &[u8] = include_bytes!("../../../test/fixtures/vpn/private_key.der");
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
        let worker = thread::spawn(move || serve(listener, stopped, None, false));
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
        let worker = thread::spawn(move || serve(listener, stopped, terminal_after, true));
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
                    if packet[9] == 17 && packet.windows(7).any(|bytes| bytes == b"blocked") {
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
            &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token"}),
            roots,
        ).unwrap();
        let bridge = handle.open("campus.test".into(), 8080).unwrap();
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, bridge.port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let secret: Vec<_> = (0..64)
            .step_by(2)
            .map(|i| u8::from_str_radix(&bridge.secret[i..i + 2], 16).unwrap())
            .collect();
        stream.write_all(&secret).unwrap();
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
fn tunnel_dns_tcp_secret_backpressure_and_half_close() {
    let gateway = Gateway::new();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, info) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token"}),
        roots,
    )
    .unwrap();
    assert_eq!(info.dns, Ipv4Addr::LOCALHOST);
    // 单条非法连接不能杀死已有隧道。
    assert!(handle.open("0.0.0.0".into(), 8080).is_err());
    assert!(handle.alive());
    // 以陈旧时钟模拟调度停顿；恢复后应收到心跳回复并继续使用同一隧道。
    thread::sleep(Duration::from_millis(100));
    let (sender, receiver) = mpsc::sync_channel(1);
    handle
        .commands
        .send(Command::SimulateSuspend(sender))
        .unwrap();
    receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    let bridge = handle.open("campus.test".into(), 8080).unwrap();
    assert_eq!(handle.status()["healthy"], true);
    assert!(handle.status()["heartbeats"].as_u64().unwrap() >= 2);
    let mut intruder = TcpStream::connect((Ipv4Addr::LOCALHOST, bridge.port)).unwrap();
    intruder
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    intruder.write_all(&[0; 32]).unwrap();
    let result = intruder.read(&mut [0; 1]);
    assert!(
        matches!(result, Ok(0))
            || result.is_err_and(|e| e.kind() == io::ErrorKind::ConnectionReset)
    );
    drop(intruder);
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, bridge.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let secret: Vec<_> = (0..64)
        .step_by(2)
        .map(|i| u8::from_str_radix(&bridge.secret[i..i + 2], 16).unwrap())
        .collect();
    stream.write_all(&secret).unwrap();
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
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token"}),
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
    handle.probe("campus.test".into()).unwrap();
    assert_eq!(handle.status()["healthy"], true);
    let bridge = handle.open("campus.test".into(), 8080).unwrap();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, bridge.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let secret: Vec<_> = (0..64)
        .step_by(2)
        .map(|i| u8::from_str_radix(&bridge.secret[i..i + 2], 16).unwrap())
        .collect();
    stream.write_all(&secret).unwrap();
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
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token"}),
        roots,
    )
    .unwrap();
    let (sender, receiver) = mpsc::sync_channel(8);
    for _ in 0..8 {
        let handle = handle.clone();
        let sender = sender.clone();
        thread::spawn(move || {
            let _ = sender.send(handle.open("blocked.campus.test".into(), 8080));
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
fn cancelling_target_opens_keeps_tunnel_and_releases_reservations() {
    let gateway = Gateway::new();
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CERT)).unwrap();
    let (handle, _) = start_with_roots(
        &json!({"host":"localhost", "port":gateway.port, "user":"synthetic", "token":"test-token"}),
        roots,
    )
    .unwrap();
    let early = handle.prepare_open().unwrap();
    handle.cancel_open(early);
    assert!(handle
        .open_reserved("blocked.campus.test".into(), 8080, early)
        .is_err());
    let (sender, receiver) = mpsc::sync_channel(8);
    let mut ids = Vec::new();
    for _ in 0..8 {
        let id = handle.prepare_open().unwrap();
        ids.push(id);
        let handle = handle.clone();
        let sender = sender.clone();
        thread::spawn(move || {
            let _ = sender.send(handle.open_reserved("blocked.campus.test".into(), 8080, id));
        });
    }
    thread::sleep(Duration::from_millis(100));
    let started = Instant::now();
    for id in ids {
        handle.cancel_open(id);
    }
    for _ in 0..8 {
        assert!(receiver
            .recv_timeout(Duration::from_secs(1))
            .unwrap()
            .is_err_and(|error| error.kind() == io::ErrorKind::ConnectionAborted));
    }
    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(handle.alive());
    assert!(handle.opens.lock().unwrap().is_empty());
    let retained = handle.prepare_open().unwrap();
    let bridge = handle
        .open_reserved("campus.test".into(), 8080, retained)
        .unwrap();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, bridge.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let secret: Vec<_> = (0..64)
        .step_by(2)
        .map(|i| u8::from_str_radix(&bridge.secret[i..i + 2], 16).unwrap())
        .collect();
    stream.write_all(&secret).unwrap();
    stream.write_all(b"after-cancel").unwrap();
    let mut reply = [0; 12];
    stream.read_exact(&mut reply).unwrap();
    assert_eq!(&reply, b"after-cancel");
    // 已鉴权业务流不受迟到的目标建连取消影响，避免清理失败或 TTL 误伤payload。
    handle.cancel_open(retained);
    stream.write_all(b"after-cancel").unwrap();
    stream.read_exact(&mut reply).unwrap();
    assert_eq!(&reply, b"after-cancel");
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
            &json!({"host":"localhost", "port":port, "user":"synthetic", "token":"test-token"}),
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
            &json!({"host":"localhost", "port":port, "user":"synthetic", "token":"test-token"}),
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
fn running_flag_does_not_hide_stalled_worker() {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let socket = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (_peer, _) = listener.accept().unwrap();
    let (commands, receiver) = mpsc::sync_channel(1);
    let now = Instant::now();
    let handle = Handle {
        opens: Arc::new(Mutex::new(HashMap::new())),
        next_open: Arc::new(AtomicUsize::new(1)),
        commands,
        running: Arc::new(AtomicBool::new(true)),
        exit_reason: Arc::new(Mutex::new(None)),
        socket: Arc::new(socket),
        health: Arc::new(Mutex::new(Health {
            progress: now,
            received: now,
            heartbeats: 1,
            received_bytes: 12,
            recovering: false,
            dns_timeouts: 0,
            tcp_timeouts: 0,
            loop_iterations: 0,
        })),
    };
    assert_eq!(handle.status()["healthy"], true);
    handle.health.lock().unwrap().progress = now - Duration::from_secs(40);
    assert_eq!(handle.status()["alive"], true);
    assert_eq!(handle.status()["healthy"], false);
    handle.health.lock().unwrap().progress = Instant::now();
    handle.health.lock().unwrap().recovering = true;
    assert_eq!(handle.status()["healthy"], false);
    // 工作线程退出时 Open 的回执会断开，应保留连接错误而非伪装成超时。
    let opening = handle.clone();
    let worker = thread::spawn(move || opening.open("campus.test".into(), 8080));
    drop(receiver.recv_timeout(Duration::from_secs(1)).unwrap());
    assert!(worker
        .join()
        .unwrap()
        .is_err_and(|error| { error.kind() == io::ErrorKind::ConnectionAborted }));
    handle.stop();
    assert_eq!(handle.status()["alive"], false);
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
    let _ = release.send(());
    worker.join().unwrap();
}
