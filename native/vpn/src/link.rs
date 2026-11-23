//! 有界的 IP 链路，不创建 TUN，也不修改系统路由。

use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;
use std::collections::VecDeque;

const CAPACITY: usize = 256;

#[derive(Default)]
pub struct IpLink {
    pub incoming: VecDeque<Vec<u8>>,
    pub outgoing: VecDeque<Vec<u8>>,
    draining: bool,
}

impl IpLink {
    /// 可接收的数据包数量，用于在读取 TLS 明文前施加背压。
    pub fn receive_capacity(&self) -> usize {
        CAPACITY.saturating_sub(self.incoming.len())
    }

    /// 终态只交付已经收到的尾包，之后生成的 ACK 不再阻塞接收队列。
    pub fn enter_draining(&mut self) {
        self.draining = true;
        self.outgoing.clear();
    }

    pub fn can_transmit(&self) -> bool {
        self.draining || self.outgoing.len() < CAPACITY
    }

    pub fn inject(&mut self, packet: Vec<u8>) {
        // 接收拥塞时丢包，交给 TCP 重传，避免无限占用内存。
        if self.incoming.len() < CAPACITY {
            self.incoming.push_back(packet);
        }
    }
}

pub struct Rx(Vec<u8>);
pub struct Tx<'a>(Option<&'a mut VecDeque<Vec<u8>>>);

impl RxToken for Rx {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}

impl TxToken for Tx<'_> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut packet = vec![0; len];
        let result = f(&mut packet);
        if let Some(queue) = self.0 {
            queue.push_back(packet);
        }
        result
    }
}

impl Device for IpLink {
    type RxToken<'a> = Rx;
    type TxToken<'a> = Tx<'a>;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Rx, Tx<'_>)> {
        if !self.can_transmit() {
            return None;
        }
        Some((
            Rx(self.incoming.pop_front()?),
            Tx(if self.draining {
                None
            } else {
                Some(&mut self.outgoing)
            }),
        ))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Tx<'_>> {
        self.can_transmit().then_some(Tx(if self.draining {
            None
        } else {
            Some(&mut self.outgoing)
        }))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = crate::frame::MTU;
        caps
    }
}
