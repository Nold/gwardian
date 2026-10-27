//! HTTP request handlers for ASH backend API.
//!
//! All handlers follow the contract:
//! - No plaintext content
//! - No user identity
//! - Best-effort delivery
//! - Minimal logging (no PII)

use crate::apns::ApnsClient;
use crate::auth::{extract_bearer_token, AuthError, AuthStore, RegisterResult};
use crate::models::*;
use crate::store::{Store, StoreError};
use axum::{
    extract::{Query, State},
    http::{header::AUTHORIZATION, StatusCode},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse,
    },
    Json,
};
use base64::Engine;
use futures::stream::Stream;
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;
use tracing::{debug, info, warn};

/// Broadcast channel capacity for SSE events
const BROADCAST_CAPACITY: usize = 1024;

/// Application state shared across handlers
#[derive(Clone)]
pub struct AppState {
    pub store: Arc<Store>,
    pub apns: Arc<ApnsClient>,
    /// Authorization token store
    pub auth: AuthStore,
    /// Broadcast channel for SSE events
    pub broadcast_tx: broadcast::Sender<BroadcastEvent>,
}

impl AppState {
    pub fn new(store: Arc<Store>, apns: Arc<ApnsClient>) -> Self {
        let (broadcast_tx, _) = broadcast::channel(BROADCAST_CAPACITY);
        Self {
            store,
            apns,
            auth: AuthStore::new(),
            broadcast_tx,
        }
    }
}

// === Health Check ===

/// GET /health - Health check endpoint
pub async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

// === Conversation Registration ===

/// POST /v1/conversations - Register a conversation with token hashes
///
/// Both ceremony participants call this endpoint after ceremony completion.
/// They provide SHA-256 hashes of their tokens (not the tokens themselves).
/// The backend stores only hashes and can verify but not forge tokens.
///
/// # DoS Protection
///
/// - Maximum 100,000 conversations (returns 503 if exceeded)
/// - Stale conversations (inactive 24h+) are evicted automatically
/// - Rate limiting should be applied at HTTP layer (nginx/cloudflare)
pub async fn register_conversation(
    State(state): State<AppState>,
    Json(req): Json<RegisterConversationRequest>,
) -> Result<Json<RegisterConversationResponse>, ApiError> {
    // Validate conversation_id format (should be 64 hex chars)
    if req.conversation_id.len() != 64
        || !req.conversation_id.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Err(ApiError::InvalidInput("invalid conversation_id format"));
    }

    // Validate token hash format (should be 64 hex chars = 32 bytes SHA-256)
    if req.auth_token_hash.len() != 64
        || !req.auth_token_hash.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Err(ApiError::InvalidInput("invalid auth_token_hash format"));
    }
    if req.burn_token_hash.len() != 64
        || !req.burn_token_hash.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Err(ApiError::InvalidInput("invalid burn_token_hash format"));
    }

    // Register the conversation (idempotent - both parties may register)
    let result = state.auth.register(
        &req.conversation_id,
        req.auth_token_hash.to_lowercase(),
        req.burn_token_hash.to_lowercase(),
    );

    match result {
        RegisterResult::Ok => {
            // Store notification preferences for new conversations
            state.store.store_prefs(
                req.conversation_id.clone(),
                req.notification_flags,
                req.ttl_seconds,
            );
            info!(
                conv_id_prefix = &req.conversation_id[..8],
                notification_flags = req.notification_flags,
                ttl_seconds = req.ttl_seconds,
                "Conversation registered"
            );
        }
        RegisterResult::AlreadyExists => {
            // Update preferences on re-registration (e.g., second party registering)
            state.store.store_prefs(
                req.conversation_id.clone(),
                req.notification_flags,
                req.ttl_seconds,
            );
            debug!(
                conv_id_prefix = &req.conversation_id[..8],
                "Conversation re-registered"
            );
        }
        RegisterResult::AtCapacity => {
            warn!("Registration rejected: server at capacity");
            return Err(ApiError::ServerAtCapacity);
        }
    }

    Ok(Json(RegisterConversationResponse { success: true }))
}

// === Token Verification Helpers ===

/// Extract auth token from request headers
fn extract_auth_token(headers: &axum::http::HeaderMap) -> Result<String, AuthError> {
    let header_value = headers
        .get(AUTHORIZATION)
        .ok_or(AuthError::MissingHeader)?
        .to_str()
        .map_err(|_| AuthError::InvalidHeader)?;

    extract_bearer_token(header_value)
        .map(|s| s.to_string())
        .ok_or(AuthError::InvalidHeader)
}

/// Verify auth token for a conversation
fn verify_auth_token(
    state: &AppState,
    conversation_id: &str,
    token: &str,
) -> Result<(), AuthError> {
    if !state.auth.is_registered(conversation_id) {
        return Err(AuthError::ConversationNotFound);
    }
    if !state.auth.verify_auth_token(conversation_id, token) {
        warn!(
            conv_id_prefix = &conversation_id[..8.min(conversation_id.len())],
            "Auth token verification failed"
        );
        return Err(AuthError::Unauthorized);
    }
    Ok(())
}

/// Verify burn token for a conversation
fn verify_burn_token(
    state: &AppState,
    conversation_id: &str,
    token: &str,
) -> Result<(), AuthError> {
    if !state.auth.is_registered(conversation_id) {
        return Err(AuthError::ConversationNotFound);
    }
    if !state.auth.verify_burn_token(conversation_id, token) {
        warn!(
            conv_id_prefix = &conversation_id[..8.min(conversation_id.len())],
            "Burn token verification failed"
        );
        return Err(AuthError::Unauthorized);
    }
    Ok(())
}

// === Device Registration ===

/// POST /v1/register - Register device for push notifications
pub async fn register_device(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(req): Json<RegisterDeviceRequest>,
) -> Result<Json<RegisterDeviceResponse>, ApiError> {
    // Verify auth token
    let token = extract_auth_token(&headers)?;
    verify_auth_token(&state, &req.conversation_id, &token)?;

    // Validate device token format (basic check)
    if req.device_token.is_empty() || req.device_token.len() > 200 {
        return Err(ApiError::InvalidInput("invalid device token"));
    }

    state
        .store
        .register_device(req.conversation_id, req.device_token, req.platform)
        .await
        .map_err(|e| match e {
            StoreError::ConversationBurned => ApiError::ConversationBurned,
            _ => ApiError::Internal,
        })?;

    debug!("Device registered");

    Ok(Json(RegisterDeviceResponse { success: true }))
}

// === Message Submission ===

/// POST /v1/messages - Submit encrypted message blob
///
/// Messages are stored with fixed 5-minute TTL. Deleted on ACK or expiry.
pub async fn submit_message(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(req): Json<SubmitMessageRequest>,
) -> Result<Json<SubmitMessageResponse>, ApiError> {
    // Verify auth token
    let token = extract_auth_token(&headers)?;
    verify_auth_token(&state, &req.conversation_id, &token)?;

    tracing::info!(
        conv_id = %req.conversation_id,
        sequence = ?req.sequence,
        ciphertext_len = req.ciphertext.len(),
        "Received message submission"
    );

    // Decode base64 ciphertext
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(&req.ciphertext)
        .map_err(|_| ApiError::InvalidInput("invalid base64 ciphertext"))?;

    // Store the blob (fixed 5-minute TTL)
    let conversation_id = req.conversation_id;
    let received_at = chrono::Utc::now();
    // Calculate expiry time using same logic as store (for client synchronization)
    let expires_at = received_at
        + chrono::Duration::from_std(crate::config::MESSAGE_TTL).expect("valid duration");

    let blob_id = state
        .store
        .store_blob(conversation_id.clone(), ciphertext.clone(), req.sequence)
        .await
        .map_err(|e| match e {
            StoreError::ConversationBurned => ApiError::ConversationBurned,
            StoreError::PayloadTooLarge => ApiError::PayloadTooLarge,
            StoreError::QueueFull => ApiError::QueueFull,
            StoreError::DatabaseError(_) => ApiError::Internal,
        })?;

    tracing::info!(
        blob_id = %blob_id,
        conv_id = %conversation_id,
        size = ciphertext.len(),
        "Message stored successfully"
    );

    // Broadcast to SSE subscribers
    let message_blob = MessageBlob {
        id: blob_id,
        sequence: req.sequence,
        ciphertext: base64::engine::general_purpose::STANDARD.encode(&ciphertext),
        received_at,
    };
    let _ = state.broadcast_tx.send(BroadcastEvent {
        conversation_id: conversation_id.clone(),
        event: StreamEvent::Message(message_blob),
    });

    // Send push notifications to registered devices (best-effort, async)
    // Only send if NOTIFY_NEW_MESSAGE flag is set
    let prefs = state.store.get_prefs(&conversation_id);
    let should_notify = prefs
        .as_ref()
        .map(|p| p.notify_new_message())
        .unwrap_or(true);

    if should_notify {
        let devices = state.store.get_device_tokens(&conversation_id);
        if !devices.is_empty() {
            let apns = state.apns.clone();
            let conv_id = conversation_id.clone();
            tokio::spawn(async move {
                apns.send_to_devices(&devices, Some(&conv_id)).await;
            });
        }
    }

    Ok(Json(SubmitMessageResponse {
        accepted: true,
        blob_id,
        expires_at,
    }))
}

// === Message Polling ===

/// GET /v1/messages - Poll for messages
pub async fn poll_messages(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Query(query): Query<PollMessagesQuery>,
) -> Result<Json<PollMessagesResponse>, ApiError> {
    // Verify auth token
    let token = extract_auth_token(&headers)?;
    verify_auth_token(&state, &query.conversation_id, &token)?;

    tracing::info!(
        conv_id = %query.conversation_id,
        has_cursor = query.cursor.is_some(),
        "Polling messages"
    );

    // Parse cursor if provided
    let cursor = query.cursor.as_ref().and_then(|c| Cursor::decode(c));

    // Check burn status
    let burned = state.store.is_burned(&query.conversation_id);

    // Get messages
    let (blobs, next_cursor) = state
        .store
        .get_blobs(&query.conversation_id, cursor.as_ref());

    tracing::info!(
        conv_id = %query.conversation_id,
        blob_count = blobs.len(),
        burned = burned,
        "Retrieved blobs from store"
    );

    // Convert to response format
    let messages: Vec<MessageBlob> = blobs
        .into_iter()
        .map(|b| {
            tracing::debug!(
                blob_id = %b.id,
                sequence = ?b.sequence,
                size = b.ciphertext.len(),
                "Returning blob"
            );
            MessageBlob {
                id: b.id,
                sequence: b.sequence,
                ciphertext: base64::engine::general_purpose::STANDARD.encode(&b.ciphertext),
                received_at: b.received_at,
            }
        })
        .collect();

    Ok(Json(PollMessagesResponse {
        messages,
        next_cursor: next_cursor.map(|c| c.encode()),
        burned,
    }))
}

// === Burn Conversation ===

/// POST /v1/burn - Burn a conversation
///
/// IMPORTANT: This endpoint requires the burn_token, not the auth_token.
/// This provides defense-in-depth: knowing the auth token is not enough to burn.
pub async fn burn_conversation(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(req): Json<BurnConversationRequest>,
) -> Result<Json<BurnConversationResponse>, ApiError> {
    // Verify BURN token (not auth token - defense in depth)
    let token = extract_auth_token(&headers)?;
    verify_burn_token(&state, &req.conversation_id, &token)?;

    let conversation_id = req.conversation_id.clone();

    // Get device tokens before burning
    let devices = state.store.get_device_tokens(&conversation_id);

    // Burn the conversation
    let _ = state.store.burn(conversation_id.clone()).await;

    // Remove auth entries
    state.auth.remove(&conversation_id);

    // Broadcast burn event to SSE subscribers
    let _ = state.broadcast_tx.send(BroadcastEvent {
        conversation_id: conversation_id.clone(),
        event: StreamEvent::Burned {
            burned_at: chrono::Utc::now(),
        },
    });

    // Send burn notification to registered devices (best-effort)
    if !devices.is_empty() {
        let apns = state.apns.clone();
        let conv_id = conversation_id.clone();
        tokio::spawn(async move {
            apns.send_to_devices(&devices, Some(&conv_id)).await;
        });
    }

    debug!("Conversation burned");

    Ok(Json(BurnConversationResponse { accepted: true }))
}

// === Message Acknowledgment ===

/// POST /v1/messages/ack - Acknowledge message delivery
///
/// Called by recipient when they receive and decrypt a message.
/// This deletes the message from the server and notifies the sender via SSE.
pub async fn ack_messages(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AckMessageRequest>,
) -> Result<Json<AckMessageResponse>, ApiError> {
    // Verify auth token
    let token = extract_auth_token(&headers)?;
    verify_auth_token(&state, &req.conversation_id, &token)?;

    if req.blob_ids.is_empty() {
        return Ok(Json(AckMessageResponse { acknowledged: 0 }));
    }

    let conversation_id = req.conversation_id.clone();
    let mut acknowledged = 0;

    // Delete acknowledged messages from store
    for blob_id in &req.blob_ids {
        if state.store.delete_blob(&conversation_id, blob_id) {
            acknowledged += 1;
        }
    }

    if acknowledged > 0 {
        debug!(
            conv_id_prefix = &conversation_id[..8],
            count = acknowledged,
            "Messages acknowledged"
        );

        // Broadcast delivery event to SSE subscribers (notifies sender)
        let _ = state.broadcast_tx.send(BroadcastEvent {
            conversation_id,
            event: StreamEvent::Delivered {
                blob_ids: req.blob_ids,
                delivered_at: chrono::Utc::now(),
            },
        });
    }

    Ok(Json(AckMessageResponse { acknowledged }))
}

// === Burn Status ===

/// GET /v1/burn - Check burn status
pub async fn burn_status(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Query(query): Query<BurnStatusQuery>,
) -> Result<Json<BurnStatusResponse>, ApiError> {
    // Verify auth token
    let token = extract_auth_token(&headers)?;
    verify_auth_token(&state, &query.conversation_id, &token)?;

    let burn_flag = state.store.get_burn_status(&query.conversation_id);

    Ok(Json(BurnStatusResponse {
        burned: burn_flag.is_some(),
        burned_at: burn_flag.map(|f| f.burned_at),
    }))
}

// === SSE Message Stream ===

/// GET /v1/messages/stream - Server-Sent Events stream for real-time messages
pub async fn message_stream(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Query(query): Query<StreamQuery>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, ApiError> {
    // Verify auth token before establishing stream
    let token = extract_auth_token(&headers)?;
    verify_auth_token(&state, &query.conversation_id, &token)?;

    let conversation_id = query.conversation_id;

    info!(conv_id = %conversation_id, "SSE client connected");

    // Subscribe to the broadcast channel
    let rx = state.broadcast_tx.subscribe();

    // Create a stream that filters events for this conversation
    let stream = BroadcastStream::new(rx).filter_map(move |result| {
        match result {
            Ok(event) if event.conversation_id == conversation_id => {
                // Serialize the event to JSON
                match serde_json::to_string(&event.event) {
                    Ok(json) => Some(Ok(Event::default().data(json))),
                    Err(_) => None,
                }
            }
            _ => None,
        }
    });

    Ok(Sse::new(stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    ))
}

// === Error Handling ===

/// API error types
#[derive(Debug)]
pub enum ApiError {
    InvalidInput(&'static str),
    ConversationBurned,
    PayloadTooLarge,
    QueueFull,
    /// Server at capacity, cannot register new conversations
    ServerAtCapacity,
    Internal,
    /// Authorization error (wraps AuthError)
    Auth(AuthError),
}

/// Implement `From<AuthError>` to enable ? operator in handlers.
impl From<AuthError> for ApiError {
    fn from(err: AuthError) -> Self {
        ApiError::Auth(err)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        match self {
            ApiError::Auth(auth_err) => auth_err.into_response(),
            other => {
                let (status, code, message) = match other {
                    ApiError::InvalidInput(msg) => (StatusCode::BAD_REQUEST, "INVALID_INPUT", msg),
                    ApiError::ConversationBurned => (
                        StatusCode::GONE,
                        "CONVERSATION_BURNED",
                        "conversation has been burned",
                    ),
                    ApiError::PayloadTooLarge => (
                        StatusCode::PAYLOAD_TOO_LARGE,
                        "PAYLOAD_TOO_LARGE",
                        "ciphertext exceeds size limit",
                    ),
                    ApiError::QueueFull => (
                        StatusCode::TOO_MANY_REQUESTS,
                        "QUEUE_FULL",
                        "message queue is full",
                    ),
                    ApiError::ServerAtCapacity => (
                        StatusCode::SERVICE_UNAVAILABLE,
                        "SERVER_AT_CAPACITY",
                        "server at capacity, try again later",
                    ),
                    ApiError::Internal => (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "INTERNAL_ERROR",
                        "internal server error",
                    ),
                    ApiError::Auth(_) => unreachable!(),
                };

                let body = Json(ErrorResponse {
                    error: message.to_string(),
                    code,
                });

                (status, body).into_response()
            }
        }
    }
}
