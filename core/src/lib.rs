//! ASH Core - Cryptographic core for secure ephemeral messaging.
//!
//! This library provides the cryptographic primitives for ASH:
//! - One-Time Pad generation and consumption
//! - Authenticated encryption (OTP + Wegman-Carter MAC)
//! - Fountain code encoding for reliable QR transfer
//! - Mnemonic checksum generation
//!
//! # Security Properties
//!
//! - Information-theoretic security via One-Time Pad
//! - Message authentication via 256-bit Wegman-Carter MAC
//! - Strict single-use pad consumption
//! - Deterministic behavior for verification
//! - Secure memory wiping
//!
//! # Constraints
//!
//! This library intentionally does NOT:
//! - Access the network
//! - Perform file I/O
//! - Access OS randomness (caller provides entropy)
//! - Contain platform-specific code
//! - Store data persistently
//! - Log sensitive data
//!
//! # Example: Complete Ceremony and Authenticated Messaging
//!
//! ```
//! use ash_core::{
//!     Pad, PadSize, Role, CeremonyMetadata, frame, mnemonic,
//!     MessageFrame, MessageType, AuthKey, AUTH_KEY_SIZE,
//! };
//!
//! // === CEREMONY (Initiator) ===
//!
//! // 1. Create pad from entropy (caller gathers entropy)
//! let entropy = vec![0u8; PadSize::Small.bytes()];
//! let initiator_pad = Pad::new(&entropy, PadSize::Small).unwrap();
//!
//! // 2. Create fountain frames for QR transfer
//! let metadata = CeremonyMetadata::default();
//! let mut generator = frame::create_fountain_ceremony(
//!     &metadata,
//!     initiator_pad.as_bytes(),
//!     256,
//!     None, // Optional passphrase
//!     frame::TransferMethod::Raptor, // Transfer method
//! ).unwrap();
//!
//! // 3. Generate mnemonic for verification
//! let initiator_mnemonic = mnemonic::generate_default(initiator_pad.as_bytes());
//!
//! // === CEREMONY (Responder) ===
//!
//! // 4. Receive fountain frames (from QR scans)
//! let mut receiver = frame::FountainFrameReceiver::new(None);
//! while !receiver.is_complete() {
//!     let frame = generator.next_frame();
//!     receiver.add_frame(&frame).unwrap();
//! }
//!
//! // 5. Get decoded pad
//! let result = receiver.get_result().unwrap();
//! let mut responder_pad = Pad::from_bytes(result.pad.clone());
//!
//! // 6. Verify mnemonic matches
//! let responder_mnemonic = mnemonic::generate_default(&result.pad);
//! assert_eq!(initiator_mnemonic, responder_mnemonic);
//!
//! // === AUTHENTICATED MESSAGING ===
//!
//! // Responder sends an authenticated message (consumes from end)
//! // Each message needs: 64 bytes auth key + N bytes encryption key
//! let plaintext = b"Hello, secure world!";
//! let auth_bytes = responder_pad.consume(AUTH_KEY_SIZE, Role::Responder).unwrap();
//! let auth_key = AuthKey::from_slice(&auth_bytes);
//! let enc_key = responder_pad.consume(plaintext.len(), Role::Responder).unwrap();
//!
//! // Create authenticated message frame
//! let frame = MessageFrame::encrypt(
//!     MessageType::Text,
//!     plaintext,
//!     &enc_key,
//!     &auth_key,
//! ).unwrap();
//! let wire_data = frame.encode();
//!
//! // Initiator receives and verifies (using Responder role to get same bytes)
//! let mut initiator = Pad::from_bytes(initiator_pad.as_bytes().to_vec());
//! let recv_auth_bytes = initiator.consume(AUTH_KEY_SIZE, Role::Responder).unwrap();
//! let recv_auth_key = AuthKey::from_slice(&recv_auth_bytes);
//! let recv_enc_key = initiator.consume(plaintext.len(), Role::Responder).unwrap();
//!
//! // Decode and verify - authentication checked BEFORE decryption
//! let received = MessageFrame::decode(&wire_data).unwrap();
//! let decrypted = received.decrypt(&recv_enc_key, &recv_auth_key).unwrap();
//! assert_eq!(decrypted, plaintext);
//! ```

// Note: unsafe is used ONLY in pad.rs for secure memory zeroing via write_volatile.
// This prevents the compiler from optimizing away the zeroing of sensitive data.
#![warn(missing_docs)]
#![warn(clippy::all)]

pub mod auth;
pub mod ceremony;
pub mod crc;
pub mod error;
pub mod fountain;
pub mod frame;
pub mod gf128;
pub mod group;
pub mod mac;
pub mod mnemonic;
pub mod message;
pub mod pad;
pub mod pad_calculator;
pub mod passphrase;
pub mod poly_hash;
pub mod raptor;
pub mod wordlist;

// Internal modules - not part of public API
// OTP is low-level XOR; always use MessageFrame for authenticated encryption
pub(crate) mod otp;

// Re-export main types at crate root
pub use ceremony::{CeremonyMetadata, NotificationFlags, DEFAULT_TTL_SECONDS, METADATA_VERSION};
pub use error::{Error, Result};
pub use fountain::{EncodedBlock, FountainDecoder, FountainEncoder, LegacyLTEncoder, LegacyLTDecoder};
pub use raptor::{RaptorDecoder, RaptorEncoder};
pub use frame::{
    create_fountain_ceremony, FountainCeremonyResult, FountainFrameGenerator,
    FountainFrameReceiver, TransferMethod, DEFAULT_BLOCK_SIZE,
};

// Re-export pad calculator types for convenience
pub use pad_calculator::{
    calculate_pad_stats, calculate_pad_stats_with_qr_size, expected_frames, redundancy_blocks,
    PadCalculator, PadStats, METADATA_OVERHEAD, DEFAULT_QR_BLOCK_SIZE,
};
pub use group::{Group, GroupFrame, MemberId, MemberPad};
pub use pad::{Pad, PadSize, Role};

// Re-export authenticated message types - the primary API for encryption
pub use mac::{AuthKey, AUTH_KEY_SIZE, TAG_SIZE};
pub use message::{
    pad_message, unpad_message, MessageFrame, MessageType,
    HEADER_SIZE, MIN_FRAME_SIZE, MIN_PADDED_SIZE,
};

/// Library version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_ceremony_roundtrip_with_authentication() {
        // Simulate complete ceremony and authenticated messaging flow

        // === Setup ===
        let entropy: Vec<u8> = (0..=255).cycle().take(PadSize::Small.bytes()).collect();

        // === Initiator creates pad ===
        let initiator_pad = Pad::new(&entropy, PadSize::Small).unwrap();

        // === Initiator creates fountain frames ===
        let metadata = CeremonyMetadata::default();
        let mut generator = frame::create_fountain_ceremony(
            &metadata,
            initiator_pad.as_bytes(),
            256,
            None,
            frame::TransferMethod::Raptor,
        )
        .unwrap();

        // === Initiator generates mnemonic ===
        let initiator_mnemonic = mnemonic::generate_default(initiator_pad.as_bytes());
        assert_eq!(initiator_mnemonic.len(), 6);

        // === Simulate QR transfer with fountain codes ===
        let mut receiver = FountainFrameReceiver::new(None);
        while !receiver.is_complete() {
            let frame = generator.next_frame();
            receiver.add_frame(&frame).unwrap();
        }

        // === Responder gets decoded result ===
        let result = receiver.get_result().unwrap();
        let reconstructed = result.pad;
        assert_eq!(reconstructed, initiator_pad.as_bytes());

        // === Responder generates mnemonic ===
        let responder_mnemonic = mnemonic::generate_default(&reconstructed);

        // === Verify mnemonics match ===
        assert_eq!(initiator_mnemonic, responder_mnemonic);

        // === Both parties can now send authenticated messages ===
        let mut initiator = Pad::from_bytes(initiator_pad.as_bytes().to_vec());
        let mut responder = Pad::from_bytes(reconstructed);

        // Initiator sends an authenticated message (consumes from start)
        let plaintext1 = b"Hello from initiator!";

        // Consume auth key (64 bytes) + encryption key (plaintext length)
        let init_auth_bytes = initiator.consume(AUTH_KEY_SIZE, Role::Initiator).unwrap();
        let init_auth_key = AuthKey::from_slice(&init_auth_bytes);
        let init_enc_key = initiator.consume(plaintext1.len(), Role::Initiator).unwrap();

        // Create authenticated frame
        let frame1 = MessageFrame::encrypt(
            MessageType::Text,
            plaintext1,
            &init_enc_key,
            &init_auth_key,
        ).unwrap();
        let wire1 = frame1.encode();

        // Responder verifies and decrypts
        let resp_auth_bytes = responder.consume(AUTH_KEY_SIZE, Role::Initiator).unwrap();
        let resp_auth_key = AuthKey::from_slice(&resp_auth_bytes);
        let resp_enc_key = responder.consume(plaintext1.len(), Role::Initiator).unwrap();

        let received1 = MessageFrame::decode(&wire1).unwrap();
        let decrypted1 = received1.decrypt(&resp_enc_key, &resp_auth_key).unwrap();
        assert_eq!(decrypted1, plaintext1);

        // Responder sends an authenticated message (consumes from end)
        let plaintext2 = b"Hello from responder!";

        let resp_send_auth_bytes = responder.consume(AUTH_KEY_SIZE, Role::Responder).unwrap();
        let resp_send_auth_key = AuthKey::from_slice(&resp_send_auth_bytes);
        let resp_send_enc_key = responder.consume(plaintext2.len(), Role::Responder).unwrap();

        let frame2 = MessageFrame::encrypt(
            MessageType::Text,
            plaintext2,
            &resp_send_enc_key,
            &resp_send_auth_key,
        ).unwrap();
        let wire2 = frame2.encode();

        // Initiator verifies and decrypts
        let init_recv_auth_bytes = initiator.consume(AUTH_KEY_SIZE, Role::Responder).unwrap();
        let init_recv_auth_key = AuthKey::from_slice(&init_recv_auth_bytes);
        let init_recv_enc_key = initiator.consume(plaintext2.len(), Role::Responder).unwrap();

        let received2 = MessageFrame::decode(&wire2).unwrap();
        let decrypted2 = received2.decrypt(&init_recv_enc_key, &init_recv_auth_key).unwrap();
        assert_eq!(decrypted2, plaintext2);
    }

    #[test]
    fn tampered_message_rejected() {
        // Verify that tampering with wire data is detected
        let entropy: Vec<u8> = (0..=255).cycle().take(PadSize::Small.bytes()).collect();
        let mut sender_pad = Pad::new(&entropy, PadSize::Small).unwrap();
        let mut receiver_pad = Pad::from_bytes(sender_pad.as_bytes().to_vec());

        let plaintext = b"Secret message";

        // Sender creates authenticated frame
        let auth_bytes = sender_pad.consume(AUTH_KEY_SIZE, Role::Initiator).unwrap();
        let auth_key = AuthKey::from_slice(&auth_bytes);
        let enc_key = sender_pad.consume(plaintext.len(), Role::Initiator).unwrap();

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key).unwrap();
        let mut wire = frame.encode();

        // Attacker tampers with ciphertext
        wire[HEADER_SIZE] ^= 0xFF;

        // Receiver tries to decrypt
        let recv_auth_bytes = receiver_pad.consume(AUTH_KEY_SIZE, Role::Initiator).unwrap();
        let recv_auth_key = AuthKey::from_slice(&recv_auth_bytes);
        let recv_enc_key = receiver_pad.consume(plaintext.len(), Role::Initiator).unwrap();

        let received = MessageFrame::decode(&wire).unwrap();
        let result = received.decrypt(&recv_enc_key, &recv_auth_key);

        // Should fail authentication
        assert!(matches!(result, Err(Error::AuthenticationFailed)));
    }

    #[test]
    fn pad_exhaustion() {
        let entropy = vec![0u8; 200]; // Need enough for auth keys
        let mut pad = Pad::from_bytes(entropy);

        // Consume 100 from initiator side, 100 from responder side
        pad.consume(100, Role::Initiator).unwrap();
        pad.consume(100, Role::Responder).unwrap();
        assert!(pad.is_exhausted());

        // Try to consume more
        let result = pad.consume(1, Role::Initiator);
        assert!(result.is_err());
    }

    #[test]
    fn fountain_corruption_detected() {
        let metadata = CeremonyMetadata::default();
        let pad = vec![0u8; 1000];
        let mut generator =
            frame::create_fountain_ceremony(&metadata, &pad, 256, None, frame::TransferMethod::Raptor)
                .unwrap();

        let mut frame = generator.next_frame();

        // Corrupt a byte in the payload
        frame[15] ^= 0xFF;

        // Should fail CRC check
        let mut receiver = FountainFrameReceiver::new(None);
        let result = receiver.add_frame(&frame);
        assert!(matches!(result, Err(Error::CrcMismatch { .. })));
    }

    #[test]
    fn mnemonic_consistency() {
        let pad1 = vec![0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE];
        let pad2 = pad1.clone();

        let mnemonic1 = mnemonic::generate_default(&pad1);
        let mnemonic2 = mnemonic::generate_default(&pad2);

        assert_eq!(mnemonic1, mnemonic2);
    }

    // Low-level OTP test (internal module, tests XOR properties)
    #[test]
    fn otp_xor_symmetric() {
        let key = vec![0xAB, 0xCD, 0xEF];
        let data = vec![0x12, 0x34, 0x56];

        let encrypted = otp::encrypt(&key, &data).unwrap();
        let decrypted = otp::decrypt(&key, &encrypted).unwrap();

        assert_eq!(data, decrypted);
    }
}
