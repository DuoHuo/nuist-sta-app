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
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker = thread::spawn(move || serve(listener, stopped));
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

fn serve(listener: TcpListener, stop: Arc<AtomicBool>) -> (usize, bool) {
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
    while !stop.load(Ordering::Acquire) && started.elapsed() < Duration::from_secs(30) {
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
                    if !dropped_syn && packet[9] == 6 {
                        dropped_syn = true;
                    } else {
                        device.inject(packet.to_vec());
                    }
                }
                1 => {
                    tls.conn
                        .writer()
                        .write_all(&[1, 2, 0, 8, 0, 0, 0, 0])
                        .unwrap();
                }
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
        thread::sleep(Duration::from_millis(2));
    }
    (received, graceful)
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
    let bridge = handle.open("campus.test".into(), 8080).unwrap();
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
