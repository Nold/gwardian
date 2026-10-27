//! FFI wrapper for group messaging (one sending pad per member).

use std::sync::Mutex;

use ash_core::group::{Group, GroupFrame, MemberPad};
use ash_core::MessageType;

use crate::{AshError, AuthTokens};

/// How a pad was distributed; see `ash_core::group::SecurityLevel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecurityLevel {
    Standard,
    Enhanced,
    Maximum,
}

impl From<SecurityLevel> for ash_core::group::SecurityLevel {
    fn from(level: SecurityLevel) -> Self {
        match level {
            SecurityLevel::Standard => Self::Standard,
            SecurityLevel::Enhanced => Self::Enhanced,
            SecurityLevel::Maximum => Self::Maximum,
        }
    }
}

impl From<ash_core::group::SecurityLevel> for SecurityLevel {
    fn from(level: ash_core::group::SecurityLevel) -> Self {
        match level {
            ash_core::group::SecurityLevel::Standard => Self::Standard,
            ash_core::group::SecurityLevel::Enhanced => Self::Enhanced,
            ash_core::group::SecurityLevel::Maximum => Self::Maximum,
        }
    }
}

/// Integrity status of a member's pad; see `ash_core::group::MemberHealth`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemberHealth {
    Healthy,
    CorruptedLocally,
    Suspect { consecutive_failures: u32 },
}

impl From<ash_core::group::MemberHealth> for MemberHealth {
    fn from(health: ash_core::group::MemberHealth) -> Self {
        match health {
            ash_core::group::MemberHealth::Healthy => Self::Healthy,
            ash_core::group::MemberHealth::CorruptedLocally => Self::CorruptedLocally,
            ash_core::group::MemberHealth::Suspect {
                consecutive_failures,
            } => Self::Suspect {
                consecutive_failures,
            },
        }
    }
}

/// Consumed `[start, end)` range of a pad.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsedRange {
    pub start: u64,
    pub end: u64,
}

/// Everything needed to restore one member's pad, for secure storage.
#[derive(Debug, Clone)]
pub struct MemberPadState {
    pub member: u8,
    pub pad: Vec<u8>,
    pub used: Vec<UsedRange>,
    pub checksums: Vec<u32>,
    pub level: SecurityLevel,
}

/// A verified, decrypted group message.
#[derive(Debug, Clone)]
pub struct GroupMessage {
    pub sender: u8,
    pub msg_type: u8,
    pub plaintext: Vec<u8>,
    /// Level of the sender's pad, which bounds this message's security.
    pub level: SecurityLevel,
}

/// A member's view of a group. Named `PadGroup` to avoid clashing with
/// SwiftUI's `Group`.
pub struct PadGroup {
    inner: Mutex<Group>,
}

fn pad(bytes: Vec<u8>, level: SecurityLevel) -> MemberPad {
    MemberPad::from_bytes(bytes, level.into())
}

impl PadGroup {
    pub fn new(me: u8, own_pad: Vec<u8>, level: SecurityLevel) -> Self {
        Self {
            inner: Mutex::new(Group::new(me, pad(own_pad, level))),
        }
    }

    /// Rebuild a group from `export_state`. The states were accepted when
    /// first added, so restoring never counts as a downgrade.
    pub fn restore(me: u8, states: Vec<MemberPadState>) -> Result<Self, AshError> {
        let mut pads = Vec::with_capacity(states.len());
        for state in states {
            let used: Vec<(usize, usize)> = state
                .used
                .iter()
                .map(|r| (r.start as usize, r.end as usize))
                .collect();
            let pad = MemberPad::from_bytes_with_state(
                state.pad,
                &used,
                &state.checksums,
                state.level.into(),
            )?;
            pads.push((state.member, pad));
        }
        let own = pads
            .iter()
            .position(|(member, _)| *member == me)
            .ok_or(AshError::UnknownMember)?;
        let (_, own_pad) = pads.swap_remove(own);
        let mut group = Group::new(me, own_pad);
        for (member, pad) in pads {
            group.add_member_allow_downgrade(member, pad)?;
        }
        Ok(Self {
            inner: Mutex::new(group),
        })
    }

    fn group(&self) -> std::sync::MutexGuard<'_, Group> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn me(&self) -> u8 {
        self.group().me()
    }

    pub fn members(&self) -> Vec<u8> {
        self.group().members().collect()
    }

    pub fn security_level(&self) -> SecurityLevel {
        self.group().security_level().into()
    }

    pub fn member_level(&self, member: u8) -> Option<SecurityLevel> {
        self.group().pad(member).map(|p| p.level().into())
    }

    pub fn add_member(
        &self,
        member: u8,
        pad_bytes: Vec<u8>,
        level: SecurityLevel,
    ) -> Result<(), AshError> {
        Ok(self.group().add_member(member, pad(pad_bytes, level))?)
    }

    pub fn add_member_allow_downgrade(
        &self,
        member: u8,
        pad_bytes: Vec<u8>,
        level: SecurityLevel,
    ) -> Result<(), AshError> {
        Ok(self
            .group()
            .add_member_allow_downgrade(member, pad(pad_bytes, level))?)
    }

    pub fn replace_pad(
        &self,
        member: u8,
        pad_bytes: Vec<u8>,
        level: SecurityLevel,
    ) -> Result<(), AshError> {
        Ok(self.group().replace_pad(member, pad(pad_bytes, level))?)
    }

    pub fn replace_pad_allow_downgrade(
        &self,
        member: u8,
        pad_bytes: Vec<u8>,
        level: SecurityLevel,
    ) -> Result<(), AshError> {
        Ok(self
            .group()
            .replace_pad_allow_downgrade(member, pad(pad_bytes, level))?)
    }

    pub fn remove_member(&self, member: u8) -> bool {
        self.group().remove_member(member).is_some()
    }

    pub fn health(&self, member: u8) -> Option<MemberHealth> {
        self.group().health(member).map(Into::into)
    }

    pub fn check_integrity(&self) -> Vec<u8> {
        self.group().check_integrity()
    }

    pub fn can_send(&self, plaintext_length: u32) -> bool {
        self.group().can_send(plaintext_length as usize)
    }

    /// Encrypt with this device's pad; returns the encoded group frame.
    pub fn encrypt(&self, msg_type: u8, plaintext: Vec<u8>) -> Result<Vec<u8>, AshError> {
        let msg_type = MessageType::from_byte(msg_type).ok_or(AshError::InvalidMessageType)?;
        Ok(self.group().encrypt(msg_type, &plaintext)?.encode())
    }

    /// Relay tokens from member 0's pad; those bytes are consumed so they
    /// never also serve as message keys. Call once when the group is formed.
    pub fn take_relay_tokens(&self) -> Result<AuthTokens, AshError> {
        let (conversation_id, auth_token, burn_token) = self.group().take_relay_tokens()?;
        Ok(AuthTokens {
            conversation_id,
            auth_token,
            burn_token,
        })
    }

    /// Verify and decrypt an encoded group frame from another member.
    pub fn decrypt(&self, frame: Vec<u8>) -> Result<GroupMessage, AshError> {
        let frame = GroupFrame::decode(&frame)?;
        let mut group = self.group();
        let plaintext = group.decrypt(&frame)?;
        let level = group
            .pad(frame.sender)
            .map(|p| p.level().into())
            .expect("sender pad exists after successful decryption");
        Ok(GroupMessage {
            sender: frame.sender,
            msg_type: frame.frame.msg_type.to_byte(),
            plaintext,
            level,
        })
    }

    /// State of every pad, to persist after each send or receive.
    pub fn export_state(&self) -> Vec<MemberPadState> {
        let group = self.group();
        group
            .members()
            .filter_map(|member| group.pad(member).map(|pad| (member, pad)))
            .map(|(member, pad)| MemberPadState {
                member,
                pad: pad.as_bytes().to_vec(),
                used: pad
                    .used_ranges()
                    .iter()
                    .map(|&(start, end)| UsedRange {
                        start: start as u64,
                        end: end as u64,
                    })
                    .collect(),
                checksums: pad.checksums().to_vec(),
                level: pad.level().into(),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(seed: u8) -> Vec<u8> {
        (0..10_000u32)
            .map(|i| (i as u8).wrapping_mul(31) ^ seed)
            .collect()
    }

    fn pair() -> (PadGroup, PadGroup) {
        let alice = PadGroup::new(0, bytes(0), SecurityLevel::Maximum);
        alice
            .add_member(1, bytes(1), SecurityLevel::Maximum)
            .unwrap();
        let bob = PadGroup::new(1, bytes(1), SecurityLevel::Maximum);
        bob.add_member(0, bytes(0), SecurityLevel::Maximum).unwrap();
        (alice, bob)
    }

    #[test]
    fn relay_tokens_are_shared_and_taken_once() {
        let (alice, bob) = pair();
        let tokens = alice.take_relay_tokens().unwrap();
        let theirs = bob.take_relay_tokens().unwrap();
        assert_eq!(theirs.conversation_id, tokens.conversation_id);
        assert_eq!(theirs.auth_token, tokens.auth_token);
        assert_eq!(theirs.burn_token, tokens.burn_token);
        assert!(alice.take_relay_tokens().is_err());
        let frame = alice.encrypt(0x01, b"hi".to_vec()).unwrap();
        assert_eq!(bob.decrypt(frame).unwrap().plaintext, b"hi");
    }

    #[test]
    fn messages_roundtrip() {
        let (alice, bob) = pair();
        let frame = alice.encrypt(0x01, b"hello".to_vec()).unwrap();
        let message = bob.decrypt(frame).unwrap();
        assert_eq!(message.sender, 0);
        assert_eq!(message.msg_type, 0x01);
        assert_eq!(message.plaintext, b"hello");
        assert_eq!(message.level, SecurityLevel::Maximum);
        assert!(matches!(
            alice.encrypt(0xEE, b"x".to_vec()),
            Err(AshError::InvalidMessageType)
        ));
    }

    #[test]
    fn state_survives_export_and_restore() {
        let (alice, bob) = pair();
        let first = alice.encrypt(0x01, b"one".to_vec()).unwrap();
        let second = alice.encrypt(0x01, b"two".to_vec()).unwrap();
        bob.decrypt(first.clone()).unwrap();

        let restored = PadGroup::restore(1, bob.export_state()).unwrap();
        assert_eq!(restored.members(), vec![0, 1]);
        assert!(restored.check_integrity().is_empty());
        assert!(matches!(
            restored.decrypt(first),
            Err(AshError::PadRangeAlreadyUsed)
        ));
        assert_eq!(restored.decrypt(second).unwrap().plaintext, b"two");

        assert!(matches!(
            PadGroup::restore(7, bob.export_state()),
            Err(AshError::UnknownMember)
        ));
    }

    #[test]
    fn levels_and_downgrades() {
        let group = PadGroup::new(0, bytes(0), SecurityLevel::Maximum);
        assert!(matches!(
            group.add_member(1, bytes(1), SecurityLevel::Standard),
            Err(AshError::SecurityDowngrade)
        ));
        group
            .add_member_allow_downgrade(1, bytes(1), SecurityLevel::Standard)
            .unwrap();
        assert_eq!(group.security_level(), SecurityLevel::Standard);
        assert_eq!(group.member_level(1), Some(SecurityLevel::Standard));
        group
            .replace_pad(1, bytes(2), SecurityLevel::Maximum)
            .unwrap();
        assert_eq!(group.security_level(), SecurityLevel::Maximum);
        assert_eq!(group.health(1), Some(MemberHealth::Healthy));
        assert_eq!(group.health(9), None);
    }
}
