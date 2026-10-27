//! End-to-end pad transfer, including an attacker in the middle.

use ash_core::group::SecurityLevel;
use ash_transfer::{
    Error, NonceMessage, Offer, Receiver, ReceiverVerified, Response, Reveal, SealedPad, Sender,
    SenderVerified,
};

/// Each message goes through encode/decode, as over a real channel.
fn wire<T>(encode: Vec<u8>, decode: fn(&[u8]) -> ash_transfer::Result<T>) -> T {
    decode(&encode).unwrap()
}

fn exchange(seed: u8) -> (ReceiverVerified, SenderVerified) {
    let (receiver, offer) = Receiver::start([seed; 32]);
    let offer = wire(offer.encode(), Offer::decode);

    let (sender, response) = Sender::on_offer(&offer, [seed + 1; 64], [seed + 2; 32]).unwrap();
    let response = wire(response.encode(), Response::decode);

    let (receiver, nonce) = receiver.on_response(response, [seed + 3; 32]);
    let nonce = wire(nonce.encode(), NonceMessage::decode);

    let (sender, reveal) = sender.on_nonce(&nonce);
    let reveal = wire(reveal.encode(), Reveal::decode);

    (receiver.on_reveal(&reveal).unwrap(), sender)
}

#[test]
fn pad_transfer_roundtrip() {
    let (receiver, sender) = exchange(10);
    assert_eq!(receiver.words(), sender.words());
    assert_eq!(receiver.words().len(), 6);

    let pad: Vec<u8> = (0..100_000u32).map(|i| (i * 7) as u8).collect();
    let sealed = sender.seal_pad(&pad, SecurityLevel::Enhanced).unwrap();
    let sealed = wire(sealed.encode(), SealedPad::decode);

    let (received, level) = receiver.open_pad(&sealed).unwrap();
    assert_eq!(*received, pad);
    assert_eq!(level, SecurityLevel::Enhanced);
}

#[test]
fn different_sessions_give_different_words() {
    let (a, _) = exchange(10);
    let (b, _) = exchange(20);
    assert_ne!(a.words(), b.words());
}

#[test]
fn attacker_in_the_middle_is_detected() {
    // The receiver talks to the attacker, who talks to the sender
    let (receiver, offer) = Receiver::start([1; 32]);
    let (attacker_as_sender, response_to_receiver) =
        Sender::on_offer(&offer, [66; 64], [67; 32]).unwrap();
    let (attacker_as_receiver, offer_to_sender) = Receiver::start([68; 32]);
    let (sender, response) = Sender::on_offer(&offer_to_sender, [2; 64], [3; 32]).unwrap();

    let (receiver, nonce) = receiver.on_response(response_to_receiver, [4; 32]);
    let (attacker_as_receiver, nonce_to_sender) =
        attacker_as_receiver.on_response(response, [69; 32]);
    let (sender, reveal) = sender.on_nonce(&nonce_to_sender);
    let (attacker_as_sender, reveal_to_receiver) = attacker_as_sender.on_nonce(&nonce);

    let receiver = receiver.on_reveal(&reveal_to_receiver).unwrap();
    let attacker_as_receiver = attacker_as_receiver.on_reveal(&reveal).unwrap();

    // Each leg is a valid exchange, but people see different words
    assert_eq!(receiver.words(), attacker_as_sender.words());
    assert_eq!(sender.words(), attacker_as_receiver.words());
    assert_ne!(receiver.words(), sender.words());

    // A pad sealed by the real sender cannot be opened by the receiver
    let sealed = sender.seal_pad(&[9; 64], SecurityLevel::Standard).unwrap();
    assert_eq!(
        receiver.open_pad(&sealed).unwrap_err(),
        Error::DecryptionFailed
    );
}

#[test]
fn altered_reveal_breaks_commitment() {
    let (receiver, offer) = Receiver::start([5; 32]);
    let (sender, response) = Sender::on_offer(&offer, [6; 64], [7; 32]).unwrap();
    let (receiver, nonce) = receiver.on_response(response, [8; 32]);
    let (_, reveal) = sender.on_nonce(&nonce);

    let mut bytes = reveal.encode();
    bytes[2] ^= 1;
    let altered = Reveal::decode(&bytes).unwrap();
    assert_eq!(
        receiver.on_reveal(&altered).err(),
        Some(Error::CommitmentMismatch)
    );
}

#[test]
fn altered_sealed_pad_rejected() {
    let (receiver, sender) = exchange(30);
    let sealed = sender.seal_pad(&[1; 256], SecurityLevel::Standard).unwrap();
    let mut bytes = sealed.encode();
    let last = bytes.len() - 1;
    bytes[last] ^= 1;
    let altered = SealedPad::decode(&bytes).unwrap();
    assert_eq!(
        receiver.open_pad(&altered).unwrap_err(),
        Error::DecryptionFailed
    );
}

#[test]
fn level_is_authenticated() {
    let (receiver, sender) = exchange(40);
    let sealed = sender.seal_pad(&[1; 256], SecurityLevel::Standard).unwrap();
    // Claim the pad was exchanged at Enhanced level
    let mut bytes = sealed.encode();
    bytes[2] = SecurityLevel::Enhanced.to_byte();
    let upgraded = SealedPad::decode(&bytes).unwrap();
    assert_eq!(
        receiver.open_pad(&upgraded).unwrap_err(),
        Error::DecryptionFailed
    );
}

#[test]
fn maximum_level_not_allowed() {
    let (_, sender) = exchange(50);
    assert_eq!(
        sender
            .seal_pad(&[1; 32], SecurityLevel::Maximum)
            .unwrap_err(),
        Error::LevelNotAllowed
    );
}

#[test]
fn malformed_messages_rejected() {
    let (_, offer) = Receiver::start([1; 32]);
    let bytes = offer.encode();

    assert!(matches!(
        Offer::decode(&bytes[..10]),
        Err(Error::Malformed { .. })
    ));
    assert!(matches!(Offer::decode(&[]), Err(Error::Malformed { .. })));
    assert!(matches!(
        Response::decode(&bytes),
        Err(Error::Malformed { .. })
    ));

    let mut wrong_version = bytes.clone();
    wrong_version[1] = 99;
    assert!(matches!(
        Offer::decode(&wrong_version),
        Err(Error::Malformed { .. })
    ));

    assert!(matches!(
        SealedPad::decode(&[5, 1, 1]),
        Err(Error::Malformed { .. })
    ));
}
