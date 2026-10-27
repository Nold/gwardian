//! Splitting protocol messages into small packets for Bluetooth LE.
//!
//! A BLE write or notification carries 20 to ~500 bytes depending on the
//! negotiated MTU, far less than an offer (1218 bytes) or a sealed pad. Both
//! apps use this module so iOS and Android agree on the format.
//!
//! ```text
//! start packet:  0x01 │ message id │ total length (u32 BE) │ CRC-32 (u32 BE) │ data…
//! data packet:   0x02 │ message id │ index (u24 BE)                          │ data…
//! ```
//!
//! - Packets of one message are sent in order; data packets count from 1.
//! - The message id increments per message, so stray packets of an earlier
//!   message are recognized.
//! - The CRC-32 catches corruption or a missing packet. It is not a security
//!   measure: the transfer protocol authenticates everything it accepts.
//!
//! BLE delivers packets reliably and in order, so any gap is an error and the
//! transfer starts over rather than requesting retransmission.

use ash_core::crc;

use crate::error::{Error, Result};

/// GATT service advertised by the device receiving a pad. See
/// `docs/ble-transfer.md` for roles and characteristics.
pub const BLE_SERVICE_UUID: &str = "77c45bd0-3c1a-4051-959d-387547be92f7";
/// Characteristic the pad owner (central) writes its messages to.
pub const BLE_TO_RECEIVER_UUID: &str = "31fa7cbc-d38b-42f7-95f0-26023575637c";
/// Characteristic the receiver (peripheral) notifies its messages on.
pub const BLE_TO_SENDER_UUID: &str = "6b284ef0-96af-4d31-9672-b73d80f71d78";

/// Smallest usable packet: the default BLE MTU of 23 minus 3 bytes of ATT header.
pub const MIN_PACKET_SIZE: usize = 20;
/// Largest message accepted, matching the relay's limit.
pub const MAX_MESSAGE_SIZE: usize = 2 * 1024 * 1024;

const START: u8 = 0x01;
const DATA: u8 = 0x02;
const START_HEADER: usize = 10;
const DATA_HEADER: usize = 5;
const MAX_INDEX: u32 = (1 << 24) - 1;

fn malformed(reason: &'static str) -> Error {
    Error::Malformed { reason }
}

/// Split `message` into packets of at most `max_packet` bytes.
///
/// # Errors
///
/// `Malformed` if `max_packet` is below `MIN_PACKET_SIZE`, the message is
/// empty or larger than `MAX_MESSAGE_SIZE`.
pub fn packets(message: &[u8], message_id: u8, max_packet: usize) -> Result<Vec<Vec<u8>>> {
    if max_packet < MIN_PACKET_SIZE {
        return Err(malformed("packet size below BLE minimum"));
    }
    if message.is_empty() || message.len() > MAX_MESSAGE_SIZE {
        return Err(malformed("message size out of range"));
    }

    let first_len = message.len().min(max_packet - START_HEADER);
    let mut start = Vec::with_capacity(START_HEADER + first_len);
    start.extend_from_slice(&[START, message_id]);
    start.extend_from_slice(&(message.len() as u32).to_be_bytes());
    start.extend_from_slice(&crc::compute(message).to_be_bytes());
    start.extend_from_slice(&message[..first_len]);

    let mut out = vec![start];
    for (i, chunk) in message[first_len..]
        .chunks(max_packet - DATA_HEADER)
        .enumerate()
    {
        let index = (i + 1) as u32;
        let mut packet = Vec::with_capacity(DATA_HEADER + chunk.len());
        packet.extend_from_slice(&[DATA, message_id]);
        packet.extend_from_slice(&index.to_be_bytes()[1..]);
        packet.extend_from_slice(chunk);
        out.push(packet);
    }
    Ok(out)
}

struct InProgress {
    message_id: u8,
    total: usize,
    crc: u32,
    next_index: u32,
    data: Vec<u8>,
}

/// Rebuilds messages from packets received in order.
#[derive(Default)]
pub struct Reassembler {
    current: Option<InProgress>,
}

impl Reassembler {
    /// Create a reassembler waiting for a start packet.
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed one packet; returns the message once its last packet arrives.
    ///
    /// # Errors
    ///
    /// `Malformed` on an unknown packet type, a packet out of order or from
    /// another message, a declared size out of range, or a CRC mismatch. The
    /// partial message is dropped; the next start packet begins afresh.
    pub fn push(&mut self, packet: &[u8]) -> Result<Option<Vec<u8>>> {
        let result = self.accept(packet);
        if result.is_err() {
            self.current = None;
        }
        result
    }

    fn accept(&mut self, packet: &[u8]) -> Result<Option<Vec<u8>>> {
        match packet {
            [START, message_id, rest @ ..] if rest.len() >= START_HEADER - 2 => {
                let total = u32::from_be_bytes(rest[..4].try_into().expect("4 bytes")) as usize;
                let crc = u32::from_be_bytes(rest[4..8].try_into().expect("4 bytes"));
                let data = &rest[8..];
                if total == 0 || total > MAX_MESSAGE_SIZE || data.len() > total {
                    return Err(malformed("declared message size out of range"));
                }
                let mut buffer = Vec::with_capacity(total);
                buffer.extend_from_slice(data);
                self.current = Some(InProgress {
                    message_id: *message_id,
                    total,
                    crc,
                    next_index: 1,
                    data: buffer,
                });
            }
            [DATA, message_id, i0, i1, i2, data @ ..] => {
                let current = self
                    .current
                    .as_mut()
                    .ok_or(malformed("data packet without start"))?;
                let index = u32::from_be_bytes([0, *i0, *i1, *i2]);
                if *message_id != current.message_id {
                    return Err(malformed("packet from another message"));
                }
                if index != current.next_index || index > MAX_INDEX {
                    return Err(malformed("packet out of order"));
                }
                if current.data.len() + data.len() > current.total {
                    return Err(malformed("more data than declared"));
                }
                current.data.extend_from_slice(data);
                current.next_index += 1;
            }
            _ => return Err(malformed("unknown or truncated packet")),
        }

        let complete = self
            .current
            .as_ref()
            .is_some_and(|c| c.data.len() == c.total);
        if !complete {
            return Ok(None);
        }
        let done = self.current.take().expect("checked above");
        if crc::compute(&done.data) != done.crc {
            return Err(malformed("message checksum mismatch"));
        }
        Ok(Some(done.data))
    }

    /// Whether a message is partly received.
    pub fn is_receiving(&self) -> bool {
        self.current.is_some()
    }

    /// Progress of the message in flight, from 0.0 to 1.0.
    pub fn progress(&self) -> f64 {
        self.current
            .as_ref()
            .map_or(0.0, |c| c.data.len() as f64 / c.total as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 7 + 3) as u8).collect()
    }

    fn roundtrip(len: usize, max_packet: usize) {
        let original = message(len);
        let packets = packets(&original, 9, max_packet).unwrap();
        assert!(packets.iter().all(|p| p.len() <= max_packet));
        let mut reassembler = Reassembler::new();
        let (last, rest) = packets.split_last().unwrap();
        for packet in rest {
            assert_eq!(reassembler.push(packet).unwrap(), None);
        }
        assert_eq!(reassembler.push(last).unwrap(), Some(original));
        assert!(!reassembler.is_receiving());
    }

    #[test]
    fn roundtrip_various_sizes() {
        for (len, max) in [
            (1, 20),
            (10, 20),
            (11, 20),
            (1218, 20),
            (1218, 185),
            (1218, 512),
            (1024 * 1024 + 16, 182),
            (MAX_MESSAGE_SIZE, 512),
        ] {
            roundtrip(len, max);
        }
    }

    #[test]
    fn single_packet_message() {
        let packets = packets(b"hi", 1, 20).unwrap();
        assert_eq!(packets.len(), 1);
        assert_eq!(
            Reassembler::new().push(&packets[0]).unwrap(),
            Some(b"hi".to_vec())
        );
    }

    #[test]
    fn consecutive_messages() {
        let mut reassembler = Reassembler::new();
        for id in 0..3u8 {
            let original = message(500 + id as usize);
            let mut result = None;
            for packet in packets(&original, id, 64).unwrap() {
                result = reassembler.push(&packet).unwrap();
            }
            assert_eq!(result, Some(original));
        }
    }

    #[test]
    fn progress_is_reported() {
        let packets = packets(&message(1000), 1, 110).unwrap();
        let mut reassembler = Reassembler::new();
        assert_eq!(reassembler.progress(), 0.0);
        reassembler.push(&packets[0]).unwrap();
        assert!(reassembler.is_receiving());
        assert!((reassembler.progress() - 0.1).abs() < 1e-9);
    }

    #[test]
    fn missing_packet_detected() {
        let packets = packets(&message(300), 1, 40).unwrap();
        let mut reassembler = Reassembler::new();
        reassembler.push(&packets[0]).unwrap();
        assert!(reassembler.push(&packets[2]).is_err());
        // The partial message was dropped
        assert!(!reassembler.is_receiving());
        assert!(reassembler.push(&packets[3]).is_err());
    }

    #[test]
    fn corruption_detected() {
        let mut packets = packets(&message(300), 1, 40).unwrap();
        let last = packets.len() - 1;
        packets[last][7] ^= 1;
        let mut reassembler = Reassembler::new();
        let mut result = Ok(None);
        for packet in &packets {
            result = reassembler.push(packet);
        }
        assert_eq!(
            result,
            Err(Error::Malformed {
                reason: "message checksum mismatch"
            })
        );
    }

    #[test]
    fn stray_packet_from_other_message_detected() {
        let first = packets(&message(300), 1, 40).unwrap();
        let second = packets(&message(300), 2, 40).unwrap();
        let mut reassembler = Reassembler::new();
        reassembler.push(&second[0]).unwrap();
        assert!(reassembler.push(&first[1]).is_err());
    }

    #[test]
    fn invalid_inputs_rejected() {
        assert!(packets(b"x", 0, 19).is_err());
        assert!(packets(b"", 0, 20).is_err());
        assert!(packets(&vec![0; MAX_MESSAGE_SIZE + 1], 0, 512).is_err());

        let mut reassembler = Reassembler::new();
        assert!(reassembler.push(&[]).is_err());
        assert!(reassembler.push(&[0x07, 1, 2]).is_err());
        assert!(reassembler.push(&[DATA, 1, 0, 0, 1, 5]).is_err());
        // Declared size above the limit
        let mut oversized = vec![START, 1];
        oversized.extend_from_slice(&((MAX_MESSAGE_SIZE + 1) as u32).to_be_bytes());
        oversized.extend_from_slice(&[0; 4]);
        assert!(reassembler.push(&oversized).is_err());
    }
}
