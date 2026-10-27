//! Pad usage calculator for capacity planning.
//!
//! This module provides calculations for:
//! - Message capacity based on pad size
//! - QR code count for ceremony transfer
//! - Authentication overhead impact
//! - Pad exhaustion estimates
//!
//! # Security Model
//!
//! Each message consumes pad bytes for:
//! - **Authentication**: 64 bytes (r₁, r₂, s₁, s₂ for 256-bit Wegman-Carter MAC)
//! - **Encryption**: Variable (equal to plaintext length)
//!
//! # Example
//!
//! ```
//! use ash_core::pad_calculator::{PadCalculator, calculate_pad_stats};
//! use ash_core::TransferMethod;
//!
//! // Calculate stats for a 256 KB pad with Raptor codes
//! let stats = calculate_pad_stats(256 * 1024);
//!
//! println!("Messages at 100 bytes avg: {}", stats.messages_at_avg(100));
//! println!("Source blocks: {}", stats.source_blocks);
//! println!("Expected frames (Raptor): {}", stats.expected_frames(TransferMethod::Raptor));
//! ```

use crate::frame::TransferMethod;
use crate::mac::AUTH_KEY_SIZE;
use crate::message::HEADER_SIZE;

/// Authentication overhead per message in bytes.
///
/// This is the fixed cost for Wegman-Carter MAC: r₁ + r₂ + s₁ + s₂ = 64 bytes.
pub const AUTH_OVERHEAD: usize = AUTH_KEY_SIZE;

/// Frame header size in bytes.
pub const FRAME_OVERHEAD: usize = HEADER_SIZE;

/// Default QR block size for ceremony transfer (bytes per QR code).
pub const DEFAULT_QR_BLOCK_SIZE: usize = 1500;

/// Metadata overhead in bytes (version + ttl + disappearing + flags + url_len + typical url).
pub const METADATA_OVERHEAD: usize = 50;

/// Reserved bytes at pad start for token derivation.
///
/// The first 160 bytes are used for conversation ID, auth token, and burn token.
pub const RESERVED_FOR_TOKENS: usize = 160;

/// Calculate expected frames needed for successful transfer.
///
/// # Arguments
///
/// * `source_blocks` - Number of source blocks (K)
/// * `method` - Transfer method
///
/// # Returns
///
/// Expected number of frames to scan for successful decoding.
pub fn expected_frames(source_blocks: usize, method: TransferMethod) -> usize {
    match method {
        // Raptor: K + 2-5 blocks, we use 5% + 3 for safety margin
        TransferMethod::Raptor => {
            let overhead = (source_blocks as f64 * 0.05) as usize + 3;
            source_blocks + overhead
        }
        // LT codes: K + O(√K), we use 15% + √K
        TransferMethod::LT => {
            let sqrt_k = (source_blocks as f64).sqrt() as usize;
            let overhead = (source_blocks as f64 * 0.15) as usize + sqrt_k;
            source_blocks + overhead
        }
        // Sequential: exactly K frames (all must be received)
        TransferMethod::Sequential => source_blocks,
    }
}

/// Calculate redundancy blocks to pre-generate beyond source count.
///
/// This is used for QR pre-generation to ensure enough frames are ready.
pub fn redundancy_blocks(source_blocks: usize, method: TransferMethod) -> usize {
    const MIN_REDUNDANCY: usize = 15;
    const REDUNDANCY_PERCENTAGE: f64 = 0.15;

    match method {
        TransferMethod::Raptor => {
            // Raptor needs less redundancy (2-5 blocks typical)
            std::cmp::max(
                MIN_REDUNDANCY,
                (source_blocks as f64 * REDUNDANCY_PERCENTAGE) as usize,
            )
        }
        TransferMethod::LT => {
            // LT needs more redundancy: O(√K)
            let sqrt_k = (source_blocks as f64).sqrt() as usize;
            std::cmp::max(20, sqrt_k * 2)
        }
        TransferMethod::Sequential => {
            // Sequential: cycle through source blocks once more
            source_blocks
        }
    }
}

/// Pad usage statistics and calculations.
#[derive(Debug, Clone, PartialEq)]
pub struct PadStats {
    /// Total pad size in bytes.
    pub pad_size: usize,

    /// Usable bytes after token reservation.
    pub usable_bytes: usize,

    /// Authentication overhead per message (64 bytes).
    pub auth_overhead_per_message: usize,

    /// Number of source blocks (K) for fountain encoding.
    pub source_blocks: usize,

    /// Bytes per QR code used in calculation.
    pub bytes_per_qr: usize,

    /// DEPRECATED: Use expected_frames() instead.
    /// This is kept for backwards compatibility but represents source blocks only.
    pub qr_codes_needed: usize,

    /// Estimated ceremony transfer time at given QR scan rate.
    pub estimated_transfer_seconds: f64,
}

impl PadStats {
    /// Calculate expected frames for a given transfer method.
    ///
    /// This is the number of frames needed for successful transfer,
    /// accounting for erasure coding overhead.
    pub fn expected_frames(&self, method: TransferMethod) -> usize {
        expected_frames(self.source_blocks, method)
    }

    /// Calculate redundancy blocks to pre-generate for a given transfer method.
    pub fn redundancy_blocks(&self, method: TransferMethod) -> usize {
        redundancy_blocks(self.source_blocks, method)
    }

    /// Calculate total frames to pre-generate (source + redundancy).
    pub fn frames_to_generate(&self, method: TransferMethod) -> usize {
        self.source_blocks + self.redundancy_blocks(method)
    }
}

impl PadStats {
    /// Calculate how many messages can be sent with a given average message size.
    ///
    /// # Arguments
    ///
    /// * `avg_message_bytes` - Average plaintext message size in bytes
    ///
    /// # Returns
    ///
    /// Number of messages that can fit (considering auth overhead).
    ///
    /// # Formula
    ///
    /// `messages = usable_bytes / (auth_overhead + avg_message_bytes)`
    pub fn messages_at_avg(&self, avg_message_bytes: usize) -> usize {
        let bytes_per_message = AUTH_OVERHEAD + avg_message_bytes;
        if bytes_per_message == 0 {
            return 0;
        }
        self.usable_bytes / bytes_per_message
    }

    /// Calculate messages for text of a given average character count.
    ///
    /// Assumes UTF-8 encoding with ~1.5 bytes per character average
    /// (accounting for some emoji/unicode).
    pub fn messages_at_avg_chars(&self, avg_chars: usize) -> usize {
        let avg_bytes = (avg_chars * 3) / 2; // ~1.5 bytes per char
        self.messages_at_avg(avg_bytes)
    }

    /// Calculate total bytes consumed for N messages of a given average size.
    pub fn bytes_for_messages(&self, count: usize, avg_message_bytes: usize) -> usize {
        count * (AUTH_OVERHEAD + avg_message_bytes)
    }

    /// Calculate remaining pad capacity after sending N messages.
    ///
    /// Returns (remaining_bytes, remaining_messages_at_same_avg).
    pub fn remaining_after(
        &self,
        messages_sent: usize,
        avg_message_bytes: usize,
    ) -> (usize, usize) {
        let consumed = self.bytes_for_messages(messages_sent, avg_message_bytes);
        let remaining = self.usable_bytes.saturating_sub(consumed);
        let remaining_messages = remaining / (AUTH_OVERHEAD + avg_message_bytes);
        (remaining, remaining_messages)
    }
}

/// Calculate pad statistics for a given size.
///
/// # Arguments
///
/// * `pad_size` - Total pad size in bytes
///
/// # Returns
///
/// [`PadStats`] with all calculated metrics.
///
/// # Example
///
/// ```
/// use ash_core::pad_calculator::calculate_pad_stats;
///
/// let stats = calculate_pad_stats(64 * 1024); // 64 KB
/// assert!(stats.messages_at_avg(100) > 300);
/// ```
pub fn calculate_pad_stats(pad_size: usize) -> PadStats {
    calculate_pad_stats_with_qr_size(pad_size, DEFAULT_QR_BLOCK_SIZE)
}

/// Calculate pad statistics with custom QR block size.
///
/// # Arguments
///
/// * `pad_size` - Total pad size in bytes
/// * `qr_block_size` - Bytes per QR code (default 1500)
pub fn calculate_pad_stats_with_qr_size(pad_size: usize, qr_block_size: usize) -> PadStats {
    let usable_bytes = pad_size.saturating_sub(RESERVED_FOR_TOKENS);

    // Total data to encode: pad + metadata
    let total_data = pad_size + METADATA_OVERHEAD;

    // Source blocks (K): ceiling division of total data by block size
    let source_blocks = if qr_block_size == 0 {
        0
    } else {
        total_data.div_ceil(qr_block_size)
    };

    // qr_codes_needed is deprecated, kept for compatibility (same as source_blocks)
    let qr_codes_needed = source_blocks;

    // Estimate transfer time at 10 QR codes per second scan rate
    // Use Raptor overhead for estimate
    let qr_scan_rate = 10.0;
    let expected = expected_frames(source_blocks, TransferMethod::Raptor);
    let estimated_transfer_seconds = expected as f64 / qr_scan_rate;

    PadStats {
        pad_size,
        usable_bytes,
        auth_overhead_per_message: AUTH_OVERHEAD,
        source_blocks,
        qr_codes_needed,
        bytes_per_qr: qr_block_size,
        estimated_transfer_seconds,
    }
}

/// Detailed pad calculator with configurable parameters.
#[derive(Debug, Clone)]
pub struct PadCalculator {
    /// Pad size in bytes.
    pub pad_size: usize,
    /// Bytes per QR code.
    pub qr_block_size: usize,
    /// Expected QR scan rate (codes per second).
    pub qr_scan_rate: f64,
}

impl PadCalculator {
    /// Create a new calculator with default settings.
    pub fn new(pad_size: usize) -> Self {
        Self {
            pad_size,
            qr_block_size: DEFAULT_QR_BLOCK_SIZE,
            qr_scan_rate: 10.0,
        }
    }

    /// Set custom QR block size.
    pub fn with_qr_block_size(mut self, size: usize) -> Self {
        self.qr_block_size = size;
        self
    }

    /// Set expected QR scan rate.
    pub fn with_qr_scan_rate(mut self, rate: f64) -> Self {
        self.qr_scan_rate = rate;
        self
    }

    /// Calculate statistics.
    pub fn calculate(&self) -> PadStats {
        let usable_bytes = self.pad_size.saturating_sub(RESERVED_FOR_TOKENS);

        // Total data to encode: pad + metadata
        let total_data = self.pad_size + METADATA_OVERHEAD;

        let source_blocks = if self.qr_block_size == 0 {
            0
        } else {
            total_data.div_ceil(self.qr_block_size)
        };

        let qr_codes_needed = source_blocks;

        let estimated_transfer_seconds = if self.qr_scan_rate > 0.0 {
            let expected = expected_frames(source_blocks, TransferMethod::Raptor);
            expected as f64 / self.qr_scan_rate
        } else {
            0.0
        };

        PadStats {
            pad_size: self.pad_size,
            usable_bytes,
            auth_overhead_per_message: AUTH_OVERHEAD,
            source_blocks,
            qr_codes_needed,
            bytes_per_qr: self.qr_block_size,
            estimated_transfer_seconds,
        }
    }

    /// Calculate message capacity for various average sizes.
    ///
    /// Returns a list of (avg_size, message_count) pairs.
    pub fn message_capacity_table(&self) -> Vec<(usize, usize)> {
        let stats = self.calculate();
        vec![
            (50, stats.messages_at_avg(50)),     // Short messages
            (100, stats.messages_at_avg(100)),   // Medium messages
            (200, stats.messages_at_avg(200)),   // Longer messages
            (500, stats.messages_at_avg(500)),   // Long messages
            (1000, stats.messages_at_avg(1000)), // Very long messages
        ]
    }
}

/// Format bytes as human-readable string.
pub fn format_bytes(bytes: usize) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        format!("{:.2} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if bytes >= 1024 * 1024 {
        format!("{:.2} MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.2} KB", bytes as f64 / 1024.0)
    } else {
        format!("{} bytes", bytes)
    }
}

/// Format duration as human-readable string.
pub fn format_duration(seconds: f64) -> String {
    if seconds < 60.0 {
        format!("{:.1} seconds", seconds)
    } else if seconds < 3600.0 {
        let mins = seconds / 60.0;
        format!("{:.1} minutes", mins)
    } else {
        let hours = seconds / 3600.0;
        format!("{:.1} hours", hours)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_overhead_is_64_bytes() {
        assert_eq!(AUTH_OVERHEAD, 64);
    }

    #[test]
    fn calculate_stats_basic() {
        let stats = calculate_pad_stats(64 * 1024);

        assert_eq!(stats.pad_size, 64 * 1024);
        assert_eq!(stats.usable_bytes, 64 * 1024 - RESERVED_FOR_TOKENS);
        assert_eq!(stats.auth_overhead_per_message, 64);
    }

    #[test]
    fn messages_at_avg_calculation() {
        let stats = calculate_pad_stats(64 * 1024);

        // With 100 byte messages + 64 byte auth = 164 bytes per message
        // Usable: 65536 - 160 = 65376 bytes
        // Messages: 65376 / 164 = 398
        let messages = stats.messages_at_avg(100);
        assert_eq!(messages, 398);
    }

    #[test]
    fn messages_at_avg_empty() {
        let stats = calculate_pad_stats(64 * 1024);

        // Empty messages: just auth overhead = 64 bytes per message
        let messages = stats.messages_at_avg(0);
        assert_eq!(messages, (64 * 1024 - RESERVED_FOR_TOKENS) / 64);
    }

    #[test]
    fn qr_codes_calculation() {
        // 64 KB pad with 1500 byte QR blocks
        let stats = calculate_pad_stats(64 * 1024);

        // 65536 / 1500 = 43.69 -> 44 QR codes
        assert_eq!(stats.qr_codes_needed, 44);
    }

    #[test]
    fn qr_codes_large_pad() {
        // 1 MB pad
        let stats = calculate_pad_stats(1024 * 1024);

        // 1048576 / 1500 = 699.05 -> 700 QR codes
        assert_eq!(stats.qr_codes_needed, 700);
    }

    #[test]
    fn transfer_time_estimate() {
        let stats = calculate_pad_stats(64 * 1024);

        // 44 source blocks + Raptor overhead (5% + 3) = 49 expected frames
        // 49 frames at 10/second = 4.9 seconds
        assert!((stats.estimated_transfer_seconds - 4.9).abs() < 0.1);
    }

    #[test]
    fn bytes_for_messages() {
        let stats = calculate_pad_stats(64 * 1024);

        // 10 messages of 100 bytes = 10 * (64 + 100) = 1640 bytes
        assert_eq!(stats.bytes_for_messages(10, 100), 1640);
    }

    #[test]
    fn remaining_after() {
        let stats = calculate_pad_stats(64 * 1024);

        let (remaining_bytes, remaining_msgs) = stats.remaining_after(100, 100);

        // Consumed: 100 * 164 = 16400 bytes
        // Remaining: 65376 - 16400 = 48976 bytes
        assert_eq!(remaining_bytes, 65376 - 16400);
        // Remaining messages: 48976 / 164 = 298
        assert_eq!(remaining_msgs, 298);
    }

    #[test]
    fn calculator_custom_settings() {
        let calc = PadCalculator::new(256 * 1024)
            .with_qr_block_size(2000)
            .with_qr_scan_rate(15.0);

        let stats = calc.calculate();

        assert_eq!(stats.pad_size, 256 * 1024);
        assert_eq!(stats.bytes_per_qr, 2000);
        // (262144 + 50) / 2000 = 131.097 -> 132 source blocks
        assert_eq!(stats.qr_codes_needed, 132);
        // 132 source blocks + Raptor overhead (5% + 3) = 141 expected frames
        // 141 / 15 = 9.4 seconds
        assert!((stats.estimated_transfer_seconds - 9.4).abs() < 0.1);
    }

    #[test]
    fn message_capacity_table() {
        let calc = PadCalculator::new(256 * 1024);
        let table = calc.message_capacity_table();

        assert_eq!(table.len(), 5);

        // Verify some entries
        for (avg_size, count) in &table {
            assert!(
                *count > 0,
                "Should have positive message count for size {}",
                avg_size
            );
        }

        // Larger messages should have fewer count
        assert!(table[0].1 > table[4].1);
    }

    #[test]
    fn format_bytes_test() {
        assert_eq!(format_bytes(500), "500 bytes");
        assert_eq!(format_bytes(1024), "1.00 KB");
        assert_eq!(format_bytes(64 * 1024), "64.00 KB");
        assert_eq!(format_bytes(1024 * 1024), "1.00 MB");
        assert_eq!(format_bytes(1024 * 1024 * 1024), "1.00 GB");
    }

    #[test]
    fn format_duration_test() {
        assert_eq!(format_duration(5.5), "5.5 seconds");
        assert_eq!(format_duration(90.0), "1.5 minutes");
        assert_eq!(format_duration(3600.0), "1.0 hours");
    }

    #[test]
    fn various_pad_sizes() {
        // Test a range of valid pad sizes
        let sizes = [
            32 * 1024,         // 32 KB (minimum)
            64 * 1024,         // 64 KB
            256 * 1024,        // 256 KB
            512 * 1024,        // 512 KB
            1024 * 1024,       // 1 MB
            10 * 1024 * 1024,  // 10 MB
            100 * 1024 * 1024, // 100 MB
        ];

        for size in sizes {
            let stats = calculate_pad_stats(size);
            assert_eq!(stats.pad_size, size);
            assert!(stats.usable_bytes < size);
            assert!(stats.messages_at_avg(100) > 0);
            assert!(stats.qr_codes_needed > 0);
        }
    }

    #[test]
    fn messages_at_avg_chars() {
        let stats = calculate_pad_stats(64 * 1024);

        // 100 characters * 1.5 = 150 bytes avg
        let messages = stats.messages_at_avg_chars(100);

        // Compare with direct calculation: (64*1024 - 160) / (64 + 150) = 305
        assert_eq!(messages, 305);
    }
}
