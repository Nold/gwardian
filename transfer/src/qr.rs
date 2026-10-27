//! Encryption of the ceremony QR codes with a spoken passphrase.
//!
//! The QR ceremony (`Maximum`) shows the pad on screen. Anyone who films the
//! screen gets the frames; this layer makes them useless without the
//! passphrase the two people say aloud.
//!
//! - The sender's app draws six words from the core word list (512 words,
//!   54 bits). People never choose it, so it is never weak.
//! - Argon2id (19 MiB, 2 passes) turns the words and a random per-ceremony
//!   salt into a key, making every guess of an offline attacker costly.
//! - Each frame is sealed with ChaCha20-Poly1305; the nonce is the frame
//!   index, which is unique within a ceremony and repeats only for the very
//!   same frame. The salt travels in every frame, since the receiver may
//!   start scanning anywhere.
//!
//! Sealed frame: `[version: u8][salt: 16][index: u32 BE][ciphertext][tag: 16]`
//!
//! This protects the transfer against observation; it does not replace
//! doing the ceremony out of sight. The pad itself stays a one-time pad.

use argon2::{Algorithm, Argon2, Params, Version};
use ash_core::wordlist::WORDLIST;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use zeroize::Zeroizing;

use crate::error::{Error, Result};

/// Words in a QR passphrase.
pub const PASSPHRASE_WORDS: usize = 6;
/// Random bytes needed by [`generate_passphrase`]: two per word.
pub const PASSPHRASE_RANDOM_BYTES: usize = 2 * PASSPHRASE_WORDS;
/// Bytes of salt carried in every sealed frame.
pub const SALT_SIZE: usize = 16;

const VERSION: u8 = 1;
const HEADER_SIZE: usize = 1 + SALT_SIZE + 4;
const TAG_SIZE: usize = 16;
/// OWASP's first recommended Argon2id setting, light enough for any phone.
const ARGON2_MEMORY_KIB: u32 = 19 * 1024;
const ARGON2_PASSES: u32 = 2;

/// Draw a passphrase from [`PASSPHRASE_RANDOM_BYTES`] secure random bytes.
///
/// # Errors
///
/// Returns [`Error::Malformed`] if `random` has the wrong length.
pub fn generate_passphrase(random: &[u8]) -> Result<Vec<String>> {
    if random.len() != PASSPHRASE_RANDOM_BYTES {
        return Err(Error::Malformed {
            reason: "passphrase randomness",
        });
    }
    // 65536 is a multiple of 512, so the modulo is unbiased
    Ok(random
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            WORDLIST[usize::from(u16::from_be_bytes([pair[0], pair[1]])) % WORDLIST.len()]
                .to_string()
        })
        .collect())
}

/// Canonical form of a typed passphrase: six known words, lowercase, one
/// space apart. Spaces, hyphens, dots and commas all separate words.
///
/// # Errors
///
/// Returns [`Error::InvalidPassphrase`] if it is not six known words.
pub fn normalize_passphrase(input: &str) -> Result<String> {
    let words: Vec<String> = input
        .split(|c: char| c.is_whitespace() || matches!(c, '-' | '.' | ',' | '·'))
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .collect();
    if words.len() != PASSPHRASE_WORDS
        || !words.iter().all(|word| WORDLIST.contains(&word.as_str()))
    {
        return Err(Error::InvalidPassphrase);
    }
    Ok(words.join(" "))
}

/// The key sealing one ceremony's frames.
pub struct FrameKey {
    cipher: ChaCha20Poly1305,
    salt: [u8; SALT_SIZE],
}

impl FrameKey {
    /// Derive the key from a passphrase (any accepted spelling) and the salt.
    ///
    /// Deliberately slow (Argon2id): derive once per ceremony and reuse.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidPassphrase`] if the passphrase is not valid.
    pub fn derive(passphrase: &str, salt: [u8; SALT_SIZE]) -> Result<Self> {
        let passphrase = Zeroizing::new(normalize_passphrase(passphrase)?);
        let params = Params::new(ARGON2_MEMORY_KIB, ARGON2_PASSES, 1, Some(32)).map_err(|_| {
            Error::Malformed {
                reason: "argon2 parameters",
            }
        })?;
        let mut key = Zeroizing::new([0u8; 32]);
        Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
            .hash_password_into(passphrase.as_bytes(), &salt, key.as_mut())
            .map_err(|_| Error::Malformed { reason: "argon2" })?;
        Ok(Self {
            cipher: ChaCha20Poly1305::new(&Key::from(*key)),
            salt,
        })
    }

    /// Salt this key was derived with.
    pub fn salt(&self) -> [u8; SALT_SIZE] {
        self.salt
    }

    /// Seal frame number `index`.
    pub fn seal(&self, index: u32, frame: &[u8]) -> Vec<u8> {
        let header = self.header(index);
        let ciphertext = self
            .cipher
            .encrypt(
                &nonce(index),
                Payload {
                    msg: frame,
                    aad: &header,
                },
            )
            .expect("ChaCha20-Poly1305 encryption cannot fail for frame-sized input");
        let mut sealed = header;
        sealed.extend_from_slice(&ciphertext);
        sealed
    }

    /// Open a sealed frame made with this key.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Malformed`] for a frame that is not a sealed frame,
    /// [`Error::FrameAuthenticationFailed`] for another salt, a wrong
    /// passphrase or an altered frame.
    pub fn open(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        let salt = frame_salt(sealed)?;
        if salt != self.salt {
            return Err(Error::FrameAuthenticationFailed);
        }
        let index = u32::from_be_bytes(
            sealed[1 + SALT_SIZE..HEADER_SIZE]
                .try_into()
                .expect("4 bytes"),
        );
        self.cipher
            .decrypt(
                &nonce(index),
                Payload {
                    msg: &sealed[HEADER_SIZE..],
                    aad: &sealed[..HEADER_SIZE],
                },
            )
            .map_err(|_| Error::FrameAuthenticationFailed)
    }

    fn header(&self, index: u32) -> Vec<u8> {
        let mut header = Vec::with_capacity(HEADER_SIZE);
        header.push(VERSION);
        header.extend_from_slice(&self.salt);
        header.extend_from_slice(&index.to_be_bytes());
        header
    }
}

/// Salt of a sealed frame, read before the key exists.
///
/// # Errors
///
/// Returns [`Error::Malformed`] if `sealed` is not a sealed frame.
pub fn frame_salt(sealed: &[u8]) -> Result<[u8; SALT_SIZE]> {
    if sealed.len() < HEADER_SIZE + TAG_SIZE || sealed[0] != VERSION {
        return Err(Error::Malformed {
            reason: "sealed QR frame",
        });
    }
    Ok(sealed[1..1 + SALT_SIZE].try_into().expect("salt size"))
}

fn nonce(index: u32) -> Nonce {
    let mut nonce = [0u8; 12];
    nonce[8..].copy_from_slice(&index.to_be_bytes());
    Nonce::from(nonce)
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORDS: &str = "able acid aged also area army";

    #[test]
    fn generated_passphrases_are_six_known_words() {
        let words = generate_passphrase(&[0xAB; PASSPHRASE_RANDOM_BYTES]).unwrap();
        assert_eq!(words.len(), PASSPHRASE_WORDS);
        assert!(normalize_passphrase(&words.join(" ")).is_ok());
        assert_eq!(
            generate_passphrase(&[0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0]).unwrap()[..3],
            ["able", "acid", "able"]
        );
        assert!(generate_passphrase(&[0; 3]).is_err());
    }

    #[test]
    fn typed_passphrases_are_normalized() {
        assert_eq!(
            normalize_passphrase("  Able-ACID aged, also.area · army ").unwrap(),
            WORDS
        );
        assert!(normalize_passphrase("able acid aged also area").is_err());
        assert!(normalize_passphrase("able acid aged also area zzzz").is_err());
        assert!(normalize_passphrase("able acid aged also area army able").is_err());
    }

    #[test]
    fn frames_round_trip_with_the_same_passphrase() {
        let sender = FrameKey::derive(WORDS, [7; SALT_SIZE]).unwrap();
        let sealed = sender.seal(42, b"fountain frame");
        let salt = frame_salt(&sealed).unwrap();
        let receiver = FrameKey::derive("ABLE acid aged also area army", salt).unwrap();
        assert_eq!(receiver.open(&sealed).unwrap(), b"fountain frame");
    }

    #[test]
    fn wrong_passphrase_or_tampering_is_rejected() {
        let sender = FrameKey::derive(WORDS, [7; SALT_SIZE]).unwrap();
        let sealed = sender.seal(1, b"fountain frame");

        let wrong = FrameKey::derive("able acid aged also area back", [7; SALT_SIZE]).unwrap();
        assert_eq!(wrong.open(&sealed), Err(Error::FrameAuthenticationFailed));

        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert_eq!(
            sender.open(&tampered),
            Err(Error::FrameAuthenticationFailed)
        );

        // The index is authenticated: moving a frame breaks it
        let mut moved = sealed.clone();
        moved[1 + SALT_SIZE + 3] ^= 1;
        assert_eq!(sender.open(&moved), Err(Error::FrameAuthenticationFailed));

        let other_ceremony = FrameKey::derive(WORDS, [8; SALT_SIZE]).unwrap();
        assert_eq!(
            other_ceremony.open(&sealed),
            Err(Error::FrameAuthenticationFailed)
        );

        assert!(frame_salt(b"short").is_err());
    }
}
