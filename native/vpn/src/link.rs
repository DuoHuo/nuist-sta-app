//! 有界的 IP 链路，不创建 TUN，也不修改系统路由。

use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;
use std::collections::VecDeque;

const CAPACITY: usize = 256;

#[derive(Default)]
pub struct IpLink {
    pub incoming: VecDeque<Vec<u8>>,
    pub outgoing: VecDeque<Vec<u8>>,
}

impl IpLink {
    pub fn inject(&mut self, packet: Vec<u8>) {
        // 接收拥塞时丢包，交给 TCP 重传，避免无限占用内存。
        if self.incoming.len() < CAPACITY {
            self.incoming.push_back(packet);
        }
    }
}

pub struct Rx(Vec<u8>);
pub struct Tx<'a>(&'a mut VecDeque<Vec<u8>>);

impl RxToken for Rx {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}

impl TxToken for Tx<'_> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut packet = vec![0; len];
        let result = f(&mut packet);
        self.0.push_back(packet);
        result
    }
}

impl Device for IpLink {
    type RxToken<'a> = Rx;
    type TxToken<'a> = Tx<'a>;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Rx, Tx<'_>)> {
        if self.outgoing.len() >= CAPACITY {
            return None;
        }
        Some((Rx(self.incoming.pop_front()?), Tx(&mut self.outgoing)))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Tx<'_>> {
        (self.outgoing.len() < CAPACITY).then_some(Tx(&mut self.outgoing))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = crate::frame::MTU;
        caps
    }
}
