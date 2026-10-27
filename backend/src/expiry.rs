//! Expiry notification worker.
//!
//! Background task that monitors message TTL and sends notifications
//! for messages about to expire, based on notification flags.

use crate::apns::ApnsClient;
use crate::handlers::AppState;
use crate::models::notification_flags;
use chrono::{Duration, Utc};
use std::collections::HashSet;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info, warn};
use uuid::Uuid;

/// Tracks which expiry notifications have been sent to avoid duplicates
#[derive(Default)]
struct ExpiryTracker {
    /// Blob IDs for which 5-min warning was sent
    warned_5min: HashSet<Uuid>,
    /// Blob IDs for which 1-min warning was sent
    warned_1min: HashSet<Uuid>,
    /// Blob IDs for which expiry notification was sent
    expired: HashSet<Uuid>,
}

impl ExpiryTracker {
    fn cleanup_old(&mut self, valid_ids: &HashSet<Uuid>) {
        self.warned_5min.retain(|id| valid_ids.contains(id));
        self.warned_1min.retain(|id| valid_ids.contains(id));
        self.expired.retain(|id| valid_ids.contains(id));
    }
}

/// Expiry notification worker
pub struct ExpiryWorker {
    state: AppState,
    apns: Arc<ApnsClient>,
    tracker: Arc<RwLock<ExpiryTracker>>,
    /// Check interval (default 30 seconds)
    check_interval: std::time::Duration,
}

impl ExpiryWorker {
    pub fn new(state: AppState, apns: Arc<ApnsClient>) -> Self {
        Self {
            state,
            apns,
            tracker: Arc::new(RwLock::new(ExpiryTracker::default())),
            check_interval: std::time::Duration::from_secs(30),
        }
    }

    /// Start the background worker
    pub fn start(self: Arc<Self>) {
        let worker = self.clone();
        tokio::spawn(async move {
            info!(
                interval_secs = worker.check_interval.as_secs(),
                "Started expiry notification worker"
            );

            let mut ticker = tokio::time::interval(worker.check_interval);
            loop {
                ticker.tick().await;
                if let Err(e) = worker.check_expiring_messages().await {
                    warn!(error = ?e, "Error checking expiring messages");
                }
            }
        });
    }

    /// Check for messages near expiry and send notifications
    async fn check_expiring_messages(
        &self,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let now = Utc::now();
        let five_min = Duration::minutes(5);
        let one_min = Duration::minutes(1);

        // Get all conversations with expiry notifications enabled
        let conversations = self
            .state
            .store
            .get_conversations_with_expiry_notifications();

        let mut active_blob_ids = HashSet::new();

        for conversation_id in conversations {
            // Get notification preferences
            let prefs = match self.state.store.get_prefs(&conversation_id) {
                Some(p) => p,
                None => continue,
            };

            let notify_expiring =
                (prefs.notification_flags & notification_flags::NOTIFY_MESSAGE_EXPIRING) != 0;
            let notify_expired =
                (prefs.notification_flags & notification_flags::NOTIFY_MESSAGE_EXPIRED) != 0;

            if !notify_expiring && !notify_expired {
                continue;
            }

            // Get blobs for this conversation
            let (blobs, _) = self.state.store.get_blobs(&conversation_id, None, None);

            for blob in blobs {
                active_blob_ids.insert(blob.id);

                let time_until_expiry = blob.expires_at - now;

                // Check 5-minute warning
                if notify_expiring && time_until_expiry <= five_min && time_until_expiry > one_min {
                    let mut tracker = self.tracker.write().await;
                    if !tracker.warned_5min.contains(&blob.id) {
                        tracker.warned_5min.insert(blob.id);
                        drop(tracker);

                        debug!(
                            blob_id = %blob.id,
                            minutes_left = time_until_expiry.num_minutes(),
                            "Sending 5-minute expiry warning"
                        );

                        self.send_expiry_notification(&conversation_id, "expiring_5min")
                            .await;
                    }
                }

                // Check 1-minute warning
                if notify_expiring
                    && time_until_expiry <= one_min
                    && time_until_expiry > Duration::zero()
                {
                    let mut tracker = self.tracker.write().await;
                    if !tracker.warned_1min.contains(&blob.id) {
                        tracker.warned_1min.insert(blob.id);
                        drop(tracker);

                        debug!(
                            blob_id = %blob.id,
                            seconds_left = time_until_expiry.num_seconds(),
                            "Sending 1-minute expiry warning"
                        );

                        self.send_expiry_notification(&conversation_id, "expiring_1min")
                            .await;
                    }
                }

                // Check if expired (for "expired" notification)
                if notify_expired && time_until_expiry <= Duration::zero() {
                    let mut tracker = self.tracker.write().await;
                    if !tracker.expired.contains(&blob.id) {
                        tracker.expired.insert(blob.id);
                        drop(tracker);

                        debug!(
                            blob_id = %blob.id,
                            "Sending message expired notification"
                        );

                        self.send_expiry_notification(&conversation_id, "expired")
                            .await;
                    }
                }
            }
        }

        // Cleanup tracker (remove entries for blobs that no longer exist)
        let mut tracker = self.tracker.write().await;
        tracker.cleanup_old(&active_blob_ids);

        Ok(())
    }

    /// Send an expiry notification to devices registered for a conversation
    async fn send_expiry_notification(&self, conversation_id: &str, notification_type: &str) {
        let devices = self
            .state
            .store
            .get_device_tokens(&conversation_id.to_string());

        if devices.is_empty() {
            return;
        }

        debug!(
            notification_type = notification_type,
            device_count = devices.len(),
            "Sending expiry notification"
        );

        // Send push notification (best-effort)
        let apns = self.apns.clone();
        let devices = devices.clone();
        let conv_id = conversation_id.to_string();
        tokio::spawn(async move {
            apns.send_to_devices(&devices, Some(&conv_id)).await;
        });
    }
}
