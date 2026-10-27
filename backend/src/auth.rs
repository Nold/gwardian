//! Authorization token verification for ASH backend.
//!
//! Tokens are derived from pad bytes during ceremony. The backend stores
//! only hashes of tokens, so it can verify but not forge them.
//!
//! # Token Types
//!
//! - **Auth Token**: Required for all API operations (messages, polling, registration)
//! - **Burn Token**: Required specifically for burning conversations (defense in depth)
//!
//! # Security Model
//!
//! - Tokens are ceremony-derived, no server involvement
//! - Backend stores SHA-256(token), cannot reverse to get token
//! - Without pad access, tokens cannot be computed
//! - Separate tokens for different operations prevent escalation
//!
//! # DoS Protection
//!
//! - Maximum conversation limit prevents memory exhaustion
//! - TTL on inactive conversations enables automatic cleanup
//! - Rate limiting should be applied at the HTTP layer (nginx/cloudflare)

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use dashmap::DashMap;
use ring::digest::{digest, SHA256};
use serde::Serialize;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Token type for authorization
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenType {
    /// Auth token for general API operations
    Auth,
    /// Burn token specifically for burn operations
    Burn,
}

/// Maximum number of registered conversations (DoS protection).
/// At ~200 bytes per entry, 100k entries = ~20MB memory.
pub const MAX_CONVERSATIONS: usize = 100_000;

/// Inactive conversation TTL (24 hours).
/// Conversations with no activity are eligible for eviction.
pub const INACTIVE_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// Stored token hashes for a conversation
#[derive(Debug, Clone)]
pub struct ConversationAuth {
    /// SHA-256 hash of the auth token (hex-encoded)
    pub auth_token_hash: String,
    /// SHA-256 hash of the burn token (hex-encoded)
    pub burn_token_hash: String,
    /// Last activity timestamp (for TTL eviction)
    pub last_activity: Instant,
}

/// Registration result
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegisterResult {
    /// Successfully registered
    Ok,
    /// Already registered (idempotent success)
    AlreadyExists,
    /// Server at capacity, try again later
    AtCapacity,
}

/// Thread-safe storage for conversation authentication
#[derive(Clone, Default)]
pub struct AuthStore {
    /// Token hashes per conversation
    conversations: Arc<DashMap<String, ConversationAuth>>,
}

impl AuthStore {
    /// Create a new empty auth store
    pub fn new() -> Self {
        Self {
            conversations: Arc::new(DashMap::new()),
        }
    }

    /// Current number of registered conversations
    pub fn len(&self) -> usize {
        self.conversations.len()
    }

    /// Check if store is empty
    pub fn is_empty(&self) -> bool {
        self.conversations.is_empty()
    }

    /// Register a conversation with its token hashes.
    ///
    /// The hashes should be SHA-256(token), hex-encoded.
    /// Both clients send the same hashes (derived from same pad).
    ///
    /// # DoS Protection
    ///
    /// - Returns `AtCapacity` if MAX_CONVERSATIONS reached
    /// - Evicts stale conversations before rejecting
    /// - Idempotent: re-registering same conv_id just updates timestamp
    pub fn register(
        &self,
        conversation_id: &str,
        auth_token_hash: String,
        burn_token_hash: String,
    ) -> RegisterResult {
        // Check if already registered (idempotent update)
        if self.conversations.contains_key(conversation_id) {
            // Update timestamp on re-registration
            if let Some(mut entry) = self.conversations.get_mut(conversation_id) {
                entry.last_activity = Instant::now();
            }
            return RegisterResult::AlreadyExists;
        }

        // Check capacity
        if self.conversations.len() >= MAX_CONVERSATIONS {
            // Try to evict stale entries first
            self.evict_inactive();

            // Still at capacity?
            if self.conversations.len() >= MAX_CONVERSATIONS {
                return RegisterResult::AtCapacity;
            }
        }

        self.conversations.insert(
            conversation_id.to_string(),
            ConversationAuth {
                auth_token_hash,
                burn_token_hash,
                last_activity: Instant::now(),
            },
        );

        RegisterResult::Ok
    }

    /// Evict conversations inactive for longer than INACTIVE_TTL.
    fn evict_inactive(&self) {
        let cutoff = Instant::now() - INACTIVE_TTL;
        self.conversations
            .retain(|_, auth| auth.last_activity > cutoff);
    }

    /// Update last activity timestamp (call on successful auth).
    pub fn touch(&self, conversation_id: &str) {
        if let Some(mut entry) = self.conversations.get_mut(conversation_id) {
            entry.last_activity = Instant::now();
        }
    }

    /// Verify an auth token for a conversation.
    ///
    /// Returns true if the token hashes to the stored auth_token_hash.
    pub fn verify_auth_token(&self, conversation_id: &str, token: &str) -> bool {
        self.conversations
            .get(conversation_id)
            .map(|auth| {
                let provided_hash = hash_token(token);
                auth.auth_token_hash == provided_hash
            })
            .unwrap_or(false)
    }

    /// Verify a burn token for a conversation.
    ///
    /// Returns true if the token hashes to the stored burn_token_hash.
    pub fn verify_burn_token(&self, conversation_id: &str, token: &str) -> bool {
        self.conversations
            .get(conversation_id)
            .map(|auth| {
                let provided_hash = hash_token(token);
                auth.burn_token_hash == provided_hash
            })
            .unwrap_or(false)
    }

    /// Check if a conversation is registered
    pub fn is_registered(&self, conversation_id: &str) -> bool {
        self.conversations.contains_key(conversation_id)
    }

    /// Remove a conversation (on burn)
    pub fn remove(&self, conversation_id: &str) {
        self.conversations.remove(conversation_id);
    }
}

/// Hash a token using SHA-256 and return hex-encoded result
pub fn hash_token(token: &str) -> String {
    let hash = digest(&SHA256, token.as_bytes());
    hex::encode(hash.as_ref())
}

/// Extracted and verified auth token from request
#[derive(Debug, Clone)]
pub struct AuthToken {
    /// The raw token value
    pub token: String,
    /// The conversation ID from the request
    pub conversation_id: String,
}

/// Authorization error
#[derive(Debug)]
pub enum AuthError {
    /// Missing Authorization header
    MissingHeader,
    /// Invalid Authorization header format
    InvalidHeader,
    /// Token verification failed
    Unauthorized,
    /// Conversation not registered
    ConversationNotFound,
}

impl IntoResponse for AuthError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            AuthError::MissingHeader => (
                StatusCode::UNAUTHORIZED,
                "MISSING_AUTH",
                "Authorization header required",
            ),
            AuthError::InvalidHeader => (
                StatusCode::BAD_REQUEST,
                "INVALID_AUTH",
                "Invalid Authorization header format",
            ),
            AuthError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "UNAUTHORIZED",
                "Invalid or expired token",
            ),
            AuthError::ConversationNotFound => (
                StatusCode::NOT_FOUND,
                "CONVERSATION_NOT_FOUND",
                "Conversation not registered",
            ),
        };

        let body = Json(AuthErrorResponse {
            error: message.to_string(),
            code,
        });

        (status, body).into_response()
    }
}

#[derive(Debug, Serialize)]
struct AuthErrorResponse {
    error: String,
    code: &'static str,
}

/// Extract Bearer token from Authorization header
pub fn extract_bearer_token(authorization: &str) -> Option<&str> {
    authorization
        .strip_prefix("Bearer ")
        .or_else(|| authorization.strip_prefix("bearer "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_token_works() {
        let token = "test-token-1234567890abcdef";
        let hash = hash_token(token);

        // Should be 64 hex chars (32 bytes SHA-256)
        assert_eq!(hash.len(), 64);
        assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));

        // Should be deterministic
        assert_eq!(hash, hash_token(token));
    }

    #[test]
    fn auth_store_register_and_verify() {
        let store = AuthStore::new();

        let auth_token = "auth-token-abc123";
        let burn_token = "burn-token-xyz789";
        let auth_hash = hash_token(auth_token);
        let burn_hash = hash_token(burn_token);

        let result = store.register("conv-1", auth_hash.clone(), burn_hash.clone());
        assert_eq!(result, RegisterResult::Ok);

        assert!(store.is_registered("conv-1"));
        assert!(!store.is_registered("conv-2"));

        assert!(store.verify_auth_token("conv-1", auth_token));
        assert!(!store.verify_auth_token("conv-1", "wrong-token"));
        assert!(!store.verify_auth_token("conv-1", burn_token)); // Wrong token type

        assert!(store.verify_burn_token("conv-1", burn_token));
        assert!(!store.verify_burn_token("conv-1", auth_token)); // Wrong token type

        // Re-registration returns AlreadyExists
        let result = store.register("conv-1", auth_hash, burn_hash);
        assert_eq!(result, RegisterResult::AlreadyExists);
    }

    #[test]
    fn auth_store_capacity_limit() {
        let store = AuthStore::new();

        // Register up to max (but use a smaller test limit)
        // For real tests, we'd mock MAX_CONVERSATIONS
        for i in 0..100 {
            let result = store.register(
                &format!("conv-{i:064x}"),
                format!("{i:064x}"),
                format!("{:064x}", i + 1000),
            );
            assert_eq!(result, RegisterResult::Ok, "Failed at {i}");
        }

        assert_eq!(store.len(), 100);
    }

    #[test]
    fn auth_store_touch_updates_activity() {
        let store = AuthStore::new();
        let auth_hash = hash_token("token");
        let burn_hash = hash_token("burn");

        store.register("conv-1", auth_hash, burn_hash);

        // Touch should not panic
        store.touch("conv-1");
        store.touch("nonexistent"); // Should be no-op
    }

    #[test]
    fn extract_bearer_token_works() {
        assert_eq!(extract_bearer_token("Bearer abc123"), Some("abc123"));
        assert_eq!(extract_bearer_token("bearer ABC123"), Some("ABC123"));
        assert_eq!(extract_bearer_token("Basic abc123"), None);
        assert_eq!(extract_bearer_token("abc123"), None);
    }
}
