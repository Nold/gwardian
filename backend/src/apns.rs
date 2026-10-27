//! Apple Push Notification Service (APNS) integration.
//!
//! Sends silent push notifications to wake up iOS devices.
//! Best-effort delivery - failures are logged but not retried.
//!
//! Talks to the APNS HTTP/2 API directly with token-based authentication:
//! an ES256 JWT signed with the team's `.p8` key, refreshed every 50 minutes
//! (Apple rejects tokens older than one hour).

use crate::config::Config;
use crate::models::DeviceRegistration;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tracing::{debug, error, warn};

const PRODUCTION_HOST: &str = "https://api.push.apple.com";
const SANDBOX_HOST: &str = "https://api.sandbox.push.apple.com";

/// Regenerate the JWT before Apple's one-hour limit.
const TOKEN_LIFETIME: Duration = Duration::from_secs(50 * 60);

/// Signs APNS provider tokens (ES256 JWT).
struct TokenSigner {
    key: EcdsaKeyPair,
    rng: SystemRandom,
    key_id: String,
    team_id: String,
    cached: Mutex<Option<(String, Instant)>>,
}

impl TokenSigner {
    /// Load a PKCS#8 PEM key, as downloaded from the Apple developer portal.
    fn from_pem(pem: &str, key_id: &str, team_id: &str) -> Result<Self, String> {
        let body: String = pem
            .lines()
            .filter(|line| !line.starts_with("-----"))
            .map(str::trim)
            .collect();
        let der = STANDARD
            .decode(body)
            .map_err(|e| format!("invalid base64 in key: {e}"))?;
        let rng = SystemRandom::new();
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &rng)
            .map_err(|e| format!("invalid P-256 PKCS#8 key: {e}"))?;
        Ok(Self {
            key,
            rng,
            key_id: key_id.to_string(),
            team_id: team_id.to_string(),
            cached: Mutex::new(None),
        })
    }

    /// Current token, regenerated when older than `TOKEN_LIFETIME`.
    fn token(&self) -> Result<String, String> {
        let mut cached = self.cached.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((token, issued)) = cached.as_ref() {
            if issued.elapsed() < TOKEN_LIFETIME {
                return Ok(token.clone());
            }
        }
        let issued_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        let token = self.sign(issued_at)?;
        *cached = Some((token.clone(), Instant::now()));
        Ok(token)
    }

    fn sign(&self, issued_at: u64) -> Result<String, String> {
        let header = serde_json::json!({ "alg": "ES256", "kid": self.key_id });
        let claims = serde_json::json!({ "iss": self.team_id, "iat": issued_at });
        let signing_input = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(header.to_string()),
            URL_SAFE_NO_PAD.encode(claims.to_string())
        );
        let signature = self
            .key
            .sign(&self.rng, signing_input.as_bytes())
            .map_err(|e| format!("signing failed: {e}"))?;
        Ok(format!(
            "{signing_input}.{}",
            URL_SAFE_NO_PAD.encode(signature.as_ref())
        ))
    }
}

/// APNS device tokens are hex strings; reject anything else before it
/// reaches the request path.
fn is_valid_device_token(token: &str) -> bool {
    !token.is_empty() && token.len() <= 200 && token.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Silent (content-available) notification body.
fn silent_payload(conversation_id: Option<&str>) -> serde_json::Value {
    let mut payload = serde_json::json!({ "aps": { "content-available": 1 } });
    if let Some(conv_id) = conversation_id {
        payload["conversation_id"] = serde_json::Value::from(conv_id);
    }
    payload
}

struct Connection {
    http: reqwest::Client,
    signer: TokenSigner,
    host: &'static str,
}

/// APNS client wrapper
pub struct ApnsClient {
    connection: Option<Connection>,
    bundle_id: String,
}

impl ApnsClient {
    /// Create a new APNS client from configuration
    pub fn new(config: &Config) -> Self {
        if !config.apns_configured() {
            warn!("APNS not configured - push notifications disabled");
            return Self {
                connection: None,
                bundle_id: String::new(),
            };
        }

        let team_id = config.apns_team_id.as_ref().unwrap();
        let key_id = config.apns_key_id.as_ref().unwrap();
        let key_path = config.apns_key_path.as_ref().unwrap();
        let bundle_id = config.apns_bundle_id.as_ref().unwrap().clone();

        let disabled = |bundle_id| Self {
            connection: None,
            bundle_id,
        };

        let key_pem = match std::fs::read_to_string(key_path) {
            Ok(pem) => pem,
            Err(e) => {
                error!(path = %key_path, error = %e, "Failed to read APNS key file");
                return disabled(bundle_id);
            }
        };

        let signer = match TokenSigner::from_pem(&key_pem, key_id, team_id) {
            Ok(s) => s,
            Err(e) => {
                error!(error = %e, "Failed to load APNS key");
                return disabled(bundle_id);
            }
        };

        // reqwest is built without a bundled crypto provider; use ring,
        // already used elsewhere in the backend. Fails only if one is set.
        let _ = rustls::crypto::ring::default_provider().install_default();

        let http = match reqwest::Client::builder()
            .https_only(true)
            .http2_prior_knowledge()
            .timeout(Duration::from_secs(10))
            .build()
        {
            Ok(c) => c,
            Err(e) => {
                error!(error = %e, "Failed to create APNS HTTP client");
                return disabled(bundle_id);
            }
        };

        let host = if config.apns_sandbox {
            SANDBOX_HOST
        } else {
            PRODUCTION_HOST
        };
        debug!(sandbox = config.apns_sandbox, "APNS client initialized");

        Self {
            connection: Some(Connection { http, signer, host }),
            bundle_id,
        }
    }

    /// Send silent push notification to a device (best-effort)
    pub async fn send_silent_push(
        &self,
        device_token: &str,
        conversation_id: Option<&str>,
    ) -> bool {
        let conn = match &self.connection {
            Some(c) => c,
            None => return false,
        };

        if !is_valid_device_token(device_token) {
            debug!("Skipping push: malformed device token");
            return false;
        }

        let token = match conn.signer.token() {
            Ok(t) => t,
            Err(e) => {
                error!(error = %e, "Failed to sign APNS token");
                return false;
            }
        };

        let result = conn
            .http
            .post(format!("{}/3/device/{device_token}", conn.host))
            .bearer_auth(token)
            .header("apns-topic", &self.bundle_id)
            .header("apns-push-type", "background")
            .header("apns-priority", "5")
            .json(&silent_payload(conversation_id))
            .send()
            .await;

        match result {
            Ok(response) => {
                let status = response.status();
                debug!(status = %status, "Sent silent push");
                status.is_success()
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
        if self.connection.is_none() || devices.is_empty() {
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
        self.connection.is_some()
    }
}

/// Create a shared APNS client
pub fn create_client(config: &Config) -> Arc<ApnsClient> {
    Arc::new(ApnsClient::new(config))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{EcdsaKeyPair, KeyPair, UnparsedPublicKey, ECDSA_P256_SHA256_FIXED};

    fn test_key_pem() -> (String, Vec<u8>) {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
            .unwrap();
        let body = STANDARD.encode(pkcs8.as_ref());
        let lines: Vec<&str> = body
            .as_bytes()
            .chunks(64)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect();
        let pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
            lines.join("\n")
        );
        (pem, key.public_key().as_ref().to_vec())
    }

    #[test]
    fn jwt_is_valid_es256() {
        let (pem, public_key) = test_key_pem();
        let signer = TokenSigner::from_pem(&pem, "KEYID12345", "TEAMID1234").unwrap();
        let token = signer.sign(1_700_000_000).unwrap();

        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);

        let header: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).unwrap()).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "KEYID12345");

        let claims: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["iss"], "TEAMID1234");
        assert_eq!(claims["iat"], 1_700_000_000);

        let signature = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert_eq!(signature.len(), 64);
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &public_key)
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .expect("signature verifies with the key's public half");
    }

    #[test]
    fn token_is_cached() {
        let (pem, _) = test_key_pem();
        let signer = TokenSigner::from_pem(&pem, "KEYID12345", "TEAMID1234").unwrap();
        assert_eq!(signer.token().unwrap(), signer.token().unwrap());
    }

    #[test]
    fn invalid_key_rejected() {
        assert!(TokenSigner::from_pem("not a key", "K", "T").is_err());
        let garbage = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
            STANDARD.encode([0u8; 32])
        );
        assert!(TokenSigner::from_pem(&garbage, "K", "T").is_err());
    }

    #[test]
    fn device_token_validation() {
        assert!(is_valid_device_token(&"ab12".repeat(16)));
        assert!(!is_valid_device_token(""));
        assert!(!is_valid_device_token("../../3/device/x"));
        assert!(!is_valid_device_token("abc?x=1"));
        assert!(!is_valid_device_token(&"a".repeat(201)));
    }

    #[test]
    fn payload_shape() {
        assert_eq!(
            silent_payload(Some("conv-1")),
            serde_json::json!({ "aps": { "content-available": 1 }, "conversation_id": "conv-1" })
        );
        assert_eq!(
            silent_payload(None),
            serde_json::json!({ "aps": { "content-available": 1 } })
        );
    }
}
