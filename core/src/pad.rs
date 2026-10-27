//! One-Time Pad generation and consumption.
//!
//! The Pad struct enforces strict single-use semantics:
//! - Bytes can only be consumed once
//! - Initiator (sender) consumes from the beginning
//! - Responder (receiver) consumes from the end
//! - Memory is securely wiped on drop
//!
//! # Bidirectional Consumption
//!
//! ASH uses a bidirectional pad consumption model:
//! - **Initiator (Alice)**: Consumes bytes from the **start** of the pad
//! - **Responder (Bob)**: Consumes bytes from the **end** of the pad
//!
//! This design allows both parties to encrypt messages independently without
//! coordination, as long as the pad is large enough for both directions.
//!
//! ```text
//! Pad: [████████████████████████████████]
//!       ↑                              ↑
//!       Initiator consumes →    ← Responder consumes
//! ```

use crate::error::{Error, Result};

/// Available pad sizes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PadSize {
    /// 32 KB - approximately 25 short messages, ~25 QR frames
    Tiny,
    /// 64 KB - approximately 50 short messages, ~45 QR frames
    Small,
    /// 256 KB - approximately 200 short messages, ~177 QR frames
    Medium,
    /// 512 KB - approximately 400 short messages, ~353 QR frames
    Large,
    /// 1 MB - approximately 800 short messages, ~705 QR frames
    Huge,
}

impl PadSize {
    /// Get the size in bytes.
    #[inline]
    pub const fn bytes(self) -> usize {
        match self {
            PadSize::Tiny => 32 * 1024,    // 32 KB
            PadSize::Small => 64 * 1024,   // 64 KB
            PadSize::Medium => 256 * 1024, // 256 KB
            PadSize::Large => 512 * 1024,  // 512 KB
            PadSize::Huge => 1024 * 1024,  // 1 MB
        }
    }
}

/// Role in the conversation, determining pad consumption direction.
///
/// The role is established during the ceremony:
/// - The person who initiates the ceremony becomes the Initiator
/// - The person who receives/scans becomes the Responder
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Initiator (sender/Alice) - consumes from the start of the pad
    Initiator,
    /// Responder (receiver/Bob) - consumes from the end of the pad
    Responder,
}

/// Securely zero memory, preventing compiler optimization.
///
/// Uses volatile writes to ensure the zeroing is not optimized away,
/// followed by a compiler fence to prevent reordering.
#[inline(never)]
pub(crate) fn secure_zero(data: &mut [u8]) {
    // Use volatile writes to prevent optimization
    for byte in data.iter_mut() {
        // SAFETY: We're writing to valid, aligned memory that we own
        unsafe {
            std::ptr::write_volatile(byte, 0);
        }
    }
    // Compiler fence to prevent reordering
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// A One-Time Pad with bidirectional consumption semantics.
///
/// # Bidirectional Consumption
///
/// - **Initiator**: Consumes bytes from index 0 forward
/// - **Responder**: Consumes bytes from the end backward
///
/// This allows both parties to send messages without coordination.
/// The pad is exhausted when the two consumption fronts meet.
///
/// # Security
///
/// - Pad bytes are consumed strictly once
/// - Each direction is independent
/// - Memory is securely zeroed on drop
///
/// # Example
///
/// ```
/// use ash_core::pad::{Pad, PadSize, Role};
///
/// // Create pad from entropy (caller provides entropy)
/// let entropy = vec![0u8; PadSize::Small.bytes()];
/// let mut pad = Pad::new(&entropy, PadSize::Small).unwrap();
///
/// // Initiator consumes from start
/// let key1 = pad.consume(100, Role::Initiator).unwrap();
/// assert_eq!(key1.len(), 100);
///
/// // Responder consumes from end
/// let key2 = pad.consume(100, Role::Responder).unwrap();
/// assert_eq!(key2.len(), 100);
/// ```
pub struct Pad {
    /// The pad bytes (securely wiped on drop)
    bytes: Vec<u8>,
    /// Number of bytes consumed from the start (Initiator)
    consumed_front: usize,
    /// Number of bytes consumed from the end (Responder)
    consumed_back: usize,
}

impl Drop for Pad {
    fn drop(&mut self) {
        secure_zero(&mut self.bytes);
    }
}

impl Pad {
    /// Create a new pad from entropy.
    ///
    /// The entropy must be exactly the size specified by `size`.
    /// The caller is responsible for gathering high-quality entropy
    /// (e.g., from OS randomness + gesture input).
    ///
    /// # Errors
    ///
    /// Returns `Error::InvalidEntropySize` if entropy length doesn't match size.
    pub fn new(entropy: &[u8], size: PadSize) -> Result<Self> {
        let expected = size.bytes();
        if entropy.len() != expected {
            return Err(Error::InvalidEntropySize {
                size: entropy.len(),
                expected,
            });
        }

        Ok(Self {
            bytes: entropy.to_vec(),
            consumed_front: 0,
            consumed_back: 0,
        })
    }

    /// Create a pad directly from raw bytes.
    ///
    /// This is primarily used for reconstructing a pad after ceremony transfer.
    /// The bytes are used as-is without size validation.
    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            consumed_front: 0,
            consumed_back: 0,
        }
    }

    /// Create a pad with pre-existing consumption state.
    ///
    /// Used when restoring a pad from persistent storage.
    pub fn from_bytes_with_state(
        bytes: Vec<u8>,
        consumed_front: usize,
        consumed_back: usize,
    ) -> Self {
        Self {
            bytes,
            consumed_front,
            consumed_back,
        }
    }

    /// Consume the next `n` bytes from the pad based on role.
    ///
    /// - **Initiator**: Consumes from the start, moving forward
    /// - **Responder**: Consumes from the end, moving backward
    ///
    /// # Security
    ///
    /// Each byte can only be consumed once. After consumption,
    /// those bytes cannot be retrieved again.
    ///
    /// # Errors
    ///
    /// Returns `Error::InsufficientPadBytes` if fewer than `n` bytes remain.
    pub fn consume(&mut self, n: usize, role: Role) -> Result<Vec<u8>> {
        let available = self.remaining();
        if n > available {
            return Err(Error::InsufficientPadBytes {
                needed: n,
                available,
            });
        }

        match role {
            Role::Initiator => {
                let start = self.consumed_front;
                let end = start + n;
                let slice = self.bytes[start..end].to_vec();
                self.consumed_front = end;
                Ok(slice)
            }
            Role::Responder => {
                let end = self.bytes.len() - self.consumed_back;
                let start = end - n;
                let slice = self.bytes[start..end].to_vec();
                self.consumed_back += n;
                Ok(slice)
            }
        }
    }

    /// Get the number of bytes remaining in the pad.
    ///
    /// This is the total unused bytes in the middle, available to either role.
    #[inline]
    pub fn remaining(&self) -> usize {
        self.bytes
            .len()
            .saturating_sub(self.consumed_front)
            .saturating_sub(self.consumed_back)
    }

    /// Get the number of bytes consumed by the Initiator (from start).
    #[inline]
    pub fn consumed_front(&self) -> usize {
        self.consumed_front
    }

    /// Get the number of bytes consumed by the Responder (from end).
    #[inline]
    pub fn consumed_back(&self) -> usize {
        self.consumed_back
    }

    /// Get the total number of bytes consumed (both directions).
    #[inline]
    pub fn consumed(&self) -> usize {
        self.consumed_front + self.consumed_back
    }

    /// Get the total size of the pad.
    #[inline]
    pub fn total_size(&self) -> usize {
        self.bytes.len()
    }

    /// Check if the pad is fully exhausted.
    #[inline]
    pub fn is_exhausted(&self) -> bool {
        self.remaining() == 0
    }

    /// Check if we can send a message of the given length.
    ///
    /// This implements dynamic allocation - we can use bytes up to the point
    /// where we would collide with the peer's consumption from the other end.
    ///
    /// # Arguments
    ///
    /// * `length` - Number of bytes needed for the message
    /// * `role` - Our role (determines which direction we consume)
    ///
    /// # Returns
    ///
    /// `true` if the message can be sent without exhausting the pad.
    #[inline]
    pub fn can_send(&self, length: usize, role: Role) -> bool {
        match role {
            // Initiator consumes from front, peer consumes from back
            // Safe if: consumed_front + length + consumed_back <= total_size
            Role::Initiator => {
                self.consumed_front + length + self.consumed_back <= self.bytes.len()
            }
            // Responder consumes from back, peer consumes from front
            // Safe if: consumed_front + consumed_back + length <= total_size
            Role::Responder => {
                self.consumed_front + self.consumed_back + length <= self.bytes.len()
            }
        }
    }

    /// Get the number of bytes available for sending (dynamic allocation).
    ///
    /// This returns how many bytes we can safely consume without
    /// colliding with the peer's consumption from the other end.
    ///
    /// # Arguments
    ///
    /// * `role` - Our role (determines which direction we consume)
    ///
    /// # Returns
    ///
    /// Number of bytes available for sending.
    #[inline]
    pub fn available_for_sending(&self, _role: Role) -> usize {
        let total = self.bytes.len();
        let total_consumed = self.consumed_front + self.consumed_back;
        if total_consumed >= total {
            return 0;
        }
        total - total_consumed
    }

    /// Update peer's consumption based on a received message.
    ///
    /// When we receive a message from the peer, we learn how much of the pad
    /// they have consumed from their end. This updates our tracking.
    ///
    /// # Arguments
    ///
    /// * `peer_role` - The peer's role (opposite of ours)
    /// * `new_consumed` - Total bytes the peer has consumed
    ///
    /// # Note
    ///
    /// This only updates if `new_consumed` is greater than current tracking,
    /// preventing replay attacks from reducing the known consumption.
    pub fn update_peer_consumption(&mut self, peer_role: Role, new_consumed: usize) {
        match peer_role {
            Role::Initiator => {
                // Peer is initiator, they consume from front
                if new_consumed > self.consumed_front {
                    self.consumed_front = new_consumed;
                }
            }
            Role::Responder => {
                // Peer is responder, they consume from back
                if new_consumed > self.consumed_back {
                    self.consumed_back = new_consumed;
                }
            }
        }
    }

    /// Get the offset for the next message we send.
    ///
    /// This is the position in the pad where our next message's key material starts.
    /// Used for message sequencing and deduplication.
    ///
    /// # Arguments
    ///
    /// * `role` - Our role (determines which direction we consume)
    ///
    /// # Returns
    ///
    /// The byte offset for the next outgoing message.
    #[inline]
    pub fn next_send_offset(&self, role: Role) -> usize {
        match role {
            Role::Initiator => self.consumed_front,
            Role::Responder => self.bytes.len() - self.consumed_back,
        }
    }

    /// Serialize pad state for persistent storage.
    ///
    /// Returns a tuple of (bytes, consumed_front, consumed_back) that can be
    /// stored and later restored with `from_bytes_with_state`.
    pub fn serialize_state(&self) -> (Vec<u8>, usize, usize) {
        (self.bytes.clone(), self.consumed_front, self.consumed_back)
    }

    /// Securely zero bytes at a specific offset.
    ///
    /// This is used for forward secrecy: when a message expires,
    /// the key material (pad bytes) used to encrypt it are zeroed.
    /// Even if an attacker later gains access to the pad, they cannot
    /// decrypt messages whose keys have been zeroed.
    ///
    /// # Arguments
    ///
    /// * `offset` - Starting offset in the pad
    /// * `length` - Number of bytes to zero
    ///
    /// # Returns
    ///
    /// `true` if bytes were zeroed, `false` if offset/length is out of bounds.
    ///
    /// # Security Note
    ///
    /// This does not affect the consumption counters. It only zeros the
    /// actual byte values, rendering them useless for encryption/decryption.
    pub fn zero_bytes_at(&mut self, offset: usize, length: usize) -> bool {
        let end = offset.saturating_add(length);
        if end > self.bytes.len() {
            return false;
        }
        secure_zero(&mut self.bytes[offset..end]);
        true
    }

    /// Get the raw pad bytes (for ceremony transfer).
    ///
    /// # Security
    ///
    /// This should only be used during ceremony to create frames.
    /// The returned slice includes all bytes, not just unconsumed ones.
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }
}

impl std::fmt::Debug for Pad {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Don't expose actual bytes in debug output
        f.debug_struct("Pad")
            .field("total_size", &self.bytes.len())
            .field("consumed_front", &self.consumed_front)
            .field("consumed_back", &self.consumed_back)
            .field("remaining", &self.remaining())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_size_bytes() {
        assert_eq!(PadSize::Tiny.bytes(), 32768); // 32 KB
        assert_eq!(PadSize::Small.bytes(), 65536); // 64 KB
        assert_eq!(PadSize::Medium.bytes(), 262144); // 256 KB
        assert_eq!(PadSize::Large.bytes(), 524288); // 512 KB
        assert_eq!(PadSize::Huge.bytes(), 1048576); // 1 MB
    }

    #[test]
    fn pad_new_valid() {
        let entropy = vec![0xAB; PadSize::Small.bytes()];
        let pad = Pad::new(&entropy, PadSize::Small).unwrap();
        assert_eq!(pad.total_size(), PadSize::Small.bytes());
        assert_eq!(pad.remaining(), PadSize::Small.bytes());
        assert_eq!(pad.consumed(), 0);
    }

    #[test]
    fn pad_new_wrong_size() {
        let entropy = vec![0xAB; 100]; // Wrong size
        let result = Pad::new(&entropy, PadSize::Small);
        assert!(matches!(result, Err(Error::InvalidEntropySize { .. })));
    }

    #[test]
    fn pad_consume_initiator() {
        let entropy: Vec<u8> = (0..=255).cycle().take(256).collect();
        let mut pad = Pad::from_bytes(entropy);

        let slice = pad.consume(10, Role::Initiator).unwrap();
        assert_eq!(slice.len(), 10);
        // Should be first 10 bytes: 0, 1, 2, ..., 9
        assert_eq!(slice, (0..10).collect::<Vec<u8>>());
        assert_eq!(pad.consumed_front(), 10);
        assert_eq!(pad.consumed_back(), 0);
        assert_eq!(pad.remaining(), 246);
    }

    #[test]
    fn pad_consume_responder() {
        let entropy: Vec<u8> = (0..=255).cycle().take(256).collect();
        let mut pad = Pad::from_bytes(entropy);

        let slice = pad.consume(10, Role::Responder).unwrap();
        assert_eq!(slice.len(), 10);
        // Should be last 10 bytes: 246, 247, ..., 255
        assert_eq!(slice, (246..=255).collect::<Vec<u8>>());
        assert_eq!(pad.consumed_front(), 0);
        assert_eq!(pad.consumed_back(), 10);
        assert_eq!(pad.remaining(), 246);
    }

    #[test]
    fn pad_bidirectional_consumption() {
        let entropy: Vec<u8> = (0..100).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Initiator takes first 20
        let init_slice = pad.consume(20, Role::Initiator).unwrap();
        assert_eq!(init_slice, (0..20).collect::<Vec<u8>>());

        // Responder takes last 20
        let resp_slice = pad.consume(20, Role::Responder).unwrap();
        assert_eq!(resp_slice, (80..100).collect::<Vec<u8>>());

        // 60 bytes remain in the middle
        assert_eq!(pad.remaining(), 60);
        assert_eq!(pad.consumed_front(), 20);
        assert_eq!(pad.consumed_back(), 20);

        // Initiator takes 30 more (indices 20-49)
        let init_slice2 = pad.consume(30, Role::Initiator).unwrap();
        assert_eq!(init_slice2, (20..50).collect::<Vec<u8>>());

        // Responder takes 30 more (indices 50-79)
        let resp_slice2 = pad.consume(30, Role::Responder).unwrap();
        assert_eq!(resp_slice2, (50..80).collect::<Vec<u8>>());

        // Pad is exhausted
        assert!(pad.is_exhausted());
        assert_eq!(pad.remaining(), 0);
    }

    #[test]
    fn pad_consume_insufficient() {
        let entropy = vec![0u8; 100];
        let mut pad = Pad::from_bytes(entropy);

        // Consume 50 from front
        pad.consume(50, Role::Initiator).unwrap();
        // Consume 30 from back
        pad.consume(30, Role::Responder).unwrap();
        // Only 20 remain

        // Try to consume 30 - should fail
        let result = pad.consume(30, Role::Initiator);
        assert!(matches!(
            result,
            Err(Error::InsufficientPadBytes {
                needed: 30,
                available: 20
            })
        ));
    }

    #[test]
    fn pad_with_state() {
        let entropy: Vec<u8> = (0..100).collect();
        let pad = Pad::from_bytes_with_state(entropy, 10, 20);

        assert_eq!(pad.consumed_front(), 10);
        assert_eq!(pad.consumed_back(), 20);
        assert_eq!(pad.remaining(), 70);
    }

    #[test]
    fn pad_debug_hides_bytes() {
        let entropy = vec![0xDE, 0xAD, 0xBE, 0xEF];
        let pad = Pad::from_bytes(entropy);
        let debug = format!("{:?}", pad);

        // Debug output should not contain actual byte values
        assert!(!debug.contains("0xde"));
        assert!(!debug.contains("dead"));
        assert!(debug.contains("total_size"));
        assert!(debug.contains("remaining"));
        assert!(debug.contains("consumed_front"));
        assert!(debug.contains("consumed_back"));
    }

    #[test]
    fn secure_zero_works() {
        let mut data = vec![0xAB; 100];
        secure_zero(&mut data);
        assert!(data.iter().all(|&b| b == 0));
    }

    #[test]
    fn can_send_dynamic_allocation() {
        let entropy: Vec<u8> = (0..100).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Fresh pad: initiator can send up to 100 bytes
        assert!(pad.can_send(100, Role::Initiator));
        assert!(pad.can_send(100, Role::Responder));
        assert!(!pad.can_send(101, Role::Initiator));

        // Initiator consumes 30 from front
        pad.consume(30, Role::Initiator).unwrap();
        assert!(pad.can_send(70, Role::Initiator));
        assert!(pad.can_send(70, Role::Responder));
        assert!(!pad.can_send(71, Role::Initiator));

        // Responder consumes 20 from back
        pad.consume(20, Role::Responder).unwrap();
        assert!(pad.can_send(50, Role::Initiator));
        assert!(pad.can_send(50, Role::Responder));
        assert!(!pad.can_send(51, Role::Initiator));
    }

    #[test]
    fn available_for_sending() {
        let entropy: Vec<u8> = (0..100).collect();
        let mut pad = Pad::from_bytes(entropy);

        assert_eq!(pad.available_for_sending(Role::Initiator), 100);
        assert_eq!(pad.available_for_sending(Role::Responder), 100);

        pad.consume(30, Role::Initiator).unwrap();
        assert_eq!(pad.available_for_sending(Role::Initiator), 70);
        assert_eq!(pad.available_for_sending(Role::Responder), 70);

        pad.consume(20, Role::Responder).unwrap();
        assert_eq!(pad.available_for_sending(Role::Initiator), 50);
        assert_eq!(pad.available_for_sending(Role::Responder), 50);
    }

    #[test]
    fn update_peer_consumption() {
        let entropy: Vec<u8> = (0..100).collect();
        let mut pad = Pad::from_bytes(entropy);

        // We are responder, peer is initiator
        // Peer has consumed 40 bytes from front
        pad.update_peer_consumption(Role::Initiator, 40);
        assert_eq!(pad.consumed_front(), 40);
        assert_eq!(pad.consumed_back(), 0);
        assert_eq!(pad.available_for_sending(Role::Responder), 60);

        // Peer consumption should only increase, not decrease (replay protection)
        pad.update_peer_consumption(Role::Initiator, 30);
        assert_eq!(pad.consumed_front(), 40); // Still 40

        // Peer consumed more
        pad.update_peer_consumption(Role::Initiator, 50);
        assert_eq!(pad.consumed_front(), 50);
    }

    #[test]
    fn next_send_offset() {
        let entropy: Vec<u8> = (0..100).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Initiator sends from offset 0
        assert_eq!(pad.next_send_offset(Role::Initiator), 0);
        // Responder sends from offset 100 (end of pad)
        assert_eq!(pad.next_send_offset(Role::Responder), 100);

        // Initiator consumes 30
        pad.consume(30, Role::Initiator).unwrap();
        assert_eq!(pad.next_send_offset(Role::Initiator), 30);
        assert_eq!(pad.next_send_offset(Role::Responder), 100);

        // Responder consumes 20
        pad.consume(20, Role::Responder).unwrap();
        assert_eq!(pad.next_send_offset(Role::Initiator), 30);
        assert_eq!(pad.next_send_offset(Role::Responder), 80);
    }

    #[test]
    fn serialize_state_roundtrip() {
        let entropy: Vec<u8> = (0..100).collect();
        let mut pad = Pad::from_bytes(entropy);

        pad.consume(30, Role::Initiator).unwrap();
        pad.consume(20, Role::Responder).unwrap();

        let (bytes, front, back) = pad.serialize_state();
        let restored = Pad::from_bytes_with_state(bytes, front, back);

        assert_eq!(restored.consumed_front(), 30);
        assert_eq!(restored.consumed_back(), 20);
        assert_eq!(restored.remaining(), 50);
    }

    // ==========================================================================
    // Dynamic Allocation Tests - Asymmetric Usage (Alice 20%, Bob 80%, etc.)
    // ==========================================================================

    #[test]
    fn asymmetric_allocation_alice_20_bob_80() {
        // Test that Alice (Initiator) can use only 20% while Bob (Responder) uses 80%
        let pad_size = 1000;
        let entropy: Vec<u8> = (0..pad_size).map(|i| i as u8).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Alice (Initiator) uses 20% = 200 bytes from the beginning
        let alice_bytes = pad.consume(200, Role::Initiator).unwrap();
        assert_eq!(alice_bytes.len(), 200);
        // Verify Alice got bytes 0-199
        assert_eq!(alice_bytes[0], 0);
        assert_eq!(alice_bytes[199], 199);

        // Bob (Responder) can now use remaining 80% = 800 bytes from the end
        assert!(pad.can_send(800, Role::Responder));
        let bob_bytes = pad.consume(800, Role::Responder).unwrap();
        assert_eq!(bob_bytes.len(), 800);
        // Verify Bob got bytes 200-999 (from the end)
        assert_eq!(bob_bytes[0], 200); // First byte Bob gets is at index 200
        assert_eq!(bob_bytes[799], (999 % 256) as u8); // Last byte is index 999 mod 256 = 231

        // Pad is now exhausted
        assert!(pad.is_exhausted());
        assert_eq!(pad.remaining(), 0);
        assert_eq!(pad.consumed_front(), 200);
        assert_eq!(pad.consumed_back(), 800);
    }

    #[test]
    fn asymmetric_allocation_alice_80_bob_20() {
        // Test that Alice (Initiator) can use 80% while Bob (Responder) uses only 20%
        let pad_size = 1000;
        let entropy: Vec<u8> = (0..pad_size).map(|i| i as u8).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Bob (Responder) uses 20% = 200 bytes from the end first
        let bob_bytes = pad.consume(200, Role::Responder).unwrap();
        assert_eq!(bob_bytes.len(), 200);
        // Verify Bob got bytes 800-999 (from the end)
        assert_eq!(bob_bytes[0], (800 % 256) as u8);

        // Alice (Initiator) can now use remaining 80% = 800 bytes from the beginning
        assert!(pad.can_send(800, Role::Initiator));
        let alice_bytes = pad.consume(800, Role::Initiator).unwrap();
        assert_eq!(alice_bytes.len(), 800);
        // Verify Alice got bytes 0-799
        assert_eq!(alice_bytes[0], 0);
        assert_eq!(alice_bytes[799], (799 % 256) as u8);

        // Pad is now exhausted
        assert!(pad.is_exhausted());
        assert_eq!(pad.remaining(), 0);
    }

    #[test]
    fn asymmetric_allocation_alice_99_bob_1() {
        // Extreme case: Alice uses 99%, Bob uses only 1%
        let pad_size = 1000;
        let entropy: Vec<u8> = vec![0xAB; pad_size];
        let mut pad = Pad::from_bytes(entropy);

        // Alice takes 990 bytes (99%)
        assert!(pad.can_send(990, Role::Initiator));
        pad.consume(990, Role::Initiator).unwrap();

        // Bob can only take 10 bytes (1%)
        assert!(pad.can_send(10, Role::Responder));
        assert!(!pad.can_send(11, Role::Responder));
        pad.consume(10, Role::Responder).unwrap();

        assert!(pad.is_exhausted());
    }

    #[test]
    fn asymmetric_allocation_bob_100_alice_0() {
        // Edge case: Bob uses 100%, Alice uses 0%
        let pad_size = 1000;
        let entropy: Vec<u8> = vec![0xCD; pad_size];
        let mut pad = Pad::from_bytes(entropy);

        // Bob takes everything from the end
        assert!(pad.can_send(1000, Role::Responder));
        let bob_bytes = pad.consume(1000, Role::Responder).unwrap();
        assert_eq!(bob_bytes.len(), 1000);

        // Alice can't send anything now
        assert!(!pad.can_send(1, Role::Initiator));
        assert!(pad.is_exhausted());
    }

    #[test]
    fn asymmetric_allocation_alice_100_bob_0() {
        // Edge case: Alice uses 100%, Bob uses 0%
        let pad_size = 1000;
        let entropy: Vec<u8> = vec![0xEF; pad_size];
        let mut pad = Pad::from_bytes(entropy);

        // Alice takes everything from the beginning
        assert!(pad.can_send(1000, Role::Initiator));
        let alice_bytes = pad.consume(1000, Role::Initiator).unwrap();
        assert_eq!(alice_bytes.len(), 1000);

        // Bob can't send anything now
        assert!(!pad.can_send(1, Role::Responder));
        assert!(pad.is_exhausted());
    }

    #[test]
    fn dynamic_allocation_interleaved_messages() {
        // Simulate real conversation: interleaved messages with varying sizes
        let pad_size = 10000;
        let entropy: Vec<u8> = (0..pad_size).map(|i| i as u8).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Alice sends a short message (100 bytes)
        pad.consume(100, Role::Initiator).unwrap();
        assert_eq!(pad.consumed_front(), 100);

        // Bob sends a long message (2000 bytes)
        pad.consume(2000, Role::Responder).unwrap();
        assert_eq!(pad.consumed_back(), 2000);

        // Alice sends a medium message (500 bytes)
        pad.consume(500, Role::Initiator).unwrap();
        assert_eq!(pad.consumed_front(), 600);

        // Bob sends many short messages totaling 5000 bytes
        pad.consume(5000, Role::Responder).unwrap();
        assert_eq!(pad.consumed_back(), 7000);

        // Alice sends more (1000 bytes)
        pad.consume(1000, Role::Initiator).unwrap();
        assert_eq!(pad.consumed_front(), 1600);

        // Total consumed: 1600 + 7000 = 8600
        // Remaining: 10000 - 8600 = 1400
        assert_eq!(pad.remaining(), 1400);

        // Verify asymmetric usage:
        // Alice: 16% (1600/10000)
        // Bob: 70% (7000/10000)
        // Remaining: 14%
        assert_eq!(pad.consumed_front() * 100 / pad_size, 16);
        assert_eq!(pad.consumed_back() * 100 / pad_size, 70);
    }

    #[test]
    fn dynamic_allocation_bytes_do_not_overlap() {
        // Verify that Alice and Bob never get the same bytes
        let pad_size = 100;
        let entropy: Vec<u8> = (0..pad_size as u8).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Alice takes 30 bytes
        let alice_bytes = pad.consume(30, Role::Initiator).unwrap();

        // Bob takes 60 bytes
        let bob_bytes = pad.consume(60, Role::Responder).unwrap();

        // Verify no overlap
        let alice_set: std::collections::HashSet<u8> = alice_bytes.iter().copied().collect();
        let bob_set: std::collections::HashSet<u8> = bob_bytes.iter().copied().collect();
        let intersection: Vec<_> = alice_set.intersection(&bob_set).collect();
        assert!(
            intersection.is_empty(),
            "Alice and Bob bytes should never overlap"
        );

        // Alice got 0-29, Bob got 40-99
        assert_eq!(alice_bytes, (0..30).collect::<Vec<u8>>());
        assert_eq!(bob_bytes, (40..100).collect::<Vec<u8>>());
    }

    #[test]
    fn dynamic_allocation_peer_update_affects_available() {
        // When we learn peer has consumed bytes, our available space decreases
        let pad_size = 1000;
        let entropy: Vec<u8> = vec![0u8; pad_size];
        let mut pad = Pad::from_bytes(entropy);

        // Initially Alice (as Initiator) can send all 1000 bytes
        assert_eq!(pad.available_for_sending(Role::Initiator), 1000);

        // We receive a message from Bob (peer is Responder), he consumed 600 bytes
        pad.update_peer_consumption(Role::Responder, 600);

        // Now Alice can only send 400 bytes
        assert_eq!(pad.available_for_sending(Role::Initiator), 400);
        assert!(pad.can_send(400, Role::Initiator));
        assert!(!pad.can_send(401, Role::Initiator));

        // If Alice sends 300 bytes
        pad.consume(300, Role::Initiator).unwrap();

        // Only 100 bytes remain
        assert_eq!(pad.remaining(), 100);
        assert_eq!(pad.available_for_sending(Role::Initiator), 100);
    }

    #[test]
    fn dynamic_allocation_offsets_track_correctly() {
        // Verify that send offsets track consumption correctly for asymmetric usage
        let pad_size = 1000;
        let entropy: Vec<u8> = vec![0u8; pad_size];
        let mut pad = Pad::from_bytes(entropy);

        // Initial offsets
        assert_eq!(pad.next_send_offset(Role::Initiator), 0);
        assert_eq!(pad.next_send_offset(Role::Responder), 1000);

        // Alice sends 50 bytes
        pad.consume(50, Role::Initiator).unwrap();
        assert_eq!(pad.next_send_offset(Role::Initiator), 50);
        assert_eq!(pad.next_send_offset(Role::Responder), 1000);

        // Bob sends 800 bytes (asymmetric: Bob uses much more)
        pad.consume(800, Role::Responder).unwrap();
        assert_eq!(pad.next_send_offset(Role::Initiator), 50);
        assert_eq!(pad.next_send_offset(Role::Responder), 200);

        // Alice sends 100 more
        pad.consume(100, Role::Initiator).unwrap();
        assert_eq!(pad.next_send_offset(Role::Initiator), 150);
        assert_eq!(pad.next_send_offset(Role::Responder), 200);

        // Remaining space is 50 bytes (indices 150-199)
        assert_eq!(pad.remaining(), 50);
    }

    #[test]
    fn zero_bytes_at_forward_secrecy() {
        // Test that we can zero specific pad bytes for forward secrecy
        let entropy: Vec<u8> = (0..100).collect();
        let mut pad = Pad::from_bytes(entropy);

        // Verify original bytes
        assert_eq!(pad.as_bytes()[10..20], (10..20).collect::<Vec<u8>>());

        // Zero bytes 10-19
        assert!(pad.zero_bytes_at(10, 10));

        // Verify they are zeroed
        assert_eq!(pad.as_bytes()[10..20], [0u8; 10]);

        // Verify surrounding bytes are unchanged
        assert_eq!(pad.as_bytes()[0..10], (0..10).collect::<Vec<u8>>());
        assert_eq!(pad.as_bytes()[20..30], (20..30).collect::<Vec<u8>>());

        // Consumption counters should be unaffected
        assert_eq!(pad.consumed_front(), 0);
        assert_eq!(pad.consumed_back(), 0);
        assert_eq!(pad.remaining(), 100);
    }

    #[test]
    fn zero_bytes_at_out_of_bounds() {
        let entropy = vec![0xAB; 100];
        let mut pad = Pad::from_bytes(entropy);

        // Beyond pad size
        assert!(!pad.zero_bytes_at(90, 20));
        assert!(!pad.zero_bytes_at(100, 1));

        // Overflow protection
        assert!(!pad.zero_bytes_at(usize::MAX, 1));
    }
}
