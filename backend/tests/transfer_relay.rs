//! Pad transfer through the relay: the ash-transfer protocol run end to end
//! over the HTTP API, as two devices would.

use ash_backend::{apns, build_router, config::Config, handlers::AppState, store::Store};
use ash_core::group::SecurityLevel;
use ash_transfer::{NonceMessage, Offer, Receiver, Response, Reveal, SealedPad, Sender};
use axum::body::Bytes;
use axum::http::{header, StatusCode};
use axum_test::TestServer;
use serde_json::Value;
use std::sync::Arc;

fn server() -> TestServer {
    let config = Config::default();
    let store = Arc::new(Store::new(config.clone()));
    let state = AppState::new(store, apns::create_client(&config));
    TestServer::new(build_router(state)).unwrap()
}

struct Transfer {
    id: String,
    receiver_token: String,
    sender_token: String,
}

async fn open(server: &TestServer) -> Transfer {
    let response = server.post("/v1/transfers").await;
    response.assert_status(StatusCode::CREATED);
    let body: Value = response.json();
    assert_eq!(body["expires_in_secs"], 600);
    Transfer {
        id: body["transfer_id"].as_str().unwrap().to_string(),
        receiver_token: body["receiver_token"].as_str().unwrap().to_string(),
        sender_token: body["sender_token"].as_str().unwrap().to_string(),
    }
}

async fn send(server: &TestServer, t: &Transfer, token: &str, message: Vec<u8>) {
    server
        .post(&format!("/v1/transfers/{}/messages", t.id))
        .add_header(header::AUTHORIZATION, format!("Bearer {token}"))
        .bytes(Bytes::from(message))
        .await
        .assert_status(StatusCode::ACCEPTED);
}

async fn receive(server: &TestServer, t: &Transfer, token: &str) -> Vec<u8> {
    let response = server
        .get(&format!("/v1/transfers/{}/messages", t.id))
        .add_header(header::AUTHORIZATION, format!("Bearer {token}"))
        .await;
    response.assert_status_ok();
    response.as_bytes().to_vec()
}

#[tokio::test]
async fn pad_travels_through_relay() {
    let server = server();
    let t = open(&server).await;
    let (r, s) = (t.receiver_token.clone(), t.sender_token.clone());

    // Receiver opens the exchange
    let (receiver, offer) = Receiver::start([1; 32]);
    send(&server, &t, &r, offer.encode()).await;

    // Sender answers
    let offer = Offer::decode(&receive(&server, &t, &s).await).unwrap();
    let (sender, response) = Sender::on_offer(&offer, [2; 64], [3; 32]).unwrap();
    send(&server, &t, &s, response.encode()).await;

    let response = Response::decode(&receive(&server, &t, &r).await).unwrap();
    let (receiver, nonce) = receiver.on_response(response, [4; 32]);
    send(&server, &t, &r, nonce.encode()).await;

    let nonce = NonceMessage::decode(&receive(&server, &t, &s).await).unwrap();
    let (sender, reveal) = sender.on_nonce(&nonce);
    send(&server, &t, &s, reveal.encode()).await;

    let reveal = Reveal::decode(&receive(&server, &t, &r).await).unwrap();
    let receiver = receiver.on_reveal(&reveal).unwrap();

    // People compare the words, then the sender seals a 1 MiB pad
    assert_eq!(receiver.words(), sender.words());
    let pad: Vec<u8> = (0..1024 * 1024u32).map(|i| (i % 251) as u8).collect();
    let sealed = sender.seal_pad(&pad, SecurityLevel::Standard).unwrap();
    send(&server, &t, &s, sealed.encode()).await;

    let sealed = SealedPad::decode(&receive(&server, &t, &r).await).unwrap();
    let (opened, level) = receiver.open_pad(&sealed).unwrap();
    assert_eq!(*opened, pad);
    assert_eq!(level, SecurityLevel::Standard);

    // Either side closes the mailbox
    server
        .delete(&format!("/v1/transfers/{}", t.id))
        .add_header(header::AUTHORIZATION, format!("Bearer {r}"))
        .await
        .assert_status(StatusCode::NO_CONTENT);
    server
        .get(&format!("/v1/transfers/{}/messages", t.id))
        .add_header(header::AUTHORIZATION, format!("Bearer {s}"))
        .await
        .assert_status(StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn empty_inbox_returns_no_content() {
    let server = server();
    let t = open(&server).await;
    server
        .get(&format!("/v1/transfers/{}/messages", t.id))
        .add_header(header::AUTHORIZATION, format!("Bearer {}", t.sender_token))
        .await
        .assert_status(StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn requests_are_authorized() {
    let server = server();
    let t = open(&server).await;
    let url = format!("/v1/transfers/{}/messages", t.id);

    server
        .get(&url)
        .await
        .assert_status(StatusCode::UNAUTHORIZED);
    server
        .get(&url)
        .add_header(header::AUTHORIZATION, "Bearer not-a-token")
        .await
        .assert_status(StatusCode::UNAUTHORIZED);
    server
        .get("/v1/transfers/unknown/messages")
        .add_header(header::AUTHORIZATION, format!("Bearer {}", t.sender_token))
        .await
        .assert_status(StatusCode::NOT_FOUND);
    server
        .post(&url)
        .add_header(header::AUTHORIZATION, format!("Bearer {}", t.sender_token))
        .bytes(Bytes::new())
        .await
        .assert_status(StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn oversized_message_rejected() {
    let server = server();
    let t = open(&server).await;
    server
        .post(&format!("/v1/transfers/{}/messages", t.id))
        .add_header(header::AUTHORIZATION, format!("Bearer {}", t.sender_token))
        .bytes(Bytes::from(vec![0u8; 2 * 1024 * 1024 + 1]))
        .await
        .assert_status(StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn other_endpoints_keep_small_body_limit() {
    let server = server();
    server
        .post("/v1/conversations")
        .add_header(header::CONTENT_TYPE, "application/json")
        .bytes(Bytes::from(vec![b' '; 32 * 1024]))
        .await
        .assert_status(StatusCode::PAYLOAD_TOO_LARGE);
}
