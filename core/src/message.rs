//! Authenticated message frame encoding and decoding.
//!
//! This module defines the wire format for messages exchanged between
//! ASH clients via the relay server. All messages include a 256-bit
//! authentication tag for integrity protection.
//!
//! # Frame Format (v1)
//!
//! ```text
//! ┌─────────┬──────┬────────┬────────────┬─────────┐
//! │ version │ type │ length │ ciphertext │   tag   │
//! │ 1 byte  │ 1    │ 2 (BE) │ N bytes    │ 32 bytes│
//! └─────────┴──────┴────────┴────────────┴─────────┘
//!     │        │       │           │          │
//!     └────────┴───────┴───────────┘          │
//!              Authenticated data             │
//!     └───────────────────────────────────────┘
//!                  Full frame
//! ```
//!
//! - **version**: Frame format version (currently 1)
//! - **type**: Message type (text, location, etc.)
//! - **length**: Ciphertext length in bytes (big-endian u16)
//! - **ciphertext**: OTP-encrypted payload
//! - **tag**: 256-bit Wegman-Carter authentication tag
//!
//! # Security Properties
//!
//! - **Confidentiality**: OTP encryption (information-theoretic)
//! - **Integrity**: Wegman-Carter MAC (information-theoretic)
//! - **Authenticity**: Only pad holders can create valid messages
//! - **Anti-malleability**: Any modification detected and rejected
//!
//! # Pad Consumption
//!
//! Each message consumes from the one-time pad:
//! - 64 bytes for authentication (r₁, r₂, s₁, s₂)
//! - N bytes for encryption (ciphertext length)
//!
//! # Example
//!
//! ```
//! use ash_core::message::{MessageType, MessageFrame};
//! use ash_core::mac::{AuthKey, AUTH_KEY_SIZE};
//!
//! // Sender: create authenticated frame
//! let auth_key = AuthKey::from_bytes(&[0x42u8; AUTH_KEY_SIZE]);
//! let encryption_key = vec![0xAB; 13]; // From pad
//! let plaintext = b"Hello, World!";
//!
//! let frame = MessageFrame::encrypt(
//!     MessageType::Text,
//!     plaintext,
//!     &encryption_key,
//!     &auth_key,
//! ).unwrap();
//!
//! let encoded = frame.encode();
//!
//! // Receiver: decode and verify
//! let decoded = MessageFrame::decode(&encoded).unwrap();
//! let decrypted = decoded.decrypt(&encryption_key, &auth_key).unwrap();
//! assert_eq!(decrypted, plaintext);
//! ```

use crate::error::{Error, Result};
use crate::mac::{compute_tag, verify_tag, AuthKey, TAG_SIZE};
use crate::otp;

/// Minimum padded message size (32 bytes).
pub const MIN_PADDED_SIZE: usize = 32;

/// Padding marker byte (0x00).
pub const PADDING_MARKER: u8 = 0x00;

/// Maximum message content length (65535 bytes = u16::MAX).
pub const MAX_MESSAGE_CONTENT_LEN: usize = u16::MAX as usize;

/// Frame format version.
pub const FRAME_VERSION: u8 = 1;

/// Header size in bytes (version + type + length).
pub const HEADER_SIZE: usize = 4;

/// Minimum frame size (header + tag, no ciphertext).
pub const MIN_FRAME_SIZE: usize = HEADER_SIZE + TAG_SIZE;

/// Maximum ciphertext length (u16 max).
pub const MAX_CIPHERTEXT_LEN: usize = u16::MAX as usize;

/// Message types supported by the protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MessageType {
    /// Text message (UTF-8 encoded).
    Text = 0x01,
    /// One-shot location (latitude, longitude as fixed-point).
    Location = 0x02,
    /// Request to delete one of the sender's own earlier messages, by the
    /// pad offset its keys started at (see [`crate::content`]).
    Delete = 0x03,
    /// Text with its own display lifetime chosen by the sender
    /// (see [`crate::content`]).
    ExpiringText = 0x04,
}

impl MessageType {
    /// Convert from byte value.
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0x01 => Some(Self::Text),
            0x02 => Some(Self::Location),
            0x03 => Some(Self::Delete),
            0x04 => Some(Self::ExpiringText),
            _ => None,
        }
    }

    /// Convert to byte value.
    pub fn to_byte(self) -> u8 {
        self as u8
    }
}

/// An authenticated message frame.
///
/// Contains the encrypted payload and authentication tag.
/// The tag covers both the header and ciphertext.
#[derive(Debug, Clone)]
pub struct MessageFrame {
    /// Message type.
    pub msg_type: MessageType,
    /// Encrypted payload.
    pub ciphertext: Vec<u8>,
    /// 256-bit authentication tag.
    pub tag: [u8; TAG_SIZE],
}

impl MessageFrame {
    /// Create an authenticated message frame by encrypting plaintext.
    ///
    /// # Arguments
    ///
    /// * `msg_type` - Type of message
    /// * `plaintext` - Data to encrypt
    /// * `encryption_key` - OTP key bytes (must equal plaintext length)
    /// * `auth_key` - Authentication key (64 bytes from pad)
    ///
    /// # Returns
    ///
    /// An authenticated message frame ready for transmission.
    ///
    /// # Errors
    ///
    /// - `LengthMismatch` if encryption key length doesn't match plaintext
    /// - `PayloadTooLarge` if plaintext exceeds maximum size
    pub fn encrypt(
        msg_type: MessageType,
        plaintext: &[u8],
        encryption_key: &[u8],
        auth_key: &AuthKey,
    ) -> Result<Self> {
        if plaintext.len() > MAX_CIPHERTEXT_LEN {
            return Err(Error::PayloadTooLarge {
                size: plaintext.len(),
                max: MAX_CIPHERTEXT_LEN,
            });
        }

        // Encrypt with OTP
        let ciphertext = otp::encrypt(encryption_key, plaintext)?;

        // Build header for authentication
        let header = Self::build_header(msg_type, ciphertext.len());

        // Compute authentication tag over header || ciphertext
        let tag = compute_tag(auth_key, &header, &ciphertext);

        Ok(Self {
            msg_type,
            ciphertext,
            tag,
        })
    }

    /// Decrypt and verify an authenticated message frame.
    ///
    /// **Important**: This method verifies the authentication tag BEFORE
    /// decryption. If verification fails, no plaintext is returned.
    ///
    /// # Arguments
    ///
    /// * `encryption_key` - OTP key bytes (must equal ciphertext length)
    /// * `auth_key` - Authentication key (must match sender's key)
    ///
    /// # Returns
    ///
    /// Decrypted plaintext if authentication succeeds.
    ///
    /// # Errors
    ///
    /// - `AuthenticationFailed` if the tag doesn't verify
    /// - `LengthMismatch` if encryption key length doesn't match ciphertext
    pub fn decrypt(&self, encryption_key: &[u8], auth_key: &AuthKey) -> Result<Vec<u8>> {
        // Build header for verification
        let header = Self::build_header(self.msg_type, self.ciphertext.len());

        // Verify authentication FIRST (before any decryption)
        if !verify_tag(auth_key, &header, &self.ciphertext, &self.tag) {
            return Err(Error::AuthenticationFailed);
        }

        // Decrypt only after successful verification
        otp::decrypt(encryption_key, &self.ciphertext)
    }

    /// Encode the frame to bytes for transmission.
    ///
    /// # Wire Format
    ///
    /// ```text
    /// [version: 1][type: 1][length: 2][ciphertext: N][tag: 32]
    /// ```
    pub fn encode(&self) -> Vec<u8> {
        let len = self.ciphertext.len() as u16;
        let mut bytes = Vec::with_capacity(HEADER_SIZE + self.ciphertext.len() + TAG_SIZE);

        // Header
        bytes.push(FRAME_VERSION);
        bytes.push(self.msg_type.to_byte());
        bytes.extend_from_slice(&len.to_be_bytes());

        // Ciphertext
        bytes.extend_from_slice(&self.ciphertext);

        // Tag
        bytes.extend_from_slice(&self.tag);

        bytes
    }

    /// Decode a frame from bytes.
    ///
    /// This only parses the frame structure; it does NOT verify the
    /// authentication tag. Call [`decrypt`](Self::decrypt) to verify and decrypt.
    ///
    /// # Errors
    ///
    /// - `FrameTooShort` if frame is smaller than minimum size
    /// - `UnsupportedFrameVersion` if version is not supported
    /// - `InvalidMessageType` if message type is unknown
    /// - `FrameLengthMismatch` if declared length doesn't match actual
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < MIN_FRAME_SIZE {
            return Err(Error::FrameTooShort {
                size: bytes.len(),
                minimum: MIN_FRAME_SIZE,
            });
        }

        // Parse header
        let version = bytes[0];
        if version != FRAME_VERSION {
            return Err(Error::UnsupportedFrameVersion { version });
        }

        let msg_type = MessageType::from_byte(bytes[1])
            .ok_or(Error::InvalidMessageType { msg_type: bytes[1] })?;

        let declared_len = u16::from_be_bytes([bytes[2], bytes[3]]) as usize;

        // Validate total length
        let expected_total = HEADER_SIZE + declared_len + TAG_SIZE;
        if bytes.len() != expected_total {
            return Err(Error::FrameLengthMismatch {
                declared: declared_len,
                actual: bytes.len().saturating_sub(HEADER_SIZE + TAG_SIZE),
            });
        }

        // Extract ciphertext and tag
        let ciphertext = bytes[HEADER_SIZE..HEADER_SIZE + declared_len].to_vec();
        let tag: [u8; TAG_SIZE] = bytes[HEADER_SIZE + declared_len..]
            .try_into()
            .expect("tag size already validated");

        Ok(Self {
            msg_type,
            ciphertext,
            tag,
        })
    }

    /// Build the header bytes for authentication.
    fn build_header(msg_type: MessageType, ciphertext_len: usize) -> [u8; HEADER_SIZE] {
        let len_bytes = (ciphertext_len as u16).to_be_bytes();
        [
            FRAME_VERSION,
            msg_type.to_byte(),
            len_bytes[0],
            len_bytes[1],
        ]
    }

    /// Get the header bytes of this frame.
    pub fn header(&self) -> [u8; HEADER_SIZE] {
        Self::build_header(self.msg_type, self.ciphertext.len())
    }

    /// Total size of the encoded frame in bytes.
    pub fn encoded_size(&self) -> usize {
        HEADER_SIZE + self.ciphertext.len() + TAG_SIZE
    }
}

/// Calculate total pad consumption for a message.
///
/// Returns the number of bytes that will be consumed from the pad
/// to encrypt and authenticate a message of the given plaintext length.
///
/// # Formula
///
/// `total = 64 (auth) + plaintext_len (encryption)`
pub const fn pad_consumption(plaintext_len: usize) -> usize {
    crate::mac::AUTH_KEY_SIZE + plaintext_len
}

/// Pad a message to minimum 32 bytes for traffic analysis protection.
///
/// # Format
///
/// ```text
/// [0x00 marker][2-byte length BE][content][zero padding to 32 bytes]
/// ```
///
/// # Arguments
///
/// * `message` - Original message bytes
///
/// # Returns
///
/// Padded message (minimum 32 bytes, larger if message exceeds 29 bytes).
///
/// # Example
///
/// ```
/// use ash_core::message::pad_message;
///
/// let padded = pad_message(b"hi").unwrap();
/// assert_eq!(padded.len(), 32);
/// assert_eq!(&padded[0..5], &[0x00, 0x00, 0x02, b'h', b'i']);
/// ```
pub fn pad_message(message: &[u8]) -> Result<Vec<u8>> {
    pad_message_to(message, MIN_PADDED_SIZE)
}

/// Pad a message to at least `min_size` bytes, in the [`pad_message`] format.
///
/// # Example
///
/// ```
/// use ash_core::message::{pad_message_to, unpad_message};
///
/// let padded = pad_message_to(b"hi", 64).unwrap();
/// assert_eq!(padded.len(), 64);
/// assert_eq!(unpad_message(&padded).unwrap(), b"hi");
/// ```
pub fn pad_message_to(message: &[u8], min_size: usize) -> Result<Vec<u8>> {
    if message.len() > u16::MAX as usize {
        return Err(Error::PayloadTooLarge {
            size: message.len(),
            max: u16::MAX as usize,
        });
    }

    let content_len = message.len();
    let total_needed = 1 + 2 + content_len; // marker + length + content
    let padded_size = total_needed.max(min_size);

    let mut padded = vec![0u8; padded_size];

    // [0x00 marker]
    padded[0] = PADDING_MARKER;

    // [2-byte length BE]
    let len_bytes = (content_len as u16).to_be_bytes();
    padded[1] = len_bytes[0];
    padded[2] = len_bytes[1];

    // [content]
    padded[3..3 + content_len].copy_from_slice(message);

    // Remaining bytes are already zero (padding)

    Ok(padded)
}

/// Remove padding from a message.
///
/// # Arguments
///
/// * `padded` - Padded message bytes
///
/// # Returns
///
/// Original message bytes.
///
/// # Errors
///
/// - `InvalidPadding` if the padding format is invalid
///
/// # Example
///
/// ```
/// use ash_core::message::{pad_message, unpad_message};
///
/// let original = b"Hello!";
/// let padded = pad_message(original).unwrap();
/// let recovered = unpad_message(&padded).unwrap();
/// assert_eq!(recovered, original);
/// ```
pub fn unpad_message(padded: &[u8]) -> Result<Vec<u8>> {
    if padded.len() < 3 {
        return Err(Error::InvalidPadding {
            reason: "padded message too short (< 3 bytes)".to_string(),
        });
    }

    // Check marker
    if padded[0] != PADDING_MARKER {
        return Err(Error::InvalidPadding {
            reason: format!(
                "invalid marker byte: expected 0x00, got 0x{:02X}",
                padded[0]
            ),
        });
    }

    // Read length
    let content_len = u16::from_be_bytes([padded[1], padded[2]]) as usize;

    // Validate length
    if 3 + content_len > padded.len() {
        return Err(Error::InvalidPadding {
            reason: format!(
                "content length {} exceeds available data {}",
                content_len,
                padded.len() - 3
            ),
        });
    }

    // Extract content
    Ok(padded[3..3 + content_len].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mac::AUTH_KEY_SIZE;

    fn make_test_keys(plaintext_len: usize) -> (Vec<u8>, AuthKey) {
        let enc_key: Vec<u8> = (0..plaintext_len).map(|i| i as u8).collect();
        let auth_bytes: [u8; AUTH_KEY_SIZE] = std::array::from_fn(|i| (i * 7) as u8);
        (enc_key, AuthKey::from_bytes(&auth_bytes))
    }

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let plaintext = b"Hello, secure world!";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        let decrypted = frame
            .decrypt(&enc_key, &auth_key)
            .expect("decryption should succeed");

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn encode_decode_roundtrip() {
        let plaintext = b"Test message";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let original = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        let encoded = original.encode();
        let decoded = MessageFrame::decode(&encoded).expect("decoding should succeed");

        assert_eq!(decoded.msg_type, original.msg_type);
        assert_eq!(decoded.ciphertext, original.ciphertext);
        assert_eq!(decoded.tag, original.tag);
    }

    #[test]
    fn frame_format_correct() {
        let plaintext = b"ABC";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        let encoded = frame.encode();

        // Check header
        assert_eq!(encoded[0], FRAME_VERSION);
        assert_eq!(encoded[1], MessageType::Text.to_byte());
        assert_eq!(u16::from_be_bytes([encoded[2], encoded[3]]), 3); // length

        // Check total size
        assert_eq!(encoded.len(), HEADER_SIZE + 3 + TAG_SIZE);
    }

    #[test]
    fn tampered_ciphertext_fails() {
        let plaintext = b"Secret message";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let mut frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        // Tamper with ciphertext
        frame.ciphertext[0] ^= 0xFF;

        let result = frame.decrypt(&enc_key, &auth_key);
        assert!(matches!(result, Err(Error::AuthenticationFailed)));
    }

    #[test]
    fn tampered_tag_fails() {
        let plaintext = b"Secret message";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let mut frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        // Tamper with tag
        frame.tag[0] ^= 0x01;

        let result = frame.decrypt(&enc_key, &auth_key);
        assert!(matches!(result, Err(Error::AuthenticationFailed)));
    }

    #[test]
    fn wrong_auth_key_fails() {
        let plaintext = b"Secret message";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        // Different auth key
        let wrong_auth = AuthKey::from_bytes(&[0xFF; AUTH_KEY_SIZE]);

        let result = frame.decrypt(&enc_key, &wrong_auth);
        assert!(matches!(result, Err(Error::AuthenticationFailed)));
    }

    #[test]
    fn modified_wire_format_fails() {
        let plaintext = b"Test";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        let mut encoded = frame.encode();

        // Modify the type byte in encoded form
        encoded[1] = MessageType::Location.to_byte();

        let decoded = MessageFrame::decode(&encoded).expect("decode should work");

        // But decryption should fail because header is authenticated
        let result = decoded.decrypt(&enc_key, &auth_key);
        assert!(matches!(result, Err(Error::AuthenticationFailed)));
    }

    #[test]
    fn location_message_type() {
        // 6 decimal places = 8 bytes per coordinate = 16 bytes total
        let location_data = [0u8; 16];
        let (enc_key, auth_key) = make_test_keys(location_data.len());

        let frame =
            MessageFrame::encrypt(MessageType::Location, &location_data, &enc_key, &auth_key)
                .expect("encryption should succeed");

        assert_eq!(frame.msg_type, MessageType::Location);

        let decrypted = frame
            .decrypt(&enc_key, &auth_key)
            .expect("decryption should succeed");

        assert_eq!(decrypted, location_data);
    }

    #[test]
    fn empty_message() {
        let plaintext = b"";
        let (enc_key, auth_key) = make_test_keys(0);

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        assert!(frame.ciphertext.is_empty());
        assert_eq!(frame.encoded_size(), HEADER_SIZE + TAG_SIZE);

        let encoded = frame.encode();
        let decoded = MessageFrame::decode(&encoded).expect("decode should succeed");

        let decrypted = decoded
            .decrypt(&enc_key, &auth_key)
            .expect("decryption should succeed");

        assert!(decrypted.is_empty());
    }

    #[test]
    fn message_type_conversion() {
        assert_eq!(MessageType::from_byte(0x01), Some(MessageType::Text));
        assert_eq!(MessageType::from_byte(0x02), Some(MessageType::Location));
        assert_eq!(MessageType::from_byte(0x03), Some(MessageType::Delete));
        assert_eq!(
            MessageType::from_byte(0x04),
            Some(MessageType::ExpiringText)
        );
        assert_eq!(MessageType::from_byte(0x00), None);
        assert_eq!(MessageType::from_byte(0xFF), None);

        assert_eq!(MessageType::Text.to_byte(), 0x01);
        assert_eq!(MessageType::Location.to_byte(), 0x02);
    }

    #[test]
    fn frame_too_short() {
        let short = vec![0u8; MIN_FRAME_SIZE - 1];
        let result = MessageFrame::decode(&short);
        assert!(matches!(result, Err(Error::FrameTooShort { .. })));
    }

    #[test]
    fn unsupported_version() {
        let mut frame = vec![0u8; MIN_FRAME_SIZE];
        frame[0] = 0xFF; // Invalid version
        frame[1] = 0x01; // Text type

        let result = MessageFrame::decode(&frame);
        assert!(matches!(result, Err(Error::UnsupportedFrameVersion { .. })));
    }

    #[test]
    fn invalid_message_type() {
        let mut frame = vec![0u8; MIN_FRAME_SIZE];
        frame[0] = FRAME_VERSION;
        frame[1] = 0xFF; // Invalid type

        let result = MessageFrame::decode(&frame);
        assert!(matches!(result, Err(Error::InvalidMessageType { .. })));
    }

    #[test]
    fn length_mismatch() {
        let plaintext = b"Test";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        let mut encoded = frame.encode();

        // Truncate one byte from ciphertext
        encoded.remove(HEADER_SIZE);

        let result = MessageFrame::decode(&encoded);
        assert!(matches!(result, Err(Error::FrameLengthMismatch { .. })));
    }

    #[test]
    fn pad_consumption_calculation() {
        assert_eq!(pad_consumption(0), AUTH_KEY_SIZE);
        assert_eq!(pad_consumption(100), AUTH_KEY_SIZE + 100);
        assert_eq!(pad_consumption(1000), AUTH_KEY_SIZE + 1000);
    }

    #[test]
    fn header_method() {
        let plaintext = b"Test";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        let header = frame.header();
        assert_eq!(header[0], FRAME_VERSION);
        assert_eq!(header[1], MessageType::Text.to_byte());
        assert_eq!(u16::from_be_bytes([header[2], header[3]]), 4);
    }

    #[test]
    fn encoded_size_method() {
        let plaintext = b"Hello";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        assert_eq!(frame.encoded_size(), HEADER_SIZE + 5 + TAG_SIZE);
        assert_eq!(frame.encode().len(), frame.encoded_size());
    }

    #[test]
    fn all_bit_flips_in_ciphertext_detected() {
        let plaintext = b"Test message for bit flip detection";
        let (enc_key, auth_key) = make_test_keys(plaintext.len());

        let original = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key)
            .expect("encryption should succeed");

        for byte_idx in 0..original.ciphertext.len() {
            for bit in 0..8 {
                let mut frame = original.clone();
                frame.ciphertext[byte_idx] ^= 1 << bit;

                let result = frame.decrypt(&enc_key, &auth_key);
                assert!(
                    result.is_err(),
                    "Bit flip at byte {} bit {} should be detected",
                    byte_idx,
                    bit
                );
            }
        }
    }
}
