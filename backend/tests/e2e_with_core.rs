//! End-to-end integration tests using ash-core for cryptographic operations.
//!
//! These tests verify the complete flow:
//! 1. Ceremony (pad creation, token derivation)
//! 2. Backend registration
//! 3. Message encryption, submission, polling, decryption
//! 4. Burn operations

use ash_backend::{apns, auth, build_router, config::Config, handlers::AppState, store::Store};
use ash_core::{
    auth as core_auth, frame, mnemonic, AuthKey, CeremonyMetadata, MessageFrame, MessageType, Pad,
    PadSize, Role, TransferMethod, AUTH_KEY_SIZE,
};
use axum::http::{header, StatusCode};
use axum_test::TestServer;
use serde_json::{json, Value};
use std::sync::Arc;

/// Build test server with the application router
async fn build_test_server() -> TestServer {
    let config = Config::default();
    let store = Arc::new(Store::new(config.clone()));
    let apns = apns::create_client(&config).await;
    let state = AppState::new(store, apns);

    let app = build_router(state);
    TestServer::new(app).unwrap()
}

/// Create authorization header value
fn auth_header(token: &str) -> String {
    format!("Bearer {token}")
}

/// Helper struct to hold ceremony result for both parties
struct CeremonyParty {
    pad: Pad,
    conversation_id: String,
    auth_token: String,
    burn_token: String,
}

/// Perform a complete ceremony between initiator and responder
fn perform_ceremony() -> (CeremonyParty, CeremonyParty) {
    // Create deterministic entropy for testing
    let entropy: Vec<u8> = (0..=255).cycle().take(PadSize::Small.bytes()).collect();

    // Initiator creates pad
    let initiator_pad = Pad::new(&entropy, PadSize::Small).unwrap();

    // Derive tokens from initiator's pad
    let (conversation_id, auth_token, burn_token) =
        core_auth::derive_all_tokens(initiator_pad.as_bytes()).unwrap();

    // Create ceremony frames using fountain codes
    let metadata = CeremonyMetadata::default();
    let mut generator = frame::create_fountain_ceremony(
        &metadata,
        initiator_pad.as_bytes(),
        256,
        None,
        TransferMethod::Sequential,
    )
    .unwrap();

    // Responder receives frames
    let mut receiver = frame::FountainFrameReceiver::new(None);
    while !receiver.is_complete() {
        let frame_data = generator.next_frame();
        receiver.add_frame(&frame_data).unwrap();
    }

    let result = receiver.get_result().unwrap();
    let responder_pad = Pad::from_bytes(result.pad.clone());

    // Verify mnemonics match (ceremony verification)
    let initiator_mnemonic = mnemonic::generate_default(initiator_pad.as_bytes());
    let responder_mnemonic = mnemonic::generate_default(&result.pad);
    assert_eq!(initiator_mnemonic, responder_mnemonic);

    // Verify responder derives same tokens
    let (r_conv_id, r_auth, r_burn) = core_auth::derive_all_tokens(&result.pad).unwrap();
    assert_eq!(conversation_id, r_conv_id);
    assert_eq!(auth_token, r_auth);
    assert_eq!(burn_token, r_burn);

    (
        CeremonyParty {
            pad: Pad::from_bytes(initiator_pad.as_bytes().to_vec()),
            conversation_id: conversation_id.clone(),
            auth_token: auth_token.clone(),
            burn_token: burn_token.clone(),
        },
        CeremonyParty {
            pad: responder_pad,
            conversation_id,
            auth_token,
            burn_token,
        },
    )
}

// =============================================================================
// E2E Ceremony + Registration Tests
// =============================================================================

#[tokio::test]
async fn test_e2e_ceremony_and_registration() {
    let server = build_test_server().await;
    let (initiator, _responder) = perform_ceremony();

    // Register conversation with backend using derived tokens
    let response = server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["success"], true);
}

#[tokio::test]
async fn test_e2e_both_parties_can_register() {
    let server = build_test_server().await;
    let (initiator, responder) = perform_ceremony();

    // Initiator registers
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // Responder registers (idempotent, same tokens derived from same pad)
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": responder.conversation_id,
            "auth_token_hash": auth::hash_token(&responder.auth_token),
            "burn_token_hash": auth::hash_token(&responder.burn_token)
        }))
        .await
        .assert_status_ok();
}

// =============================================================================
// E2E Message Exchange Tests
// =============================================================================

#[tokio::test]
async fn test_e2e_initiator_sends_responder_receives() {
    let server = build_test_server().await;
    let (mut initiator, mut responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // === Initiator encrypts and sends message ===
    let plaintext = b"Hello from initiator via OTP!";

    // Consume pad bytes for authentication and encryption
    let auth_bytes = initiator
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let auth_key = AuthKey::from_slice(&auth_bytes);
    let enc_key = initiator
        .pad
        .consume(plaintext.len(), Role::Initiator)
        .unwrap();

    // Create authenticated encrypted frame
    let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key).unwrap();
    let wire_data = frame.encode();

    // Submit to backend as base64
    let ciphertext_b64 =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &wire_data);

    let submit_response = server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "ciphertext": ciphertext_b64,
            "sequence": 1
        }))
        .await;

    submit_response.assert_status_ok();
    let blob_id = submit_response.json::<Value>()["blob_id"]
        .as_str()
        .unwrap()
        .to_string();

    // === Responder polls and decrypts ===
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            responder.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&responder.auth_token))
        .await;

    poll_response.assert_status_ok();
    let poll_body: Value = poll_response.json();
    let messages = poll_body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1);

    // Decode received ciphertext
    let received_b64 = messages[0]["ciphertext"].as_str().unwrap();
    let received_wire =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, received_b64).unwrap();

    // Responder consumes same pad positions (Initiator role = same direction)
    let resp_auth_bytes = responder
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let resp_auth_key = AuthKey::from_slice(&resp_auth_bytes);
    let resp_enc_key = responder
        .pad
        .consume(plaintext.len(), Role::Initiator)
        .unwrap();

    // Decrypt and verify
    let received_frame = MessageFrame::decode(&received_wire).unwrap();
    let decrypted = received_frame
        .decrypt(&resp_enc_key, &resp_auth_key)
        .unwrap();

    assert_eq!(decrypted, plaintext);

    // Acknowledge receipt
    let ack_response = server
        .post("/v1/messages/ack")
        .add_header(header::AUTHORIZATION, auth_header(&responder.auth_token))
        .json(&json!({
            "conversation_id": responder.conversation_id,
            "blob_ids": [blob_id]
        }))
        .await;

    ack_response.assert_status_ok();
    assert_eq!(ack_response.json::<Value>()["acknowledged"], 1);
}

#[tokio::test]
async fn test_e2e_responder_sends_initiator_receives() {
    let server = build_test_server().await;
    let (mut initiator, mut responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // === Responder encrypts and sends message (consumes from END) ===
    let plaintext = b"Hello from responder via OTP!";

    // Responder consumes from the END of the pad
    let auth_bytes = responder
        .pad
        .consume(AUTH_KEY_SIZE, Role::Responder)
        .unwrap();
    let auth_key = AuthKey::from_slice(&auth_bytes);
    let enc_key = responder
        .pad
        .consume(plaintext.len(), Role::Responder)
        .unwrap();

    let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key).unwrap();
    let wire_data = frame.encode();
    let ciphertext_b64 =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &wire_data);

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&responder.auth_token))
        .json(&json!({
            "conversation_id": responder.conversation_id,
            "ciphertext": ciphertext_b64,
            "sequence": 1
        }))
        .await
        .assert_status_ok();

    // === Initiator polls and decrypts ===
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            initiator.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .await;

    poll_response.assert_status_ok();
    let poll_body: Value = poll_response.json();
    let messages = poll_body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1);

    let received_b64 = messages[0]["ciphertext"].as_str().unwrap();
    let received_wire =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, received_b64).unwrap();

    // Initiator consumes from END (Responder role direction)
    let init_auth_bytes = initiator
        .pad
        .consume(AUTH_KEY_SIZE, Role::Responder)
        .unwrap();
    let init_auth_key = AuthKey::from_slice(&init_auth_bytes);
    let init_enc_key = initiator
        .pad
        .consume(plaintext.len(), Role::Responder)
        .unwrap();

    let received_frame = MessageFrame::decode(&received_wire).unwrap();
    let decrypted = received_frame
        .decrypt(&init_enc_key, &init_auth_key)
        .unwrap();

    assert_eq!(decrypted, plaintext);
}

#[tokio::test]
async fn test_e2e_bidirectional_message_exchange() {
    let server = build_test_server().await;
    let (mut initiator, mut responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // === Message 1: Initiator -> Responder ===
    let msg1 = b"Message 1 from initiator";
    let auth1 = initiator
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let enc1 = initiator.pad.consume(msg1.len(), Role::Initiator).unwrap();
    let frame1 =
        MessageFrame::encrypt(MessageType::Text, msg1, &enc1, &AuthKey::from_slice(&auth1))
            .unwrap();
    let wire1 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, frame1.encode());

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "ciphertext": wire1,
            "sequence": 1
        }))
        .await
        .assert_status_ok();

    // === Message 2: Responder -> Initiator ===
    let msg2 = b"Message 2 from responder";
    let auth2 = responder
        .pad
        .consume(AUTH_KEY_SIZE, Role::Responder)
        .unwrap();
    let enc2 = responder.pad.consume(msg2.len(), Role::Responder).unwrap();
    let frame2 =
        MessageFrame::encrypt(MessageType::Text, msg2, &enc2, &AuthKey::from_slice(&auth2))
            .unwrap();
    let wire2 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, frame2.encode());

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&responder.auth_token))
        .json(&json!({
            "conversation_id": responder.conversation_id,
            "ciphertext": wire2,
            "sequence": 2
        }))
        .await
        .assert_status_ok();

    // === Message 3: Initiator -> Responder ===
    let msg3 = b"Message 3 from initiator";
    let auth3 = initiator
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let enc3 = initiator.pad.consume(msg3.len(), Role::Initiator).unwrap();
    let frame3 =
        MessageFrame::encrypt(MessageType::Text, msg3, &enc3, &AuthKey::from_slice(&auth3))
            .unwrap();
    let wire3 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, frame3.encode());

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "ciphertext": wire3,
            "sequence": 3
        }))
        .await
        .assert_status_ok();

    // Poll should show 3 messages
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            initiator.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .await;

    let poll_body: Value = poll_response.json();
    let messages = poll_body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
}

// =============================================================================
// E2E Location Message Tests
// =============================================================================

#[tokio::test]
async fn test_e2e_location_message() {
    let server = build_test_server().await;
    let (mut initiator, mut responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // Send location (6 decimal places = ~10cm precision)
    let location = b"37.774929,-122.419416";

    let auth_bytes = initiator
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let auth_key = AuthKey::from_slice(&auth_bytes);
    let enc_key = initiator
        .pad
        .consume(location.len(), Role::Initiator)
        .unwrap();

    let frame =
        MessageFrame::encrypt(MessageType::Location, location, &enc_key, &auth_key).unwrap();
    let wire_data = frame.encode();
    let ciphertext_b64 =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &wire_data);

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "ciphertext": ciphertext_b64,
            "sequence": 1
        }))
        .await
        .assert_status_ok();

    // Responder receives and decrypts
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            responder.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&responder.auth_token))
        .await;

    let poll_body: Value = poll_response.json();
    let messages = poll_body["messages"].as_array().unwrap();
    let received_b64 = messages[0]["ciphertext"].as_str().unwrap();
    let received_wire =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, received_b64).unwrap();

    let resp_auth_bytes = responder
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let resp_enc_key = responder
        .pad
        .consume(location.len(), Role::Initiator)
        .unwrap();

    let received_frame = MessageFrame::decode(&received_wire).unwrap();
    assert_eq!(received_frame.msg_type, MessageType::Location);

    let decrypted = received_frame
        .decrypt(&resp_enc_key, &AuthKey::from_slice(&resp_auth_bytes))
        .unwrap();
    assert_eq!(decrypted, location);
}

// =============================================================================
// E2E Burn Tests
// =============================================================================

#[tokio::test]
async fn test_e2e_burn_with_derived_tokens() {
    let server = build_test_server().await;
    let (mut initiator, _responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // Submit a message
    let plaintext = b"Message to be burned";
    let auth_bytes = initiator
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let enc_key = initiator
        .pad
        .consume(plaintext.len(), Role::Initiator)
        .unwrap();
    let frame = MessageFrame::encrypt(
        MessageType::Text,
        plaintext,
        &enc_key,
        &AuthKey::from_slice(&auth_bytes),
    )
    .unwrap();
    let ciphertext =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, frame.encode());

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "ciphertext": ciphertext,
            "sequence": 1
        }))
        .await
        .assert_status_ok();

    // Burn using derived burn token
    let burn_response = server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.burn_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id
        }))
        .await;

    burn_response.assert_status_ok();
    assert_eq!(burn_response.json::<Value>()["accepted"], true);

    // Verify conversation is gone
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            initiator.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .await;

    poll_response.assert_status(StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_e2e_burn_requires_burn_token_not_auth_token() {
    let server = build_test_server().await;
    let (initiator, _responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // Try to burn with auth token (should fail - defense in depth)
    let burn_response = server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id
        }))
        .await;

    burn_response.assert_status(StatusCode::UNAUTHORIZED);

    // Conversation should still be accessible
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            initiator.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .await;

    poll_response.assert_status_ok();
}

#[tokio::test]
async fn test_e2e_either_party_can_burn() {
    let server = build_test_server().await;
    let (initiator, responder) = perform_ceremony();

    // Both parties have the same burn token
    assert_eq!(initiator.burn_token, responder.burn_token);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // Responder burns (using their derived burn token)
    let burn_response = server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&responder.burn_token))
        .json(&json!({
            "conversation_id": responder.conversation_id
        }))
        .await;

    burn_response.assert_status_ok();
}

// =============================================================================
// E2E Pad Exhaustion Tests
// =============================================================================

#[tokio::test]
async fn test_e2e_pad_consumption_tracking() {
    let server = build_test_server().await;
    let (mut initiator, _responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    let initial_remaining = initiator.pad.remaining();

    // Send multiple messages and track consumption
    for i in 0..5 {
        let msg = format!("Message number {i}");
        let msg_bytes = msg.as_bytes();

        let auth_bytes = initiator
            .pad
            .consume(AUTH_KEY_SIZE, Role::Initiator)
            .unwrap();
        let enc_key = initiator
            .pad
            .consume(msg_bytes.len(), Role::Initiator)
            .unwrap();

        let frame = MessageFrame::encrypt(
            MessageType::Text,
            msg_bytes,
            &enc_key,
            &AuthKey::from_slice(&auth_bytes),
        )
        .unwrap();
        let ciphertext =
            base64::Engine::encode(&base64::engine::general_purpose::STANDARD, frame.encode());

        server
            .post("/v1/messages")
            .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
            .json(&json!({
                "conversation_id": initiator.conversation_id,
                "ciphertext": ciphertext,
                "sequence": i + 1
            }))
            .await
            .assert_status_ok();
    }

    // Verify pad consumption
    let consumed = initial_remaining - initiator.pad.remaining();
    assert!(consumed > 0);
    assert!(!initiator.pad.is_exhausted());
}

// =============================================================================
// E2E Authentication Failure Tests
// =============================================================================

#[tokio::test]
async fn test_e2e_tampered_message_rejected() {
    let server = build_test_server().await;
    let (mut initiator, mut responder) = perform_ceremony();

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "auth_token_hash": auth::hash_token(&initiator.auth_token),
            "burn_token_hash": auth::hash_token(&initiator.burn_token)
        }))
        .await
        .assert_status_ok();

    // Initiator sends message
    let plaintext = b"Secret message";
    let auth_bytes = initiator
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let auth_key = AuthKey::from_slice(&auth_bytes);
    let enc_key = initiator
        .pad
        .consume(plaintext.len(), Role::Initiator)
        .unwrap();

    let frame = MessageFrame::encrypt(MessageType::Text, plaintext, &enc_key, &auth_key).unwrap();
    let mut wire_data = frame.encode();

    // Tamper with the ciphertext (flip a bit in the middle)
    let tamper_pos = wire_data.len() / 2;
    wire_data[tamper_pos] ^= 0x01;

    let ciphertext_b64 =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &wire_data);

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&initiator.auth_token))
        .json(&json!({
            "conversation_id": initiator.conversation_id,
            "ciphertext": ciphertext_b64,
            "sequence": 1
        }))
        .await
        .assert_status_ok();

    // Responder tries to decrypt - should fail authentication
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            responder.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&responder.auth_token))
        .await;

    let poll_body: Value = poll_response.json();
    let messages = poll_body["messages"].as_array().unwrap();
    let received_b64 = messages[0]["ciphertext"].as_str().unwrap();
    let received_wire =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, received_b64).unwrap();

    let resp_auth_bytes = responder
        .pad
        .consume(AUTH_KEY_SIZE, Role::Initiator)
        .unwrap();
    let resp_enc_key = responder
        .pad
        .consume(plaintext.len(), Role::Initiator)
        .unwrap();

    let received_frame = MessageFrame::decode(&received_wire).unwrap();
    let decrypt_result =
        received_frame.decrypt(&resp_enc_key, &AuthKey::from_slice(&resp_auth_bytes));

    // Decryption should fail due to authentication failure
    assert!(decrypt_result.is_err());
}

// =============================================================================
// E2E Mnemonic Verification Tests
// =============================================================================

#[tokio::test]
async fn test_e2e_mnemonic_verification() {
    let (initiator, responder) = perform_ceremony();

    // Both parties should generate identical mnemonics
    let init_mnemonic = mnemonic::generate_default(initiator.pad.as_bytes());
    let resp_mnemonic = mnemonic::generate_default(responder.pad.as_bytes());

    assert_eq!(init_mnemonic.len(), 6); // 6 words
    assert_eq!(init_mnemonic, resp_mnemonic);

    // Mnemonics should be deterministic
    let init_mnemonic_2 = mnemonic::generate_default(initiator.pad.as_bytes());
    assert_eq!(init_mnemonic, init_mnemonic_2);
}
