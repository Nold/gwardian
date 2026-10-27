//! Server configuration loaded from environment variables.
//!
//! All configuration is loaded at startup. No secrets are logged.
//!
//! # Environment Variables
//!
//! | Variable | Default | Description |
//! |----------|---------|-------------|
//! | `BIND_ADDR` | `0.0.0.0` | Server bind address |
//! | `PORT` | `8080` | Server port |
//! | `BURN_TTL_SECS` | `300` | Burn flag TTL |
//! | `DEVICE_TOKEN_TTL_SECS` | `86400` | Device registration TTL |
//! | `MAX_CIPHERTEXT_SIZE` | `8192` | Max ciphertext size (bytes) |
//! | `MAX_BLOBS_PER_CONVERSATION` | `50` | Max queued messages |
//! | `CLEANUP_INTERVAL_SECS` | `10` | TTL cleanup interval |
//! | `MAX_MESSAGE_TTL_SECS` | `604800` | Longest retention a conversation may ask for (7 days) |
//! | `APNS_TEAM_ID` | - | Apple team ID |
//! | `APNS_KEY_ID` | - | APNS key ID |
//! | `APNS_KEY_PATH` | - | Path to .p8 key file |
//! | `APNS_BUNDLE_ID` | - | App bundle identifier |
//! | `APNS_SANDBOX` | `true` | Use sandbox environment |

use std::time::Duration;

/// Message TTL for conversations that registered no retention (5 minutes).
pub const MESSAGE_TTL: Duration = Duration::from_secs(300);

/// Largest group a conversation may register (members are numbered 0 to 7).
pub const MAX_GROUP_MEMBERS: u8 = 8;

/// Default values as constants for clarity.
mod defaults {
    use std::time::Duration;

    pub const BIND_ADDR: &str = "0.0.0.0";
    pub const PORT: u16 = 8080;
    pub const BURN_TTL: Duration = Duration::from_secs(300);
    pub const DEVICE_TOKEN_TTL: Duration = Duration::from_secs(24 * 3600);
    pub const MAX_CIPHERTEXT_SIZE: usize = 8 * 1024;
    pub const MAX_BLOBS_PER_CONVERSATION: usize = 50;
    pub const CLEANUP_INTERVAL: Duration = Duration::from_secs(10);
    pub const MAX_MESSAGE_TTL: Duration = Duration::from_secs(7 * 24 * 3600);
}

/// Server configuration.
#[derive(Debug, Clone)]
pub struct Config {
    // === Network ===
    /// Server bind address.
    pub bind_addr: String,
    /// Server port.
    pub port: u16,

    // === TTL Configuration ===
    /// TTL for blobs of conversations that registered no retention.
    pub blob_ttl: Duration,
    /// Cap on the retention a conversation registers.
    pub max_message_ttl: Duration,
    /// TTL for burn flags.
    pub burn_ttl: Duration,
    /// TTL for device registrations.
    pub device_token_ttl: Duration,

    // === Limits ===
    /// Maximum ciphertext size in bytes.
    pub max_ciphertext_size: usize,
    /// Maximum queued blobs per conversation.
    pub max_blobs_per_conversation: usize,
    /// Interval between TTL cleanup runs.
    pub cleanup_interval: Duration,

    // === APNS Configuration ===
    /// Apple team ID.
    pub apns_team_id: Option<String>,
    /// APNS key ID.
    pub apns_key_id: Option<String>,
    /// Path to APNS private key (.p8 file).
    pub apns_key_path: Option<String>,
    /// App bundle identifier.
    pub apns_bundle_id: Option<String>,
    /// Use APNS sandbox (development) environment.
    pub apns_sandbox: bool,
}

impl Config {
    /// Load configuration from environment variables.
    pub fn from_env() -> Self {
        Self {
            bind_addr: env_or("BIND_ADDR", defaults::BIND_ADDR.to_string()),
            port: env_parse("PORT", defaults::PORT),
            blob_ttl: MESSAGE_TTL,
            max_message_ttl: Duration::from_secs(env_parse(
                "MAX_MESSAGE_TTL_SECS",
                defaults::MAX_MESSAGE_TTL.as_secs(),
            )),
            burn_ttl: Duration::from_secs(env_parse("BURN_TTL_SECS", defaults::BURN_TTL.as_secs())),
            device_token_ttl: Duration::from_secs(env_parse(
                "DEVICE_TOKEN_TTL_SECS",
                defaults::DEVICE_TOKEN_TTL.as_secs(),
            )),
            max_ciphertext_size: env_parse("MAX_CIPHERTEXT_SIZE", defaults::MAX_CIPHERTEXT_SIZE),
            max_blobs_per_conversation: env_parse(
                "MAX_BLOBS_PER_CONVERSATION",
                defaults::MAX_BLOBS_PER_CONVERSATION,
            ),
            cleanup_interval: Duration::from_secs(env_parse(
                "CLEANUP_INTERVAL_SECS",
                defaults::CLEANUP_INTERVAL.as_secs(),
            )),
            apns_team_id: std::env::var("APNS_TEAM_ID").ok(),
            apns_key_id: std::env::var("APNS_KEY_ID").ok(),
            apns_key_path: std::env::var("APNS_KEY_PATH").ok(),
            apns_bundle_id: std::env::var("APNS_BUNDLE_ID").ok(),
            apns_sandbox: env_bool("APNS_SANDBOX", true),
        }
    }

    /// Check if APNS is fully configured.
    pub fn apns_configured(&self) -> bool {
        self.apns_team_id.is_some()
            && self.apns_key_id.is_some()
            && self.apns_key_path.is_some()
            && self.apns_bundle_id.is_some()
    }
}

impl Default for Config {
    fn default() -> Self {
        Self::from_env()
    }
}

/// Get environment variable or default.
fn env_or(key: &str, default: String) -> String {
    std::env::var(key).unwrap_or(default)
}

/// Parse environment variable or use default.
fn env_parse<T: std::str::FromStr>(key: &str, default: T) -> T {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Parse boolean environment variable (accepts "true", "1", "yes").
fn env_bool(key: &str, default: bool) -> bool {
    std::env::var(key)
        .map(|v| matches!(v.to_lowercase().as_str(), "true" | "1" | "yes"))
        .unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_is_valid() {
        // Clear any env vars that might interfere
        std::env::remove_var("BIND_ADDR");
        std::env::remove_var("PORT");

        let config = Config::from_env();

        assert_eq!(config.bind_addr, "0.0.0.0");
        assert_eq!(config.port, 8080);
        assert_eq!(config.blob_ttl, MESSAGE_TTL);
        assert_eq!(config.max_ciphertext_size, 8 * 1024);
        assert!(!config.apns_configured());
    }

    #[test]
    fn env_parsing_works() {
        assert_eq!(env_parse::<u16>("NONEXISTENT_VAR", 42), 42);
        assert!(env_bool("NONEXISTENT_VAR", true));
        assert!(!env_bool("NONEXISTENT_VAR", false));
    }
}
