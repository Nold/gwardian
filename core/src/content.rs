//! Payloads of control messages: deletion requests and expiring text.
//!
//! Both travel encrypted like any message, so the relay cannot tell them
//! from text.
//!
//! # Delete (`MessageType::Delete`)
//!
//! ```text
//! [offset: u64 big-endian]
//! ```
//!
//! `offset` is where the keys of the message to delete started in the
//! sender's pad: the relay `sequence` of a two-person message, or the
//! `offset` of a group frame. A request only ever refers to a message of
//! the same sender, so receivers delete the message with this offset from
//! this sender and nothing else. Deletion on the other phones is a request:
//! a modified app or an earlier screenshot can keep the message.
//!
//! # Expiring text (`MessageType::ExpiringText`)
//!
//! ```text
//! [seconds: u32 big-endian][text: UTF-8]
//! ```
//!
//! The text disappears `seconds` after it is shown on the receiving phone.
//! `seconds` must be at least 1; plain `Text` follows the conversation's
//! setting instead.

use crate::error::{Error, Result};

/// Size of a delete request payload.
pub const DELETE_PAYLOAD_SIZE: usize = 8;

/// Encode a request to delete the sender's message whose keys started at `offset`.
pub fn encode_delete(offset: u64) -> [u8; DELETE_PAYLOAD_SIZE] {
    offset.to_be_bytes()
}

/// Decode a delete request payload into the offset of the message to delete.
///
/// # Errors
///
/// `InvalidContent` if the payload is not exactly 8 bytes.
pub fn decode_delete(payload: &[u8]) -> Result<u64> {
    let bytes: [u8; DELETE_PAYLOAD_SIZE] =
        payload.try_into().map_err(|_| Error::InvalidContent {
            reason: "delete request must be 8 bytes",
        })?;
    Ok(u64::from_be_bytes(bytes))
}

/// Encode text that disappears `seconds` after it is shown.
///
/// # Errors
///
/// `InvalidContent` if `seconds` is 0.
pub fn encode_expiring_text(seconds: u32, text: &str) -> Result<Vec<u8>> {
    if seconds == 0 {
        return Err(Error::InvalidContent {
            reason: "lifetime must be at least one second",
        });
    }
    let mut payload = Vec::with_capacity(4 + text.len());
    payload.extend_from_slice(&seconds.to_be_bytes());
    payload.extend_from_slice(text.as_bytes());
    Ok(payload)
}

/// Decode an expiring text payload into its lifetime and text.
///
/// # Errors
///
/// `InvalidContent` if the payload is shorter than 4 bytes, the lifetime is
/// 0 or the text is not UTF-8.
pub fn decode_expiring_text(payload: &[u8]) -> Result<(u32, String)> {
    if payload.len() < 4 {
        return Err(Error::InvalidContent {
            reason: "expiring text shorter than its lifetime",
        });
    }
    let seconds = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
    if seconds == 0 {
        return Err(Error::InvalidContent {
            reason: "lifetime must be at least one second",
        });
    }
    let text = String::from_utf8(payload[4..].to_vec()).map_err(|_| Error::InvalidContent {
        reason: "expiring text is not UTF-8",
    })?;
    Ok((seconds, text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delete_round_trip() {
        for offset in [0, 160, u64::MAX] {
            assert_eq!(decode_delete(&encode_delete(offset)).unwrap(), offset);
        }
        assert_eq!(encode_delete(1), [0, 0, 0, 0, 0, 0, 0, 1]);
    }

    #[test]
    fn delete_rejects_wrong_size() {
        assert!(decode_delete(&[]).is_err());
        assert!(decode_delete(&[0; 7]).is_err());
        assert!(decode_delete(&[0; 9]).is_err());
    }

    #[test]
    fn expiring_text_round_trip() {
        let payload = encode_expiring_text(30, "à bientôt").unwrap();
        assert_eq!(&payload[..4], &[0, 0, 0, 30]);
        assert_eq!(
            decode_expiring_text(&payload).unwrap(),
            (30, "à bientôt".to_string())
        );
        assert_eq!(
            decode_expiring_text(&encode_expiring_text(5, "").unwrap()).unwrap(),
            (5, String::new())
        );
    }

    #[test]
    fn expiring_text_rejects_bad_payloads() {
        assert!(encode_expiring_text(0, "x").is_err());
        assert!(decode_expiring_text(&[0, 0, 0]).is_err());
        assert!(decode_expiring_text(&[0, 0, 0, 0, b'x']).is_err());
        assert!(decode_expiring_text(&[0, 0, 0, 1, 0xFF]).is_err());
    }

    #[test]
    fn control_messages_go_through_the_group_like_text() {
        use crate::group::{Group, GroupFrame, MemberPad, SecurityLevel};
        use crate::message::MessageType;

        let pad = |seed: u8| {
            MemberPad::from_bytes(
                (0..4096u32).map(|i| (i as u8) ^ seed).collect(),
                SecurityLevel::Maximum,
            )
        };
        let mut alice = Group::new(0, pad(0));
        alice.add_member(1, pad(1)).unwrap();
        let mut bob = Group::new(1, pad(1));
        bob.add_member(0, pad(0)).unwrap();

        let text =
            GroupFrame::decode(&alice.encrypt(MessageType::Text, b"hi").unwrap().encode()).unwrap();
        let delete = alice
            .encrypt(MessageType::Delete, &encode_delete(text.offset))
            .unwrap();
        bob.decrypt(&text).unwrap();
        let delete = GroupFrame::decode(&delete.encode()).unwrap();
        assert_eq!(delete.frame.msg_type, MessageType::Delete);
        assert_eq!(
            decode_delete(&bob.decrypt(&delete).unwrap()).unwrap(),
            text.offset
        );
    }
}
