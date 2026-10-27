//! LT Codes (Luby Transform) for reliable rateless erasure coding.
//!
//! LT codes provide near-optimal recovery: K source symbols can be recovered
//! from approximately K + O(√K) encoded symbols with high probability.
//!
//! Key improvements over simple XOR pairs:
//! - Variable degree (1 to K neighbors) per encoded block
//! - Robust Soliton distribution ensures many degree-1 blocks
//! - Belief propagation decoding enables cascading recovery
//!
//! # Example
//!
//! ```
//! use ash_core::fountain::{LTEncoder, LTDecoder};
//!
//! let data = b"Hello, LT codes!";
//! let mut encoder = LTEncoder::new(data, 8);
//!
//! let mut decoder = LTDecoder::new(encoder.source_count() as u16, 8, data.len());
//!
//! while !decoder.is_complete() {
//!     decoder.add_block(&encoder.next_block());
//! }
//!
//! assert_eq!(decoder.get_data().unwrap(), data);
//! ```

use crate::crc;
use crate::error::{Error, Result};

/// Default block size in bytes.
/// ~1500 bytes fits well in QR codes with L correction.
pub const DEFAULT_BLOCK_SIZE: usize = 1500;

/// An encoded block for transmission.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedBlock {
    /// Block index (sequential, 0..infinity).
    pub index: u32,
    /// Total number of source blocks.
    pub source_count: u16,
    /// Size of each block in bytes.
    pub block_size: u16,
    /// Original data length.
    pub original_len: u32,
    /// Block data (XOR of selected source blocks).
    pub data: Vec<u8>,
    /// CRC-32 checksum.
    pub checksum: u32,
}

impl EncodedBlock {
    /// Encode to bytes: `[index:4][count:2][size:2][len:4][data:N][crc:4]`
    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(16 + self.data.len());
        bytes.extend_from_slice(&self.index.to_be_bytes());
        bytes.extend_from_slice(&self.source_count.to_be_bytes());
        bytes.extend_from_slice(&self.block_size.to_be_bytes());
        bytes.extend_from_slice(&self.original_len.to_be_bytes());
        bytes.extend_from_slice(&self.data);
        bytes.extend_from_slice(&self.checksum.to_be_bytes());
        bytes
    }

    /// Decode from bytes.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 17 {
            return Err(Error::FountainBlockTooShort {
                size: bytes.len(),
                minimum: 17,
            });
        }

        let index = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        let source_count = u16::from_be_bytes([bytes[4], bytes[5]]);
        let block_size = u16::from_be_bytes([bytes[6], bytes[7]]);
        let original_len = u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);

        let data_end = 12 + block_size as usize;
        if bytes.len() < data_end + 4 {
            return Err(Error::FountainBlockTooShort {
                size: bytes.len(),
                minimum: data_end + 4,
            });
        }

        let data = bytes[12..data_end].to_vec();
        let checksum = u32::from_be_bytes([
            bytes[data_end],
            bytes[data_end + 1],
            bytes[data_end + 2],
            bytes[data_end + 3],
        ]);

        let computed = crc::compute(&data);
        if computed != checksum {
            return Err(Error::CrcMismatch {
                expected: checksum,
                actual: computed,
            });
        }

        Ok(Self {
            index,
            source_count,
            block_size,
            original_len,
            data,
            checksum,
        })
    }
}

/// LT Encoder - generates encoded blocks from source data.
pub struct LTEncoder {
    source_blocks: Vec<Vec<u8>>,
    block_size: usize,
    original_len: usize,
    next_index: u32,
    k: usize, // Number of source blocks
}

impl LTEncoder {
    /// Create encoder with specified block size.
    pub fn new(data: &[u8], block_size: usize) -> Self {
        assert!(block_size > 0, "block_size must be > 0");

        let original_len = data.len();
        let k = if data.is_empty() {
            1
        } else {
            data.len().div_ceil(block_size)
        };

        // Split into blocks, pad last with zeros
        let mut source_blocks = Vec::with_capacity(k);
        for i in 0..k {
            let start = i * block_size;
            let end = ((i + 1) * block_size).min(data.len());
            let mut block = if start < data.len() {
                data[start..end].to_vec()
            } else {
                Vec::new()
            };
            block.resize(block_size, 0);
            source_blocks.push(block);
        }

        Self {
            source_blocks,
            block_size,
            original_len,
            next_index: 0,
            k,
        }
    }

    /// Create encoder with default block size.
    pub fn with_default_block_size(data: &[u8]) -> Self {
        Self::new(data, DEFAULT_BLOCK_SIZE)
    }

    /// Generate next block.
    pub fn next_block(&mut self) -> EncodedBlock {
        let block = self.generate_block(self.next_index);
        self.next_index = self.next_index.wrapping_add(1);
        block
    }

    /// Generate specific block by index.
    pub fn generate_block(&self, index: u32) -> EncodedBlock {
        // First K blocks are source blocks directly (degree 1, identity)
        // This guarantees we have raw source blocks for easy recovery start
        let data = if (index as usize) < self.k {
            self.source_blocks[index as usize].clone()
        } else {
            // Encoded blocks use LT degree distribution
            let neighbors = self.get_neighbors(index);
            self.xor_neighbors(&neighbors)
        };

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

    /// Get neighbor indices for an encoded block using Robust Soliton distribution.
    fn get_neighbors(&self, index: u32) -> Vec<usize> {
        let mut rng = PseudoRng::new(index as u64);
        let degree = self.sample_degree(&mut rng);

        // Select `degree` unique neighbors
        let mut neighbors = Vec::with_capacity(degree);
        let mut available: Vec<usize> = (0..self.k).collect();

        for _ in 0..degree.min(self.k) {
            if available.is_empty() {
                break;
            }
            let idx = rng.next_usize() % available.len();
            neighbors.push(available.swap_remove(idx));
        }

        neighbors
    }

    /// Sample degree from Robust Soliton distribution.
    /// This distribution ensures:
    /// - Many degree-1 blocks (for decoding "seeds")
    /// - Good coverage across all source blocks
    fn sample_degree(&self, rng: &mut PseudoRng) -> usize {
        let k = self.k;
        if k == 1 {
            return 1;
        }

        // Robust Soliton distribution parameters
        // c and delta control the spike at degree k/R
        let c = 0.1;
        let delta = 0.5;
        let r = c * (k as f64).ln() * (k as f64 / delta).sqrt();
        let r = r.max(1.0);

        // Build CDF of Robust Soliton distribution
        // ρ(d) = 1/k for d=1, 1/(d*(d-1)) for d=2..k (Ideal Soliton)
        // τ(d) = spike at d = k/R (Robust addition)
        let mut cdf = Vec::with_capacity(k);
        let mut sum = 0.0;

        for d in 1..=k {
            // Ideal Soliton
            let rho = if d == 1 {
                1.0 / k as f64
            } else {
                1.0 / (d * (d - 1)) as f64
            };

            // Robust Soliton addition (spike)
            #[allow(clippy::comparison_chain)]
            let tau = if d < (k as f64 / r) as usize {
                r / (d as f64 * k as f64)
            } else if d == (k as f64 / r) as usize {
                r * (r / delta).ln() / k as f64
            } else {
                0.0
            };

            sum += rho + tau;
            cdf.push(sum);
        }

        // Normalize and sample
        let sample = rng.next_f64() * sum;
        for (d, &threshold) in cdf.iter().enumerate() {
            if sample <= threshold {
                return d + 1;
            }
        }

        k // Fallback (shouldn't happen)
    }

    /// XOR multiple source blocks together.
    fn xor_neighbors(&self, neighbors: &[usize]) -> Vec<u8> {
        let mut result = vec![0u8; self.block_size];
        for &idx in neighbors {
            for (r, s) in result.iter_mut().zip(self.source_blocks[idx].iter()) {
                *r ^= s;
            }
        }
        result
    }

    /// Number of source blocks.
    pub fn source_count(&self) -> usize {
        self.k
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

/// LT Decoder - reconstructs data from received blocks.
pub struct LTDecoder {
    k: usize,
    block_size: usize,
    original_len: usize,
    /// Decoded source blocks (None if not yet decoded)
    decoded: Vec<Option<Vec<u8>>>,
    /// Pending encoded blocks: (block_data, neighbor_indices)
    pending: Vec<(Vec<u8>, Vec<usize>)>,
    /// Track which block indices we've seen (to skip duplicates)
    seen_indices: std::collections::HashSet<u32>,
}

impl LTDecoder {
    /// Create decoder from first received block.
    pub fn from_block(block: &EncodedBlock) -> Self {
        Self::new(
            block.source_count,
            block.block_size,
            block.original_len as usize,
        )
    }

    /// Create decoder with known parameters.
    pub fn new(source_count: u16, block_size: u16, original_len: usize) -> Self {
        let k = source_count as usize;
        Self {
            k,
            block_size: block_size as usize,
            original_len,
            decoded: vec![None; k],
            pending: Vec::new(),
            seen_indices: std::collections::HashSet::new(),
        }
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

        // First K blocks are source blocks directly
        if (block.index as usize) < self.k {
            let idx = block.index as usize;
            if self.decoded[idx].is_none() {
                self.decoded[idx] = Some(block.data.clone());
                self.propagate();
            }
            return self.is_complete();
        }

        // For encoded blocks, compute neighbors and try to process
        let neighbors = self.get_neighbors(block.index, self.k);

        // Try immediate decoding if degree-1 after removing known blocks
        let unknown: Vec<usize> = neighbors
            .iter()
            .filter(|&&n| self.decoded[n].is_none())
            .copied()
            .collect();

        if unknown.is_empty() {
            // All neighbors known - redundant block
            return self.is_complete();
        }

        if unknown.len() == 1 {
            // Can decode immediately!
            let target = unknown[0];
            let mut data = block.data.clone();

            // XOR out known neighbors
            for &n in &neighbors {
                if n != target {
                    if let Some(ref src) = self.decoded[n] {
                        for (d, s) in data.iter_mut().zip(src.iter()) {
                            *d ^= s;
                        }
                    }
                }
            }

            self.decoded[target] = Some(data);
            self.propagate();
        } else {
            // Store for later processing
            self.pending.push((block.data.clone(), neighbors));
        }

        self.is_complete()
    }

    /// Belief propagation: try to decode more blocks using pending blocks.
    fn propagate(&mut self) {
        let mut changed = true;
        while changed {
            changed = false;

            self.pending.retain_mut(|(data, neighbors)| {
                // Find unknown neighbors
                let unknown: Vec<usize> = neighbors
                    .iter()
                    .filter(|&&n| self.decoded[n].is_none())
                    .copied()
                    .collect();

                if unknown.is_empty() {
                    // All known - discard
                    return false;
                }

                if unknown.len() == 1 {
                    // Can decode!
                    let target = unknown[0];
                    let mut result = data.clone();

                    for &n in neighbors.iter() {
                        if n != target {
                            if let Some(ref src) = self.decoded[n] {
                                for (d, s) in result.iter_mut().zip(src.iter()) {
                                    *d ^= s;
                                }
                            }
                        }
                    }

                    self.decoded[target] = Some(result);
                    changed = true;
                    return false; // Remove from pending
                }

                true // Keep in pending
            });
        }
    }

    /// Get neighbor indices for an encoded block (must match encoder).
    fn get_neighbors(&self, index: u32, k: usize) -> Vec<usize> {
        let mut rng = PseudoRng::new(index as u64);
        let degree = self.sample_degree(k, &mut rng);

        let mut neighbors = Vec::with_capacity(degree);
        let mut available: Vec<usize> = (0..k).collect();

        for _ in 0..degree.min(k) {
            if available.is_empty() {
                break;
            }
            let idx = rng.next_usize() % available.len();
            neighbors.push(available.swap_remove(idx));
        }

        neighbors
    }

    /// Sample degree (must match encoder).
    fn sample_degree(&self, k: usize, rng: &mut PseudoRng) -> usize {
        if k == 1 {
            return 1;
        }

        let c = 0.1;
        let delta = 0.5;
        let r = c * (k as f64).ln() * (k as f64 / delta).sqrt();
        let r = r.max(1.0);

        let mut cdf = Vec::with_capacity(k);
        let mut sum = 0.0;

        for d in 1..=k {
            let rho = if d == 1 {
                1.0 / k as f64
            } else {
                1.0 / (d * (d - 1)) as f64
            };

            #[allow(clippy::comparison_chain)]
            let tau = if d < (k as f64 / r) as usize {
                r / (d as f64 * k as f64)
            } else if d == (k as f64 / r) as usize {
                r * (r / delta).ln() / k as f64
            } else {
                0.0
            };

            sum += rho + tau;
            cdf.push(sum);
        }

        let sample = rng.next_f64() * sum;
        for (d, &threshold) in cdf.iter().enumerate() {
            if sample <= threshold {
                return d + 1;
            }
        }

        k
    }

    /// Check if all source blocks are decoded.
    pub fn is_complete(&self) -> bool {
        self.decoded.iter().all(|b| b.is_some())
    }

    /// Decoding progress (0.0 to 1.0).
    pub fn progress(&self) -> f64 {
        if self.k == 0 {
            return 1.0;
        }
        self.decoded.iter().filter(|b| b.is_some()).count() as f64 / self.k as f64
    }

    /// Number of decoded blocks.
    pub fn decoded_count(&self) -> usize {
        self.decoded.iter().filter(|b| b.is_some()).count()
    }

    /// Total source blocks needed.
    pub fn source_count(&self) -> usize {
        self.k
    }

    /// Number of unique blocks received (excluding duplicates).
    pub fn unique_blocks_received(&self) -> usize {
        self.seen_indices.len()
    }

    /// Get decoded data (None if incomplete).
    pub fn get_data(&self) -> Option<Vec<u8>> {
        if !self.is_complete() {
            return None;
        }

        let mut data = Vec::with_capacity(self.k * self.block_size);
        for block in &self.decoded {
            data.extend_from_slice(block.as_ref()?);
        }
        data.truncate(self.original_len);
        Some(data)
    }
}

/// Simple deterministic PRNG for reproducible neighbor selection.
/// Both encoder and decoder must use the same algorithm.
struct PseudoRng {
    state: u64,
}

impl PseudoRng {
    fn new(seed: u64) -> Self {
        // Mix seed to avoid patterns
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
        // xorshift64*
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

/// Primary encoder for fountain codes - uses Raptor codes for better efficiency.
///
/// Raptor codes provide lower overhead than pure LT codes:
/// - K + 2-5 blocks needed vs K + O(√K) for LT
/// - Better burst loss handling via LDPC pre-coding
/// - Consistent performance with low variance
pub type FountainEncoder = crate::raptor::RaptorEncoder;

/// Primary decoder for fountain codes - uses Raptor codes for better efficiency.
pub type FountainDecoder = crate::raptor::RaptorDecoder;

/// Legacy alias for LT encoder (kept for comparison tests).
pub type LegacyLTEncoder = LTEncoder;
/// Legacy alias for LT decoder (kept for comparison tests).
pub type LegacyLTDecoder = LTDecoder;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoded_block_roundtrip() {
        let block = EncodedBlock {
            index: 42,
            source_count: 10,
            block_size: 256,
            original_len: 2500,
            data: vec![0xAB; 256],
            checksum: crc::compute(&vec![0xAB; 256]),
        };

        let encoded = block.encode();
        let decoded = EncodedBlock::decode(&encoded).unwrap();
        assert_eq!(block, decoded);
    }

    #[test]
    fn encoded_block_crc_verification() {
        let block = EncodedBlock {
            index: 1,
            source_count: 5,
            block_size: 64,
            original_len: 300,
            data: vec![0x12; 64],
            checksum: crc::compute(&[0x12; 64]),
        };

        let mut encoded = block.encode();
        encoded[20] ^= 0xFF; // Corrupt

        assert!(matches!(
            EncodedBlock::decode(&encoded),
            Err(Error::CrcMismatch { .. })
        ));
    }

    #[test]
    fn lt_small_data() {
        let data = b"Hello, LT codes!";
        let mut encoder = LTEncoder::new(data, 8);
        let mut decoder = LTDecoder::new(encoder.source_count() as u16, 8, data.len());

        let mut blocks_used = 0;
        while !decoder.is_complete() {
            decoder.add_block(&encoder.next_block());
            blocks_used += 1;
            assert!(blocks_used < 50, "Too many blocks needed");
        }

        assert_eq!(decoder.get_data().unwrap(), data);
        println!(
            "Small: {} blocks for {} source",
            blocks_used,
            encoder.source_count()
        );
    }

    #[test]
    fn lt_medium_data() {
        let data: Vec<u8> = (0..1024).map(|i| (i % 256) as u8).collect();
        let mut encoder = LTEncoder::new(&data, 256);
        let mut decoder = LTDecoder::new(encoder.source_count() as u16, 256, data.len());

        let mut blocks_used = 0;
        while !decoder.is_complete() {
            decoder.add_block(&encoder.next_block());
            blocks_used += 1;
            assert!(blocks_used < 20, "Too many blocks");
        }

        assert_eq!(decoder.get_data().unwrap(), data);
        println!(
            "Medium: {} blocks for {} source",
            blocks_used,
            encoder.source_count()
        );
    }

    #[test]
    fn lt_large_data() {
        let data: Vec<u8> = (0..65536).map(|i| (i % 256) as u8).collect();
        let mut encoder = LTEncoder::new(&data, 512);
        let mut decoder = LTDecoder::new(encoder.source_count() as u16, 512, data.len());

        let mut blocks_used = 0;
        while !decoder.is_complete() {
            decoder.add_block(&encoder.next_block());
            blocks_used += 1;
            assert!(blocks_used < 200, "Too many blocks");
        }

        assert_eq!(decoder.get_data().unwrap(), data);
        println!(
            "Large: {} blocks for {} source (overhead: {:.1}%)",
            blocks_used,
            encoder.source_count(),
            (blocks_used as f64 / encoder.source_count() as f64 - 1.0) * 100.0
        );
    }

    #[test]
    fn lt_out_of_order() {
        let data = b"Out of order test data here!";
        let mut encoder = LTEncoder::new(data, 8);
        let k = encoder.source_count();

        // Generate extra blocks
        let blocks: Vec<_> = (0..(k + 10)).map(|_| encoder.next_block()).collect();

        let mut decoder = LTDecoder::new(k as u16, 8, data.len());

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
    fn lt_skip_blocks() {
        let data = b"Test with some skipped blocks here";
        let mut encoder = LTEncoder::new(data, 4);
        let k = encoder.source_count();

        let blocks: Vec<_> = (0..(k * 3)).map(|_| encoder.next_block()).collect();

        let mut decoder = LTDecoder::new(k as u16, 4, data.len());

        // Add every other block
        for (i, block) in blocks.iter().enumerate() {
            if i % 2 == 0 && decoder.add_block(block) {
                break;
            }
        }

        // If not complete, add the rest
        if !decoder.is_complete() {
            for (i, block) in blocks.iter().enumerate() {
                if i % 2 == 1 && decoder.add_block(block) {
                    break;
                }
            }
        }

        assert!(decoder.is_complete());
        assert_eq!(decoder.get_data().unwrap(), data);
    }

    #[test]
    fn lt_duplicate_blocks() {
        let data = b"Duplicate test";
        let mut encoder = LTEncoder::new(data, 4);
        let mut decoder = LTDecoder::new(encoder.source_count() as u16, 4, data.len());

        while !decoder.is_complete() {
            let block = encoder.next_block();
            decoder.add_block(&block);
            decoder.add_block(&block); // Duplicate - should be ignored
        }

        assert_eq!(decoder.get_data().unwrap(), data);
    }

    #[test]
    fn lt_first_k_sufficient() {
        // First K blocks should always be enough (they're source blocks)
        let data: Vec<u8> = (0..512).map(|i| (i % 256) as u8).collect();
        let mut encoder = LTEncoder::new(&data, 64);
        let k = encoder.source_count();

        let mut decoder = LTDecoder::new(k as u16, 64, data.len());

        // Only first K blocks (source blocks)
        for _ in 0..k {
            decoder.add_block(&encoder.next_block());
        }

        assert!(decoder.is_complete());
        assert_eq!(decoder.get_data().unwrap(), data);
    }

    #[test]
    fn lt_random_loss_recovery() {
        // Simulate 20% packet loss with pseudo-random pattern
        let data: Vec<u8> = (0..2048).map(|i| (i % 256) as u8).collect();
        let mut encoder = LTEncoder::new(&data, 256);
        let k = encoder.source_count();

        // Generate 2x source count blocks
        let blocks: Vec<_> = (0..(k * 2)).map(|_| encoder.next_block()).collect();

        let mut decoder = LTDecoder::new(k as u16, 256, data.len());

        // Skip 20% of blocks using deterministic but scattered pattern
        // Keep indices where (i * 7 + 3) % 10 != 0 (drops ~10%)
        let mut received = 0;
        for (i, block) in blocks.iter().enumerate() {
            if (i * 7 + 3) % 10 != 0 {
                decoder.add_block(block);
                received += 1;
                if decoder.is_complete() {
                    break;
                }
            }
        }

        assert!(
            decoder.is_complete(),
            "Failed to decode with 10% loss after {} blocks",
            received
        );
        assert_eq!(decoder.get_data().unwrap(), data);
        println!(
            "10% loss recovery: {} blocks received for {} source",
            received, k
        );
    }

    #[test]
    fn lt_progress_tracking() {
        let data: Vec<u8> = (0..256).map(|i| i as u8).collect();
        let mut encoder = LTEncoder::new(&data, 64);
        let mut decoder = LTDecoder::new(encoder.source_count() as u16, 64, data.len());

        assert_eq!(decoder.progress(), 0.0);
        assert_eq!(decoder.decoded_count(), 0);

        while !decoder.is_complete() {
            decoder.add_block(&encoder.next_block());
        }

        assert_eq!(decoder.progress(), 1.0);
        assert_eq!(decoder.decoded_count(), encoder.source_count());
    }

    // ==================== PERFORMANCE TESTS ====================

    #[test]
    fn perf_lt_64kb() {
        run_perf("64KB", 64 * 1024, 256, 100);
    }

    #[test]
    fn perf_lt_256kb() {
        run_perf("256KB", 256 * 1024, 256, 50);
    }

    #[test]
    fn perf_lt_1mb() {
        run_perf("1MB", 1024 * 1024, 512, 20);
    }

    fn run_perf(name: &str, size: usize, block_size: usize, iters: usize) {
        let data: Vec<u8> = (0..size).map(|i| (i % 256) as u8).collect();

        // Measure overhead
        let mut overhead_sum = 0.0;
        for _ in 0..iters {
            let mut enc = LTEncoder::new(&data, block_size);
            let k = enc.source_count();
            let mut dec = LTDecoder::new(k as u16, block_size as u16, size);

            let mut blocks_used = 0;
            while !dec.is_complete() {
                dec.add_block(&enc.next_block());
                blocks_used += 1;
            }
            overhead_sum += blocks_used as f64 / k as f64;
        }

        println!(
            "\n{}: avg overhead {:.1}% (K={})",
            name,
            (overhead_sum / iters as f64 - 1.0) * 100.0,
            LTEncoder::new(&data, block_size).source_count()
        );
    }

    #[test]
    fn perf_loss_resilience() {
        println!("\n=== Loss Resilience Test ===");
        println!(
            "{:>8} {:>6} {:>8} {:>8} {:>8}",
            "Size", "K", "0% loss", "20% loss", "40% loss"
        );

        for size in [16 * 1024, 64 * 1024, 256 * 1024] {
            let data: Vec<u8> = (0..size).map(|i| (i % 256) as u8).collect();
            let mut enc = LTEncoder::new(&data, 256);
            let k = enc.source_count();
            let blocks: Vec<_> = (0..(k * 3)).map(|_| enc.next_block()).collect();

            // 0% loss
            let mut dec = LTDecoder::new(k as u16, 256, size);
            let mut no_loss = 0;
            for b in &blocks {
                no_loss += 1;
                if dec.add_block(b) {
                    break;
                }
            }

            // 20% loss
            let mut dec = LTDecoder::new(k as u16, 256, size);
            let mut loss_20 = 0;
            for (i, b) in blocks.iter().enumerate() {
                if i % 5 != 0 {
                    // Keep 80%
                    loss_20 += 1;
                    if dec.add_block(b) {
                        break;
                    }
                }
            }
            if !dec.is_complete() {
                loss_20 = 9999;
            }

            // 40% loss
            let mut dec = LTDecoder::new(k as u16, 256, size);
            let mut loss_40 = 0;
            for (i, b) in blocks.iter().enumerate() {
                if i % 5 > 1 {
                    // Keep 60%
                    loss_40 += 1;
                    if dec.add_block(b) {
                        break;
                    }
                }
            }
            if !dec.is_complete() {
                loss_40 = 9999;
            }

            println!(
                "{:>7}K {:>6} {:>8} {:>8} {:>8}",
                size / 1024,
                k,
                no_loss,
                if loss_20 == 9999 {
                    "FAIL".to_string()
                } else {
                    loss_20.to_string()
                },
                if loss_40 == 9999 {
                    "FAIL".to_string()
                } else {
                    loss_40.to_string()
                }
            );
        }
    }
}
