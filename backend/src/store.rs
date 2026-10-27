//! In-memory ephemeral store with TTL-based cleanup.
//!
//! All data is automatically deleted when TTL expires.
//! No persistence - data is lost on restart (by design).

use crate::config::Config;
use crate::models::{
    BurnFlag, ConversationId, ConversationPrefs, DeviceRegistration, Platform, SequenceNumber,
    StoredBlob,
};
use chrono::Utc;
use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info};
use uuid::Uuid;

// =============================================================================
// Store
// =============================================================================

/// Thread-safe in-memory store for ephemeral message relay.
#[derive(Clone)]
pub struct Store {
    /// Encrypted blobs per conversation.
    blobs: Arc<DashMap<ConversationId, Vec<StoredBlob>>>,
    /// Burn flags per conversation.
    burns: Arc<DashMap<ConversationId, BurnFlag>>,
    /// Device registrations per conversation.
    devices: Arc<DashMap<ConversationId, Vec<DeviceRegistration>>>,
    /// Conversation notification preferences.
    prefs: Arc<DashMap<ConversationId, ConversationPrefs>>,
    /// Configuration.
    config: Arc<Config>,
    /// Aggregate metrics (no PII).
    metrics: Arc<RwLock<StoreMetrics>>,
}

/// Aggregate metrics (no PII, no per-conversation data).
#[derive(Debug, Default, Clone)]
pub struct StoreMetrics {
    pub total_blobs_stored: u64,
    pub total_blobs_expired: u64,
    pub total_burns: u64,
    pub total_registrations: u64,
}

impl Store {
    /// Create a new empty store with the given configuration.
    pub fn new(config: Config) -> Self {
        Self {
            blobs: Arc::new(DashMap::new()),
            burns: Arc::new(DashMap::new()),
            devices: Arc::new(DashMap::new()),
            prefs: Arc::new(DashMap::new()),
            config: Arc::new(config),
            metrics: Arc::new(RwLock::new(StoreMetrics::default())),
        }
    }

    /// Start background TTL cleanup task.
    pub fn start_cleanup_task(self: Arc<Self>) {
        let store = self.clone();
        let interval = self.config.cleanup_interval;

        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(interval);
            loop {
                ticker.tick().await;
                store.cleanup_expired().await;
            }
        });

        info!(
            interval_secs = interval.as_secs(),
            "Started TTL cleanup task"
        );
    }

    // =========================================================================
    // Blob Operations
    // =========================================================================

    /// Store an encrypted blob for a conversation.
    ///
    /// Kept for the retention the message carries, or else the one the
    /// conversation registered, capped by the server; 5 minutes without
    /// either. Deleted on expiry or once acknowledged (by every other member
    /// in a group). Returns its ID and expiry.
    pub async fn store_blob(
        &self,
        conversation_id: ConversationId,
        ciphertext: Vec<u8>,
        sequence: Option<SequenceNumber>,
        sender: Option<u8>,
        ttl_seconds: Option<u64>,
    ) -> Result<(Uuid, chrono::DateTime<Utc>), StoreError> {
        if self.is_burned(&conversation_id) {
            return Err(StoreError::ConversationBurned);
        }

        if ciphertext.len() > self.config.max_ciphertext_size {
            return Err(StoreError::PayloadTooLarge);
        }

        let now = Utc::now();
        let ttl = self.blob_ttl(&conversation_id, ttl_seconds);
        let expires_at = now + chrono::Duration::from_std(ttl).expect("valid duration");

        let blob = StoredBlob {
            id: Uuid::new_v4(),
            sequence,
            ciphertext,
            received_at: now,
            expires_at,
            sender,
            acked_by: 0,
        };

        let blob_id = blob.id;

        // Store blob with queue limit enforcement
        let mut entry = self.blobs.entry(conversation_id).or_default();
        if entry.value().len() >= self.config.max_blobs_per_conversation {
            return Err(StoreError::QueueFull);
        }
        entry.value_mut().push(blob);

        // Update metrics
        self.metrics.write().await.total_blobs_stored += 1;

        debug!(blob_id = %blob_id, ttl_secs = ttl.as_secs(), "Stored blob");
        Ok((blob_id, expires_at))
    }

    /// Retention for a blob: the message's, else the conversation's, capped.
    fn blob_ttl(
        &self,
        conversation_id: &ConversationId,
        ttl_seconds: Option<u64>,
    ) -> std::time::Duration {
        ttl_seconds
            .or_else(|| self.prefs.get(conversation_id).map(|p| p.ttl_seconds))
            .map(|secs| std::time::Duration::from_secs(secs.max(1)))
            .unwrap_or(self.config.blob_ttl)
            .min(self.config.max_message_ttl)
    }

    /// Get blobs for a conversation, optionally filtered by cursor.
    ///
    /// A group `member` does not get its own blobs back, nor those it already
    /// acknowledged.
    pub fn get_blobs(
        &self,
        conversation_id: &ConversationId,
        cursor: Option<&crate::models::Cursor>,
        member: Option<u8>,
    ) -> (Vec<StoredBlob>, Option<crate::models::Cursor>) {
        use crate::models::Cursor;

        if self.is_burned(conversation_id) {
            return (vec![], None);
        }

        let now = Utc::now();

        let Some(entry) = self.blobs.get(conversation_id) else {
            return (vec![], None);
        };

        // Filter expired and apply cursor
        let filtered: Vec<StoredBlob> = entry
            .value()
            .iter()
            .filter(|b| b.expires_at > now)
            .filter(|b| {
                member.map_or(true, |m| {
                    b.sender != Some(m) && b.acked_by & member_bit(m) == 0
                })
            })
            .filter(|b| {
                cursor.map_or(true, |c| {
                    if let Some(last_id) = c.last_id {
                        return b.id != last_id;
                    }
                    if let Some(since) = c.since {
                        return b.received_at > since;
                    }
                    true
                })
            })
            .cloned()
            .collect();

        // Generate next cursor from last blob
        let next_cursor = filtered.last().map(|b| Cursor {
            last_id: Some(b.id),
            last_sequence: b.sequence,
            since: Some(b.received_at),
        });

        (filtered, next_cursor)
    }

    /// Acknowledge a blob.
    ///
    /// Without a `member`, or in a two-person conversation, the blob is
    /// deleted at once. In a group, the member is recorded and the blob is
    /// deleted once every member except its sender acknowledged it.
    /// Returns `true` if the blob was found.
    pub fn ack_blob(
        &self,
        conversation_id: &ConversationId,
        blob_id: &Uuid,
        member: Option<u8>,
    ) -> bool {
        let members = self
            .prefs
            .get(conversation_id)
            .map(|p| p.members)
            .unwrap_or(2);
        let Some(member) = member.filter(|_| members > 2) else {
            return self.delete_blob(conversation_id, blob_id);
        };
        let Some(mut entry) = self.blobs.get_mut(conversation_id) else {
            return false;
        };
        let Some(blob) = entry.value_mut().iter_mut().find(|b| b.id == *blob_id) else {
            return false;
        };
        blob.acked_by |= member_bit(member);
        let everyone: u8 = if members >= 8 {
            u8::MAX
        } else {
            (1u8 << members) - 1
        };
        let needed = everyone & !blob.sender.map_or(0, member_bit);
        if blob.acked_by & needed == needed {
            entry.value_mut().retain(|b| b.id != *blob_id);
            debug!(blob_id = %blob_id, "Deleted group blob after every member acknowledged");
        }
        true
    }

    /// Delete a specific blob by ID.
    ///
    /// Returns `true` if the blob was found and deleted.
    pub fn delete_blob(&self, conversation_id: &ConversationId, blob_id: &Uuid) -> bool {
        if let Some(mut entry) = self.blobs.get_mut(conversation_id) {
            let before = entry.value().len();
            entry.value_mut().retain(|b| b.id != *blob_id);
            let deleted = entry.value().len() < before;
            if deleted {
                debug!(blob_id = %blob_id, "Deleted blob on ACK");
            }
            return deleted;
        }
        false
    }

    // =========================================================================
    // Device Registration
    // =========================================================================

    /// Register a device for push notifications.
    pub async fn register_device(
        &self,
        conversation_id: ConversationId,
        device_token: String,
        platform: Platform,
    ) -> Result<(), StoreError> {
        if self.is_burned(&conversation_id) {
            return Err(StoreError::ConversationBurned);
        }

        let now = Utc::now();
        let expires_at =
            now + chrono::Duration::from_std(self.config.device_token_ttl).expect("valid duration");

        let registration = DeviceRegistration {
            device_token: device_token.clone(),
            platform,
            registered_at: now,
            expires_at,
        };

        let mut entry = self.devices.entry(conversation_id).or_default();
        // Remove existing registration with same token (refresh)
        entry.value_mut().retain(|d| d.device_token != device_token);
        entry.value_mut().push(registration);

        self.metrics.write().await.total_registrations += 1;
        debug!("Registered device for push notifications");
        Ok(())
    }

    /// Get valid device tokens for a conversation.
    pub fn get_device_tokens(&self, conversation_id: &ConversationId) -> Vec<DeviceRegistration> {
        let now = Utc::now();
        self.devices
            .get(conversation_id)
            .map(|entry| {
                entry
                    .value()
                    .iter()
                    .filter(|d| d.expires_at > now)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }

    // =========================================================================
    // Burn Operations
    // =========================================================================

    /// Burn a conversation (delete all data, set burn flag).
    pub async fn burn(&self, conversation_id: ConversationId) {
        // Remove all data immediately
        self.blobs.remove(&conversation_id);
        self.devices.remove(&conversation_id);
        self.prefs.remove(&conversation_id);

        // Set burn flag with TTL
        let now = Utc::now();
        let burn_flag = BurnFlag {
            burned_at: now,
            expires_at: now
                + chrono::Duration::from_std(self.config.burn_ttl).expect("valid duration"),
        };
        self.burns.insert(conversation_id, burn_flag);

        self.metrics.write().await.total_burns += 1;
        debug!("Burned conversation");
    }

    /// Check if a conversation is burned.
    pub fn is_burned(&self, conversation_id: &ConversationId) -> bool {
        let now = Utc::now();
        self.burns
            .get(conversation_id)
            .map(|entry| entry.expires_at > now)
            .unwrap_or(false)
    }

    /// Get burn status for a conversation.
    pub fn get_burn_status(&self, conversation_id: &ConversationId) -> Option<BurnFlag> {
        let now = Utc::now();
        self.burns
            .get(conversation_id)
            .filter(|entry| entry.expires_at > now)
            .map(|entry| entry.value().clone())
    }

    // =========================================================================
    // Preferences
    // =========================================================================

    /// Store notification preferences for a conversation.
    pub fn store_prefs(
        &self,
        conversation_id: ConversationId,
        notification_flags: u16,
        ttl_seconds: u64,
        members: u8,
    ) {
        let prefs = ConversationPrefs::new(notification_flags, ttl_seconds, members);
        self.prefs.insert(conversation_id, prefs);
        debug!("Stored conversation preferences");
    }

    /// Get notification preferences for a conversation.
    pub fn get_prefs(&self, conversation_id: &ConversationId) -> Option<ConversationPrefs> {
        self.prefs.get(conversation_id).map(|e| e.value().clone())
    }

    /// Get all conversations with expiry notifications enabled.
    pub fn get_conversations_with_expiry_notifications(&self) -> Vec<ConversationId> {
        self.prefs
            .iter()
            .filter(|entry| entry.value().notify_message_expiring())
            .map(|entry| entry.key().clone())
            .collect()
    }

    // =========================================================================
    // Cleanup
    // =========================================================================

    /// Clean up expired data.
    async fn cleanup_expired(&self) {
        let now = Utc::now();
        let mut expired_blobs = 0u64;

        // Clean up expired blobs
        for mut entry in self.blobs.iter_mut() {
            let before = entry.value().len();
            entry.value_mut().retain(|b| b.expires_at > now);
            expired_blobs += (before - entry.value().len()) as u64;
        }
        self.blobs.retain(|_, v| !v.is_empty());

        // Clean up expired burn flags
        self.burns.retain(|_, v| v.expires_at > now);

        // Clean up expired device registrations
        for mut entry in self.devices.iter_mut() {
            entry.value_mut().retain(|d| d.expires_at > now);
        }
        self.devices.retain(|_, v| !v.is_empty());

        if expired_blobs > 0 {
            self.metrics.write().await.total_blobs_expired += expired_blobs;
            debug!(expired_blobs, "Cleaned up expired data");
        }
    }

    /// Get aggregate metrics (no PII).
    pub async fn get_metrics(&self) -> StoreMetrics {
        self.metrics.read().await.clone()
    }
}

// =============================================================================
// Errors
// =============================================================================

/// Store operation errors.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("conversation has been burned")]
    ConversationBurned,

    #[error("payload too large")]
    PayloadTooLarge,

    #[error("message queue full")]
    QueueFull,

    #[error("database error: {0}")]
    DatabaseError(String),
}

// =============================================================================
// Tests
// =============================================================================

/// Bit of a group member in [`StoredBlob::acked_by`].
fn member_bit(member: u8) -> u8 {
    1u8.checked_shl(u32::from(member)).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn test_config() -> Config {
        Config {
            bind_addr: "127.0.0.1".to_string(),
            port: 8080,
            blob_ttl: std::time::Duration::from_secs(300),
            max_message_ttl: std::time::Duration::from_secs(7 * 24 * 3600),
            burn_ttl: std::time::Duration::from_secs(300),
            device_token_ttl: std::time::Duration::from_secs(3600),
            max_ciphertext_size: 8192,
            max_blobs_per_conversation: 50,
            cleanup_interval: std::time::Duration::from_secs(10),
            apns_team_id: None,
            apns_key_id: None,
            apns_key_path: None,
            apns_bundle_id: None,
            apns_sandbox: true,
        }
    }

    #[tokio::test]
    async fn store_and_retrieve_blob() {
        let store = Store::new(test_config());
        let conv_id = "a".repeat(64);
        let ciphertext = vec![1, 2, 3, 4];

        let (blob_id, _) = store
            .store_blob(conv_id.clone(), ciphertext.clone(), Some(1), None, None)
            .await
            .expect("store failed");

        let (blobs, cursor) = store.get_blobs(&conv_id, None, None);
        assert_eq!(blobs.len(), 1);
        assert_eq!(blobs[0].id, blob_id);
        assert_eq!(blobs[0].ciphertext, ciphertext);
        assert!(cursor.is_some());
    }

    #[tokio::test]
    async fn delete_blob_on_ack() {
        let store = Store::new(test_config());
        let conv_id = "b".repeat(64);

        let (blob_id, _) = store
            .store_blob(conv_id.clone(), vec![1], None, None, None)
            .await
            .unwrap();

        assert!(store.ack_blob(&conv_id, &blob_id, None));
        assert!(!store.delete_blob(&conv_id, &blob_id)); // Already deleted

        let (blobs, _) = store.get_blobs(&conv_id, None, None);
        assert!(blobs.is_empty());
    }

    #[tokio::test]
    async fn burn_removes_all_data() {
        let store = Store::new(test_config());
        let conv_id = "c".repeat(64);

        store
            .store_blob(conv_id.clone(), vec![1], None, None, None)
            .await
            .unwrap();
        store.store_prefs(conv_id.clone(), 0, 300, 2);

        store.burn(conv_id.clone()).await;

        assert!(store.is_burned(&conv_id));
        let (blobs, _) = store.get_blobs(&conv_id, None, None);
        assert!(blobs.is_empty());
    }

    #[tokio::test]
    async fn queue_full_error() {
        let mut config = test_config();
        config.max_blobs_per_conversation = 2;
        let store = Store::new(config);
        let conv_id = "d".repeat(64);

        store
            .store_blob(conv_id.clone(), vec![1], None, None, None)
            .await
            .unwrap();
        store
            .store_blob(conv_id.clone(), vec![2], None, None, None)
            .await
            .unwrap();

        let result = store
            .store_blob(conv_id.clone(), vec![3], None, None, None)
            .await;
        assert!(matches!(result, Err(StoreError::QueueFull)));
    }

    #[tokio::test]
    async fn payload_too_large_error() {
        let mut config = test_config();
        config.max_ciphertext_size = 10;
        let store = Store::new(config);
        let conv_id = "e".repeat(64);

        let result = store
            .store_blob(conv_id, vec![0; 100], None, None, None)
            .await;
        assert!(matches!(result, Err(StoreError::PayloadTooLarge)));
    }

    #[tokio::test]
    async fn burned_conversation_rejects_operations() {
        let store = Store::new(test_config());
        let conv_id = "f".repeat(64);

        store.burn(conv_id.clone()).await;

        let result = store
            .store_blob(conv_id.clone(), vec![1], None, None, None)
            .await;
        assert!(matches!(result, Err(StoreError::ConversationBurned)));

        let result = store
            .register_device(conv_id, "token".to_string(), Platform::Ios)
            .await;
        assert!(matches!(result, Err(StoreError::ConversationBurned)));
    }

    #[tokio::test]
    async fn group_blob_is_kept_until_every_other_member_acked() {
        let store = Store::new(test_config());
        let conv_id = "g".repeat(64);
        store.store_prefs(conv_id.clone(), 0, 3600, 3);

        // Member 0 sends; members 1 and 2 must both acknowledge
        let (blob_id, _) = store
            .store_blob(conv_id.clone(), vec![1], None, Some(0), None)
            .await
            .unwrap();

        // The sender does not get its own message back
        assert!(store.get_blobs(&conv_id, None, Some(0)).0.is_empty());
        assert_eq!(store.get_blobs(&conv_id, None, Some(1)).0.len(), 1);

        assert!(store.ack_blob(&conv_id, &blob_id, Some(1)));
        // Member 1 no longer sees it, member 2 still does
        assert!(store.get_blobs(&conv_id, None, Some(1)).0.is_empty());
        assert_eq!(store.get_blobs(&conv_id, None, Some(2)).0.len(), 1);

        assert!(store.ack_blob(&conv_id, &blob_id, Some(2)));
        assert!(store.get_blobs(&conv_id, None, None).0.is_empty());
        assert!(!store.ack_blob(&conv_id, &blob_id, Some(2)));
    }

    #[tokio::test]
    async fn eight_member_group_acks() {
        let store = Store::new(test_config());
        let conv_id = "h".repeat(64);
        store.store_prefs(conv_id.clone(), 0, 3600, 8);
        let (blob_id, _) = store
            .store_blob(conv_id.clone(), vec![1], None, Some(7), None)
            .await
            .unwrap();
        for member in 0..7 {
            assert_eq!(
                store.get_blobs(&conv_id, None, None).0.len(),
                1,
                "before member {member}"
            );
            assert!(store.ack_blob(&conv_id, &blob_id, Some(member)));
        }
        assert!(store.get_blobs(&conv_id, None, None).0.is_empty());
    }

    #[tokio::test]
    async fn two_person_ack_deletes_at_once() {
        let store = Store::new(test_config());
        let conv_id = "i".repeat(64);
        store.store_prefs(conv_id.clone(), 0, 3600, 2);
        let (blob_id, _) = store
            .store_blob(conv_id.clone(), vec![1], None, None, None)
            .await
            .unwrap();
        assert!(store.ack_blob(&conv_id, &blob_id, Some(1)));
        assert!(store.get_blobs(&conv_id, None, None).0.is_empty());
    }

    #[tokio::test]
    async fn retention_follows_the_conversation_and_is_capped() {
        let store = Store::new(test_config());
        let day = "j".repeat(64);
        let year = "k".repeat(64);
        let unregistered = "l".repeat(64);
        store.store_prefs(day.clone(), 0, 24 * 3600, 2);
        store.store_prefs(year.clone(), 0, 365 * 24 * 3600, 2);

        let now = Utc::now();
        let (_, day_expiry) = store
            .store_blob(day, vec![1], None, None, None)
            .await
            .unwrap();
        let (_, year_expiry) = store
            .store_blob(year, vec![1], None, None, None)
            .await
            .unwrap();
        let (_, default_expiry) = store
            .store_blob(unregistered.clone(), vec![1], None, None, None)
            .await
            .unwrap();
        let (_, message_expiry) = store
            .store_blob(unregistered, vec![1], None, None, Some(3600))
            .await
            .unwrap();

        // Minutes from now, within a minute of slack
        let minutes = |t: chrono::DateTime<Utc>| (t - now).num_minutes();
        assert!((minutes(day_expiry) - 24 * 60).abs() <= 1);
        assert!(
            (minutes(year_expiry) - 7 * 24 * 60).abs() <= 1,
            "capped at 7 days"
        );
        assert!(
            (minutes(default_expiry) - 5).abs() <= 1,
            "5 minutes without retention"
        );
        assert!(
            (minutes(message_expiry) - 60).abs() <= 1,
            "the message's retention wins"
        );
    }
}
