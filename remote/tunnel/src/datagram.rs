//! Bounded, lossy fragmentation: video packets never wait behind TCP/file traffic.
use bytes::Bytes;
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

const HEADER: usize = 10;
const MAX_PACKET: usize = 65_507;
const MAX_PARTS: usize = 80;
const MAX_PENDING: usize = 128;
const LIFETIME: Duration = Duration::from_millis(500);

pub fn fragments(flow: u32, sequence: u32, payload: &[u8], mtu: usize) -> Vec<Bytes> {
    let chunk = mtu.saturating_sub(HEADER).min(1100);
    if chunk < 900 || payload.len() > MAX_PACKET {
        return vec![];
    }
    let count = payload.len().max(1).div_ceil(chunk);
    if count > MAX_PARTS {
        return vec![];
    }
    (0..count)
        .map(|index| {
            let mut data = Vec::with_capacity(mtu);
            data.extend_from_slice(&flow.to_be_bytes());
            data.extend_from_slice(&sequence.to_be_bytes());
            data.extend_from_slice(&[index as u8, count as u8]);
            let start = index * chunk;
            data.extend_from_slice(&payload[start..payload.len().min(start + chunk)]);
            Bytes::from(data)
        })
        .collect()
}

struct Pending {
    at: Instant,
    parts: Vec<Option<Bytes>>,
    size: usize,
}
#[derive(Default)]
pub struct Assembler {
    pending: HashMap<(u32, u32), Pending>,
}
impl Assembler {
    pub fn receive(&mut self, data: Bytes) -> Option<(u32, Vec<u8>)> {
        self.pending.retain(|_, p| p.at.elapsed() < LIFETIME);
        if data.len() < HEADER || data.len() > 1110 {
            return None;
        }
        let flow = u32::from_be_bytes(data[..4].try_into().ok()?);
        let sequence = u32::from_be_bytes(data[4..8].try_into().ok()?);
        let index = data[8] as usize;
        let count = data[9] as usize;
        if count == 0 || count > MAX_PARTS || index >= count {
            return None;
        }
        let key = (flow, sequence);
        if !self.pending.contains_key(&key) && self.pending.len() >= MAX_PENDING {
            return None;
        }
        let packet = self.pending.entry(key).or_insert_with(|| Pending {
            at: Instant::now(),
            parts: vec![None; count],
            size: 0,
        });
        if packet.parts.len() != count {
            return None;
        }
        if packet.parts[index].is_none() {
            packet.size += data.len() - HEADER;
            packet.parts[index] = Some(data.slice(HEADER..));
        }
        if packet.size > MAX_PACKET {
            self.pending.remove(&key);
            return None;
        }
        if packet.parts.iter().all(Option::is_some) {
            let packet = self.pending.remove(&key)?;
            return Some((flow, packet.parts.into_iter().flatten().flatten().collect()));
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reordered_duplicate_fragments_restore_large_udp_packets() {
        let data = vec![42; 65_507];
        let mut pieces = fragments(7, 9, &data, 1100);
        let mut assembler = Assembler::default();
        let first = pieces.pop().unwrap();
        assert!(assembler.receive(first.clone()).is_none());
        assert!(assembler.receive(first).is_none());
        let mut result = None;
        for piece in pieces.into_iter().rev() {
            result = assembler.receive(piece);
        }
        assert_eq!(result, Some((7, data)));
    }
    #[test]
    fn malformed_and_unbounded_packets_are_dropped() {
        let mut assembler = Assembler::default();
        for count in [0, 81, 255] {
            let mut invalid = vec![0; 11];
            invalid[9] = count;
            assert!(assembler.receive(invalid.into()).is_none());
        }
        assert!(fragments(0, 0, &vec![0; 65_508], 1100).is_empty());
        for seq in 0..1000 {
            assembler.receive(fragments(0, seq, &vec![0; 2000], 1100).remove(0));
        }
        assert_eq!(assembler.pending.len(), MAX_PENDING);
    }
}
