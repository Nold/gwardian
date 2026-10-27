//! Official X-Wing test vectors from draft-connolly-cfrg-xwing-kem
//! (spec/test-vectors.json in github.com/dconnolly/draft-connolly-cfrg-xwing-kem).

use ash_transfer::xwing;

fn bytes<const N: usize>(vector: &serde_json::Value, field: &str) -> [u8; N] {
    let hex = vector[field].as_str().expect("field is a hex string");
    hex::decode(hex)
        .expect("valid hex")
        .try_into()
        .unwrap_or_else(|v: Vec<u8>| panic!("{field}: expected {N} bytes, got {}", v.len()))
}

#[test]
fn official_vectors() {
    let vectors: serde_json::Value =
        serde_json::from_str(include_str!("xwing-vectors.json")).expect("valid JSON");
    let vectors = vectors.as_array().expect("array of vectors");
    assert_eq!(vectors.len(), 3);

    for vector in vectors {
        let seed = bytes::<{ xwing::SEED_SIZE }>(vector, "seed");
        assert_eq!(seed, bytes::<{ xwing::SEED_SIZE }>(vector, "sk"));

        let (key, pk) = xwing::generate_key_pair(seed);
        assert_eq!(pk, bytes::<{ xwing::PUBLIC_KEY_SIZE }>(vector, "pk"));

        let (ss, ct) = xwing::encapsulate(&pk, bytes(vector, "eseed")).unwrap();
        assert_eq!(ct, bytes::<{ xwing::CIPHERTEXT_SIZE }>(vector, "ct"));
        assert_eq!(*ss, bytes::<{ xwing::SHARED_SECRET_SIZE }>(vector, "ss"));

        assert_eq!(*key.decapsulate(&ct), *ss);
    }
}

#[test]
fn invalid_public_key_rejected() {
    // Coefficients of 0xFFF exceed the ML-KEM modulus
    let pk = [0xFFu8; xwing::PUBLIC_KEY_SIZE];
    assert_eq!(
        xwing::encapsulate(&pk, [7; 64]).unwrap_err(),
        ash_transfer::Error::InvalidPublicKey
    );
}

#[test]
fn tampered_ciphertext_gives_unrelated_secret() {
    let (key, pk) = xwing::generate_key_pair([1; 32]);
    let (ss, mut ct) = xwing::encapsulate(&pk, [2; 64]).unwrap();
    ct[0] ^= 1;
    assert_ne!(*key.decapsulate(&ct), *ss);
}
