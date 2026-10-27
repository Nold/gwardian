//! Error types for ash-transfer.

use std::error::Error as StdError;
use std::fmt;

/// Result type alias for ash-transfer operations.
pub type Result<T> = std::result::Result<T, Error>;

/// Errors that can occur while transferring a pad.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A message has the wrong type, version or length.
    Malformed {
        /// Description of what is wrong.
        reason: &'static str,
    },
    /// The peer's ML-KEM public key fails the FIPS 203 modulus check.
    InvalidPublicKey,
    /// The revealed nonce does not match the earlier commitment: someone
    /// tampered with the exchange.
    CommitmentMismatch,
    /// The sealed pad failed authentication: wrong key (an attacker in the
    /// middle, or words not compared) or altered in transit.
    DecryptionFailed,
    /// Only `Standard` and `Enhanced` pads travel over this channel; a
    /// `Maximum` pad must be exchanged by QR code.
    LevelNotAllowed,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Malformed { reason } => write!(f, "malformed message: {reason}"),
            Error::InvalidPublicKey => write!(f, "invalid public key"),
            Error::CommitmentMismatch => write!(f, "commitment mismatch"),
            Error::DecryptionFailed => write!(f, "sealed pad failed authentication"),
            Error::LevelNotAllowed => write!(f, "security level not allowed for this channel"),
        }
    }
}

impl StdError for Error {}
