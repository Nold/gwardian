//! Group messaging with one sending pad per member.
//!
//! In a group, every member owns a pad that only they encrypt with.
//! Every other member holds a copy of that pad so they can decrypt.
//! Because a pad has a single writer, two members can never consume the
//! same bytes, whatever the size of the group.
//!
//! ```text
//!              sends with   holds copies of
//! member 0  →  pad 0        pad 1, pad 2
//! member 1  →  pad 1        pad 0, pad 2
//! member 2  →  pad 2        pad 0, pad 1
//! ```
//!
//! # Frame Format (v1)
//!
//! ```text
//! ┌─────────┬────────┬─────────────┬──────────────────────┐
//! │ version │ sender │ offset      │ message frame        │
//! │ 1 byte  │ 1 byte │ 8 bytes (BE)│ see `message` module │
//! └─────────┴────────┴─────────────┴──────────────────────┘
//! ```
//!
//! - **sender**: Member whose pad was used
//! - **offset**: Position in the sender's pad where this message's keys start
//!
//! Each message consumes `AUTH_KEY_SIZE + ciphertext length` bytes of the
//! sender's pad starting at `offset`: first the authentication key, then
//! the encryption key.
//!
//! # Security Properties
//!
//! - **sender** and **offset** are not covered by the MAC directly, but they
//!   select the authentication key, so tampering with either makes
//!   verification fail.
//! - Receivers consume a range only after the tag verifies, so forged frames
//!   cannot burn pad bytes.
//! - A range is accepted at most once: replays are rejected.
//! - Messages may arrive out of order or be lost without desynchronizing.
//!
//! # Limitations
//!
//! - Authenticity is per group, not per member: every member holds every pad,
//!   so a malicious member can forge messages under another member's id.
//! - Removing a member does not revoke the copies they hold. Remaining members
//!   must generate and exchange new pads.
//!
//! # Example
//!
//! ```
//! use ash_core::group::{Group, GroupFrame, MemberPad};
//! use ash_core::MessageType;
//!
//! let pad_alice = vec![0x11u8; 4096]; // From OS entropy in practice
//! let pad_bob = vec![0x22u8; 4096];
//!
//! let mut alice = Group::new(0, MemberPad::from_bytes(pad_alice.clone()));
//! alice.add_member(1, MemberPad::from_bytes(pad_bob.clone())).unwrap();
//!
//! let mut bob = Group::new(1, MemberPad::from_bytes(pad_bob));
//! bob.add_member(0, MemberPad::from_bytes(pad_alice)).unwrap();
//!
//! let wire = alice.encrypt(MessageType::Text, b"Hello").unwrap().encode();
//! let frame = GroupFrame::decode(&wire).unwrap();
//! assert_eq!(bob.decrypt(&frame).unwrap(), b"Hello");
//! ```

use std::collections::BTreeMap;

use crate::error::{Error, Result};
use crate::mac::{AuthKey, AUTH_KEY_SIZE};
use crate::message::{MessageFrame, MessageType, MAX_CIPHERTEXT_LEN};
use crate::pad::secure_zero;

/// Identifier of a member within a group.
pub type MemberId = u8;

/// Group frame format version.
pub const GROUP_FRAME_VERSION: u8 = 1;

/// Group header size in bytes (version + sender + offset).
pub const GROUP_HEADER_SIZE: usize = 10;

/// A member's sending pad, tracking which byte ranges have been consumed.
///
/// The owner consumes it sequentially when sending. Holders of a copy
/// consume the ranges named by received frames, in any order.
pub struct MemberPad {
    bytes: Vec<u8>,
    /// Consumed `[start, end)` ranges, sorted and non-overlapping.
    used: Vec<(usize, usize)>,
}

impl Drop for MemberPad {
    fn drop(&mut self) {
        secure_zero(&mut self.bytes);
    }
}

impl MemberPad {
    /// Create a fresh pad from raw bytes.
    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            used: Vec::new(),
        }
    }

    /// Restore a pad with its consumed ranges, as returned by `used_ranges`.
    pub fn from_bytes_with_state(bytes: Vec<u8>, used: &[(usize, usize)]) -> Self {
        let mut pad = Self::from_bytes(bytes);
        for &(start, end) in used {
            pad.mark_used(start, end);
        }
        pad
    }

    /// Consumed `[start, end)` ranges, for persistence.
    pub fn used_ranges(&self) -> &[(usize, usize)] {
        &self.used
    }

    /// Total pad size in bytes.
    pub fn total_size(&self) -> usize {
        self.bytes.len()
    }

    /// Number of bytes not consumed yet.
    pub fn remaining(&self) -> usize {
        let consumed: usize = self.used.iter().map(|&(start, end)| end - start).sum();
        self.bytes.len() - consumed
    }

    /// Offset where the owner's next message starts.
    ///
    /// The owner consumes sequentially, so this is the end of the last range.
    pub fn next_send_offset(&self) -> usize {
        self.used.last().map_or(0, |&(_, end)| end)
    }

    /// Bytes the owner can still send with, including the authentication key.
    pub fn available_for_sending(&self) -> usize {
        self.bytes.len() - self.next_send_offset()
    }

    fn check_range(&self, start: usize, len: usize) -> Result<usize> {
        let end = start
            .checked_add(len)
            .filter(|&end| end <= self.bytes.len())
            .ok_or(Error::InsufficientPadBytes {
                needed: len,
                available: self.bytes.len().saturating_sub(start),
            })?;
        let overlaps = self.used.iter().any(|&(s, e)| s < end && start < e);
        if overlaps {
            return Err(Error::PadRangeAlreadyUsed { offset: start });
        }
        Ok(end)
    }

    /// Consume `[start, end)`: wipe the bytes and record the range.
    fn burn(&mut self, start: usize, end: usize) {
        secure_zero(&mut self.bytes[start..end]);
        self.mark_used(start, end);
    }

    fn mark_used(&mut self, start: usize, end: usize) {
        if start >= end {
            return;
        }
        let pos = self.used.partition_point(|&(s, _)| s < start);
        self.used.insert(pos, (start, end));
        let mut merged: Vec<(usize, usize)> = Vec::with_capacity(self.used.len());
        for &(s, e) in &self.used {
            match merged.last_mut() {
                Some(last) if s <= last.1 => last.1 = last.1.max(e),
                _ => merged.push((s, e)),
            }
        }
        self.used = merged;
    }
}

/// An encrypted group message: sender, pad offset and authenticated frame.
#[derive(Debug, Clone)]
pub struct GroupFrame {
    /// Member whose pad encrypted this message.
    pub sender: MemberId,
    /// Offset in the sender's pad where this message's keys start.
    pub offset: u64,
    /// Authenticated message frame.
    pub frame: MessageFrame,
}

impl GroupFrame {
    /// Encode the frame to bytes for transmission.
    pub fn encode(&self) -> Vec<u8> {
        let inner = self.frame.encode();
        let mut out = Vec::with_capacity(GROUP_HEADER_SIZE + inner.len());
        out.push(GROUP_FRAME_VERSION);
        out.push(self.sender);
        out.extend_from_slice(&self.offset.to_be_bytes());
        out.extend_from_slice(&inner);
        out
    }

    /// Decode a frame from bytes. Does not verify authentication.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < GROUP_HEADER_SIZE {
            return Err(Error::FrameTooShort {
                size: bytes.len(),
                minimum: GROUP_HEADER_SIZE,
            });
        }
        if bytes[0] != GROUP_FRAME_VERSION {
            return Err(Error::UnsupportedFrameVersion { version: bytes[0] });
        }
        let mut offset = [0u8; 8];
        offset.copy_from_slice(&bytes[2..GROUP_HEADER_SIZE]);
        Ok(Self {
            sender: bytes[1],
            offset: u64::from_be_bytes(offset),
            frame: MessageFrame::decode(&bytes[GROUP_HEADER_SIZE..])?,
        })
    }
}

/// A member's view of a group: their own pad plus copies of everyone else's.
pub struct Group {
    me: MemberId,
    pads: BTreeMap<MemberId, MemberPad>,
}

impl Group {
    /// Create a group view for member `me`, who sends with `own_pad`.
    pub fn new(me: MemberId, own_pad: MemberPad) -> Self {
        let mut pads = BTreeMap::new();
        pads.insert(me, own_pad);
        Self { me, pads }
    }

    /// This device's member id.
    pub fn me(&self) -> MemberId {
        self.me
    }

    /// Ids of all members, including this device.
    pub fn members(&self) -> impl Iterator<Item = MemberId> + '_ {
        self.pads.keys().copied()
    }

    /// The pad of a member, if known.
    pub fn pad(&self, member: MemberId) -> Option<&MemberPad> {
        self.pads.get(&member)
    }

    /// Add a member with the copy of their sending pad.
    pub fn add_member(&mut self, member: MemberId, pad: MemberPad) -> Result<()> {
        if self.pads.contains_key(&member) {
            return Err(Error::DuplicateMember { member });
        }
        self.pads.insert(member, pad);
        Ok(())
    }

    /// Forget a member's pad. Cannot remove this device.
    ///
    /// This does not revoke the copies of other pads the member holds:
    /// remaining members must exchange new pads.
    pub fn remove_member(&mut self, member: MemberId) -> Option<MemberPad> {
        if member == self.me {
            return None;
        }
        self.pads.remove(&member)
    }

    /// Whether a message of `plaintext_len` bytes fits in this device's pad.
    pub fn can_send(&self, plaintext_len: usize) -> bool {
        AUTH_KEY_SIZE + plaintext_len <= self.own_pad().available_for_sending()
    }

    /// Encrypt a message with this device's pad.
    pub fn encrypt(&mut self, msg_type: MessageType, plaintext: &[u8]) -> Result<GroupFrame> {
        if plaintext.len() > MAX_CIPHERTEXT_LEN {
            return Err(Error::PayloadTooLarge {
                size: plaintext.len(),
                max: MAX_CIPHERTEXT_LEN,
            });
        }
        let me = self.me;
        let pad = self.pads.get_mut(&me).expect("own pad is always present");
        let start = pad.next_send_offset();
        let end = pad.check_range(start, AUTH_KEY_SIZE + plaintext.len())?;

        let auth_key = AuthKey::from_slice(&pad.bytes[start..start + AUTH_KEY_SIZE]);
        let result = MessageFrame::encrypt(
            msg_type,
            plaintext,
            &pad.bytes[start + AUTH_KEY_SIZE..end],
            &auth_key,
        );
        // Burn even if encryption failed: these keys must never be reused.
        pad.burn(start, end);

        Ok(GroupFrame {
            sender: me,
            offset: start as u64,
            frame: result?,
        })
    }

    /// Verify and decrypt a message from another member.
    ///
    /// The pad range is consumed only if authentication succeeds.
    pub fn decrypt(&mut self, frame: &GroupFrame) -> Result<Vec<u8>> {
        let pad = self
            .pads
            .get_mut(&frame.sender)
            .ok_or(Error::UnknownMember {
                member: frame.sender,
            })?;
        let start = usize::try_from(frame.offset).map_err(|_| Error::InsufficientPadBytes {
            needed: AUTH_KEY_SIZE + frame.frame.ciphertext.len(),
            available: 0,
        })?;
        let end = pad.check_range(start, AUTH_KEY_SIZE + frame.frame.ciphertext.len())?;

        let auth_key = AuthKey::from_slice(&pad.bytes[start..start + AUTH_KEY_SIZE]);
        let plaintext = frame
            .frame
            .decrypt(&pad.bytes[start + AUTH_KEY_SIZE..end], &auth_key)?;
        pad.burn(start, end);
        Ok(plaintext)
    }

    fn own_pad(&self) -> &MemberPad {
        &self.pads[&self.me]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pad_bytes(seed: u8, len: usize) -> Vec<u8> {
        (0..len)
            .map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed))
            .collect()
    }

    /// Build the view of each member of a group, all pads of `len` bytes.
    fn family(size: u8, len: usize) -> Vec<Group> {
        (0..size)
            .map(|me| {
                let mut group = Group::new(me, MemberPad::from_bytes(pad_bytes(me, len)));
                for other in (0..size).filter(|&o| o != me) {
                    group
                        .add_member(other, MemberPad::from_bytes(pad_bytes(other, len)))
                        .unwrap();
                }
                group
            })
            .collect()
    }

    fn send(group: &mut Group, text: &[u8]) -> GroupFrame {
        let wire = group.encrypt(MessageType::Text, text).unwrap().encode();
        GroupFrame::decode(&wire).unwrap()
    }

    #[test]
    fn every_member_reads_every_other() {
        let mut groups = family(4, 4096);
        for sender in 0..4 {
            let text = format!("hello from {}", sender);
            let frame = send(&mut groups[sender], text.as_bytes());
            for receiver in (0..4).filter(|&r| r != sender) {
                assert_eq!(groups[receiver].decrypt(&frame).unwrap(), text.as_bytes());
            }
        }
    }

    #[test]
    fn concurrent_senders_use_disjoint_keys() {
        let mut groups = family(3, 4096);
        // Members 0 and 1 send at the same time, before reading anything
        let a = send(&mut groups[0], b"from zero");
        let b = send(&mut groups[1], b"from one");
        assert_eq!(a.offset, 0);
        assert_eq!(b.offset, 0);
        assert_eq!(groups[2].decrypt(&a).unwrap(), b"from zero");
        assert_eq!(groups[2].decrypt(&b).unwrap(), b"from one");
    }

    #[test]
    fn out_of_order_and_lost_messages() {
        let mut groups = family(2, 4096);
        let m1 = send(&mut groups[0], b"first");
        let _lost = send(&mut groups[0], b"lost");
        let m3 = send(&mut groups[0], b"third");
        assert_eq!(groups[1].decrypt(&m3).unwrap(), b"third");
        assert_eq!(groups[1].decrypt(&m1).unwrap(), b"first");
    }

    #[test]
    fn replay_rejected() {
        let mut groups = family(2, 4096);
        let frame = send(&mut groups[0], b"once");
        groups[1].decrypt(&frame).unwrap();
        assert_eq!(
            groups[1].decrypt(&frame).unwrap_err(),
            Error::PadRangeAlreadyUsed { offset: 0 }
        );
    }

    #[test]
    fn own_echo_rejected() {
        let mut groups = family(2, 4096);
        let frame = send(&mut groups[0], b"echo");
        assert_eq!(
            groups[0].decrypt(&frame).unwrap_err(),
            Error::PadRangeAlreadyUsed { offset: 0 }
        );
    }

    #[test]
    fn unknown_sender_rejected() {
        let mut groups = family(2, 4096);
        let mut frame = send(&mut groups[0], b"hi");
        frame.sender = 9;
        assert_eq!(
            groups[1].decrypt(&frame).unwrap_err(),
            Error::UnknownMember { member: 9 }
        );
    }

    #[test]
    fn tampering_fails_without_burning_pad() {
        let mut groups = family(3, 4096);
        let frame = send(&mut groups[0], b"genuine");

        let mut wrong_sender = frame.clone();
        wrong_sender.sender = 2;
        assert_eq!(
            groups[1].decrypt(&wrong_sender).unwrap_err(),
            Error::AuthenticationFailed
        );

        let mut wrong_offset = frame.clone();
        wrong_offset.offset = 1;
        assert_eq!(
            groups[1].decrypt(&wrong_offset).unwrap_err(),
            Error::AuthenticationFailed
        );

        let mut flipped = frame.clone();
        flipped.frame.ciphertext[0] ^= 1;
        assert_eq!(
            groups[1].decrypt(&flipped).unwrap_err(),
            Error::AuthenticationFailed
        );

        // Nothing was consumed: the genuine message still decrypts
        assert!(groups[1].pad(0).unwrap().used_ranges().is_empty());
        assert!(groups[1].pad(2).unwrap().used_ranges().is_empty());
        assert_eq!(groups[1].decrypt(&frame).unwrap(), b"genuine");
    }

    #[test]
    fn offset_out_of_range_rejected() {
        let mut groups = family(2, 4096);
        let mut frame = send(&mut groups[0], b"hi");
        frame.offset = u64::MAX;
        assert!(matches!(
            groups[1].decrypt(&frame),
            Err(Error::InsufficientPadBytes { .. })
        ));
    }

    #[test]
    fn used_bytes_are_wiped() {
        let mut groups = family(2, 4096);
        let frame = send(&mut groups[0], b"wipe me");
        let len = AUTH_KEY_SIZE + frame.frame.ciphertext.len();
        assert!(groups[0].pads[&0].bytes[..len].iter().all(|&b| b == 0));

        groups[1].decrypt(&frame).unwrap();
        assert!(groups[1].pads[&0].bytes[..len].iter().all(|&b| b == 0));
        assert_ne!(groups[1].pads[&0].bytes[len], 0);
    }

    #[test]
    fn pad_exhaustion() {
        let mut groups = family(2, AUTH_KEY_SIZE + 10);
        assert!(groups[0].can_send(10));
        assert!(!groups[0].can_send(11));
        assert!(matches!(
            groups[0].encrypt(MessageType::Text, &[0u8; 11]),
            Err(Error::InsufficientPadBytes { .. })
        ));
        send(&mut groups[0], &[0u8; 10]);
        assert!(!groups[0].can_send(0));
        assert_eq!(groups[0].pad(0).unwrap().remaining(), 0);
    }

    #[test]
    fn membership_changes() {
        let mut group = Group::new(0, MemberPad::from_bytes(pad_bytes(0, 128)));
        group
            .add_member(1, MemberPad::from_bytes(pad_bytes(1, 128)))
            .unwrap();
        assert_eq!(
            group
                .add_member(1, MemberPad::from_bytes(pad_bytes(1, 128)))
                .unwrap_err(),
            Error::DuplicateMember { member: 1 }
        );
        assert_eq!(
            group
                .add_member(0, MemberPad::from_bytes(pad_bytes(0, 128)))
                .unwrap_err(),
            Error::DuplicateMember { member: 0 }
        );
        assert!(group.remove_member(0).is_none());
        assert!(group.remove_member(1).is_some());
        assert_eq!(group.members().collect::<Vec<_>>(), vec![0]);
    }

    #[test]
    fn state_persists_across_restore() {
        let mut groups = family(2, 4096);
        let m1 = send(&mut groups[0], b"one");
        let m2 = send(&mut groups[0], b"two");
        groups[1].decrypt(&m2).unwrap();

        // Receiver restarts: rebuild sender's pad copy from saved state
        let used = groups[1].pad(0).unwrap().used_ranges().to_vec();
        let mut restored = Group::new(1, MemberPad::from_bytes(pad_bytes(1, 4096)));
        restored
            .add_member(
                0,
                MemberPad::from_bytes_with_state(pad_bytes(0, 4096), &used),
            )
            .unwrap();
        assert!(matches!(
            restored.decrypt(&m2),
            Err(Error::PadRangeAlreadyUsed { .. })
        ));
        assert_eq!(restored.decrypt(&m1).unwrap(), b"one");
    }

    #[test]
    fn used_ranges_merge() {
        let mut pad = MemberPad::from_bytes(vec![1u8; 100]);
        pad.mark_used(50, 60);
        pad.mark_used(0, 10);
        pad.mark_used(10, 20);
        pad.mark_used(55, 70);
        assert_eq!(pad.used_ranges(), &[(0, 20), (50, 70)]);
        assert_eq!(pad.remaining(), 60);
        assert_eq!(pad.next_send_offset(), 70);
    }

    #[test]
    fn frame_encoding() {
        let mut groups = family(2, 4096);
        let frame = groups[0].encrypt(MessageType::Text, b"wire").unwrap();
        let wire = frame.encode();
        assert_eq!(wire[0], GROUP_FRAME_VERSION);
        assert_eq!(wire[1], 0);
        assert_eq!(&wire[2..10], &0u64.to_be_bytes());

        assert!(matches!(
            GroupFrame::decode(&wire[..5]),
            Err(Error::FrameTooShort { .. })
        ));
        let mut bad_version = wire.clone();
        bad_version[0] = 99;
        assert_eq!(
            GroupFrame::decode(&bad_version).unwrap_err(),
            Error::UnsupportedFrameVersion { version: 99 }
        );
    }
}
