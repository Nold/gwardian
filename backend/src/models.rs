//! Data models for ASH backend API.
//!
//! All models are designed for ephemeral storage with automatic TTL cleanup.
//! No user identity or plaintext content is ever stored or transmitted.

use base64::Engine;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// =============================================================================
// Type Aliases
// =============================================================================

/// Conversation identifier (64-char hex string derived from shared secret).
pub type ConversationId = String;

/// Message sequence number for ordering.
pub type SequenceNumber = u64;

// =============================================================================
// Notification Flags
// =============================================================================

/// Notification flag constants for push notification preferences.
///
/// These flags are set during ceremony and control which push notifications
/// are sent to registered devices.
pub mod notification_flags {
    /// Notify when new message arrives (receiver).
    pub const NOTIFY_NEW_MESSAGE: u16 = 1 << 0;

    /// Notify before message expires - 5min and 1min warnings (receiver).
    pub const NOTIFY_MESSAGE_EXPIRING: u16 = 1 << 1;

    /// Notify when message expires (receiver).
    pub const NOTIFY_MESSAGE_EXPIRED: u16 = 1 << 2;

    /// Notify if message TTL expires unread (sender).
    pub const NOTIFY_DELIVERY_FAILED: u16 = 1 << 8;

    /// Reserved for future read receipts.
    pub const NOTIFY_MESSAGE_READ: u16 = 1 << 9;

    /// Default flags: new message + expiring + delivery failed.
    pub const DEFAULT: u16 = NOTIFY_NEW_MESSAGE | NOTIFY_MESSAGE_EXPIRING | NOTIFY_DELIVERY_FAILED;
}

// =============================================================================
// Internal Models
// =============================================================================

/// Conversation notification preferences.
#[derive(Debug, Clone, Default)]
pub struct ConversationPrefs {
    /// 16-bit notification flags.
    pub notification_flags: u16,
    /// Message retention in seconds, chosen at the ceremony.
    pub ttl_seconds: u64,
    /// Number of members: 2 for a two-person conversation, up to 8 for a group.
    pub members: u8,
    /// When the preferences were registered.
    pub created_at: DateTime<Utc>,
}

impl ConversationPrefs {
    /// Create new preferences with the given flags and TTL.
    pub fn new(notification_flags: u16, ttl_seconds: u64, members: u8) -> Self {
        Self {
            notification_flags,
            ttl_seconds,
            members,
            created_at: Utc::now(),
        }
    }

    /// Check if a specific notification flag is set.
    #[inline]
    pub const fn has_flag(&self, flag: u16) -> bool {
        (self.notification_flags & flag) != 0
    }

    /// Check if new message notifications are enabled.
    #[inline]
    pub const fn notify_new_message(&self) -> bool {
        self.has_flag(notification_flags::NOTIFY_NEW_MESSAGE)
    }

    /// Check if message expiring notifications are enabled.
    #[inline]
    pub const fn notify_message_expiring(&self) -> bool {
        self.has_flag(notification_flags::NOTIFY_MESSAGE_EXPIRING)
    }

    /// Check if message expired notifications are enabled.
    #[inline]
    pub const fn notify_message_expired(&self) -> bool {
        self.has_flag(notification_flags::NOTIFY_MESSAGE_EXPIRED)
    }

    /// Check if delivery failed notifications are enabled.
    #[inline]
    pub const fn notify_delivery_failed(&self) -> bool {
        self.has_flag(notification_flags::NOTIFY_DELIVERY_FAILED)
    }
}

/// Encrypted message blob stored temporarily.
#[derive(Debug, Clone)]
pub struct StoredBlob {
    /// Unique blob ID for deduplication and acknowledgment.
    pub id: Uuid,
    /// Client-provided sequence number (optional).
    pub sequence: Option<SequenceNumber>,
    /// Encrypted ciphertext (opaque to backend).
    pub ciphertext: Vec<u8>,
    /// When the blob was received.
    pub received_at: DateTime<Utc>,
    /// When the blob expires (automatic deletion).
    pub expires_at: DateTime<Utc>,
    /// Group member who sent it (anonymous index), for group conversations.
    pub sender: Option<u8>,
    /// Bit `n` set once group member `n` acknowledged the blob.
    pub acked_by: u8,
}

/// Registered device for push notifications.
#[derive(Debug, Clone)]
pub struct DeviceRegistration {
    /// APNS device token (hex string).
    pub device_token: String,
    /// Platform (ios, macos).
    pub platform: Platform,
    /// When the registration was created.
    pub registered_at: DateTime<Utc>,
    /// When the registration expires.
    pub expires_at: DateTime<Utc>,
}

/// Supported platforms for push notifications.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    #[default]
    Ios,
    Macos,
}

/// Burn flag indicating a conversation has been destroyed.
#[derive(Debug, Clone)]
pub struct BurnFlag {
    /// When the burn was initiated.
    pub burned_at: DateTime<Utc>,
    /// When the burn flag expires (cleanup).
    pub expires_at: DateTime<Utc>,
}

/// Cursor for message pagination.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cursor {
    /// Last seen blob ID.
    pub last_id: Option<Uuid>,
    /// Last seen sequence number.
    pub last_sequence: Option<SequenceNumber>,
    /// Timestamp for time-based cursors.
    pub since: Option<DateTime<Utc>>,
}

impl Cursor {
    /// Create an empty cursor (start from beginning).
    pub const fn empty() -> Self {
        Self {
            last_id: None,
            last_sequence: None,
            since: None,
        }
    }

    /// Encode cursor to URL-safe base64 string.
    pub fn encode(&self) -> String {
        let json = serde_json::to_string(self).unwrap_or_default();
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json)
    }

    /// Decode cursor from URL-safe base64 string.
    pub fn decode(s: &str) -> Option<Self> {
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(s)
            .ok()?;
        serde_json::from_slice(&bytes).ok()
    }
}

// =============================================================================
// API Request Models
// =============================================================================

/// Register conversation request.
///
/// Both ceremony participants call this after completing the QR exchange.
#[derive(Debug, Deserialize)]
pub struct RegisterConversationRequest {
    /// Conversation ID (64-char hex string derived from pad).
    pub conversation_id: ConversationId,
    /// SHA-256 hash of auth token (64-char hex string).
    pub auth_token_hash: String,
    /// SHA-256 hash of burn token (64-char hex string).
    pub burn_token_hash: String,
    /// Notification preferences (16-bit flags).
    #[serde(default = "default_notification_flags")]
    pub notification_flags: u16,
    /// Message TTL in seconds.
    #[serde(default = "default_ttl_seconds")]
    pub ttl_seconds: u64,
    /// Number of members (2 to 8). Group members are only anonymous indexes.
    #[serde(default = "default_members")]
    pub members: u8,
}

fn default_members() -> u8 {
    2
}

fn default_notification_flags() -> u16 {
    notification_flags::DEFAULT
}

fn default_ttl_seconds() -> u64 {
    300
}

/// Register device for push notifications.
#[derive(Debug, Deserialize)]
pub struct RegisterDeviceRequest {
    /// Conversation ID.
    pub conversation_id: ConversationId,
    /// APNS device token.
    pub device_token: String,
    /// Platform (defaults to iOS).
    #[serde(default)]
    pub platform: Platform,
}

/// Submit encrypted message.
#[derive(Debug, Deserialize)]
pub struct SubmitMessageRequest {
    /// Conversation ID.
    pub conversation_id: ConversationId,
    /// Base64-encoded ciphertext.
    pub ciphertext: String,
    /// Optional client sequence number.
    pub sequence: Option<SequenceNumber>,
    /// Group member index of the sender, for group conversations.
    #[serde(default)]
    pub sender: Option<u8>,
    /// Retention the conversation chose, sent by the apps with each message.
    #[serde(default)]
    pub ttl_seconds: Option<u64>,
}

/// Poll messages query parameters.
#[derive(Debug, Deserialize)]
pub struct PollMessagesQuery {
    /// Conversation ID.
    pub conversation_id: ConversationId,
    /// Pagination cursor (base64-encoded).
    pub cursor: Option<String>,
    /// Group member polling: skips its own messages and those it acknowledged.
    #[serde(default)]
    pub member: Option<u8>,
}

/// Burn conversation request.
#[derive(Debug, Deserialize)]
pub struct BurnConversationRequest {
    /// Conversation ID.
    pub conversation_id: ConversationId,
}

/// Burn status query parameters.
#[derive(Debug, Deserialize)]
pub struct BurnStatusQuery {
    /// Conversation ID.
    pub conversation_id: ConversationId,
}

/// Acknowledge message delivery.
#[derive(Debug, Deserialize)]
pub struct AckMessageRequest {
    /// Conversation ID.
    pub conversation_id: ConversationId,
    /// Blob IDs to acknowledge.
    pub blob_ids: Vec<Uuid>,
    /// Group member acknowledging: a group blob is deleted once every other
    /// member acknowledged it. Without it the blob is deleted at once.
    #[serde(default)]
    pub member: Option<u8>,
}

/// SSE stream query parameters.
#[derive(Debug, Deserialize)]
pub struct StreamQuery {
    /// Conversation ID.
    pub conversation_id: ConversationId,
}

// =============================================================================
// API Response Models
// =============================================================================

/// Register conversation response.
#[derive(Debug, Serialize)]
pub struct RegisterConversationResponse {
    pub success: bool,
}

/// Register device response.
#[derive(Debug, Serialize)]
pub struct RegisterDeviceResponse {
    pub success: bool,
}

/// Submit message response.
#[derive(Debug, Serialize)]
pub struct SubmitMessageResponse {
    pub accepted: bool,
    pub blob_id: Uuid,
    /// Server-calculated expiry time (for client timer synchronization).
    pub expires_at: DateTime<Utc>,
}

/// Poll messages response.
#[derive(Debug, Serialize)]
pub struct PollMessagesResponse {
    pub messages: Vec<MessageBlob>,
    pub next_cursor: Option<String>,
    pub burned: bool,
}

/// Message blob in API responses.
#[derive(Debug, Clone, Serialize)]
pub struct MessageBlob {
    pub id: Uuid,
    pub sequence: Option<SequenceNumber>,
    /// Base64-encoded ciphertext.
    pub ciphertext: String,
    pub received_at: DateTime<Utc>,
}

/// Burn conversation response.
#[derive(Debug, Serialize)]
pub struct BurnConversationResponse {
    pub accepted: bool,
}

/// Burn status response.
#[derive(Debug, Serialize)]
pub struct BurnStatusResponse {
    pub burned: bool,
    pub burned_at: Option<DateTime<Utc>>,
}

/// Acknowledge message response.
#[derive(Debug, Serialize)]
pub struct AckMessageResponse {
    pub acknowledged: usize,
}

/// Health check response.
#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub version: &'static str,
}

/// Response to opening a pad transfer.
#[derive(Debug, Serialize)]
pub struct CreateTransferResponse {
    pub transfer_id: String,
    pub receiver_token: String,
    pub sender_token: String,
    pub expires_in_secs: u64,
}

/// Error response.
#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub error: String,
    pub code: &'static str,
}

// =============================================================================
// SSE Event Models
// =============================================================================

/// Event sent over SSE stream.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StreamEvent {
    /// New message received.
    Message(MessageBlob),
    /// Message(s) acknowledged by receiver.
    Delivered {
        blob_ids: Vec<Uuid>,
        delivered_at: DateTime<Utc>,
    },
    /// Conversation has been burned.
    Burned { burned_at: DateTime<Utc> },
    /// Keep-alive ping.
    Ping,
}

/// Internal broadcast event (conversation_id + event).
#[derive(Debug, Clone)]
pub struct BroadcastEvent {
    pub conversation_id: ConversationId,
    pub event: StreamEvent,
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_encode_decode_roundtrip() {
        let cursor = Cursor {
            last_id: Some(Uuid::new_v4()),
            last_sequence: Some(42),
            since: Some(Utc::now()),
        };

        let encoded = cursor.encode();
        let decoded = Cursor::decode(&encoded).expect("decode failed");

        assert_eq!(cursor.last_id, decoded.last_id);
        assert_eq!(cursor.last_sequence, decoded.last_sequence);
    }

    #[test]
    fn cursor_decode_invalid_returns_none() {
        assert!(Cursor::decode("not-valid-base64!!!").is_none());
        assert!(Cursor::decode("").is_none());
    }

    #[test]
    fn notification_flags_work() {
        let prefs = ConversationPrefs::new(
            notification_flags::NOTIFY_NEW_MESSAGE | notification_flags::NOTIFY_MESSAGE_EXPIRING,
            300,
            2,
        );

        assert!(prefs.notify_new_message());
        assert!(prefs.notify_message_expiring());
        assert!(!prefs.notify_message_expired());
        assert!(!prefs.notify_delivery_failed());
    }

    #[test]
    fn platform_deserialize() {
        let ios: Platform = serde_json::from_str(r#""ios""#).unwrap();
        assert_eq!(ios, Platform::Ios);

        let macos: Platform = serde_json::from_str(r#""macos""#).unwrap();
        assert_eq!(macos, Platform::Macos);
    }
}
