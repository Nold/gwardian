//! Pad transfer for the `Standard` and `Enhanced` security levels.
//!
//! A member's pad normally travels by QR code, in person (`Maximum`). This
//! crate moves it instead over an untrusted channel: the relay server
//! (`Standard`) or a short-range radio link (`Enhanced`).
//!
//! - [`xwing`]: hybrid key exchange, ML-KEM-768 + X25519, so the transfer
//!   key stays safe if either is broken.
//! - [`session`]: the transfer protocol, with six words people compare to
//!   detect an attacker in the middle, and ChaCha20-Poly1305 for the pad.
//! - [`framing`]: splitting protocol messages into packets small enough for
//!   Bluetooth LE.
//!
//! A pad moved this way is only as strong as this cryptography, which is why
//! it is recorded as `Standard` or `Enhanced`, never `Maximum`. This crate is
//! separate from `ash-core` so that the core keeps no computational
//! cryptography and no dependencies.
//!
//! # Constraints
//!
//! Like the core, this crate performs no I/O and never reads OS randomness:
//! callers provide random bytes from a secure source.

pub mod error;
pub mod framing;
pub mod session;
pub mod xwing;

pub use error::{Error, Result};
pub use session::{
    NonceMessage, Offer, Receiver, ReceiverAwaitingReveal, ReceiverVerified, Response, Reveal,
    SealedPad, Sender, SenderAwaitingNonce, SenderVerified,
};
