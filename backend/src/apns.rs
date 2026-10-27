//! Apple Push Notification Service (APNS) integration.
//!
//! Sends silent push notifications to wake up iOS devices.
//! Best-effort delivery - failures are logged but not retried.

use crate::config::Config;
use crate::models::DeviceRegistration;
use a2::{
    Client, ClientConfig, DefaultNotificationBuilder, Endpoint, NotificationBuilder,
    NotificationOptions, Priority, PushType,
};
use std::fs::File;
use std::io::Read;
use std::sync::Arc;
use tracing::{debug, error, warn};

/// APNS client wrapper
pub struct ApnsClient {
    client: Option<Client>,
    bundle_id: String,
}

impl ApnsClient {
    /// Create a new APNS client from configuration
    pub fn new(config: &Config) -> Self {
        if !config.apns_configured() {
            warn!("APNS not configured - push notifications disabled");
            return Self {
                client: None,
                bundle_id: String::new(),
            };
        }

        let team_id = config.apns_team_id.as_ref().unwrap();
        let key_id = config.apns_key_id.as_ref().unwrap();
        let key_path = config.apns_key_path.as_ref().unwrap();
        let bundle_id = config.apns_bundle_id.as_ref().unwrap().clone();

        // Read the private key
        let mut key_file = match File::open(key_path) {
            Ok(f) => f,
            Err(e) => {
                error!(path = %key_path, error = %e, "Failed to open APNS key file");
                return Self {
                    client: None,
                    bundle_id,
                };
            }
        };

        let mut key_pem = Vec::new();
        if let Err(e) = key_file.read_to_end(&mut key_pem) {
            error!(error = %e, "Failed to read APNS key file");
            return Self {
                client: None,
                bundle_id,
            };
        }

        let endpoint = if config.apns_sandbox {
            Endpoint::Sandbox
        } else {
            Endpoint::Production
        };

        let client_config = ClientConfig::new(endpoint);

        let client = match Client::token(&mut &key_pem[..], key_id, team_id, client_config) {
            Ok(c) => Some(c),
            Err(e) => {
                error!(error = %e, "Failed to create APNS client");
                None
            }
        };

        if client.is_some() {
            debug!(sandbox = config.apns_sandbox, "APNS client initialized");
        }

        Self { client, bundle_id }
    }

    /// Send silent push notification to a device (best-effort)
    pub async fn send_silent_push(
        &self,
        device_token: &str,
        conversation_id: Option<&str>,
    ) -> bool {
        let client = match &self.client {
            Some(c) => c,
            None => return false,
        };

        // Build silent notification
        let options = NotificationOptions {
            apns_priority: Some(Priority::Normal),
            apns_topic: Some(&self.bundle_id),
            apns_push_type: Some(PushType::Background),
            ..Default::default()
        };

        let mut payload = DefaultNotificationBuilder::new()
            .set_content_available()
            .build(device_token, options);

        // Add conversation_id as custom data if provided
        if let Some(conv_id) = conversation_id {
            if let Err(e) = payload.add_custom_data("conversation_id", &conv_id) {
                debug!(error = %e, "Failed to add conversation_id to payload");
            }
        }

        match client.send(payload).await {
            Ok(response) => {
                debug!(
                    status = ?response.code,
                    "Sent silent push"
                );
                response.code == 200
            }
            Err(e) => {
                // Log error but don't fail - best effort delivery
                debug!(error = %e, "Failed to send push notification");
                false
            }
        }
    }

    /// Send silent push to multiple devices (best-effort, parallel)
    pub async fn send_to_devices(
        &self,
        devices: &[DeviceRegistration],
        conversation_id: Option<&str>,
    ) {
        if self.client.is_none() || devices.is_empty() {
            return;
        }

        // Send to all devices in parallel (best-effort)
        let send_futures: Vec<_> = devices
            .iter()
            .map(|d| self.send_silent_push(&d.device_token, conversation_id))
            .collect();

        let results = futures::future::join_all(send_futures).await;

        let success_count = results.iter().filter(|&&r| r).count();
        debug!(
            total = devices.len(),
            success = success_count,
            "Sent push notifications"
        );
    }

    /// Check if APNS is enabled
    pub fn is_enabled(&self) -> bool {
        self.client.is_some()
    }
}

/// Create a shared APNS client
pub fn create_client(config: &Config) -> Arc<ApnsClient> {
    Arc::new(ApnsClient::new(config))
}
