//! X-Wing hybrid KEM: ML-KEM-768 combined with X25519.
//!
//! Follows draft-connolly-cfrg-xwing-kem (revision of 2026-09-23) exactly and
//! is checked against its official test vectors. A shared secret stays safe
//! as long as either ML-KEM-768 or X25519 is unbroken.
//!
//! ```text
//! seed (32) ──SHAKE256──► d‖z (64) ──► ML-KEM-768 key pair
//!                       └► sk_X (32) ──► pk_X = X25519(sk_X, base)
//!
//! public key  = pk_M (1184) ‖ pk_X (32)
//! ciphertext  = ct_M (1088) ‖ ct_X (32)
//! shared secret = SHA3-256(ss_M ‖ ss_X ‖ ct_X ‖ pk_X ‖ "\.//^\")
//! ```
//!
//! Like the rest of the project, callers provide all randomness.

use libcrux_ml_kem::mlkem768::{self, MlKem768Ciphertext, MlKem768KeyPair, MlKem768PublicKey};
use x25519_dalek::{x25519, X25519_BASEPOINT_BYTES};
use zeroize::{Zeroize, Zeroizing};

use crate::error::{Error, Result};

/// Decapsulation key seed size.
pub const SEED_SIZE: usize = 32;
/// Encapsulation randomness size.
pub const ENCAPSULATION_SEED_SIZE: usize = 64;
/// Encapsulation key size.
pub const PUBLIC_KEY_SIZE: usize = 1216;
/// Ciphertext size.
pub const CIPHERTEXT_SIZE: usize = 1120;
/// Shared secret size.
pub const SHARED_SECRET_SIZE: usize = 32;

const ML_KEM_PUBLIC_KEY_SIZE: usize = 1184;
const ML_KEM_CIPHERTEXT_SIZE: usize = 1088;

/// `\.//^\`
const LABEL: [u8; 6] = [0x5c, 0x2e, 0x2f, 0x2f, 0x5e, 0x5c];

/// X-Wing decapsulation key, stored as its 32-byte seed as the draft
/// recommends; the component keys are re-derived when needed.
pub struct DecapsulationKey {
    seed: Zeroizing<[u8; SEED_SIZE]>,
}

/// Component keys expanded from a seed.
struct Expanded {
    ml_kem: MlKem768KeyPair,
    sk_x: Zeroizing<[u8; 32]>,
    pk_x: [u8; 32],
}

fn expand(seed: &[u8; SEED_SIZE]) -> Expanded {
    let mut expanded: [u8; 96] = libcrux_sha3::shake256(seed);
    let mut d_z = [0u8; 64];
    d_z.copy_from_slice(&expanded[..64]);
    let ml_kem = mlkem768::generate_key_pair(d_z);
    d_z.zeroize();
    let mut sk_x = Zeroizing::new([0u8; 32]);
    sk_x.copy_from_slice(&expanded[64..]);
    expanded.zeroize();
    let pk_x = x25519(*sk_x, X25519_BASEPOINT_BYTES);
    Expanded { ml_kem, sk_x, pk_x }
}

fn combiner(ss_m: &[u8; 32], ss_x: &[u8; 32], ct_x: &[u8; 32], pk_x: &[u8; 32]) -> [u8; 32] {
    let mut input = Zeroizing::new([0u8; 32 * 4 + LABEL.len()]);
    input[..32].copy_from_slice(ss_m);
    input[32..64].copy_from_slice(ss_x);
    input[64..96].copy_from_slice(ct_x);
    input[96..128].copy_from_slice(pk_x);
    input[128..].copy_from_slice(&LABEL);
    libcrux_sha3::sha256(&input[..])
}

/// Derive a key pair from a 32-byte random seed.
pub fn generate_key_pair(seed: [u8; SEED_SIZE]) -> (DecapsulationKey, [u8; PUBLIC_KEY_SIZE]) {
    let seed = Zeroizing::new(seed);
    let expanded = expand(&seed);
    let mut pk = [0u8; PUBLIC_KEY_SIZE];
    pk[..ML_KEM_PUBLIC_KEY_SIZE].copy_from_slice(expanded.ml_kem.pk());
    pk[ML_KEM_PUBLIC_KEY_SIZE..].copy_from_slice(&expanded.pk_x);
    (DecapsulationKey { seed }, pk)
}

/// Encapsulate a fresh shared secret to `pk` using 64 bytes of randomness.
///
/// # Errors
///
/// `InvalidPublicKey` if the ML-KEM half fails the FIPS 203 modulus check.
pub fn encapsulate(
    pk: &[u8; PUBLIC_KEY_SIZE],
    eseed: [u8; ENCAPSULATION_SEED_SIZE],
) -> Result<(Zeroizing<[u8; SHARED_SECRET_SIZE]>, [u8; CIPHERTEXT_SIZE])> {
    let eseed = Zeroizing::new(eseed);
    let mut pk_m_bytes = [0u8; ML_KEM_PUBLIC_KEY_SIZE];
    pk_m_bytes.copy_from_slice(&pk[..ML_KEM_PUBLIC_KEY_SIZE]);
    let pk_m = MlKem768PublicKey::from(pk_m_bytes);
    if !mlkem768::validate_public_key(&pk_m) {
        return Err(Error::InvalidPublicKey);
    }
    let mut pk_x = [0u8; 32];
    pk_x.copy_from_slice(&pk[ML_KEM_PUBLIC_KEY_SIZE..]);

    let mut ek_x = Zeroizing::new([0u8; 32]);
    ek_x.copy_from_slice(&eseed[32..]);
    let ct_x = x25519(*ek_x, X25519_BASEPOINT_BYTES);
    let ss_x = Zeroizing::new(x25519(*ek_x, pk_x));

    let mut m = Zeroizing::new([0u8; 32]);
    m.copy_from_slice(&eseed[..32]);
    let (ct_m, ss_m) = mlkem768::encapsulate(&pk_m, *m);
    let ss_m = Zeroizing::new(ss_m);

    let mut ct = [0u8; CIPHERTEXT_SIZE];
    ct[..ML_KEM_CIPHERTEXT_SIZE].copy_from_slice(ct_m.as_slice());
    ct[ML_KEM_CIPHERTEXT_SIZE..].copy_from_slice(&ct_x);
    Ok((Zeroizing::new(combiner(&ss_m, &ss_x, &ct_x, &pk_x)), ct))
}

impl DecapsulationKey {
    /// Recover the shared secret from a ciphertext.
    ///
    /// ML-KEM uses implicit rejection: a tampered ciphertext yields an
    /// unrelated secret rather than an error, so tampering surfaces later as
    /// a mismatching key.
    pub fn decapsulate(&self, ct: &[u8; CIPHERTEXT_SIZE]) -> Zeroizing<[u8; SHARED_SECRET_SIZE]> {
        let expanded = expand(&self.seed);
        let mut ct_m = [0u8; ML_KEM_CIPHERTEXT_SIZE];
        ct_m.copy_from_slice(&ct[..ML_KEM_CIPHERTEXT_SIZE]);
        let mut ct_x = [0u8; 32];
        ct_x.copy_from_slice(&ct[ML_KEM_CIPHERTEXT_SIZE..]);

        let ss_m = Zeroizing::new(mlkem768::decapsulate(
            expanded.ml_kem.private_key(),
            &MlKem768Ciphertext::from(ct_m),
        ));
        let ss_x = Zeroizing::new(x25519(*expanded.sk_x, ct_x));
        Zeroizing::new(combiner(&ss_m, &ss_x, &ct_x, &expanded.pk_x))
    }
}
