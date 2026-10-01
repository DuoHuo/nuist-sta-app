//! EnAgent 报文编解码。发送头 12 字节、接收头 8 字节；握手响应单独解析。

use std::io::{self, Read, Write};
use std::net::Ipv4Addr;

pub const MTU: usize = 1500;
pub const MAX_FRAME: usize = 65535;

#[derive(Clone, Debug)]
pub struct AuthInfo {
    pub address: Ipv4Addr,
    pub dns: Ipv4Addr,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

pub fn handshake(user: &str, token: &str) -> io::Result<Vec<u8>> {
    if user.is_empty() || token.is_empty() || user.len() > 255 || token.len() > 255 {
        return Err(invalid("隧道握手字段长度不合法"));
    }
    let mut bytes = vec![1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0];
    bytes.extend_from_slice(&[1, 0, user.len() as u8]);
    bytes.extend_from_slice(user.as_bytes());
    bytes.extend_from_slice(&[2, 0, token.len() as u8]);
    bytes.extend_from_slice(token.as_bytes());
    bytes.push(255);
    let len = bytes.len() as u16;
    bytes[2..4].copy_from_slice(&len.to_be_bytes());
    Ok(bytes)
}

pub fn authenticate(
    stream: &mut (impl Read + Write),
    user: &str,
    token: &str,
) -> io::Result<AuthInfo> {
    stream.write_all(&handshake(user, token)?)?;
    stream.flush()?;
    let mut header = [0; 12];
    stream.read_exact(&mut header)?;
    let length = u16::from_be_bytes([header[2], header[3]]) as usize;
    if header[0] != 1 || header[1] != 2 || !(12..=MAX_FRAME).contains(&length) {
        return Err(invalid("VPN 握手响应头不合法"));
    }
    let mut body = vec![0; length - 12];
    stream.read_exact(&mut body)?;
    let code = u16::from_be_bytes([header[10], header[11]]);
    if header[8] != 1 || code != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("VPN 握手被拒绝（{code:04X}）"),
        ));
    }
    parse_auth(&body)
}

pub fn parse_auth(body: &[u8]) -> io::Result<AuthInfo> {
    let mut address = None;
    let mut dns = None;
    let mut offset = 0;
    while offset < body.len() {
        let kind = body[offset];
        if kind == 255 {
            break;
        }
        let header = body
            .get(offset..offset + 3)
            .ok_or_else(|| invalid("VPN TLV 头被截断"))?;
        let size = u16::from_be_bytes([header[1], header[2]]) as usize;
        offset += 3;
        let value = body
            .get(offset..offset + size)
            .ok_or_else(|| invalid("VPN TLV 值被截断"))?;
        match kind {
            0x0b => {
                let bytes: [u8; 4] = value
                    .try_into()
                    .map_err(|_| invalid("VPN 虚拟地址不合法"))?;
                let ip = Ipv4Addr::from(bytes);
                if ip.is_unspecified() || ip.is_multicast() || ip.is_loopback() {
                    return Err(invalid("VPN 虚拟地址不可用"));
                }
                address = Some(ip);
            }
            0x24 => {
                dns = Some(
                    std::str::from_utf8(value)
                        .map_err(|_| invalid("VPN DNS 编码不合法"))?
                        .trim_end_matches('\0')
                        .parse()
                        .map_err(|_| invalid("VPN DNS 地址不合法"))?,
                );
            }
            _ => {}
        }
        offset += size;
    }
    Ok(AuthInfo {
        address: address.ok_or_else(|| invalid("VPN 未下发虚拟 IPv4"))?,
        dns: dns.ok_or_else(|| invalid("VPN 未下发 DNS IPv4"))?,
    })
}

pub fn data(packet: &[u8]) -> io::Result<Vec<u8>> {
    if packet.len() < 20 || packet[0] >> 4 != 4 || packet.len() + 12 > MAX_FRAME {
        return Err(invalid("VPN 仅支持合法的 IPv4 数据包"));
    }
    let mut bytes = vec![0; packet.len() + 12];
    bytes[0] = 1;
    bytes[1] = 4;
    let length = bytes.len() as u16;
    bytes[2..4].copy_from_slice(&length.to_be_bytes());
    bytes[11] = 0x29;
    bytes[12..].copy_from_slice(packet);
    Ok(bytes)
}

pub fn heartbeat(counter: u32) -> [u8; 16] {
    let mut bytes = [0; 16];
    bytes[..4].copy_from_slice(&[1, 1, 0, 16]);
    bytes[8] = 3;
    bytes[12..].copy_from_slice(&counter.to_le_bytes());
    bytes
}

/// 按总长度拆包，允许 TLS 分片、合并，以及控制帧和数据帧交错。
#[derive(Default)]
pub struct Decoder {
    bytes: Vec<u8>,
}

impl Decoder {
    pub fn push(&mut self, bytes: &[u8]) -> io::Result<Vec<Vec<u8>>> {
        if self.bytes.len() + bytes.len() > MAX_FRAME * 2 {
            return Err(invalid("VPN 接收缓冲超限"));
        }
        self.bytes.extend_from_slice(bytes);
        let mut packets = Vec::new();
        let mut offset = 0;
        while self.bytes.len() - offset >= 8 {
            let h = &self.bytes[offset..offset + 8];
            let length = u16::from_be_bytes([h[2], h[3]]) as usize;
            if h[0] != 1 || length < 8 || ![2, 4, 8].contains(&h[1]) {
                return Err(invalid("VPN 数据帧头不合法"));
            }
            if self.bytes.len() - offset < length {
                break;
            }
            if h[1] == 4 {
                let packet = &self.bytes[offset + 8..offset + length];
                if packet.len() < 20 || packet[0] >> 4 != 4 {
                    return Err(invalid("VPN 收到损坏的 IPv4 包"));
                }
                packets.push(packet.to_vec());
            }
            // 当前仅启用 IPv4，控制帧和 IPv6 帧都不注入协议栈。
            offset += length;
        }
        self.bytes.drain(..offset);
        Ok(packets)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_layout_matches_reference() {
        assert_eq!(
            handshake("u", "t").unwrap(),
            vec![1, 1, 0, 21, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, b'u', 2, 0, 1, b't', 255]
        );
        let mut packet = vec![0; 20];
        packet[0] = 0x45;
        let encoded = data(&packet).unwrap();
        assert_eq!(&encoded[..12], &[1, 4, 0, 32, 0, 0, 0, 0, 0, 0, 0, 41]);
        assert_eq!(&heartbeat(0x12345678)[12..], &[0x78, 0x56, 0x34, 0x12]);
    }

    #[test]
    fn fragmented_and_coalesced_frames() {
        let mut wire = vec![1, 2, 0, 8, 0, 0, 0, 0, 1, 4, 0, 28, 0, 0, 0, 0];
        wire.extend_from_slice(&[0x45; 20]);
        for split in 0..wire.len() {
            let mut decoder = Decoder::default();
            let mut packets = decoder.push(&wire[..split]).unwrap();
            packets.extend(decoder.push(&wire[split..]).unwrap());
            assert_eq!(packets, vec![vec![0x45; 20]]);
        }
        assert!(Decoder::default().push(&[1, 4, 0, 7, 0, 0, 0, 0]).is_err());
    }

    #[test]
    fn parse_binary_address_and_text_dns() {
        let body = [
            11, 0, 4, 1, 1, 8, 42, 36, 0, 9, b'1', b'2', b'7', b'.', b'0', b'.', b'0', b'.', b'1',
            255,
        ];
        let info = parse_auth(&body).unwrap();
        assert_eq!(info.address, Ipv4Addr::new(1, 1, 8, 42));
        assert_eq!(info.dns, Ipv4Addr::LOCALHOST);
        assert!(parse_auth(&body[..15]).is_err());
        assert!(parse_auth(&[255]).is_err());
    }
}
