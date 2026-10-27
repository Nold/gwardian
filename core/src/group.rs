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
//! # Corruption Handling
//!
//! Each pad keeps a CRC-32 per `CHECKSUM_CHUNK_SIZE` chunk, computed on import
//! and updated as bytes are wiped. Chunks are checked before their bytes are
//! used, which tells two failures apart:
//!
//! - `PadCorrupted`: this device's copy of the pad is damaged.
//! - `AuthenticationFailed`: the copy is intact, so the message was altered
//!   in transit or the sender's own copy is damaged.
//!
//! [`Group::health`] reports members whose pad is damaged locally or whose
//! messages repeatedly fail authentication. The fix is to exchange that
//! member's pad again, in person, and install it with [`Group::replace_pad`].
//!
//! The checksums are stored next to the pad itself, so they reveal nothing to
//! anyone who could not already read the pad.
//!
//! # Security Levels
//!
//! Every pad records the [`SecurityLevel`] of the channel it was distributed
//! over. Messages a member sends are as safe as that member's pad, and a
//! group is as safe as its weakest pad ([`Group::security_level`]).
//!
//! The level must hold for every copy of a pad: if its owner hands it to one
//! member by QR code and to another through the relay, the pad is
//! `Standard` for everyone. Owners therefore distribute a pad over a single
//! kind of channel, and generate a new pad rather than sending an existing
//! one over a weaker channel.
//!
//! The level never drops silently: adding or replacing a pad with a weaker
//! one is refused unless the caller asks for it explicitly with
//! [`Group::add_member_allow_downgrade`] or [`Group::replace_pad_allow_downgrade`].
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
//! use ash_core::group::{Group, GroupFrame, MemberPad, SecurityLevel};
//! use ash_core::MessageType;
//!
//! let pad_alice = vec![0x11u8; 4096]; // From OS entropy in practice
//! let pad_bob = vec![0x22u8; 4096];
//!
//! let mut alice = Group::new(0, MemberPad::from_bytes(pad_alice.clone(), SecurityLevel::Maximum));
//! alice.add_member(1, MemberPad::from_bytes(pad_bob.clone(), SecurityLevel::Maximum)).unwrap();
//!
//! let mut bob = Group::new(1, MemberPad::from_bytes(pad_bob, SecurityLevel::Maximum));
//! bob.add_member(0, MemberPad::from_bytes(pad_alice, SecurityLevel::Maximum)).unwrap();
//!
//! let wire = alice.encrypt(MessageType::Text, b"Hello").unwrap().encode();
//! let frame = GroupFrame::decode(&wire).unwrap();
//! assert_eq!(bob.decrypt(&frame).unwrap(), b"Hello");
//! ```

use std::collections::{BTreeMap, BTreeSet};

use crate::crc;
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

/// Size of the pad chunks covered by one integrity checksum.
pub const CHECKSUM_CHUNK_SIZE: usize = 4096;

/// Consecutive authentication failures after which a member is reported
/// as [`MemberHealth::Suspect`].
pub const SUSPECT_THRESHOLD: u32 = 3;

/// How a pad was distributed, which bounds the security of what it encrypts.
///
/// Ordered from weakest to strongest, so the minimum of several levels is the
/// weakest one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum SecurityLevel {
    /// Sent remotely through the relay, protected by computational
    /// cryptography.
    Standard = 1,
    /// Exchanged in person over a short-range radio link, protected by
    /// computational cryptography.
    Enhanced = 2,
    /// Exchanged in person by QR codes, with no computational assumption.
    Maximum = 3,
}

impl SecurityLevel {
    /// Encode as a byte, for persistence.
    pub fn to_byte(self) -> u8 {
        self as u8
    }

    /// Decode a byte produced by [`SecurityLevel::to_byte`].
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Standard),
            2 => Some(Self::Enhanced),
            3 => Some(Self::Maximum),
            _ => None,
        }
    }
}

/// A member's sending pad, tracking which byte ranges have been consumed.
///
/// The owner consumes it sequentially when sending. Holders of a copy
/// consume the ranges named by received frames, in any order.
pub struct MemberPad {
    bytes: Vec<u8>,
    /// Consumed `[start, end)` ranges, sorted and non-overlapping.
    used: Vec<(usize, usize)>,
    /// CRC-32 of each `CHECKSUM_CHUNK_SIZE` chunk, consumed bytes zeroed.
    checksums: Vec<u32>,
    /// Channel the pad was distributed over.
    level: SecurityLevel,
}

impl Drop for MemberPad {
    fn drop(&mut self) {
        secure_zero(&mut self.bytes);
    }
}

impl MemberPad {
    /// Create a fresh pad from raw bytes, distributed at `level`.
    pub fn from_bytes(bytes: Vec<u8>, level: SecurityLevel) -> Self {
        let checksums = bytes
            .chunks(CHECKSUM_CHUNK_SIZE)
            .map(crc::compute)
            .collect();
        Self {
            bytes,
            used: Vec::new(),
            checksums,
            level,
        }
    }

    /// Restore a pad with the state returned by `used_ranges`, `checksums`
    /// and `level`.
    ///
    /// Consumed ranges are wiped, so `bytes` may be stored either before or
    /// after wiping. Integrity is checked lazily as bytes are used; call
    /// [`MemberPad::verify`] to check the whole pad up front.
    ///
    /// # Errors
    ///
    /// `PadCorrupted` if the number of checksums does not match the pad size.
    pub fn from_bytes_with_state(
        bytes: Vec<u8>,
        used: &[(usize, usize)],
        checksums: &[u32],
        level: SecurityLevel,
    ) -> Result<Self> {
        if checksums.len() != bytes.len().div_ceil(CHECKSUM_CHUNK_SIZE) {
            return Err(Error::PadCorrupted { offset: 0 });
        }
        let mut pad = Self {
            bytes,
            used: Vec::new(),
            checksums: checksums.to_vec(),
            level,
        };
        for &(start, end) in used {
            let end = end.min(pad.bytes.len());
            if start < end {
                secure_zero(&mut pad.bytes[start..end]);
                pad.mark_used(start, end);
            }
        }
        Ok(pad)
    }

    /// Consumed `[start, end)` ranges, for persistence.
    pub fn used_ranges(&self) -> &[(usize, usize)] {
        &self.used
    }

    /// Channel the pad was distributed over.
    pub fn level(&self) -> SecurityLevel {
        self.level
    }

    /// Integrity checksums, for persistence alongside the pad.
    pub fn checksums(&self) -> &[u32] {
        &self.checksums
    }

    /// Check the whole pad against its checksums.
    ///
    /// # Errors
    ///
    /// `PadCorrupted` with the offset of the first damaged chunk.
    pub fn verify(&self) -> Result<()> {
        self.verify_range(0, self.bytes.len())
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

    /// Check the chunks overlapping `[start, end)`.
    fn verify_range(&self, start: usize, end: usize) -> Result<()> {
        if start >= end {
            return Ok(());
        }
        for chunk in start / CHECKSUM_CHUNK_SIZE..end.div_ceil(CHECKSUM_CHUNK_SIZE) {
            if crc::compute(self.chunk(chunk)) != self.checksums[chunk] {
                return Err(Error::PadCorrupted {
                    offset: chunk * CHECKSUM_CHUNK_SIZE,
                });
            }
        }
        Ok(())
    }

    fn chunk(&self, index: usize) -> &[u8] {
        let start = index * CHECKSUM_CHUNK_SIZE;
        &self.bytes[start..(start + CHECKSUM_CHUNK_SIZE).min(self.bytes.len())]
    }

    /// Consume `[start, end)`: wipe the bytes, record the range and update
    /// the checksums of the affected chunks.
    fn burn(&mut self, start: usize, end: usize) {
        secure_zero(&mut self.bytes[start..end]);
        self.mark_used(start, end);
        for chunk in start / CHECKSUM_CHUNK_SIZE..end.div_ceil(CHECKSUM_CHUNK_SIZE) {
            self.checksums[chunk] = crc::compute(self.chunk(chunk));
        }
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

/// Integrity status of a member's pad, as seen from this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemberHealth {
    /// No problem detected.
    Healthy,
    /// This device's copy of the member's pad failed its checksum.
    CorruptedLocally,
    /// Several consecutive messages from the member failed authentication:
    /// their own copy may be damaged, or someone is forging messages in
    /// their name.
    Suspect {
        /// Number of failures since the last authenticated message.
        consecutive_failures: u32,
    },
}

/// A member's view of a group: their own pad plus copies of everyone else's.
pub struct Group {
    me: MemberId,
    pads: BTreeMap<MemberId, MemberPad>,
    /// Consecutive authentication failures per sender.
    failures: BTreeMap<MemberId, u32>,
    /// Members whose local pad copy failed its checksum.
    corrupted: BTreeSet<MemberId>,
}

impl Group {
    /// Create a group view for member `me`, who sends with `own_pad`.
    pub fn new(me: MemberId, own_pad: MemberPad) -> Self {
        let mut pads = BTreeMap::new();
        pads.insert(me, own_pad);
        Self {
            me,
            pads,
            failures: BTreeMap::new(),
            corrupted: BTreeSet::new(),
        }
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

    /// Security level of the group: the level of its weakest pad.
    pub fn security_level(&self) -> SecurityLevel {
        self.pads
            .values()
            .map(MemberPad::level)
            .min()
            .expect("own pad is always present")
    }

    /// Add a member with the copy of their sending pad.
    ///
    /// # Errors
    ///
    /// - `DuplicateMember` if the id is taken.
    /// - `SecurityDowngrade` if the pad would lower the group's level; use
    ///   [`Group::add_member_allow_downgrade`] once the user has agreed.
    pub fn add_member(&mut self, member: MemberId, pad: MemberPad) -> Result<()> {
        self.check_no_downgrade(member, pad.level(), self.security_level())?;
        self.add_member_allow_downgrade(member, pad)
    }

    /// Add a member even if their pad lowers the group's security level.
    ///
    /// # Errors
    ///
    /// `DuplicateMember` if the id is taken.
    pub fn add_member_allow_downgrade(&mut self, member: MemberId, pad: MemberPad) -> Result<()> {
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
        self.failures.remove(&member);
        self.corrupted.remove(&member);
        self.pads.remove(&member)
    }

    /// Install a freshly exchanged pad for a member, including this device,
    /// and clear their health status. A stronger pad raises the level.
    ///
    /// # Errors
    ///
    /// - `UnknownMember` if the member is not in the group.
    /// - `SecurityDowngrade` if the new pad is weaker than the one it
    ///   replaces; use [`Group::replace_pad_allow_downgrade`] once the user
    ///   has agreed.
    pub fn replace_pad(&mut self, member: MemberId, pad: MemberPad) -> Result<()> {
        let current = self
            .pads
            .get(&member)
            .ok_or(Error::UnknownMember { member })?
            .level();
        self.check_no_downgrade(member, pad.level(), current)?;
        self.replace_pad_allow_downgrade(member, pad)
    }

    /// Install a new pad for a member even if it is weaker than the old one.
    ///
    /// # Errors
    ///
    /// `UnknownMember` if the member is not in the group.
    pub fn replace_pad_allow_downgrade(&mut self, member: MemberId, pad: MemberPad) -> Result<()> {
        let slot = self
            .pads
            .get_mut(&member)
            .ok_or(Error::UnknownMember { member })?;
        *slot = pad;
        self.failures.remove(&member);
        self.corrupted.remove(&member);
        Ok(())
    }

    /// Integrity status of a member's pad, or `None` if not a member.
    pub fn health(&self, member: MemberId) -> Option<MemberHealth> {
        if !self.pads.contains_key(&member) {
            return None;
        }
        if self.corrupted.contains(&member) {
            return Some(MemberHealth::CorruptedLocally);
        }
        match self.failures.get(&member) {
            Some(&n) if n >= SUSPECT_THRESHOLD => Some(MemberHealth::Suspect {
                consecutive_failures: n,
            }),
            _ => Some(MemberHealth::Healthy),
        }
    }

    /// Check every pad against its checksums, for example after loading the
    /// group from storage. Returns the members whose pad is damaged.
    pub fn check_integrity(&mut self) -> Vec<MemberId> {
        let damaged: Vec<MemberId> = self
            .pads
            .iter()
            .filter(|(_, pad)| pad.verify().is_err())
            .map(|(&member, _)| member)
            .collect();
        self.corrupted.extend(damaged.iter().copied());
        damaged
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
        if let Err(e) = pad.verify_range(start, end) {
            self.corrupted.insert(me);
            return Err(e);
        }

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
    /// The pad range is consumed only if authentication succeeds. Integrity
    /// and authentication failures are recorded for [`Group::health`].
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
        if let Err(e) = pad.verify_range(start, end) {
            self.corrupted.insert(frame.sender);
            return Err(e);
        }

        let auth_key = AuthKey::from_slice(&pad.bytes[start..start + AUTH_KEY_SIZE]);
        let plaintext = match frame
            .frame
            .decrypt(&pad.bytes[start + AUTH_KEY_SIZE..end], &auth_key)
        {
            Ok(plaintext) => plaintext,
            Err(e) => {
                *self.failures.entry(frame.sender).or_insert(0) += 1;
                return Err(e);
            }
        };
        pad.burn(start, end);
        self.failures.remove(&frame.sender);
        Ok(plaintext)
    }

    fn check_no_downgrade(
        &self,
        member: MemberId,
        to: SecurityLevel,
        from: SecurityLevel,
    ) -> Result<()> {
        if to < from {
            return Err(Error::SecurityDowngrade { member, from, to });
        }
        Ok(())
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
                let mut group = Group::new(
                    me,
                    MemberPad::from_bytes(pad_bytes(me, len), SecurityLevel::Maximum),
                );
                for other in (0..size).filter(|&o| o != me) {
                    group
                        .add_member(
                            other,
                            MemberPad::from_bytes(pad_bytes(other, len), SecurityLevel::Maximum),
                        )
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
        let mut group = Group::new(
            0,
            MemberPad::from_bytes(pad_bytes(0, 128), SecurityLevel::Maximum),
        );
        group
            .add_member(
                1,
                MemberPad::from_bytes(pad_bytes(1, 128), SecurityLevel::Maximum),
            )
            .unwrap();
        assert_eq!(
            group
                .add_member(
                    1,
                    MemberPad::from_bytes(pad_bytes(1, 128), SecurityLevel::Maximum)
                )
                .unwrap_err(),
            Error::DuplicateMember { member: 1 }
        );
        assert_eq!(
            group
                .add_member(
                    0,
                    MemberPad::from_bytes(pad_bytes(0, 128), SecurityLevel::Maximum)
                )
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

        // Receiver restarts: rebuild sender's pad copy from saved state.
        // The original (unwiped) bytes are given back: used ranges get wiped.
        let saved = groups[1].pad(0).unwrap();
        let used = saved.used_ranges().to_vec();
        let checksums = saved.checksums().to_vec();
        let pad = MemberPad::from_bytes_with_state(
            pad_bytes(0, 4096),
            &used,
            &checksums,
            SecurityLevel::Maximum,
        )
        .unwrap();
        pad.verify().unwrap();
        let mut restored = Group::new(
            1,
            MemberPad::from_bytes(pad_bytes(1, 4096), SecurityLevel::Maximum),
        );
        restored.add_member(0, pad).unwrap();
        assert!(matches!(
            restored.decrypt(&m2),
            Err(Error::PadRangeAlreadyUsed { .. })
        ));
        assert_eq!(restored.decrypt(&m1).unwrap(), b"one");
    }

    #[test]
    fn restore_rejects_mismatched_checksums() {
        let pad = MemberPad::from_bytes(pad_bytes(0, 10_000), SecurityLevel::Maximum);
        let mut checksums = pad.checksums().to_vec();
        assert_eq!(checksums.len(), 3);
        checksums.pop();
        assert!(matches!(
            MemberPad::from_bytes_with_state(
                pad_bytes(0, 10_000),
                &[],
                &checksums,
                SecurityLevel::Maximum
            ),
            Err(Error::PadCorrupted { offset: 0 })
        ));
    }

    #[test]
    fn checksums_follow_wiping() {
        let mut groups = family(2, 10_000);
        for _ in 0..50 {
            let frame = send(&mut groups[0], b"keep checksums in sync");
            groups[1].decrypt(&frame).unwrap();
        }
        groups[0].pad(0).unwrap().verify().unwrap();
        groups[1].pad(0).unwrap().verify().unwrap();
    }

    #[test]
    fn local_corruption_detected_before_use() {
        let mut groups = family(2, 10_000);
        let frame = send(&mut groups[0], b"hello");
        // Damage the receiver's copy of member 0's pad
        groups[1].pads.get_mut(&0).unwrap().bytes[3] ^= 0x40;

        assert_eq!(
            groups[1].decrypt(&frame).unwrap_err(),
            Error::PadCorrupted { offset: 0 }
        );
        assert_eq!(groups[1].health(0), Some(MemberHealth::CorruptedLocally));
        assert!(groups[1].pad(0).unwrap().used_ranges().is_empty());
        // Other members are unaffected
        assert_eq!(groups[1].health(1), Some(MemberHealth::Healthy));
    }

    #[test]
    fn own_corruption_blocks_sending() {
        let mut groups = family(2, 10_000);
        groups[0].pads.get_mut(&0).unwrap().bytes[10] ^= 1;
        assert_eq!(
            groups[0].encrypt(MessageType::Text, b"hi").unwrap_err(),
            Error::PadCorrupted { offset: 0 }
        );
        assert_eq!(groups[0].health(0), Some(MemberHealth::CorruptedLocally));
        assert_eq!(groups[0].pad(0).unwrap().next_send_offset(), 0);
    }

    #[test]
    fn repeated_auth_failures_make_member_suspect() {
        let mut groups = family(2, 10_000);
        let frame = send(&mut groups[0], b"genuine");
        let mut forged = frame.clone();
        forged.frame.ciphertext[0] ^= 1;

        for n in 1..SUSPECT_THRESHOLD {
            assert_eq!(
                groups[1].decrypt(&forged).unwrap_err(),
                Error::AuthenticationFailed
            );
            assert_eq!(groups[1].health(0), Some(MemberHealth::Healthy), "{n}");
        }
        groups[1].decrypt(&forged).unwrap_err();
        assert_eq!(
            groups[1].health(0),
            Some(MemberHealth::Suspect {
                consecutive_failures: SUSPECT_THRESHOLD
            })
        );

        // An authenticated message clears the suspicion
        assert_eq!(groups[1].decrypt(&frame).unwrap(), b"genuine");
        assert_eq!(groups[1].health(0), Some(MemberHealth::Healthy));
    }

    #[test]
    fn replays_do_not_count_as_failures() {
        let mut groups = family(2, 10_000);
        let frame = send(&mut groups[0], b"once");
        groups[1].decrypt(&frame).unwrap();
        for _ in 0..SUSPECT_THRESHOLD {
            groups[1].decrypt(&frame).unwrap_err();
        }
        assert_eq!(groups[1].health(0), Some(MemberHealth::Healthy));
    }

    #[test]
    fn integrity_check_and_repair() {
        let mut groups = family(3, 10_000);
        groups[0].pads.get_mut(&2).unwrap().bytes[9_000] ^= 0xFF;
        assert_eq!(groups[0].check_integrity(), vec![2]);
        assert_eq!(
            groups[0].pad(2).unwrap().verify().unwrap_err(),
            Error::PadCorrupted { offset: 8192 }
        );
        assert_eq!(groups[0].health(2), Some(MemberHealth::CorruptedLocally));
        assert_eq!(groups[0].health(9), None);

        // Member 2 exchanges a new pad in person
        let new_pad = pad_bytes(42, 10_000);
        groups[0]
            .replace_pad(
                2,
                MemberPad::from_bytes(new_pad.clone(), SecurityLevel::Maximum),
            )
            .unwrap();
        groups[2]
            .replace_pad(2, MemberPad::from_bytes(new_pad, SecurityLevel::Maximum))
            .unwrap();
        assert_eq!(groups[0].health(2), Some(MemberHealth::Healthy));
        let frame = send(&mut groups[2], b"fixed");
        assert_eq!(groups[0].decrypt(&frame).unwrap(), b"fixed");

        assert_eq!(
            groups[0]
                .replace_pad(
                    9,
                    MemberPad::from_bytes(vec![0; 10], SecurityLevel::Maximum)
                )
                .unwrap_err(),
            Error::UnknownMember { member: 9 }
        );
    }

    #[test]
    fn security_level_ordering_and_bytes() {
        use SecurityLevel::*;
        assert!(Standard < Enhanced && Enhanced < Maximum);
        for level in [Standard, Enhanced, Maximum] {
            assert_eq!(SecurityLevel::from_byte(level.to_byte()), Some(level));
        }
        assert_eq!(SecurityLevel::from_byte(0), None);
        assert_eq!(SecurityLevel::from_byte(4), None);
    }

    #[test]
    fn group_level_is_weakest_pad() {
        let mut group = Group::new(
            0,
            MemberPad::from_bytes(pad_bytes(0, 128), SecurityLevel::Maximum),
        );
        assert_eq!(group.security_level(), SecurityLevel::Maximum);

        group
            .add_member_allow_downgrade(
                1,
                MemberPad::from_bytes(pad_bytes(1, 128), SecurityLevel::Enhanced),
            )
            .unwrap();
        group
            .add_member_allow_downgrade(
                2,
                MemberPad::from_bytes(pad_bytes(2, 128), SecurityLevel::Standard),
            )
            .unwrap();
        assert_eq!(group.security_level(), SecurityLevel::Standard);
        assert_eq!(group.pad(1).unwrap().level(), SecurityLevel::Enhanced);

        // Removing the weakest member raises the level again
        group.remove_member(2);
        assert_eq!(group.security_level(), SecurityLevel::Enhanced);
    }

    #[test]
    fn adding_weaker_member_needs_consent() {
        let mut group = Group::new(
            0,
            MemberPad::from_bytes(pad_bytes(0, 128), SecurityLevel::Maximum),
        );
        assert_eq!(
            group
                .add_member(
                    1,
                    MemberPad::from_bytes(pad_bytes(1, 128), SecurityLevel::Standard)
                )
                .unwrap_err(),
            Error::SecurityDowngrade {
                member: 1,
                from: SecurityLevel::Maximum,
                to: SecurityLevel::Standard,
            }
        );
        assert_eq!(group.members().count(), 1);

        // Same or stronger level is fine
        group
            .add_member(
                1,
                MemberPad::from_bytes(pad_bytes(1, 128), SecurityLevel::Maximum),
            )
            .unwrap();
        group
            .add_member_allow_downgrade(
                2,
                MemberPad::from_bytes(pad_bytes(2, 128), SecurityLevel::Enhanced),
            )
            .unwrap();
        group
            .add_member(
                3,
                MemberPad::from_bytes(pad_bytes(3, 128), SecurityLevel::Enhanced),
            )
            .unwrap();
    }

    #[test]
    fn replacing_pad_upgrades_but_never_silently_downgrades() {
        let mut group = Group::new(
            0,
            MemberPad::from_bytes(pad_bytes(0, 128), SecurityLevel::Standard),
        );
        group
            .add_member(
                1,
                MemberPad::from_bytes(pad_bytes(1, 128), SecurityLevel::Standard),
            )
            .unwrap();

        // Meeting in person: both pads upgraded to Maximum
        group
            .replace_pad(
                0,
                MemberPad::from_bytes(pad_bytes(10, 128), SecurityLevel::Maximum),
            )
            .unwrap();
        assert_eq!(group.security_level(), SecurityLevel::Standard);
        group
            .replace_pad(
                1,
                MemberPad::from_bytes(pad_bytes(11, 128), SecurityLevel::Maximum),
            )
            .unwrap();
        assert_eq!(group.security_level(), SecurityLevel::Maximum);

        assert_eq!(
            group
                .replace_pad(
                    1,
                    MemberPad::from_bytes(pad_bytes(12, 128), SecurityLevel::Enhanced)
                )
                .unwrap_err(),
            Error::SecurityDowngrade {
                member: 1,
                from: SecurityLevel::Maximum,
                to: SecurityLevel::Enhanced,
            }
        );
        assert_eq!(group.pad(1).unwrap().level(), SecurityLevel::Maximum);

        group
            .replace_pad_allow_downgrade(
                1,
                MemberPad::from_bytes(pad_bytes(12, 128), SecurityLevel::Enhanced),
            )
            .unwrap();
        assert_eq!(group.security_level(), SecurityLevel::Enhanced);
    }

    #[test]
    fn restore_keeps_level() {
        let pad = MemberPad::from_bytes(pad_bytes(0, 128), SecurityLevel::Enhanced);
        let restored = MemberPad::from_bytes_with_state(
            pad_bytes(0, 128),
            pad.used_ranges(),
            pad.checksums(),
            SecurityLevel::from_byte(pad.level().to_byte()).unwrap(),
        )
        .unwrap();
        assert_eq!(restored.level(), SecurityLevel::Enhanced);
    }

    #[test]
    fn used_ranges_merge() {
        let mut pad = MemberPad::from_bytes(vec![1u8; 100], SecurityLevel::Maximum);
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
