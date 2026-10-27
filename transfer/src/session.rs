//! Pad transfer protocol with short authentication string (SAS) check.
//!
//! The pad owner (sender) hands a copy of their pad to another member
//! (receiver) over an untrusted channel: the relay for `Standard`, a
//! short-range radio link for `Enhanced`.
//!
//! ```text
//! Receiver                                   Sender
//!    │ Offer: X-Wing public key                 │
//!    │ ───────────────────────────────────────► │ encapsulate
//!    │ Response: ciphertext, commitment to n_S  │
//!    │ ◄─────────────────────────────────────── │
//!    │ Nonce: n_R                               │
//!    │ ───────────────────────────────────────► │
//!    │ Reveal: n_S                              │
//!    │ ◄─────────────────────────────────────── │
//! check commitment                              │
//!    │        both show the same 6 words        │
//!    │      people compare them, then confirm   │
//!    │ SealedPad: pad encrypted under the key   │
//!    │ ◄─────────────────────────────────────── │
//! ```
//!
//! # Why the words and the commitment
//!
//! Key exchange alone does not stop an active attacker in the middle, who can
//! run one exchange with each side. The words are derived from the whole
//! transcript, so each side sees different words in that case. The sender
//! commits to `n_S` before seeing `n_R`, and the receiver picks `n_R` after
//! receiving everything else, so an attacker cannot search for a transcript
//! that gives matching words: it has one chance in 2^54 per attempt.
//!
//! The pad must only be sealed or opened after people confirm the words
//! match; the types enforce that the exchange is complete, the application
//! must ask the people.

use ash_core::group::SecurityLevel;
use ash_core::mnemonic;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::error::{Error, Result};
use crate::xwing::{self, DecapsulationKey, CIPHERTEXT_SIZE, PUBLIC_KEY_SIZE};

/// Protocol version carried in every message.
pub const PROTOCOL_VERSION: u8 = 1;
/// Size of the random nonces each side contributes.
pub const NONCE_SIZE: usize = 32;
/// Largest pad accepted in a `SealedPad`.
pub const MAX_PAD_SIZE: usize = 16 * 1024 * 1024;
/// Number of words people compare.
pub const SAS_WORD_COUNT: usize = 6;

const SAS_SIZE: usize = 7; // 56 bits, of which 6 words × 9 bits are shown
const TAG_SIZE: usize = 16;
const DOMAIN: &[u8] = b"gwardian-pad-transfer-v1";

const TAG_OFFER: u8 = 1;
const TAG_RESPONSE: u8 = 2;
const TAG_NONCE: u8 = 3;
const TAG_REVEAL: u8 = 4;
const TAG_SEALED_PAD: u8 = 5;

fn header(tag: u8) -> [u8; 2] {
    [tag, PROTOCOL_VERSION]
}

fn body(bytes: &[u8], tag: u8) -> Result<&[u8]> {
    match bytes {
        [t, v, rest @ ..] if *t == tag && *v == PROTOCOL_VERSION => Ok(rest),
        [t, ..] if *t != tag => Err(Error::Malformed {
            reason: "unexpected message type",
        }),
        [_, _, ..] => Err(Error::Malformed {
            reason: "unsupported protocol version",
        }),
        _ => Err(Error::Malformed {
            reason: "message too short",
        }),
    }
}

fn fixed<const N: usize>(bytes: &[u8]) -> Result<[u8; N]> {
    bytes.try_into().map_err(|_| Error::Malformed {
        reason: "wrong message length",
    })
}

fn sha3(parts: &[&[u8]]) -> [u8; 32] {
    libcrux_sha3::sha256(&parts.concat())
}

/// First message, receiver to sender: the receiver's X-Wing public key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    public_key: [u8; PUBLIC_KEY_SIZE],
}

/// Second message: X-Wing ciphertext and commitment to the sender's nonce.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    ciphertext: [u8; CIPHERTEXT_SIZE],
    commitment: [u8; 32],
}

/// Third message: the receiver's nonce.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NonceMessage {
    nonce: [u8; NONCE_SIZE],
}

/// Fourth message: the sender's nonce, opening the commitment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reveal {
    nonce: [u8; NONCE_SIZE],
}

/// Last message: the pad and its security level, encrypted and authenticated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SealedPad {
    level: u8,
    ciphertext: Vec<u8>,
}

impl Offer {
    /// Encode for transmission.
    pub fn encode(&self) -> Vec<u8> {
        [&header(TAG_OFFER)[..], &self.public_key].concat()
    }

    /// Decode a received message.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        Ok(Self {
            public_key: fixed(body(bytes, TAG_OFFER)?)?,
        })
    }
}

impl Response {
    /// Encode for transmission.
    pub fn encode(&self) -> Vec<u8> {
        [
            &header(TAG_RESPONSE)[..],
            &self.ciphertext,
            &self.commitment,
        ]
        .concat()
    }

    /// Decode a received message.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let body: [u8; CIPHERTEXT_SIZE + 32] = fixed(body(bytes, TAG_RESPONSE)?)?;
        Ok(Self {
            ciphertext: fixed(&body[..CIPHERTEXT_SIZE])?,
            commitment: fixed(&body[CIPHERTEXT_SIZE..])?,
        })
    }
}

impl NonceMessage {
    /// Encode for transmission.
    pub fn encode(&self) -> Vec<u8> {
        [&header(TAG_NONCE)[..], &self.nonce].concat()
    }

    /// Decode a received message.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        Ok(Self {
            nonce: fixed(body(bytes, TAG_NONCE)?)?,
        })
    }
}

impl Reveal {
    /// Encode for transmission.
    pub fn encode(&self) -> Vec<u8> {
        [&header(TAG_REVEAL)[..], &self.nonce].concat()
    }

    /// Decode a received message.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        Ok(Self {
            nonce: fixed(body(bytes, TAG_REVEAL)?)?,
        })
    }
}

impl SealedPad {
    /// Encode for transmission.
    pub fn encode(&self) -> Vec<u8> {
        [&header(TAG_SEALED_PAD)[..], &[self.level], &self.ciphertext].concat()
    }

    /// Decode a received message.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        match body(bytes, TAG_SEALED_PAD)? {
            [level, ciphertext @ ..] if ciphertext.len() >= TAG_SIZE => {
                if ciphertext.len() > MAX_PAD_SIZE + TAG_SIZE {
                    return Err(Error::Malformed {
                        reason: "pad too large",
                    });
                }
                Ok(Self {
                    level: *level,
                    ciphertext: ciphertext.to_vec(),
                })
            }
            _ => Err(Error::Malformed {
                reason: "message too short",
            }),
        }
    }
}

fn commitment(public_key: &[u8], ciphertext: &[u8], nonce_s: &[u8; NONCE_SIZE]) -> [u8; 32] {
    sha3(&[DOMAIN, b" commit", public_key, ciphertext, nonce_s])
}

/// Key and words derived once both nonces are known.
struct Verified {
    key: Zeroizing<[u8; 32]>,
    sas: [u8; SAS_SIZE],
    transcript: [u8; 32],
}

fn verify(
    shared_secret: &[u8; 32],
    public_key: &[u8],
    ciphertext: &[u8],
    nonce_r: &[u8; NONCE_SIZE],
    nonce_s: &[u8; NONCE_SIZE],
) -> Verified {
    let transcript = sha3(&[DOMAIN, public_key, ciphertext, nonce_r, nonce_s]);
    let hkdf = Hkdf::<Sha256>::new(Some(&transcript), shared_secret);
    let mut key = Zeroizing::new([0u8; 32]);
    let mut sas = [0u8; SAS_SIZE];
    hkdf.expand(b"gwardian-pad-transfer-v1 key", &mut key[..])
        .expect("32 bytes is a valid HKDF-SHA256 length");
    hkdf.expand(b"gwardian-pad-transfer-v1 sas", &mut sas)
        .expect("7 bytes is a valid HKDF-SHA256 length");
    Verified {
        key,
        sas,
        transcript,
    }
}

impl Verified {
    fn words(&self) -> Vec<&'static str> {
        mnemonic::generate(&self.sas, SAS_WORD_COUNT)
    }

    fn cipher(&self) -> ChaCha20Poly1305 {
        ChaCha20Poly1305::new(&(*self.key).into())
    }

    fn aad(&self, level: u8) -> Vec<u8> {
        [DOMAIN, b" pad", &[level], &self.transcript].concat()
    }
}

/// Receiver, step 1: waiting for the sender's response.
pub struct Receiver {
    key: DecapsulationKey,
    public_key: [u8; PUBLIC_KEY_SIZE],
}

/// Receiver, step 2: waiting for the sender to reveal their nonce.
pub struct ReceiverAwaitingReveal {
    shared_secret: Zeroizing<[u8; 32]>,
    public_key: [u8; PUBLIC_KEY_SIZE],
    response: Response,
    nonce_r: [u8; NONCE_SIZE],
}

/// Receiver, exchange complete: show the words, then open the pad.
pub struct ReceiverVerified(Verified);

impl Receiver {
    /// Start a transfer with 32 random bytes; send the returned offer.
    pub fn start(seed: [u8; xwing::SEED_SIZE]) -> (Self, Offer) {
        let (key, public_key) = xwing::generate_key_pair(seed);
        (Self { key, public_key }, Offer { public_key })
    }

    /// Handle the response with 32 fresh random bytes; send the returned nonce.
    pub fn on_response(
        self,
        response: Response,
        nonce: [u8; NONCE_SIZE],
    ) -> (ReceiverAwaitingReveal, NonceMessage) {
        let shared_secret = self.key.decapsulate(&response.ciphertext);
        (
            ReceiverAwaitingReveal {
                shared_secret,
                public_key: self.public_key,
                response,
                nonce_r: nonce,
            },
            NonceMessage { nonce },
        )
    }
}

impl ReceiverAwaitingReveal {
    /// Check the sender's nonce against their commitment.
    ///
    /// # Errors
    ///
    /// `CommitmentMismatch` if the exchange was tampered with.
    pub fn on_reveal(self, reveal: &Reveal) -> Result<ReceiverVerified> {
        let expected = commitment(&self.public_key, &self.response.ciphertext, &reveal.nonce);
        if expected != self.response.commitment {
            return Err(Error::CommitmentMismatch);
        }
        Ok(ReceiverVerified(verify(
            &self.shared_secret,
            &self.public_key,
            &self.response.ciphertext,
            &self.nonce_r,
            &reveal.nonce,
        )))
    }
}

impl ReceiverVerified {
    /// Words to compare with the sender's, aloud or over a call.
    pub fn words(&self) -> Vec<&'static str> {
        self.0.words()
    }

    /// Decrypt the pad, once people have confirmed the words match.
    ///
    /// # Errors
    ///
    /// - `DecryptionFailed` if the pad was altered or the keys differ.
    /// - `LevelNotAllowed` if the authenticated level is not `Standard` or
    ///   `Enhanced`.
    pub fn open_pad(self, sealed: &SealedPad) -> Result<(Zeroizing<Vec<u8>>, SecurityLevel)> {
        let pad = self
            .0
            .cipher()
            .decrypt(
                &Nonce::default(),
                Payload {
                    msg: &sealed.ciphertext,
                    aad: &self.0.aad(sealed.level),
                },
            )
            .map_err(|_| Error::DecryptionFailed)?;
        let pad = Zeroizing::new(pad);
        match SecurityLevel::from_byte(sealed.level) {
            Some(level @ (SecurityLevel::Standard | SecurityLevel::Enhanced)) => Ok((pad, level)),
            _ => Err(Error::LevelNotAllowed),
        }
    }
}

/// Sender, step 1: waiting for the receiver's nonce.
pub struct SenderAwaitingNonce {
    shared_secret: Zeroizing<[u8; 32]>,
    public_key: [u8; PUBLIC_KEY_SIZE],
    ciphertext: [u8; CIPHERTEXT_SIZE],
    nonce_s: [u8; NONCE_SIZE],
}

/// Sender, exchange complete: show the words, then seal the pad.
pub struct SenderVerified(Verified);

/// Sender side of a transfer.
pub struct Sender;

impl Sender {
    /// Answer an offer with 64 random bytes for encapsulation and 32 for the
    /// nonce; send the returned response.
    ///
    /// # Errors
    ///
    /// `InvalidPublicKey` if the offered key is malformed.
    pub fn on_offer(
        offer: &Offer,
        encapsulation_seed: [u8; xwing::ENCAPSULATION_SEED_SIZE],
        nonce: [u8; NONCE_SIZE],
    ) -> Result<(SenderAwaitingNonce, Response)> {
        let (shared_secret, ciphertext) =
            xwing::encapsulate(&offer.public_key, encapsulation_seed)?;
        let response = Response {
            ciphertext,
            commitment: commitment(&offer.public_key, &ciphertext, &nonce),
        };
        Ok((
            SenderAwaitingNonce {
                shared_secret,
                public_key: offer.public_key,
                ciphertext,
                nonce_s: nonce,
            },
            response,
        ))
    }
}

impl SenderAwaitingNonce {
    /// Handle the receiver's nonce; send the returned reveal.
    pub fn on_nonce(self, nonce: &NonceMessage) -> (SenderVerified, Reveal) {
        let verified = verify(
            &self.shared_secret,
            &self.public_key,
            &self.ciphertext,
            &nonce.nonce,
            &self.nonce_s,
        );
        (
            SenderVerified(verified),
            Reveal {
                nonce: self.nonce_s,
            },
        )
    }
}

impl SenderVerified {
    /// Words to compare with the receiver's, aloud or over a call.
    pub fn words(&self) -> Vec<&'static str> {
        self.0.words()
    }

    /// Encrypt the pad, once people have confirmed the words match.
    ///
    /// # Errors
    ///
    /// - `LevelNotAllowed` for a `Maximum` pad, which must go by QR code.
    /// - `Malformed` if the pad exceeds `MAX_PAD_SIZE`.
    pub fn seal_pad(self, pad: &[u8], level: SecurityLevel) -> Result<SealedPad> {
        if level == SecurityLevel::Maximum {
            return Err(Error::LevelNotAllowed);
        }
        if pad.len() > MAX_PAD_SIZE {
            return Err(Error::Malformed {
                reason: "pad too large",
            });
        }
        let level = level.to_byte();
        let ciphertext = self
            .0
            .cipher()
            .encrypt(
                &Nonce::default(),
                Payload {
                    msg: pad,
                    aad: &self.0.aad(level),
                },
            )
            .expect("ChaCha20-Poly1305 accepts any pad up to MAX_PAD_SIZE");
        Ok(SealedPad { level, ciphertext })
    }
}
