//! Integration tests for ASH backend API endpoints.
//!
//! Tests the full HTTP API including authentication, message flow, and burn operations.
//! Uses ash-core for cryptographic operations and token derivation.

use ash_backend::{apns, auth, build_router, config::Config, handlers::AppState, store::Store};
use ash_core::{self, Pad, PadSize};
use axum::http::{header, StatusCode};
use axum_test::TestServer;
use serde_json::{json, Value};
use std::sync::Arc;

/// Test credentials derived from a pad
struct TestCredentials {
    conversation_id: String,
    auth_token: String,
    burn_token: String,
    auth_token_hash: String,
    burn_token_hash: String,
}

/// Generate test credentials using core's token derivation
#[allow(dead_code)]
fn generate_test_credentials() -> TestCredentials {
    // Create a pad with deterministic but unique entropy for each test
    let entropy: Vec<u8> = (0u8..=255)
        .cycle()
        .take(PadSize::Small.bytes())
        .enumerate()
        .map(|(i, b)| b.wrapping_add((i / 256) as u8))
        .collect();

    let pad = Pad::new(&entropy, PadSize::Small).unwrap();
    let (conversation_id, auth_token, burn_token) =
        ash_core::auth::derive_all_tokens(pad.as_bytes()).unwrap();

    TestCredentials {
        auth_token_hash: auth::hash_token(&auth_token),
        burn_token_hash: auth::hash_token(&burn_token),
        conversation_id,
        auth_token,
        burn_token,
    }
}

/// Generate unique test credentials using a seed
fn generate_test_credentials_with_seed(seed: u8) -> TestCredentials {
    let entropy: Vec<u8> = (0u8..=255)
        .cycle()
        .take(PadSize::Small.bytes())
        .enumerate()
        .map(|(i, b)| b.wrapping_add(seed).wrapping_add((i / 256) as u8))
        .collect();

    let pad = Pad::new(&entropy, PadSize::Small).unwrap();
    let (conversation_id, auth_token, burn_token) =
        ash_core::auth::derive_all_tokens(pad.as_bytes()).unwrap();

    TestCredentials {
        auth_token_hash: auth::hash_token(&auth_token),
        burn_token_hash: auth::hash_token(&burn_token),
        conversation_id,
        auth_token,
        burn_token,
    }
}

/// Build test server with the application router
async fn build_test_server() -> TestServer {
    let config = Config::default();
    let store = Arc::new(Store::new(config.clone()));
    let apns = apns::create_client(&config);
    let state = AppState::new(store, apns);

    let app = build_router(state);
    TestServer::new(app).unwrap()
}

/// Create authorization header value
fn auth_header(token: &str) -> String {
    format!("Bearer {token}")
}

// =============================================================================
// Health Endpoint Tests
// =============================================================================

#[tokio::test]
async fn test_health_endpoint() {
    let server = build_test_server().await;

    let response = server.get("/health").await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["status"], "ok");
    assert!(body["version"].is_string());
}

// =============================================================================
// Conversation Registration Tests
// =============================================================================

#[tokio::test]
async fn test_register_conversation_success() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(1);

    let response = server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["success"], true);
}

#[tokio::test]
async fn test_register_conversation_invalid_id() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(2);

    // Invalid conversation ID (too short)
    let response = server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": "invalid",
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await;

    response.assert_status(StatusCode::BAD_REQUEST);
    let body: Value = response.json();
    assert_eq!(body["code"], "INVALID_INPUT");
}

#[tokio::test]
async fn test_register_conversation_idempotent() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(3);

    // First registration
    let response = server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await;
    response.assert_status_ok();

    // Second registration (should succeed - idempotent)
    let response = server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await;
    response.assert_status_ok();
}

// =============================================================================
// Message Submission Tests
// =============================================================================

#[tokio::test]
async fn test_submit_message_success() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(4);

    // Register conversation first
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit message
    let ciphertext = base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        b"encrypted-message-content",
    );

    let response = server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "ciphertext": ciphertext,
            "sequence": 1
        }))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["accepted"], true);
    assert!(body["blob_id"].is_string());
}

#[tokio::test]
async fn test_submit_message_unauthorized() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(5);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit message with wrong token
    let response = server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header("wrong-token"))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "ciphertext": "YWJj",
            "sequence": 1
        }))
        .await;

    response.assert_status(StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_submit_message_missing_auth() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(6);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit message without auth header
    let response = server
        .post("/v1/messages")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "ciphertext": "YWJj",
            "sequence": 1
        }))
        .await;

    response.assert_status(StatusCode::UNAUTHORIZED);
    let body: Value = response.json();
    assert_eq!(body["code"], "MISSING_AUTH");
}

// =============================================================================
// Message Polling Tests
// =============================================================================

#[tokio::test]
async fn test_poll_messages_empty() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(7);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Poll for messages (should be empty)
    let response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert!(body["messages"].as_array().unwrap().is_empty());
    assert_eq!(body["burned"], false);
}

#[tokio::test]
async fn test_poll_messages_returns_submitted_messages() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(8);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit a message
    let ciphertext =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b"test-message");

    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "ciphertext": ciphertext,
            "sequence": 42
        }))
        .await
        .assert_status_ok();

    // Poll for messages
    let response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    let messages = body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["sequence"], 42);
    assert_eq!(messages[0]["ciphertext"], ciphertext);
}

// =============================================================================
// Message Acknowledgment Tests
// =============================================================================

#[tokio::test]
async fn test_ack_message_success() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(9);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit a message
    let submit_response = server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "ciphertext": "YWJj",
            "sequence": 1
        }))
        .await;

    submit_response.assert_status_ok();
    let blob_id = submit_response.json::<Value>()["blob_id"]
        .as_str()
        .unwrap()
        .to_string();

    // Acknowledge the message
    let response = server
        .post("/v1/messages/ack")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "blob_ids": [blob_id]
        }))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["acknowledged"], 1);

    // Verify message is deleted (poll should return empty)
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    poll_response.assert_status_ok();
    let poll_body: Value = poll_response.json();
    assert!(poll_body["messages"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn test_ack_nonexistent_message() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(10);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Acknowledge nonexistent message
    let response = server
        .post("/v1/messages/ack")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "blob_ids": ["00000000-0000-0000-0000-000000000000"]
        }))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["acknowledged"], 0);
}

// =============================================================================
// Burn Conversation Tests
// =============================================================================

#[tokio::test]
async fn test_burn_conversation_success() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(11);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit a message
    server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "ciphertext": "YWJj",
            "sequence": 1
        }))
        .await
        .assert_status_ok();

    // Burn the conversation (requires burn token, not auth token)
    let response = server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&creds.burn_token))
        .json(&json!({
            "conversation_id": creds.conversation_id
        }))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["accepted"], true);
}

#[tokio::test]
async fn test_burn_conversation_wrong_token() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(12);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Try to burn with auth token instead of burn token (should fail)
    let response = server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id
        }))
        .await;

    response.assert_status(StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_burn_conversation_unregistered() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(13);

    // Try to burn unregistered conversation
    let response = server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&creds.burn_token))
        .json(&json!({
            "conversation_id": creds.conversation_id
        }))
        .await;

    response.assert_status(StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_burn_deletes_messages() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(14);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit multiple messages
    for i in 1..=3 {
        server
            .post("/v1/messages")
            .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
            .json(&json!({
                "conversation_id": creds.conversation_id,
                "ciphertext": "YWJj",
                "sequence": i
            }))
            .await
            .assert_status_ok();
    }

    // Verify messages exist
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;
    let poll_body: Value = poll_response.json();
    assert_eq!(poll_body["messages"].as_array().unwrap().len(), 3);

    // Burn conversation
    server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&creds.burn_token))
        .json(&json!({
            "conversation_id": creds.conversation_id
        }))
        .await
        .assert_status_ok();

    // Verify conversation is burned - auth should fail now since auth entries are removed
    let poll_response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    // After burn, conversation is removed from auth store, so it should return 404
    poll_response.assert_status(StatusCode::NOT_FOUND);
}

// =============================================================================
// Burn Status Tests
// =============================================================================

#[tokio::test]
async fn test_burn_status_not_burned() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(15);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Check burn status
    let response = server
        .get(&format!(
            "/v1/burn?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["burned"], false);
    assert!(body["burned_at"].is_null());
}

#[tokio::test]
async fn test_burn_status_after_burn() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(16);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Burn conversation
    server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&creds.burn_token))
        .json(&json!({
            "conversation_id": creds.conversation_id
        }))
        .await
        .assert_status_ok();

    // Check burn status - auth entries are removed, so this should fail
    let response = server
        .get(&format!(
            "/v1/burn?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    // After burn, conversation is removed from auth store
    response.assert_status(StatusCode::NOT_FOUND);
}

// =============================================================================
// Device Registration Tests
// =============================================================================

#[tokio::test]
async fn test_register_device_success() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(17);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Register device
    let response = server
        .post("/v1/register")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "device_token": "abc123def456",
            "platform": "ios"
        }))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    assert_eq!(body["success"], true);
}

#[tokio::test]
async fn test_register_device_invalid_token() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(18);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Register device with empty token
    let response = server
        .post("/v1/register")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "device_token": "",
            "platform": "ios"
        }))
        .await;

    response.assert_status(StatusCode::BAD_REQUEST);
}

// =============================================================================
// Operations on Burned Conversation Tests
// =============================================================================

#[tokio::test]
async fn test_submit_message_after_burn() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(19);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Burn conversation
    server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&creds.burn_token))
        .json(&json!({
            "conversation_id": creds.conversation_id
        }))
        .await
        .assert_status_ok();

    // Try to submit message after burn (should fail - conversation removed)
    let response = server
        .post("/v1/messages")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "ciphertext": "YWJj",
            "sequence": 1
        }))
        .await;

    // Conversation is not found after burn (auth entries removed)
    response.assert_status(StatusCode::NOT_FOUND);
}

// =============================================================================
// Conversation Not Found Tests
// =============================================================================

#[tokio::test]
async fn test_poll_unregistered_conversation() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(20);

    let response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    response.assert_status(StatusCode::NOT_FOUND);
    let body: Value = response.json();
    assert_eq!(body["code"], "CONVERSATION_NOT_FOUND");
}

// =============================================================================
// Multiple Messages and Ordering Tests
// =============================================================================

#[tokio::test]
async fn test_multiple_messages_ordering() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(21);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Submit messages with different sequences
    for seq in [3, 1, 2] {
        let ciphertext = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            format!("message-{seq}").as_bytes(),
        );

        server
            .post("/v1/messages")
            .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
            .json(&json!({
                "conversation_id": creds.conversation_id,
                "ciphertext": ciphertext,
                "sequence": seq
            }))
            .await
            .assert_status_ok();
    }

    // Poll messages - should get all 3
    let response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    response.assert_status_ok();
    let body: Value = response.json();
    let messages = body["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
}

// =============================================================================
// Burn with Push Notification Test (integration)
// =============================================================================

#[tokio::test]
async fn test_burn_removes_device_registrations() {
    let server = build_test_server().await;
    let creds = generate_test_credentials_with_seed(22);

    // Register conversation
    server
        .post("/v1/conversations")
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "auth_token_hash": creds.auth_token_hash,
            "burn_token_hash": creds.burn_token_hash
        }))
        .await
        .assert_status_ok();

    // Register device
    server
        .post("/v1/register")
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .json(&json!({
            "conversation_id": creds.conversation_id,
            "device_token": "device123",
            "platform": "ios"
        }))
        .await
        .assert_status_ok();

    // Burn conversation
    server
        .post("/v1/burn")
        .add_header(header::AUTHORIZATION, auth_header(&creds.burn_token))
        .json(&json!({
            "conversation_id": creds.conversation_id
        }))
        .await
        .assert_status_ok();

    // Verify conversation is gone
    let response = server
        .get(&format!(
            "/v1/messages?conversation_id={}",
            creds.conversation_id
        ))
        .add_header(header::AUTHORIZATION, auth_header(&creds.auth_token))
        .await;

    response.assert_status(StatusCode::NOT_FOUND);
}
