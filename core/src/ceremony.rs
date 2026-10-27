//! Ceremony metadata for QR transfer.
//!
//! Contains conversation settings that are transferred alongside the pad
//! during the ceremony. Metadata is encoded in frame 0 of the QR stream.
//!
//! Simplified ephemeral design:
//! - Messages stored in server RAM only
//! - Fixed 5-minute TTL (deleted on ACK or expiry)
//! - Immediate burn only
//! - Configurable disappearing messages (client-side display TTL)
//!
//! ## Notification Flags
//!
//! Notification preferences are encoded as a 16-bit bitfield for extensibility.
//! Each bit represents a specific notification type that can be enabled/disabled.

use crate::error::{Error, Result};
use crate::frame::TransferMethod;

/// Maximum relay URL length in bytes.
const MAX_RELAY_URL_LEN: usize = 256;

/// Default message TTL in seconds (5 minutes).
pub const DEFAULT_TTL_SECONDS: u64 = 300;

/// Current metadata version.
pub const METADATA_VERSION: u8 = 1;

// ============================================================================
// Notification Flags (16-bit bitfield)
// ============================================================================

/// Notification flags for push notification preferences.
///
/// These flags control which events trigger push notifications.
/// Stored as a 16-bit field for extensibility (can add up to 16 flags).
///
/// # Receiver Notifications (bits 0-7)
/// - `NOTIFY_NEW_MESSAGE` (0x0001): Notify when new message arrives
/// - `NOTIFY_MESSAGE_EXPIRING` (0x0002): Notify before message expires (5min, 1min)
/// - `NOTIFY_MESSAGE_EXPIRED` (0x0004): Notify when message expires
///
/// # Sender Notifications (bits 8-15)
/// - `NOTIFY_DELIVERY_FAILED` (0x0100): Notify if message TTL expires unread
/// - `NOTIFY_MESSAGE_READ` (0x0200): Reserved for future read receipts
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NotificationFlags(u16);

impl NotificationFlags {
    // Receiver notifications (bits 0-7)
    /// Notify when new message arrives
    pub const NOTIFY_NEW_MESSAGE: u16 = 1 << 0;
    /// Notify before message expires (5min and 1min warnings, or 30s if TTL < 1min)
    pub const NOTIFY_MESSAGE_EXPIRING: u16 = 1 << 1;
    /// Notify when message expires
    pub const NOTIFY_MESSAGE_EXPIRED: u16 = 1 << 2;

    // Sender notifications (bits 8-15)
    /// Notify if message TTL expires without being read
    pub const NOTIFY_DELIVERY_FAILED: u16 = 1 << 8;
    /// Reserved: notify when message is read (future read receipts)
    pub const NOTIFY_MESSAGE_READ: u16 = 1 << 9;

    /// Default flags: new message + expiring + delivery failed
    pub const DEFAULT: u16 =
        Self::NOTIFY_NEW_MESSAGE | Self::NOTIFY_MESSAGE_EXPIRING | Self::NOTIFY_DELIVERY_FAILED;

    /// Create from raw u16 value.
    #[inline]
    pub const fn from_bits(bits: u16) -> Self {
        Self(bits)
    }

    /// Get raw u16 value.
    #[inline]
    pub const fn bits(&self) -> u16 {
        self.0
    }

    /// Create with default notification preferences.
    #[inline]
    pub const fn default_flags() -> Self {
        Self(Self::DEFAULT)
    }

    /// Create with no notifications enabled.
    #[inline]
    pub const fn none() -> Self {
        Self(0)
    }

    /// Check if a specific flag is set.
    #[inline]
    pub const fn contains(&self, flag: u16) -> bool {
        (self.0 & flag) != 0
    }

    /// Set a flag.
    #[inline]
    pub fn set(&mut self, flag: u16) {
        self.0 |= flag;
    }

    /// Clear a flag.
    #[inline]
    pub fn clear(&mut self, flag: u16) {
        self.0 &= !flag;
    }

    /// Check if new message notifications are enabled.
    #[inline]
    pub const fn notify_new_message(&self) -> bool {
        self.contains(Self::NOTIFY_NEW_MESSAGE)
    }

    /// Check if expiring message notifications are enabled.
    #[inline]
    pub const fn notify_message_expiring(&self) -> bool {
        self.contains(Self::NOTIFY_MESSAGE_EXPIRING)
    }

    /// Check if expired message notifications are enabled.
    #[inline]
    pub const fn notify_message_expired(&self) -> bool {
        self.contains(Self::NOTIFY_MESSAGE_EXPIRED)
    }

    /// Check if delivery failure notifications are enabled.
    #[inline]
    pub const fn notify_delivery_failed(&self) -> bool {
        self.contains(Self::NOTIFY_DELIVERY_FAILED)
    }
}

/// Ceremony metadata transferred via QR frame 0.
///
/// Contains settings agreed upon during ceremony:
/// - Server TTL (how long messages stay on relay)
/// - Disappearing messages (how long messages show on screen)
/// - Notification preferences
/// - Transfer method (Raptor, LT, or Sequential)
/// - Relay URL
///
/// Binary format (v2):
/// ```text
/// [version: u8][ttl: u64 BE][disappearing: u32 BE][flags: u16 BE][transfer_method: u8][url_len: u16 BE][url: bytes]
/// ```
///
/// Total: 18 bytes + url_length
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CeremonyMetadata {
    /// Protocol version (2 for current format)
    pub version: u8,

    /// Message TTL in seconds (how long messages stay on relay)
    /// Default: 300 (5 minutes)
    pub ttl_seconds: u64,

    /// Disappearing messages timeout in seconds (client-side display TTL)
    /// 0 = off (messages persist on screen)
    /// Otherwise: seconds until message disappears from UI after viewing
    pub disappearing_messages_seconds: u32,

    /// Notification preferences
    pub notification_flags: NotificationFlags,

    /// Transfer method used for QR ceremony (Raptor, LT, or Sequential)
    /// This tells the receiver which decoder to use
    pub transfer_method: TransferMethod,

    /// Relay server URL (e.g., `https://relay.ash.app`)
    pub relay_url: String,
}

impl Default for CeremonyMetadata {
    fn default() -> Self {
        Self {
            version: METADATA_VERSION,
            ttl_seconds: DEFAULT_TTL_SECONDS,
            disappearing_messages_seconds: 0, // Off by default
            notification_flags: NotificationFlags::default_flags(),
            transfer_method: TransferMethod::default(),
            relay_url: String::new(),
        }
    }
}

impl CeremonyMetadata {
    /// Create new ceremony metadata with default notification flags and Raptor transfer.
    ///
    /// # Arguments
    ///
    /// * `ttl_seconds` - Message TTL in seconds (default 300, max 604800)
    /// * `disappearing_messages_seconds` - Display TTL in seconds (0 = off)
    /// * `relay_url` - Relay server URL
    ///
    /// # Errors
    ///
    /// Returns error if relay URL is too long.
    pub fn new(
        ttl_seconds: u64,
        disappearing_messages_seconds: u32,
        relay_url: String,
    ) -> Result<Self> {
        Self::with_all(
            ttl_seconds,
            disappearing_messages_seconds,
            NotificationFlags::default_flags(),
            TransferMethod::default(),
            relay_url,
        )
    }

    /// Create new ceremony metadata with custom notification flags.
    ///
    /// # Arguments
    ///
    /// * `ttl_seconds` - Message TTL in seconds (default 300, max 604800)
    /// * `disappearing_messages_seconds` - Display TTL in seconds (0 = off)
    /// * `notification_flags` - Push notification preferences
    /// * `relay_url` - Relay server URL
    ///
    /// # Errors
    ///
    /// Returns error if relay URL is too long.
    pub fn with_flags(
        ttl_seconds: u64,
        disappearing_messages_seconds: u32,
        notification_flags: NotificationFlags,
        relay_url: String,
    ) -> Result<Self> {
        Self::with_all(
            ttl_seconds,
            disappearing_messages_seconds,
            notification_flags,
            TransferMethod::default(),
            relay_url,
        )
    }

    /// Create new ceremony metadata with all options.
    ///
    /// # Arguments
    ///
    /// * `ttl_seconds` - Message TTL in seconds (default 300, max 604800)
    /// * `disappearing_messages_seconds` - Display TTL in seconds (0 = off)
    /// * `notification_flags` - Push notification preferences
    /// * `transfer_method` - QR transfer method (Raptor, LT, or Sequential)
    /// * `relay_url` - Relay server URL
    ///
    /// # Errors
    ///
    /// Returns error if relay URL is too long.
    pub fn with_all(
        ttl_seconds: u64,
        disappearing_messages_seconds: u32,
        notification_flags: NotificationFlags,
        transfer_method: TransferMethod,
        relay_url: String,
    ) -> Result<Self> {
        if relay_url.len() > MAX_RELAY_URL_LEN {
            return Err(Error::MetadataUrlTooLong {
                len: relay_url.len(),
                max: MAX_RELAY_URL_LEN,
            });
        }

        // Cap TTL to 7 days max, use default if 0
        let ttl_seconds = if ttl_seconds == 0 {
            DEFAULT_TTL_SECONDS
        } else {
            ttl_seconds.min(604800)
        };

        Ok(Self {
            version: METADATA_VERSION,
            ttl_seconds,
            disappearing_messages_seconds,
            notification_flags,
            transfer_method,
            relay_url,
        })
    }

    /// Encode metadata to bytes for frame payload.
    ///
    /// Binary format (v2):
    /// ```text
    /// [version: u8][ttl: u64 BE][disappearing: u32 BE][flags: u16 BE][transfer_method: u8][url_len: u16 BE][url: bytes]
    /// ```
    pub fn encode(&self) -> Vec<u8> {
        let url_bytes = self.relay_url.as_bytes();
        // 1 + 8 + 4 + 2 + 1 + 2 + url_len = 18 + url_len
        let mut bytes = Vec::with_capacity(18 + url_bytes.len());

        // Version (1 byte)
        bytes.push(self.version);

        // TTL (8 bytes, big-endian)
        bytes.extend_from_slice(&self.ttl_seconds.to_be_bytes());

        // Disappearing messages (4 bytes, big-endian)
        bytes.extend_from_slice(&self.disappearing_messages_seconds.to_be_bytes());

        // Notification flags (2 bytes, big-endian)
        bytes.extend_from_slice(&self.notification_flags.bits().to_be_bytes());

        // Transfer method (1 byte)
        bytes.push(self.transfer_method.to_byte());

        // URL length (2 bytes, big-endian)
        bytes.extend_from_slice(&(url_bytes.len() as u16).to_be_bytes());

        // URL bytes
        bytes.extend_from_slice(url_bytes);

        bytes
    }

    /// Decode metadata from bytes.
    ///
    /// # Errors
    ///
    /// Returns error if bytes are malformed or too short.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        // Minimum size: version(1) + ttl(8) + disappearing(4) + flags(2) + transfer(1) + url_len(2) = 18 bytes
        if bytes.len() < 18 {
            return Err(Error::MetadataTooShort {
                size: bytes.len(),
                minimum: 18,
            });
        }

        let version = bytes[0];

        if version != 1 {
            return Err(Error::UnsupportedMetadataVersion { version });
        }

        let ttl_seconds = u64::from_be_bytes([
            bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        ]);

        let disappearing_messages_seconds =
            u32::from_be_bytes([bytes[9], bytes[10], bytes[11], bytes[12]]);

        let notification_flags =
            NotificationFlags::from_bits(u16::from_be_bytes([bytes[13], bytes[14]]));

        let transfer_method = TransferMethod::from_byte(bytes[15]);

        let url_len = u16::from_be_bytes([bytes[16], bytes[17]]) as usize;

        if bytes.len() < 18 + url_len {
            return Err(Error::MetadataTooShort {
                size: bytes.len(),
                minimum: 18 + url_len,
            });
        }

        let relay_url = String::from_utf8(bytes[18..18 + url_len].to_vec())
            .map_err(|_| Error::InvalidMetadataUrl)?;

        Ok(Self {
            version: METADATA_VERSION,
            ttl_seconds,
            disappearing_messages_seconds,
            notification_flags,
            transfer_method,
            relay_url,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ========================================================================
    // NotificationFlags Tests
    // ========================================================================

    #[test]
    fn notification_flags_default() {
        let flags = NotificationFlags::default_flags();
        assert!(flags.notify_new_message());
        assert!(flags.notify_message_expiring());
        assert!(!flags.notify_message_expired());
        assert!(flags.notify_delivery_failed());
    }

    #[test]
    fn notification_flags_none() {
        let flags = NotificationFlags::none();
        assert!(!flags.notify_new_message());
        assert!(!flags.notify_message_expiring());
        assert!(!flags.notify_message_expired());
        assert!(!flags.notify_delivery_failed());
        assert_eq!(flags.bits(), 0);
    }

    #[test]
    fn notification_flags_set_clear() {
        let mut flags = NotificationFlags::none();

        flags.set(NotificationFlags::NOTIFY_NEW_MESSAGE);
        assert!(flags.notify_new_message());

        flags.set(NotificationFlags::NOTIFY_MESSAGE_EXPIRED);
        assert!(flags.notify_message_expired());

        flags.clear(NotificationFlags::NOTIFY_NEW_MESSAGE);
        assert!(!flags.notify_new_message());
        assert!(flags.notify_message_expired());
    }

    #[test]
    fn notification_flags_roundtrip() {
        let flags = NotificationFlags::from_bits(0b0000_0001_0000_0111);
        assert_eq!(flags.bits(), 0b0000_0001_0000_0111);
        assert!(flags.notify_new_message());
        assert!(flags.notify_message_expiring());
        assert!(flags.notify_message_expired());
        assert!(flags.notify_delivery_failed());
    }

    // ========================================================================
    // CeremonyMetadata Tests
    // ========================================================================

    #[test]
    fn metadata_roundtrip() {
        let metadata = CeremonyMetadata::new(300, 30, "https://relay.ash.app".to_string()).unwrap();

        let encoded = metadata.encode();
        let decoded = CeremonyMetadata::decode(&encoded).unwrap();

        assert_eq!(metadata, decoded);
    }

    #[test]
    fn metadata_with_custom_flags() {
        let flags = NotificationFlags::from_bits(
            NotificationFlags::NOTIFY_NEW_MESSAGE | NotificationFlags::NOTIFY_MESSAGE_EXPIRED,
        );
        let metadata =
            CeremonyMetadata::with_flags(300, 60, flags, "https://relay.ash.app".to_string())
                .unwrap();

        assert!(metadata.notification_flags.notify_new_message());
        assert!(!metadata.notification_flags.notify_message_expiring());
        assert!(metadata.notification_flags.notify_message_expired());
        assert!(!metadata.notification_flags.notify_delivery_failed());

        let encoded = metadata.encode();
        let decoded = CeremonyMetadata::decode(&encoded).unwrap();

        assert_eq!(decoded.notification_flags.bits(), flags.bits());
    }

    #[test]
    fn metadata_with_disappearing_messages() {
        let metadata =
            CeremonyMetadata::new(300, 1800, "https://relay.ash.app".to_string()).unwrap();

        assert_eq!(metadata.disappearing_messages_seconds, 1800); // 30 minutes

        let encoded = metadata.encode();
        let decoded = CeremonyMetadata::decode(&encoded).unwrap();

        assert_eq!(decoded.disappearing_messages_seconds, 1800);
    }

    #[test]
    fn metadata_defaults() {
        let metadata = CeremonyMetadata::default();
        assert_eq!(metadata.version, 1);
        assert_eq!(metadata.ttl_seconds, DEFAULT_TTL_SECONDS);
        assert_eq!(metadata.disappearing_messages_seconds, 0); // Off by default
        assert_eq!(
            metadata.notification_flags.bits(),
            NotificationFlags::DEFAULT
        );
        assert_eq!(metadata.transfer_method, TransferMethod::Raptor);
        assert!(metadata.relay_url.is_empty());
    }

    #[test]
    fn metadata_ttl_capped() {
        // TTL should be capped to 7 days
        let metadata = CeremonyMetadata::new(999999999, 0, String::new()).unwrap();
        assert_eq!(metadata.ttl_seconds, 604800); // 7 days
    }

    #[test]
    fn metadata_ttl_default_on_zero() {
        let metadata = CeremonyMetadata::new(0, 0, String::new()).unwrap();
        assert_eq!(metadata.ttl_seconds, DEFAULT_TTL_SECONDS);
    }

    #[test]
    fn metadata_url_too_long() {
        let long_url = "x".repeat(300);
        let result = CeremonyMetadata::new(60, 0, long_url);
        assert!(matches!(result, Err(Error::MetadataUrlTooLong { .. })));
    }

    #[test]
    fn metadata_decode_too_short() {
        let result = CeremonyMetadata::decode(&[1, 0, 0, 0]);
        assert!(matches!(result, Err(Error::MetadataTooShort { .. })));
    }

    #[test]
    fn metadata_unsupported_version() {
        let mut encoded = CeremonyMetadata::default().encode();
        encoded[0] = 99; // Invalid version
        let result = CeremonyMetadata::decode(&encoded);
        assert!(matches!(
            result,
            Err(Error::UnsupportedMetadataVersion { .. })
        ));
    }

    #[test]
    fn metadata_encoded_size() {
        let metadata = CeremonyMetadata::new(300, 0, "https://relay.ash.app".to_string()).unwrap();
        let encoded = metadata.encode();
        // 18 bytes header + URL length (v2 includes transfer_method byte)
        assert_eq!(encoded.len(), 18 + "https://relay.ash.app".len());
    }

    #[test]
    fn metadata_with_transfer_method() {
        let metadata = CeremonyMetadata::with_all(
            300,
            60,
            NotificationFlags::default_flags(),
            TransferMethod::LT,
            "https://relay.ash.app".to_string(),
        )
        .unwrap();

        assert_eq!(metadata.transfer_method, TransferMethod::LT);

        let encoded = metadata.encode();
        let decoded = CeremonyMetadata::decode(&encoded).unwrap();

        assert_eq!(decoded.transfer_method, TransferMethod::LT);
    }
}
