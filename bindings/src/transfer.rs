//! FFI wrapper for pad transfer (`Standard` and `Enhanced` levels).
//!
//! UniFFI objects are shared references, so the typestate API of
//! `ash-transfer` is kept behind a mutex and advanced step by step. Calling a
//! step out of order fails with `InvalidState`; any failed step ends the
//! transfer, which must then start over.

use std::sync::Mutex;

use ash_transfer::{
    NonceMessage, Offer, Receiver, ReceiverAwaitingReveal, ReceiverVerified, Response, Reveal,
    SealedPad, Sender, SenderAwaitingNonce, SenderVerified,
};

use crate::group::SecurityLevel;
use crate::AshError;

fn array<const N: usize>(bytes: &[u8]) -> Result<[u8; N], AshError> {
    bytes.try_into().map_err(|_| AshError::InvalidEntropySize)
}

fn words(words: Vec<&'static str>) -> Vec<String> {
    words.into_iter().map(String::from).collect()
}

/// Pad received at the end of a transfer.
#[derive(Debug, Clone)]
pub struct ReceivedPad {
    pub pad: Vec<u8>,
    pub level: SecurityLevel,
}

/// Sender's reply to the receiver's nonce, and the words to compare.
#[derive(Debug, Clone)]
pub struct SenderReveal {
    pub reveal: Vec<u8>,
    pub words: Vec<String>,
}

// Large protocol states are boxed to keep the enum small
enum ReceiverState {
    Started(Box<Receiver>),
    AwaitingReveal(Box<ReceiverAwaitingReveal>),
    Verified(ReceiverVerified),
    Done,
}

/// Receiving side: the device getting a copy of someone's pad.
pub struct PadTransferReceiver {
    offer: Vec<u8>,
    state: Mutex<ReceiverState>,
}

impl PadTransferReceiver {
    /// Start with 32 random bytes from a secure source.
    pub fn new(seed: Vec<u8>) -> Result<Self, AshError> {
        let (receiver, offer) = Receiver::start(array(&seed)?);
        Ok(Self {
            offer: offer.encode(),
            state: Mutex::new(ReceiverState::Started(Box::new(receiver))),
        })
    }

    fn take(&self) -> ReceiverState {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::replace(&mut *state, ReceiverState::Done)
    }

    fn set(&self, next: ReceiverState) {
        *self.state.lock().unwrap_or_else(|e| e.into_inner()) = next;
    }

    /// First message, to send to the pad owner.
    pub fn offer(&self) -> Vec<u8> {
        self.offer.clone()
    }

    /// Handle the sender's response with 32 fresh random bytes; returns the
    /// nonce message to send.
    pub fn on_response(&self, response: Vec<u8>, nonce: Vec<u8>) -> Result<Vec<u8>, AshError> {
        let ReceiverState::Started(receiver) = self.take() else {
            return Err(AshError::InvalidState);
        };
        let response = Response::decode(&response)?;
        let (next, message) = (*receiver).on_response(response, array(&nonce)?);
        self.set(ReceiverState::AwaitingReveal(Box::new(next)));
        Ok(message.encode())
    }

    /// Check the sender's reveal; returns the six words to compare.
    pub fn on_reveal(&self, reveal: Vec<u8>) -> Result<Vec<String>, AshError> {
        let ReceiverState::AwaitingReveal(receiver) = self.take() else {
            return Err(AshError::InvalidState);
        };
        let verified = (*receiver).on_reveal(&Reveal::decode(&reveal)?)?;
        let result = words(verified.words());
        self.set(ReceiverState::Verified(verified));
        Ok(result)
    }

    /// Decrypt the pad, only after people confirmed the words match.
    pub fn open_pad(&self, sealed: Vec<u8>) -> Result<ReceivedPad, AshError> {
        let ReceiverState::Verified(receiver) = self.take() else {
            return Err(AshError::InvalidState);
        };
        let (pad, level) = receiver.open_pad(&SealedPad::decode(&sealed)?)?;
        Ok(ReceivedPad {
            pad: pad.to_vec(),
            level: level.into(),
        })
    }
}

enum SenderState {
    AwaitingNonce(Box<SenderAwaitingNonce>),
    Verified(SenderVerified),
    Done,
}

/// Sending side: the pad owner handing over a copy.
pub struct PadTransferSender {
    response: Vec<u8>,
    state: Mutex<SenderState>,
}

impl PadTransferSender {
    /// Answer an offer with 64 random bytes for encapsulation and 32 for the
    /// nonce, both from a secure source.
    pub fn new(
        offer: Vec<u8>,
        encapsulation_seed: Vec<u8>,
        nonce: Vec<u8>,
    ) -> Result<Self, AshError> {
        let offer = Offer::decode(&offer)?;
        let (sender, response) =
            Sender::on_offer(&offer, array(&encapsulation_seed)?, array(&nonce)?)?;
        Ok(Self {
            response: response.encode(),
            state: Mutex::new(SenderState::AwaitingNonce(Box::new(sender))),
        })
    }

    fn take(&self) -> SenderState {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::replace(&mut *state, SenderState::Done)
    }

    /// Response to send back to the receiver.
    pub fn response(&self) -> Vec<u8> {
        self.response.clone()
    }

    /// Handle the receiver's nonce; returns the reveal to send and the words.
    pub fn on_nonce(&self, nonce: Vec<u8>) -> Result<SenderReveal, AshError> {
        let SenderState::AwaitingNonce(sender) = self.take() else {
            return Err(AshError::InvalidState);
        };
        let (verified, reveal) = (*sender).on_nonce(&NonceMessage::decode(&nonce)?);
        let result = SenderReveal {
            reveal: reveal.encode(),
            words: words(verified.words()),
        };
        *self.state.lock().unwrap_or_else(|e| e.into_inner()) = SenderState::Verified(verified);
        Ok(result)
    }

    /// Encrypt the pad, only after people confirmed the words match.
    pub fn seal_pad(&self, pad: Vec<u8>, level: SecurityLevel) -> Result<Vec<u8>, AshError> {
        let SenderState::Verified(sender) = self.take() else {
            return Err(AshError::InvalidState);
        };
        Ok(sender.seal_pad(&pad, level.into())?.encode())
    }
}

/// Split a protocol message into packets of at most `max_packet` bytes for
/// Bluetooth LE; see `docs/ble-transfer.md`.
pub fn split_into_ble_packets(
    message: Vec<u8>,
    message_id: u8,
    max_packet: u32,
) -> Result<Vec<Vec<u8>>, AshError> {
    Ok(ash_transfer::framing::packets(
        &message,
        message_id,
        max_packet as usize,
    )?)
}

pub fn ble_service_uuid() -> String {
    ash_transfer::framing::BLE_SERVICE_UUID.to_string()
}

pub fn ble_to_receiver_uuid() -> String {
    ash_transfer::framing::BLE_TO_RECEIVER_UUID.to_string()
}

pub fn ble_to_sender_uuid() -> String {
    ash_transfer::framing::BLE_TO_SENDER_UUID.to_string()
}

/// Rebuilds protocol messages from Bluetooth LE packets received in order.
pub struct BlePacketReassembler {
    inner: Mutex<ash_transfer::framing::Reassembler>,
}

impl Default for BlePacketReassembler {
    fn default() -> Self {
        Self::new()
    }
}

impl BlePacketReassembler {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(ash_transfer::framing::Reassembler::new()),
        }
    }

    fn reassembler(&self) -> std::sync::MutexGuard<'_, ash_transfer::framing::Reassembler> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Feed one packet; returns the message once complete.
    pub fn push(&self, packet: Vec<u8>) -> Result<Option<Vec<u8>>, AshError> {
        Ok(self.reassembler().push(&packet)?)
    }

    pub fn is_receiving(&self) -> bool {
        self.reassembler().is_receiving()
    }

    pub fn progress(&self) -> f64 {
        self.reassembler().progress()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exchange() -> (
        PadTransferReceiver,
        PadTransferSender,
        Vec<String>,
        Vec<String>,
    ) {
        let receiver = PadTransferReceiver::new(vec![1; 32]).unwrap();
        let sender = PadTransferSender::new(receiver.offer(), vec![2; 64], vec![3; 32]).unwrap();
        let nonce = receiver
            .on_response(sender.response(), vec![4; 32])
            .unwrap();
        let reveal = sender.on_nonce(nonce).unwrap();
        let words = receiver.on_reveal(reveal.reveal).unwrap();
        (receiver, sender, words, reveal.words)
    }

    #[test]
    fn transfer_then_join_group() {
        let (receiver, sender, receiver_words, sender_words) = exchange();
        assert_eq!(receiver_words, sender_words);
        assert_eq!(receiver_words.len(), 6);

        let owner_pad: Vec<u8> = (0..8_192u32).map(|i| (i * 13) as u8).collect();
        let sealed = sender
            .seal_pad(owner_pad.clone(), SecurityLevel::Standard)
            .unwrap();
        let received = receiver.open_pad(sealed).unwrap();
        assert_eq!(received.pad, owner_pad);
        assert_eq!(received.level, SecurityLevel::Standard);

        // The received copy joins a group at its transfer level
        let owner = crate::PadGroup::new(0, owner_pad, received.level);
        let holder = crate::PadGroup::new(1, vec![9; 8_192], SecurityLevel::Standard);
        holder.add_member(0, received.pad, received.level).unwrap();
        let frame = owner.encrypt(0x01, b"welcome".to_vec()).unwrap();
        assert_eq!(holder.decrypt(frame).unwrap().plaintext, b"welcome");
    }

    #[test]
    fn steps_out_of_order_fail() {
        let receiver = PadTransferReceiver::new(vec![1; 32]).unwrap();
        assert!(matches!(
            receiver.on_reveal(vec![4, 1]),
            Err(AshError::InvalidState)
        ));
        // The failed step ended the transfer
        let sender = PadTransferSender::new(receiver.offer(), vec![2; 64], vec![3; 32]).unwrap();
        assert!(matches!(
            receiver.on_response(sender.response(), vec![4; 32]),
            Err(AshError::InvalidState)
        ));

        let (_, sender, _, _) = exchange();
        assert!(matches!(
            sender.seal_pad(vec![1; 32], SecurityLevel::Maximum),
            Err(AshError::LevelNotAllowed)
        ));
        assert!(matches!(
            sender.seal_pad(vec![1; 32], SecurityLevel::Standard),
            Err(AshError::InvalidState)
        ));
    }

    #[test]
    fn offer_travels_over_ble_packets() {
        let receiver = PadTransferReceiver::new(vec![1; 32]).unwrap();
        let packets = split_into_ble_packets(receiver.offer(), 0, 20).unwrap();
        assert!(packets.len() > 60);
        let reassembler = BlePacketReassembler::new();
        let mut offer = None;
        for packet in packets {
            offer = reassembler.push(packet).unwrap();
        }
        assert_eq!(offer, Some(receiver.offer()));
        assert!(matches!(
            reassembler.push(vec![0x09]),
            Err(AshError::MalformedMessage)
        ));
        assert_eq!(ble_service_uuid().len(), 36);
    }

    #[test]
    fn bad_inputs_rejected() {
        assert!(matches!(
            PadTransferReceiver::new(vec![1; 31]),
            Err(AshError::InvalidEntropySize)
        ));
        assert!(matches!(
            PadTransferSender::new(vec![1, 2, 3], vec![2; 64], vec![3; 32]),
            Err(AshError::MalformedMessage)
        ));
        let receiver = PadTransferReceiver::new(vec![1; 32]).unwrap();
        assert!(matches!(
            PadTransferSender::new(receiver.offer(), vec![2; 63], vec![3; 32]),
            Err(AshError::InvalidEntropySize)
        ));
    }
}
