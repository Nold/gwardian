//! Error types for ash-core.
//!
//! All errors are explicit and designed for clear FFI boundary communication.
//! No external dependencies - implements `std::error::Error` manually.
//!
//! # Error Categories
//!
//! - **Pad errors**: `InsufficientPadBytes`, `InvalidEntropySize`, `PadTooSmallForTokens`
//! - **OTP errors**: `LengthMismatch`
//! - **Fountain errors**: `FountainBlockTooShort`, `CrcMismatch`, `EmptyPayload`
//! - **Metadata errors**: `MetadataTooShort`, `UnsupportedMetadataVersion`, `MetadataUrlTooLong`, `InvalidMetadataUrl`

use std::error::Error as StdError;
use std::fmt;

/// Result type alias for ash-core operations.
pub type Result<T> = std::result::Result<T, Error>;

/// Errors that can occur during ash-core operations.
///
/// Each variant includes relevant context for debugging and error messages
/// are designed to be clear when displayed to users.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    // ==================== Pad Errors ====================
    /// Not enough bytes remaining in the pad for the requested operation.
    ///
    /// Occurs when trying to consume more bytes than available.
    InsufficientPadBytes {
        /// Number of bytes requested.
        needed: usize,
        /// Number of bytes available.
        available: usize,
    },

    /// Entropy provided does not match expected pad size.
    ///
    /// Occurs when creating a pad with wrong-sized entropy.
    InvalidEntropySize {
        /// Actual entropy size provided.
        size: usize,
        /// Expected entropy size for the pad.
        expected: usize,
    },

    /// Pad is too small to derive authorization tokens.
    ///
    /// Token derivation requires a minimum pad size (512 bytes).
    PadTooSmallForTokens {
        /// Actual pad size in bytes.
        size: usize,
        /// Minimum required size for token derivation.
        minimum: usize,
    },

    // ==================== OTP Errors ====================
    /// Key and data lengths don't match for OTP operation.
    ///
    /// OTP requires key length to exactly match data length.
    LengthMismatch {
        /// Length of the key/pad slice.
        pad_len: usize,
        /// Length of the data.
        data_len: usize,
    },

    // ==================== Fountain/Frame Errors ====================
    /// CRC checksum verification failed.
    ///
    /// Data integrity check failed - data may be corrupted.
    CrcMismatch {
        /// Expected CRC value.
        expected: u32,
        /// Actual computed CRC value.
        actual: u32,
    },

    /// Payload cannot be empty.
    ///
    /// Frame or block data must contain at least one byte.
    EmptyPayload,

    /// Fountain-encoded block is too short.
    ///
    /// Block must contain at least header + 1 byte + CRC.
    FountainBlockTooShort {
        /// Actual size in bytes.
        size: usize,
        /// Minimum required size.
        minimum: usize,
    },

    // ==================== Metadata Errors ====================
    /// Metadata frame is too short.
    ///
    /// Ceremony metadata requires a minimum size.
    MetadataTooShort {
        /// Actual size in bytes.
        size: usize,
        /// Minimum required size.
        minimum: usize,
    },

    /// Unsupported metadata version.
    ///
    /// Only version 1 is currently supported.
    UnsupportedMetadataVersion {
        /// The unsupported version number.
        version: u8,
    },

    /// Relay URL in metadata is too long.
    ///
    /// URL must fit in a single metadata frame.
    MetadataUrlTooLong {
        /// Actual URL length.
        len: usize,
        /// Maximum allowed length.
        max: usize,
    },

    /// Invalid UTF-8 in metadata URL.
    ///
    /// Relay URL must be valid UTF-8.
    InvalidMetadataUrl,

    // ==================== Message Frame Errors ====================
    /// Message authentication failed.
    ///
    /// The authentication tag does not match. The message may have been
    /// tampered with or the wrong key was used.
    ///
    /// Note: This error is intentionally uninformative to prevent
    /// leaking information about what specifically failed.
    AuthenticationFailed,

    /// Message payload exceeds maximum size.
    PayloadTooLarge {
        /// Actual payload size.
        size: usize,
        /// Maximum allowed size.
        max: usize,
    },

    /// Message frame is too short.
    FrameTooShort {
        /// Actual frame size.
        size: usize,
        /// Minimum required size.
        minimum: usize,
    },

    /// Unsupported message frame version.
    UnsupportedFrameVersion {
        /// The unsupported version number.
        version: u8,
    },

    /// Invalid message type in frame.
    InvalidMessageType {
        /// The invalid type byte.
        msg_type: u8,
    },

    /// Frame length field doesn't match actual content.
    FrameLengthMismatch {
        /// Declared length in header.
        declared: usize,
        /// Actual content length.
        actual: usize,
    },

    /// Invalid message padding format.
    InvalidPadding {
        /// Description of what's wrong.
        reason: String,
    },

    // ==================== Group Errors ====================
    /// Message names a sender that is not a member of the group.
    UnknownMember {
        /// Sender id from the frame.
        member: u8,
    },

    /// A member with this id is already in the group.
    DuplicateMember {
        /// The duplicated member id.
        member: u8,
    },

    /// Pad range was already consumed (replay or own message echoed back).
    PadRangeAlreadyUsed {
        /// Start of the requested range.
        offset: usize,
    },

    /// Local pad copy failed its integrity checksum.
    PadCorrupted {
        /// Start of the first damaged chunk.
        offset: usize,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InsufficientPadBytes { needed, available } => {
                write!(
                    f,
                    "insufficient pad bytes: needed {}, available {}",
                    needed, available
                )
            }
            Error::InvalidEntropySize { size, expected } => {
                write!(
                    f,
                    "invalid entropy size: got {}, expected {}",
                    size, expected
                )
            }
            Error::PadTooSmallForTokens { size, minimum } => {
                write!(
                    f,
                    "pad too small for token derivation: {} bytes, minimum is {}",
                    size, minimum
                )
            }
            Error::LengthMismatch { pad_len, data_len } => {
                write!(
                    f,
                    "length mismatch: key has {} bytes, data has {} bytes",
                    pad_len, data_len
                )
            }
            Error::CrcMismatch { expected, actual } => {
                write!(
                    f,
                    "CRC mismatch: expected {:#010x}, got {:#010x}",
                    expected, actual
                )
            }
            Error::EmptyPayload => write!(f, "payload cannot be empty"),
            Error::FountainBlockTooShort { size, minimum } => {
                write!(
                    f,
                    "fountain block too short: got {} bytes, minimum is {}",
                    size, minimum
                )
            }
            Error::MetadataTooShort { size, minimum } => {
                write!(
                    f,
                    "metadata too short: got {} bytes, minimum is {}",
                    size, minimum
                )
            }
            Error::UnsupportedMetadataVersion { version } => {
                write!(f, "unsupported metadata version: {}", version)
            }
            Error::MetadataUrlTooLong { len, max } => {
                write!(
                    f,
                    "metadata URL too long: {} bytes exceeds maximum {}",
                    len, max
                )
            }
            Error::InvalidMetadataUrl => {
                write!(f, "invalid UTF-8 in metadata URL")
            }
            Error::AuthenticationFailed => {
                write!(f, "message authentication failed")
            }
            Error::PayloadTooLarge { size, max } => {
                write!(
                    f,
                    "payload too large: {} bytes exceeds maximum {}",
                    size, max
                )
            }
            Error::FrameTooShort { size, minimum } => {
                write!(
                    f,
                    "frame too short: {} bytes, minimum is {}",
                    size, minimum
                )
            }
            Error::UnsupportedFrameVersion { version } => {
                write!(f, "unsupported frame version: {}", version)
            }
            Error::InvalidMessageType { msg_type } => {
                write!(f, "invalid message type: {:#04x}", msg_type)
            }
            Error::FrameLengthMismatch { declared, actual } => {
                write!(
                    f,
                    "frame length mismatch: header declares {} bytes, got {}",
                    declared, actual
                )
            }
            Error::InvalidPadding { reason } => {
                write!(f, "invalid padding: {}", reason)
            }
            Error::UnknownMember { member } => {
                write!(f, "unknown group member: {}", member)
            }
            Error::DuplicateMember { member } => {
                write!(f, "group member already exists: {}", member)
            }
            Error::PadRangeAlreadyUsed { offset } => {
                write!(f, "pad range already used at offset {}", offset)
            }
            Error::PadCorrupted { offset } => {
                write!(f, "pad corrupted at offset {}", offset)
            }
        }
    }
}

impl StdError for Error {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display_messages() {
        let err = Error::InsufficientPadBytes {
            needed: 100,
            available: 50,
        };
        assert_eq!(
            err.to_string(),
            "insufficient pad bytes: needed 100, available 50"
        );

        let err = Error::CrcMismatch {
            expected: 0xDEADBEEF,
            actual: 0xCAFEBABE,
        };
        assert!(err.to_string().contains("0xdeadbeef"));
        assert!(err.to_string().contains("0xcafebabe"));

        let err = Error::EmptyPayload;
        assert_eq!(err.to_string(), "payload cannot be empty");
    }

    #[test]
    fn error_implements_std_error() {
        let err = Error::EmptyPayload;
        let _: &dyn StdError = &err;
    }

    #[test]
    fn error_is_clone_and_eq() {
        let err1 = Error::CrcMismatch {
            expected: 123,
            actual: 456,
        };
        let err2 = err1.clone();
        assert_eq!(err1, err2);
    }
}
