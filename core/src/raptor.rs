//! Raptor Codes - Near-optimal rateless erasure codes.
//!
//! Raptor codes improve on LT codes by adding a pre-coding step that ensures
//! near-optimal decoding: K source symbols can be recovered from approximately
//! K + ε encoded symbols, where ε is typically 2-5 symbols regardless of K.
//!
//! This implementation uses a simplified systematic Raptor design:
//! - First K output symbols are source symbols directly (systematic)
//! - Pre-code adds redundancy through LDPC-like parity symbols
//! - LT encoding generates additional repair symbols
//!
//! ## Pre-coding Layer (FROZEN - DO NOT CHANGE)
//!
//! The LDPC-like parity structure is deterministic and must remain unchanged:
//! - P = ceil(K * 0.05) + 3 parity symbols
//! - Each parity XORs ~K/4 source symbols using seed (i + 0x12345678)
//! - Changing this formula breaks decoding compatibility!
//!
//! ## Key advantages over pure LT codes:
//! - Much lower overhead (2-5 extra symbols vs O(√K))
//! - Consistent performance (low variance)
//! - Handles burst losses well due to pre-coding
//!
//! # Example
//!
//! ```
//! use ash_core::raptor::{RaptorEncoder, RaptorDecoder};
//! use ash_core::fountain::EncodedBlock;
//!
//! let data = b"Hello, Raptor codes!";
//! let mut encoder = RaptorEncoder::new(data, 64);
//!
//! let mut decoder = RaptorDecoder::new(encoder.source_count() as u16, 64, data.len());
//!
//! // Raptor codes typically need only K + 2-5 blocks
//! while !decoder.is_complete() {
//!     decoder.add_block(&encoder.next_block());
//! }
//!
//! assert_eq!(decoder.get_data().unwrap(), data);
//! ```

use crate::crc;
use crate::fountain::EncodedBlock;
use std::collections::HashSet;

/// Default block size optimized for QR codes with L correction level.
/// Matches the LT encoder default for API compatibility.
pub const DEFAULT_BLOCK_SIZE: usize = 1500;

/// Raptor Encoder - generates encoded symbols from source data.
///
/// Uses systematic encoding: first K symbols are source data directly,
/// remaining symbols are repair symbols generated via LT encoding over
/// pre-coded intermediate symbols.
///
/// ## API Compatibility
///
/// This encoder is API-compatible with [`crate::fountain::LTEncoder`]:
/// - `source_count()` returns number of source blocks (K)
/// - `block_size()` returns block size in bytes
/// - `next_block()` returns [`EncodedBlock`]
/// - `generate_block(index)` returns specific block
pub struct RaptorEncoder {
    /// Source symbols
    source: Vec<Vec<u8>>,
    /// Pre-coded parity symbols (for repair generation)
    parity: Vec<Vec<u8>>,
    /// Number of source symbols
    k: usize,
    /// Number of parity symbols
    p: usize,
    /// Block size in bytes
    block_size: usize,
    /// Original data length
    original_len: usize,
    /// Next index to generate
    next_index: u32,
}

impl RaptorEncoder {
    /// Create encoder with specified block size.
    pub fn new(data: &[u8], block_size: usize) -> Self {
        assert!(block_size > 0, "block_size must be > 0");

        let original_len = data.len();
        let k = if data.is_empty() {
            1
        } else {
            data.len().div_ceil(block_size)
        };

        // Split source data into K blocks
        let mut source = Vec::with_capacity(k);
        for i in 0..k {
            let start = i * block_size;
            let end = ((i + 1) * block_size).min(data.len());
            let mut block = if start < data.len() {
                data[start..end].to_vec()
            } else {
                Vec::new()
            };
            block.resize(block_size, 0);
            source.push(block);
        }

        // Generate parity blocks using LDPC-like structure
        // P = ceil(K * 0.05) + 3 provides good redundancy
        // WARNING: This formula is FROZEN - changing it breaks compatibility!
        let p = (k as f64 * 0.05).ceil() as usize + 3;
        let parity = Self::generate_parity(&source, p, block_size);

        Self {
            source,
            parity,
            k,
            p,
            block_size,
            original_len,
            next_index: 0,
        }
    }

    /// Generate parity blocks using LDPC-like XOR combinations.
    ///
    /// WARNING: This structure is FROZEN. The seed formula (i + 0x12345678)
    /// and degree formula (K/4) must not change or decoding will break!
    fn generate_parity(source: &[Vec<u8>], p: usize, block_size: usize) -> Vec<Vec<u8>> {
        let k = source.len();
        let mut parity = vec![vec![0u8; block_size]; p];

        for (i, block) in parity.iter_mut().enumerate() {
            // FROZEN: seed = i + 0x12345678
            let mut rng = PseudoRng::new(i as u64 + 0x12345678);

            // FROZEN: degree = K/4, clamped to [2, K]
            let degree = (k / 4).max(2).min(k);

            let mut indices: Vec<usize> = (0..k).collect();
            for _ in 0..degree {
                if indices.is_empty() {
                    break;
                }
                let idx = rng.next_usize() % indices.len();
                let src_idx = indices.swap_remove(idx);
                xor_block(block, &source[src_idx]);
            }
        }

        parity
    }

    /// Generate the next encoded block.
    pub fn next_block(&mut self) -> EncodedBlock {
        let block = self.generate_block(self.next_index);
        self.next_index = self.next_index.wrapping_add(1);
        block
    }

    /// Generate a specific encoded block by index.
    ///
    /// Deterministic: same index always produces same block.
    pub fn generate_block(&self, index: u32) -> EncodedBlock {
        let data = self.encode_block(index);
        let checksum = crc::compute(&data);

        EncodedBlock {
            index,
            source_count: self.k as u16,
            block_size: self.block_size as u16,
            original_len: self.original_len as u32,
            data,
            checksum,
        }
    }

    /// Encode a single block by index.
    fn encode_block(&self, index: u32) -> Vec<u8> {
        let index = index as usize;

        // First K indices: systematic (direct source blocks)
        if index < self.k {
            return self.source[index].clone();
        }

        // Next P indices: parity blocks directly
        if index < self.k + self.p {
            return self.parity[index - self.k].clone();
        }

        // Remaining indices: LT-encoded repair blocks
        // XOR combination of source + parity blocks
        let total = self.k + self.p;
        let mut rng = PseudoRng::new(index as u64);

        // Degree distribution optimized for Raptor
        let degree = self.sample_degree(&mut rng, total);

        let mut result = vec![0u8; self.block_size];
        let mut indices: Vec<usize> = (0..total).collect();

        for _ in 0..degree.min(total) {
            if indices.is_empty() {
                break;
            }
            let idx = rng.next_usize() % indices.len();
            let blk_idx = indices.swap_remove(idx);

            if blk_idx < self.k {
                xor_block(&mut result, &self.source[blk_idx]);
            } else {
                xor_block(&mut result, &self.parity[blk_idx - self.k]);
            }
        }

        result
    }

    /// Sample degree from optimized distribution.
    ///
    /// Distribution tuned for low overhead:
    /// - 5% degree 1 (seeds for decoding)
    /// - 40% degree 2 (most useful for propagation)
    /// - 30% degree 3
    /// - 15% degree 4
    /// - 7% degree 5-10
    /// - 3% degree 10-20
    fn sample_degree(&self, rng: &mut PseudoRng, n: usize) -> usize {
        if n <= 2 {
            return 1;
        }

        let r = rng.next_f64();

        if r < 0.05 {
            1
        } else if r < 0.45 {
            2
        } else if r < 0.75 {
            3
        } else if r < 0.90 {
            4
        } else if r < 0.97 {
            (n / 4).clamp(5, 10)
        } else {
            (n / 2).clamp(10, 20)
        }
    }

    /// Number of source blocks (K).
    pub fn source_count(&self) -> usize {
        self.k
    }

    /// Number of parity blocks (P).
    pub fn parity_count(&self) -> usize {
        self.p
    }

    /// Block size in bytes.
    pub fn block_size(&self) -> usize {
        self.block_size
    }

    /// Original data length.
    pub fn original_len(&self) -> usize {
        self.original_len
    }
}

/// Raptor Decoder - reconstructs source data from received blocks.
///
/// Uses belief propagation with parity recovery fallback for
/// efficient decoding.
///
/// ## API Compatibility
///
/// This decoder is API-compatible with [`crate::fountain::LTDecoder`]:
/// - `from_block(&block)` creates decoder from first block
/// - `add_block(&block)` adds a block, returns true when complete
/// - `is_complete()`, `progress()`, `get_data()` work identically
pub struct RaptorDecoder {
    k: usize,
    p: usize,
    block_size: usize,
    original_len: usize,
    /// Decoded source blocks (None if not yet decoded)
    decoded_source: Vec<Option<Vec<u8>>>,
    /// Decoded parity blocks (None if not yet decoded)
    decoded_parity: Vec<Option<Vec<u8>>>,
    /// Pending equations: (block_data, indices into combined space)
    pending: Vec<(Vec<u8>, Vec<usize>)>,
    /// Track received block indices
    seen_indices: HashSet<u32>,
}

impl RaptorDecoder {
    /// Create decoder with known parameters.
    pub fn new(source_count: u16, block_size: u16, original_len: usize) -> Self {
        let k = source_count as usize;
        // FROZEN: parity count formula must match encoder
        let p = (k as f64 * 0.05).ceil() as usize + 3;

        Self {
            k,
            p,
            block_size: block_size as usize,
            original_len,
            decoded_source: vec![None; k],
            decoded_parity: vec![None; p],
            pending: Vec::new(),
            seen_indices: HashSet::new(),
        }
    }

    /// Create decoder from first received block.
    pub fn from_block(block: &EncodedBlock) -> Self {
        Self::new(
            block.source_count,
            block.block_size,
            block.original_len as usize,
        )
    }

    /// Add a received block. Returns true if decoding is complete.
    pub fn add_block(&mut self, block: &EncodedBlock) -> bool {
        if self.is_complete() {
            return true;
        }

        // Skip duplicates
        if self.seen_indices.contains(&block.index) {
            return self.is_complete();
        }
        self.seen_indices.insert(block.index);

        let index = block.index as usize;

        // Systematic source block
        if index < self.k {
            if self.decoded_source[index].is_none() {
                self.decoded_source[index] = Some(block.data.clone());
                self.propagate();
            }
            return self.is_complete();
        }

        // Parity block
        if index < self.k + self.p {
            let parity_idx = index - self.k;
            if self.decoded_parity[parity_idx].is_none() {
                self.decoded_parity[parity_idx] = Some(block.data.clone());
                self.propagate();
            }
            return self.is_complete();
        }

        // LT-encoded repair block
        let total = self.k + self.p;
        let mut rng = PseudoRng::new(index as u64);
        let degree = self.sample_degree(&mut rng, total);

        let mut indices = Vec::with_capacity(degree);
        let mut available: Vec<usize> = (0..total).collect();

        for _ in 0..degree.min(total) {
            if available.is_empty() {
                break;
            }
            let idx = rng.next_usize() % available.len();
            indices.push(available.swap_remove(idx));
        }

        // Try immediate decoding
        let unknown: Vec<usize> = indices
            .iter()
            .filter(|&&i| self.get_block(i).is_none())
            .copied()
            .collect();

        if unknown.is_empty() {
            // Redundant block
            return self.is_complete();
        }

        if unknown.len() == 1 {
            // Can decode immediately
            let target = unknown[0];
            let mut data = block.data.clone();

            for &i in &indices {
                if i != target {
                    if let Some(blk) = self.get_block(i) {
                        xor_block(&mut data, blk);
                    }
                }
            }

            self.set_block(target, data);
            self.propagate();
        } else {
            // Store for later
            self.pending.push((block.data.clone(), indices));
        }

        self.is_complete()
    }

    /// Sample degree (must match encoder distribution).
    fn sample_degree(&self, rng: &mut PseudoRng, n: usize) -> usize {
        if n <= 2 {
            return 1;
        }

        let r = rng.next_f64();

        if r < 0.05 {
            1
        } else if r < 0.45 {
            2
        } else if r < 0.75 {
            3
        } else if r < 0.90 {
            4
        } else if r < 0.97 {
            (n / 4).clamp(5, 10)
        } else {
            (n / 2).clamp(10, 20)
        }
    }

    fn get_block(&self, idx: usize) -> Option<&Vec<u8>> {
        if idx < self.k {
            self.decoded_source[idx].as_ref()
        } else {
            self.decoded_parity
                .get(idx - self.k)
                .and_then(|s| s.as_ref())
        }
    }

    fn set_block(&mut self, idx: usize, data: Vec<u8>) {
        if idx < self.k {
            self.decoded_source[idx] = Some(data);
        } else if idx - self.k < self.p {
            self.decoded_parity[idx - self.k] = Some(data);
        }
    }

    /// Belief propagation to decode more blocks.
    fn propagate(&mut self) {
        let mut changed = true;
        while changed {
            changed = false;

            // Process pending equations - collect decoded blocks first
            let mut to_remove = Vec::new();
            let mut to_decode = Vec::new();

            for (idx, (data, indices)) in self.pending.iter().enumerate() {
                let unknown: Vec<usize> = indices
                    .iter()
                    .filter(|&&i| self.get_block(i).is_none())
                    .copied()
                    .collect();

                if unknown.is_empty() {
                    to_remove.push(idx);
                } else if unknown.len() == 1 {
                    let target = unknown[0];
                    let mut result = data.clone();

                    for &i in indices.iter() {
                        if i != target {
                            if let Some(blk) = self.get_block(i) {
                                xor_block(&mut result, blk);
                            }
                        }
                    }

                    to_decode.push((target, result));
                    to_remove.push(idx);
                    changed = true;
                }
            }

            // Apply decoded blocks
            for (target, data) in to_decode {
                self.set_block(target, data);
            }

            // Remove processed equations (in reverse order to preserve indices)
            for idx in to_remove.into_iter().rev() {
                self.pending.swap_remove(idx);
            }

            // Try to use parity equations if source blocks are stuck
            if !changed && !self.is_complete() {
                changed = self.try_parity_recovery();
            }
        }
    }

    /// Try to recover source blocks using parity equations.
    fn try_parity_recovery(&mut self) -> bool {
        // For each decoded parity block, check if it can help
        for parity_idx in 0..self.p {
            if self.decoded_parity[parity_idx].is_none() {
                continue;
            }

            // Regenerate the parity equation (FROZEN formula)
            let mut rng = PseudoRng::new(parity_idx as u64 + 0x12345678);
            let degree = (self.k / 4).max(2).min(self.k);

            let mut source_indices = Vec::new();
            let mut available: Vec<usize> = (0..self.k).collect();

            for _ in 0..degree {
                if available.is_empty() {
                    break;
                }
                let idx = rng.next_usize() % available.len();
                source_indices.push(available.swap_remove(idx));
            }

            // Check how many source blocks are unknown
            let unknown: Vec<usize> = source_indices
                .iter()
                .filter(|&&i| self.decoded_source[i].is_none())
                .copied()
                .collect();

            if unknown.len() == 1 {
                // Can recover!
                let target = unknown[0];
                let mut result = self.decoded_parity[parity_idx].as_ref().unwrap().clone();

                for &i in &source_indices {
                    if i != target {
                        if let Some(blk) = &self.decoded_source[i] {
                            xor_block(&mut result, blk);
                        }
                    }
                }

                self.decoded_source[target] = Some(result);
                return true;
            }
        }

        false
    }

    /// Check if all source symbols are decoded.
    pub fn is_complete(&self) -> bool {
        self.decoded_source.iter().all(|s| s.is_some())
    }

    /// Decoding progress (0.0 to 1.0).
    pub fn progress(&self) -> f64 {
        if self.k == 0 {
            return 1.0;
        }
        self.decoded_source.iter().filter(|s| s.is_some()).count() as f64 / self.k as f64
    }

    /// Number of unique blocks received (excluding duplicates).
    pub fn unique_blocks_received(&self) -> usize {
        self.seen_indices.len()
    }

    /// Number of blocks received (alias for compatibility).
    pub fn blocks_received(&self) -> usize {
        self.seen_indices.len()
    }

    /// Number of decoded source blocks.
    pub fn decoded_count(&self) -> usize {
        self.decoded_source.iter().filter(|s| s.is_some()).count()
    }

    /// Source block count (K).
    pub fn source_count(&self) -> usize {
        self.k
    }

    /// Get decoded data (None if incomplete).
    pub fn get_data(&self) -> Option<Vec<u8>> {
        if !self.is_complete() {
            return None;
        }

        let mut data = Vec::with_capacity(self.k * self.block_size);
        for block in &self.decoded_source {
            data.extend_from_slice(block.as_ref()?);
        }
        data.truncate(self.original_len);
        Some(data)
    }
}

/// XOR one block into another.
#[inline]
fn xor_block(dest: &mut [u8], src: &[u8]) {
    for (d, s) in dest.iter_mut().zip(src.iter()) {
        *d ^= s;
    }
}

/// Deterministic PRNG for reproducible encoding/decoding.
struct PseudoRng {
    state: u64,
}

impl PseudoRng {
    fn new(seed: u64) -> Self {
        let mut state = seed;
        state = state.wrapping_add(0x9E3779B97F4A7C15);
        state ^= state >> 30;
        state = state.wrapping_mul(0xBF58476D1CE4E5B9);
        state ^= state >> 27;
        state = state.wrapping_mul(0x94D049BB133111EB);
        state ^= state >> 31;
        Self { state }
    }

    fn next_u64(&mut self) -> u64 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        self.state.wrapping_mul(0x2545F4914F6CDD1D)
    }

    fn next_usize(&mut self) -> usize {
        self.next_u64() as usize
    }

    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raptor_encoded_block_roundtrip() {
        // Test that Raptor uses the same EncodedBlock format as LT codes
        let block = EncodedBlock {
            index: 42,
            source_count: 10,
            block_size: 64,
            original_len: 500,
            data: vec![0xAB; 64],
            checksum: crc::compute(&[0xAB; 64]),
        };

        let encoded = block.encode();
        let decoded = EncodedBlock::decode(&encoded).unwrap();
        assert_eq!(block, decoded);
    }

    #[test]
    fn raptor_small_data() {
        let data = b"Hello, Raptor codes!";
        let mut encoder = RaptorEncoder::new(data, 8);
        let mut decoder = RaptorDecoder::new(encoder.source_count() as u16, 8, data.len());

        println!(
            "Small: K={}, P={}",
            encoder.source_count(),
            encoder.parity_count()
        );

        let mut blocks_used = 0;
        while !decoder.is_complete() {
            decoder.add_block(&encoder.next_block());
            blocks_used += 1;
            assert!(blocks_used < 50, "Too many blocks needed");
        }

        assert_eq!(decoder.get_data().unwrap(), data);
        println!(
            "Small: {} blocks for K={} (overhead: {})",
            blocks_used,
            encoder.source_count(),
            blocks_used - encoder.source_count() as i32
        );
    }

    #[test]
    fn raptor_medium_data() {
        let data: Vec<u8> = (0..1024).map(|i| (i % 256) as u8).collect();
        let mut encoder = RaptorEncoder::new(&data, 64);
        let mut decoder = RaptorDecoder::new(encoder.source_count() as u16, 64, data.len());

        println!(
            "Medium: K={}, P={}",
            encoder.source_count(),
            encoder.parity_count()
        );

        let mut blocks_used = 0;
        while !decoder.is_complete() {
            decoder.add_block(&encoder.next_block());
            blocks_used += 1;
            assert!(blocks_used < 30, "Too many blocks");
        }

        assert_eq!(decoder.get_data().unwrap(), data);
        println!(
            "Medium: {} blocks for K={} (overhead: {})",
            blocks_used,
            encoder.source_count(),
            blocks_used - encoder.source_count() as i32
        );
    }

    #[test]
    fn raptor_large_data() {
        let data: Vec<u8> = (0..65536).map(|i| (i % 256) as u8).collect();
        let mut encoder = RaptorEncoder::new(&data, 512);
        let mut decoder = RaptorDecoder::new(encoder.source_count() as u16, 512, data.len());

        let k = encoder.source_count();
        println!("Large: K={}, P={}", k, encoder.parity_count());

        let mut blocks_used = 0;
        while !decoder.is_complete() {
            decoder.add_block(&encoder.next_block());
            blocks_used += 1;
            assert!(
                blocks_used < k + 20,
                "Too many blocks: {} for K={}",
                blocks_used,
                k
            );
        }

        assert_eq!(decoder.get_data().unwrap(), data);
        let overhead = blocks_used as f64 / k as f64 - 1.0;
        println!(
            "Large: {} blocks for K={} (overhead: {:.1}%)",
            blocks_used,
            k,
            overhead * 100.0
        );
    }

    #[test]
    fn raptor_systematic() {
        // First K blocks should be systematic (raw source data)
        let data: Vec<u8> = (0..256).map(|i| i as u8).collect();
        let encoder = RaptorEncoder::new(&data, 64);

        // First K blocks should directly contain source data
        for i in 0..encoder.source_count() {
            let block = encoder.generate_block(i as u32);
            let start = i * 64;
            let end = ((i + 1) * 64).min(data.len());
            let mut expected = data[start..end].to_vec();
            expected.resize(64, 0);
            assert_eq!(block.data, expected, "Block {} not systematic", i);
        }
    }

    #[test]
    fn raptor_out_of_order() {
        let data = b"Out of order Raptor test!";
        let mut encoder = RaptorEncoder::new(data, 8);
        let k = encoder.source_count();
        let p = encoder.parity_count();

        // Generate K + P + 10 blocks
        let blocks: Vec<_> = (0..(k + p + 10)).map(|_| encoder.next_block()).collect();

        let mut decoder = RaptorDecoder::new(k as u16, 8, data.len());

        // Add in reverse order
        for block in blocks.iter().rev() {
            if decoder.add_block(block) {
                break;
            }
        }

        assert!(decoder.is_complete());
        assert_eq!(decoder.get_data().unwrap(), data);
    }

    #[test]
    fn raptor_with_loss() {
        // Test with simulated packet loss
        let data: Vec<u8> = (0..2048).map(|i| (i % 256) as u8).collect();
        let mut encoder = RaptorEncoder::new(&data, 128);
        let k = encoder.source_count();
        let p = encoder.parity_count();

        // Generate 2x (K+P) blocks
        let total = (k + p) * 2;
        let blocks: Vec<_> = (0..total).map(|_| encoder.next_block()).collect();

        let mut decoder = RaptorDecoder::new(k as u16, 128, data.len());

        // Skip every 5th block (20% loss)
        let mut received = 0;
        for (i, block) in blocks.iter().enumerate() {
            if i % 5 != 0 {
                decoder.add_block(block);
                received += 1;
                if decoder.is_complete() {
                    break;
                }
            }
        }

        assert!(
            decoder.is_complete(),
            "Failed with 20% loss after {} blocks",
            received
        );
        assert_eq!(decoder.get_data().unwrap(), data);
        println!("20% loss: recovered with {} blocks for K={}", received, k);
    }

    // ==================== COMPARISON TESTS ====================

    #[test]
    fn compare_raptor_vs_lt() {
        use crate::fountain::{LegacyLTDecoder, LegacyLTEncoder};

        println!("\n=== Raptor vs LT Comparison ===");
        println!(
            "{:>8} {:>6} {:>12} {:>12} {:>10}",
            "Size", "K", "LT blocks", "Raptor", "Savings"
        );

        for size in [1024, 4096, 16384, 65536] {
            let data: Vec<u8> = (0..size).map(|i| (i % 256) as u8).collect();
            let block_size = 256;

            // LT test (average of 5 runs)
            let mut lt_total = 0;
            for _ in 0..5 {
                let mut lt_enc = LegacyLTEncoder::new(&data, block_size);
                let k = lt_enc.source_count();
                let mut lt_dec = LegacyLTDecoder::new(k as u16, block_size as u16, size);
                let mut lt_blocks = 0;
                while !lt_dec.is_complete() {
                    lt_dec.add_block(&lt_enc.next_block());
                    lt_blocks += 1;
                }
                lt_total += lt_blocks;
            }
            let lt_blocks = lt_total / 5;

            // Raptor test (average of 5 runs)
            let mut raptor_total = 0;
            let mut k = 0;
            for _ in 0..5 {
                let mut raptor_enc = RaptorEncoder::new(&data, block_size);
                k = raptor_enc.source_count();
                let mut raptor_dec = RaptorDecoder::new(k as u16, block_size as u16, size);
                let mut raptor_blocks = 0;
                while !raptor_dec.is_complete() {
                    raptor_dec.add_block(&raptor_enc.next_block());
                    raptor_blocks += 1;
                }
                raptor_total += raptor_blocks;
            }
            let raptor_blocks = raptor_total / 5;

            let savings = (1.0 - raptor_blocks as f64 / lt_blocks as f64) * 100.0;
            println!(
                "{:>7}K {:>6} {:>12} {:>12} {:>9.1}%",
                size / 1024,
                k,
                lt_blocks,
                raptor_blocks,
                savings
            );
        }
    }

    #[test]
    fn raptor_overhead_stats() {
        println!("\n=== Raptor Overhead Statistics ===");
        println!(
            "{:>8} {:>6} {:>6} {:>8} {:>8} {:>8}",
            "Size", "K", "P", "Min", "Max", "Avg"
        );

        for size in [1024, 4096, 16384, 65536] {
            let data: Vec<u8> = (0..size).map(|i| (i % 256) as u8).collect();
            let block_size = 256;

            let mut min_blocks = usize::MAX;
            let mut max_blocks = 0;
            let mut total_blocks = 0;
            let runs = 20;

            let mut k = 0;
            let mut p = 0;

            for _ in 0..runs {
                let mut enc = RaptorEncoder::new(&data, block_size);
                k = enc.source_count();
                p = enc.parity_count();
                let mut dec = RaptorDecoder::new(k as u16, block_size as u16, size);

                let mut blocks = 0;
                while !dec.is_complete() {
                    dec.add_block(&enc.next_block());
                    blocks += 1;
                }

                min_blocks = min_blocks.min(blocks);
                max_blocks = max_blocks.max(blocks);
                total_blocks += blocks;
            }

            let avg = total_blocks as f64 / runs as f64;
            println!(
                "{:>7}K {:>6} {:>6} {:>8} {:>8} {:>8.1}",
                size / 1024,
                k,
                p,
                min_blocks,
                max_blocks,
                avg
            );
        }
    }
}
