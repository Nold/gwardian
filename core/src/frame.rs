//! Fountain code based QR frame transfer for ceremony.
//!
//! This module provides rateless erasure coding for reliable pad transfer:
//!
//! - **Sender** generates unlimited encoded blocks using [`FountainFrameGenerator`]
//! - **Receiver** decodes from ANY sufficient subset using [`FountainFrameReceiver`]
//! - No need to wait for specific frames - just keep scanning until complete
//!
//! # Why Fountain Codes?
//!
//! Traditional sequential frames require receiving ALL specific frames in a set.
//! Missing frame 47 of 100? You must wait for the display to cycle back to it.
//!
//! Fountain codes eliminate this problem:
//! - First K blocks are source data (no encoding overhead)
//! - Additional blocks are XOR combinations for redundancy
//! - Receiver can recover from ANY K blocks (with small overhead for out-of-order)
//!
//! # Performance
//!
//! For QR ceremony with ~10 QR codes/second scanning rate:
//! - Encoding: >100,000 blocks/second
//! - Decoding: >50,000 blocks/second
//! - QR scanning is the bottleneck, not fountain codes
//!
//! # Example
//!
//! ```
//! use ash_core::{CeremonyMetadata, frame, TransferMethod};
//!
//! // Sender side
//! let metadata = CeremonyMetadata::default();
//! let pad = vec![0u8; 1000];
//! let mut generator = frame::create_fountain_ceremony(
//!     &metadata, &pad, 256, None, TransferMethod::Raptor
//! ).unwrap();
//!
//! // Generate QR frames (can generate unlimited)
//! let frame1 = generator.next_frame();
//! let frame2 = generator.next_frame();
//!
//! // Receiver side
//! let mut receiver = frame::FountainFrameReceiver::new(None);
//!
//! // Add frames as they're scanned
//! receiver.add_frame(&frame1).unwrap();
//! receiver.add_frame(&frame2).unwrap();
//!
//! // Continue until complete
//! while !receiver.is_complete() {
//!     let frame = generator.next_frame();
//!     receiver.add_frame(&frame).unwrap();
//! }
//!
//! // Get the result
//! let result = receiver.get_result().unwrap();
//! assert_eq!(result.pad, pad);
//! ```
//!
//! # Passphrase Encryption
//!
//! Optional passphrase encryption XORs each block's payload with a derived key:
//!
//! ```
//! use ash_core::{CeremonyMetadata, frame, TransferMethod};
//!
//! let metadata = CeremonyMetadata::default();
//! let pad = vec![0u8; 1000];
//! let passphrase = "verbal code";
//!
//! // Encrypt on sender side
//! let mut generator = frame::create_fountain_ceremony(
//!     &metadata, &pad, 256, Some(passphrase), TransferMethod::Raptor
//! ).unwrap();
//!
//! // Decrypt on receiver side (same passphrase required)
//! let mut receiver = frame::FountainFrameReceiver::new(Some(passphrase));
//! ```

use crate::error::{Error, Result};
use crate::fountain::{EncodedBlock, LTEncoder};
use crate::raptor::RaptorEncoder;

/// Transfer method for QR ceremony.
///
/// Determines which erasure coding strategy is used for pad transfer.
/// Encoded in ceremony metadata so receiver knows which decoder to use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TransferMethod {
    /// Raptor codes - near-optimal, K + 2-5 blocks overhead (recommended).
    ///
    /// Uses LDPC pre-coding for better burst loss handling and
    /// lower variance than pure LT codes.
    #[default]
    Raptor,
    /// LT codes - legacy fountain codes, K + O(√K) blocks overhead.
    ///
    /// Uses Robust Soliton distribution for reliable decoding.
    /// Higher overhead than Raptor but well-tested.
    LT,
    /// Sequential - plain numbered frames, no erasure coding.
    ///
    /// Simplest method: each frame contains one source block.
    /// Requires receiving all K unique blocks to decode.
    /// No error recovery - if a frame is missed, must wait for cycle.
    Sequential,
}

impl TransferMethod {
    /// Convert to byte for serialization.
    pub const fn to_byte(self) -> u8 {
        match self {
            TransferMethod::Raptor => 0,
            TransferMethod::LT => 1,
            TransferMethod::Sequential => 2,
        }
    }

    /// Convert from byte, defaulting to Raptor for unknown values.
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            0 => TransferMethod::Raptor,
            1 => TransferMethod::LT,
            2 => TransferMethod::Sequential,
            _ => TransferMethod::Raptor, // Default for unknown
        }
    }

    /// Get display name for the transfer method.
    pub const fn name(&self) -> &'static str {
        match self {
            TransferMethod::Raptor => "Raptor",
            TransferMethod::LT => "LT Codes",
            TransferMethod::Sequential => "Sequential",
        }
    }
}

/// Default block size for fountain encoding (1500 bytes).
///
/// With 16-byte header, total = 1516 bytes, base64 = ~2021 chars.
/// Fits in Version 23-24 QR codes with L correction.
///
/// Frame counts: ~44 for 64KB, ~175 for 256KB, ~699 for 1MB.
pub const DEFAULT_BLOCK_SIZE: usize = 1500;

/// Sequential encoder - splits data into blocks without erasure coding.
///
/// This is the simplest transfer method: each block contains exactly
/// one portion of the source data. Unlike fountain codes, there's no
/// redundancy - all K blocks must be received to decode.
struct SequentialEncoder {
    source_blocks: Vec<Vec<u8>>,
    block_size: usize,
    original_len: usize,
    next_index: u32,
}

impl SequentialEncoder {
    /// Create a new sequential encoder.
    fn new(data: &[u8], block_size: usize) -> Self {
        let original_len = data.len();
        let source_count = data.len().div_ceil(block_size);

        let mut source_blocks = Vec::with_capacity(source_count);
        for i in 0..source_count {
            let start = i * block_size;
            let end = std::cmp::min(start + block_size, data.len());
            let mut block = data[start..end].to_vec();
            // Pad last block to full size
            block.resize(block_size, 0);
            source_blocks.push(block);
        }

        Self {
            source_blocks,
            block_size,
            original_len,
            next_index: 0,
        }
    }

    /// Generate the next block (cycles through source blocks).
    fn next_block(&mut self) -> EncodedBlock {
        let block = self.generate_block(self.next_index);
        self.next_index += 1;
        block
    }

    /// Generate a specific block by index.
    fn generate_block(&self, index: u32) -> EncodedBlock {
        let block_index = (index as usize) % self.source_blocks.len();
        let data = self.source_blocks[block_index].clone();
        let checksum = crate::crc::compute(&data);

        EncodedBlock {
            index,
            source_count: self.source_blocks.len() as u16,
            block_size: self.block_size as u16,
            original_len: self.original_len as u32,
            data,
            checksum,
        }
    }

    /// Number of source blocks.
    fn source_count(&self) -> usize {
        self.source_blocks.len()
    }

    /// Block size in bytes.
    fn block_size(&self) -> usize {
        self.block_size
    }

    /// Original data length.
    fn original_len(&self) -> usize {
        self.original_len
    }
}

/// Create a fountain frame generator for ceremony QR transfer.
///
/// This is the main entry point for creating QR frames. The generator
/// produces unlimited encoded blocks that can be displayed as QR codes.
///
/// # Arguments
///
/// * `metadata` - Ceremony metadata (TTL, relay URL, etc.)
/// * `pad_bytes` - The pad data to transfer
/// * `block_size` - Size of each fountain block (default 256)
/// * `passphrase` - Optional passphrase for encryption
/// * `method` - Transfer method (Raptor, LT, or Sequential)
///
/// # Returns
///
/// A [`FountainFrameGenerator`] that produces encoded frames.
///
/// # Errors
///
/// Returns [`Error::EmptyPayload`] if `pad_bytes` is empty.
///
/// # Example
///
/// ```
/// use ash_core::{CeremonyMetadata, frame};
/// use ash_core::frame::TransferMethod;
///
/// let metadata = CeremonyMetadata::default();
/// let pad = vec![0u8; 64 * 1024]; // 64KB pad
///
/// let mut generator = frame::create_fountain_ceremony(
///     &metadata, &pad, 256, None, TransferMethod::Raptor
/// ).unwrap();
///
/// println!("Source blocks: {}", generator.source_count());
/// println!("Total size: {} bytes", generator.total_size());
/// ```
pub fn create_fountain_ceremony(
    metadata: &crate::CeremonyMetadata,
    pad_bytes: &[u8],
    block_size: usize,
    passphrase: Option<&str>,
    method: TransferMethod,
) -> Result<FountainFrameGenerator> {
    FountainFrameGenerator::new(metadata, pad_bytes, block_size, passphrase, method)
}

/// Fountain frame generator for QR display.
///
/// Generates unlimited encoded blocks from ceremony data. The display
/// cycles through blocks until the receiver signals completion.
///
/// # Block Types (for fountain codes)
///
/// - **Blocks 0..K**: Source blocks (direct data, no encoding overhead)
/// - **Blocks K+**: XOR blocks (combinations of source blocks for recovery)
///
/// # Transfer Methods
///
/// - **Raptor**: Near-optimal erasure coding (K + 2-5 blocks overhead)
/// - **LT**: Legacy fountain codes (K + O(√K) blocks overhead)
/// - **Sequential**: Plain numbered frames, no erasure coding
///
/// # Usage Pattern
///
/// ```text
/// [Generator] ─── next_frame() ──▶ [QR Display] ─── scan ──▶ [Receiver]
///      │                                                          │
///      └──────────────── repeat until complete ◀──────────────────┘
/// ```
pub struct FountainFrameGenerator {
    encoder: EncoderType,
    passphrase: Option<String>,
    method: TransferMethod,
}

/// Internal enum to hold different encoder types.
enum EncoderType {
    Raptor(RaptorEncoder),
    LT(LTEncoder),
    Sequential(SequentialEncoder),
}

impl FountainFrameGenerator {
    /// Create a new fountain frame generator.
    ///
    /// # Data Format
    ///
    /// The generator prepends metadata to the pad data:
    /// ```text
    /// [metadata_len: 4B][metadata][pad_bytes]
    /// ```
    ///
    /// Transfer method is encoded in every frame's header (first byte),
    /// allowing the receiver to detect it from ANY frame.
    ///
    /// Frame format: `[method:1][index:4][count:2][size:2][len:4][data:N][crc:4]`
    pub fn new(
        metadata: &crate::CeremonyMetadata,
        pad_bytes: &[u8],
        block_size: usize,
        passphrase: Option<&str>,
        method: TransferMethod,
    ) -> Result<Self> {
        if pad_bytes.is_empty() {
            return Err(Error::EmptyPayload);
        }

        // Prepend metadata to pad data (transfer method is in frame header, not data)
        let metadata_bytes = metadata.encode();
        let mut data = Vec::with_capacity(4 + metadata_bytes.len() + pad_bytes.len());

        // Format: [metadata_len: 4B][metadata][pad_bytes]
        data.extend_from_slice(&(metadata_bytes.len() as u32).to_be_bytes());
        data.extend_from_slice(&metadata_bytes);
        data.extend_from_slice(pad_bytes);

        // Create appropriate encoder based on method
        let encoder = match method {
            TransferMethod::Raptor => EncoderType::Raptor(RaptorEncoder::new(&data, block_size)),
            TransferMethod::LT => EncoderType::LT(LTEncoder::new(&data, block_size)),
            TransferMethod::Sequential => {
                EncoderType::Sequential(SequentialEncoder::new(&data, block_size))
            }
        };

        Ok(Self {
            encoder,
            passphrase: passphrase.map(String::from),
            method,
        })
    }

    /// Generate the next QR frame bytes.
    ///
    /// Can be called infinitely - generates new blocks each time.
    /// For fountain codes, cycles through source blocks then XOR blocks.
    /// For sequential, cycles through source blocks only.
    ///
    /// # Returns
    ///
    /// Encoded block bytes ready for QR code display.
    pub fn next_frame(&mut self) -> Vec<u8> {
        let block = match &mut self.encoder {
            EncoderType::Raptor(e) => e.next_block(),
            EncoderType::LT(e) => e.next_block(),
            EncoderType::Sequential(e) => e.next_block(),
        };
        self.encode_block(&block)
    }

    /// Generate a specific block by index.
    ///
    /// Useful for regenerating specific blocks or random access.
    /// Same index always produces same block (deterministic).
    ///
    /// # Arguments
    ///
    /// * `index` - Block index (0..K for source, K+ for XOR blocks in fountain mode)
    pub fn generate_frame(&self, index: u32) -> Vec<u8> {
        let block = match &self.encoder {
            EncoderType::Raptor(e) => e.generate_block(index),
            EncoderType::LT(e) => e.generate_block(index),
            EncoderType::Sequential(e) => e.generate_block(index),
        };
        self.encode_block(&block)
    }

    /// Encode a block for QR transmission.
    ///
    /// Prepends transfer method byte to the encoded block so receivers
    /// can detect the method from ANY frame, not just block 0.
    ///
    /// Frame format: `[method:1][index:4][count:2][size:2][len:4][data:N][crc:4]`
    fn encode_block(&self, block: &EncodedBlock) -> Vec<u8> {
        let encoded = block.encode();

        // Prepend transfer method byte
        let mut frame = Vec::with_capacity(1 + encoded.len());
        frame.push(self.method.to_byte());
        frame.extend_from_slice(&encoded);

        // Optionally encrypt payload portion (skip method byte)
        if let Some(ref pass) = self.passphrase {
            encrypt_fountain_frame(&frame, pass)
        } else {
            frame
        }
    }

    /// Number of source blocks (minimum needed for decoding).
    ///
    /// This is K in the fountain code. For sequential mode, this is
    /// exactly the number of blocks needed. For fountain codes,
    /// receiving K distinct source blocks is sufficient (in-order),
    /// or K + small overhead (out-of-order).
    pub fn source_count(&self) -> usize {
        match &self.encoder {
            EncoderType::Raptor(e) => e.source_count(),
            EncoderType::LT(e) => e.source_count(),
            EncoderType::Sequential(e) => e.source_count(),
        }
    }

    /// Block size in bytes.
    pub fn block_size(&self) -> usize {
        match &self.encoder {
            EncoderType::Raptor(e) => e.block_size(),
            EncoderType::LT(e) => e.block_size(),
            EncoderType::Sequential(e) => e.block_size(),
        }
    }

    /// Total data size being transferred (metadata + pad).
    pub fn total_size(&self) -> usize {
        match &self.encoder {
            EncoderType::Raptor(e) => e.original_len(),
            EncoderType::LT(e) => e.original_len(),
            EncoderType::Sequential(e) => e.original_len(),
        }
    }

    /// Get the transfer method used by this generator.
    pub fn method(&self) -> TransferMethod {
        self.method
    }
}

/// Encrypt a fountain frame's payload (XOR with passphrase-derived key).
///
/// # Frame Format
///
/// ```text
/// [method:1][index:4][count:2][size:2][len:4][payload:N][crc:4]
///                                             ~~~~~~~~~~
///                                             encrypted portion
/// ```
///
/// Only the payload is encrypted. Header (including method byte) remains
/// readable for decoder initialization and progress tracking.
fn encrypt_fountain_frame(frame: &[u8], passphrase: &str) -> Vec<u8> {
    let mut result = frame.to_vec();

    // Account for method byte prefix
    let method_len = 1;
    let header_len = method_len + 12; // method(1) + index(4) + source_count(2) + block_size(2) + original_len(4)
    let block_size = u16::from_be_bytes([frame[method_len + 6], frame[method_len + 7]]) as usize;
    let payload_end = header_len + block_size;

    if result.len() < payload_end + 4 {
        return result; // Invalid frame, return as-is
    }

    // Use lower 16 bits of index for key derivation
    let index_u16 = u16::from_be_bytes([frame[method_len + 2], frame[method_len + 3]]);

    // XOR payload with passphrase-derived key
    let key = crate::passphrase::derive_key(passphrase, index_u16, block_size);
    for i in 0..block_size {
        result[header_len + i] ^= key[i];
    }

    // Recompute CRC over just the payload (after XOR)
    // EncodedBlock::decode() expects CRC over data only, not header
    let new_crc = crate::crc::compute(&result[header_len..payload_end]);
    result[payload_end..payload_end + 4].copy_from_slice(&new_crc.to_be_bytes());

    result
}

/// Decrypt a fountain frame's payload.
///
/// XOR encryption is symmetric, so decryption is identical to encryption.
fn decrypt_fountain_frame(frame: &[u8], passphrase: &str) -> Vec<u8> {
    encrypt_fountain_frame(frame, passphrase)
}

/// Internal enum to hold different decoder types for receiving.
enum ReceiverDecoderType {
    Raptor(crate::raptor::RaptorDecoder),
    LT(crate::fountain::LTDecoder),
    // Sequential uses the same decoder as LT (it's just source blocks)
}

impl ReceiverDecoderType {
    fn from_block(block: &EncodedBlock, method: TransferMethod) -> Self {
        match method {
            TransferMethod::Raptor => {
                ReceiverDecoderType::Raptor(crate::raptor::RaptorDecoder::from_block(block))
            }
            TransferMethod::LT | TransferMethod::Sequential => {
                ReceiverDecoderType::LT(crate::fountain::LTDecoder::from_block(block))
            }
        }
    }

    fn add_block(&mut self, block: &EncodedBlock) {
        match self {
            ReceiverDecoderType::Raptor(d) => {
                d.add_block(block);
            }
            ReceiverDecoderType::LT(d) => {
                d.add_block(block);
            }
        }
    }

    fn is_complete(&self) -> bool {
        match self {
            ReceiverDecoderType::Raptor(d) => d.is_complete(),
            ReceiverDecoderType::LT(d) => d.is_complete(),
        }
    }

    fn progress(&self) -> f64 {
        match self {
            ReceiverDecoderType::Raptor(d) => d.progress(),
            ReceiverDecoderType::LT(d) => d.progress(),
        }
    }

    fn source_count(&self) -> usize {
        match self {
            ReceiverDecoderType::Raptor(d) => d.source_count(),
            ReceiverDecoderType::LT(d) => d.source_count(),
        }
    }

    fn unique_blocks_received(&self) -> usize {
        match self {
            ReceiverDecoderType::Raptor(d) => d.unique_blocks_received(),
            ReceiverDecoderType::LT(d) => d.unique_blocks_received(),
        }
    }

    fn get_data(&self) -> Option<Vec<u8>> {
        match self {
            ReceiverDecoderType::Raptor(d) => d.get_data(),
            ReceiverDecoderType::LT(d) => d.get_data(),
        }
    }
}

/// Fountain frame receiver for QR scanning.
///
/// Collects scanned blocks and tracks decoding progress.
/// Automatically detects transfer method from the first byte of ANY frame
/// and uses the appropriate decoder (Raptor, LT, or Sequential).
///
/// # Frame Format
///
/// Each frame starts with a transfer method byte:
/// ```text
/// [method:1][index:4][count:2][size:2][len:4][data:N][crc:4]
/// ```
///
/// This allows instant detection from any frame - no need to wait for block 0.
///
/// # Usage
///
/// ```
/// use ash_core::frame::FountainFrameReceiver;
///
/// let mut receiver = FountainFrameReceiver::new(None);
///
/// // Add frames as they're scanned
/// // receiver.add_frame(&scanned_bytes).unwrap();
///
/// // Check progress
/// println!("Progress: {:.0}%", receiver.progress() * 100.0);
/// println!("Blocks received: {}", receiver.blocks_received());
///
/// // Check completion
/// if receiver.is_complete() {
///     let result = receiver.get_result().unwrap();
///     println!("Pad size: {} bytes", result.pad.len());
/// }
/// ```
pub struct FountainFrameReceiver {
    decoder: Option<ReceiverDecoderType>,
    passphrase: Option<String>,
    blocks_received: usize,
    detected_method: Option<TransferMethod>,
}

impl FountainFrameReceiver {
    /// Create a new receiver.
    ///
    /// # Arguments
    ///
    /// * `passphrase` - Must match sender's passphrase if encryption was used
    pub fn new(passphrase: Option<&str>) -> Self {
        Self {
            decoder: None,
            passphrase: passphrase.map(String::from),
            blocks_received: 0,
            detected_method: None,
        }
    }

    /// Add a scanned QR frame.
    ///
    /// # Returns
    ///
    /// - `Ok(true)` if decoding is now complete
    /// - `Ok(false)` if more blocks are needed
    /// - `Err(_)` if the block is invalid or CRC fails
    ///
    /// # Note
    ///
    /// Duplicate blocks are safely ignored. Out-of-order blocks
    /// are handled automatically by the fountain decoder.
    /// Transfer method is auto-detected from the first byte of ANY frame.
    pub fn add_frame(&mut self, frame_bytes: &[u8]) -> Result<bool> {
        if frame_bytes.is_empty() {
            return Err(Error::FountainBlockTooShort {
                size: 0,
                minimum: 1,
            });
        }

        // Extract transfer method from first byte (present in ALL frames)
        let method = TransferMethod::from_byte(frame_bytes[0]);

        // Decode block (strip method byte first, with optional decryption)
        let block = self.decode_frame(frame_bytes)?;
        self.blocks_received += 1;

        // Initialize decoder on first frame if needed
        if self.decoder.is_none() {
            self.detected_method = Some(method);
            self.decoder = Some(ReceiverDecoderType::from_block(&block, method));
        }

        // Add block to decoder
        if let Some(decoder) = self.decoder.as_mut() {
            decoder.add_block(&block);
        }

        Ok(self.is_complete())
    }

    /// Decode a received frame (strip method byte, decrypt if needed).
    fn decode_frame(&self, frame_bytes: &[u8]) -> Result<EncodedBlock> {
        // Frame format: [method:1][encoded_block...]
        // First decrypt if needed (keeping method byte), then strip it
        let decrypted = if let Some(ref pass) = self.passphrase {
            decrypt_fountain_frame(frame_bytes, pass)
        } else {
            frame_bytes.to_vec()
        };

        // Strip method byte before decoding EncodedBlock
        if decrypted.len() < 2 {
            return Err(Error::FountainBlockTooShort {
                size: decrypted.len(),
                minimum: 2,
            });
        }

        EncodedBlock::decode(&decrypted[1..])
    }

    /// Check if decoding is complete.
    ///
    /// When true, [`get_result`](Self::get_result) will return the decoded data.
    pub fn is_complete(&self) -> bool {
        self.decoder.as_ref().is_some_and(|d| d.is_complete())
    }

    /// Get decoding progress (0.0 to 1.0).
    ///
    /// This represents the fraction of source blocks decoded,
    /// not the fraction of blocks received.
    pub fn progress(&self) -> f64 {
        self.decoder.as_ref().map_or(0.0, |d| d.progress())
    }

    /// Number of blocks received (including duplicates).
    pub fn blocks_received(&self) -> usize {
        self.blocks_received
    }

    /// Number of source blocks needed for complete decoding.
    ///
    /// Returns 0 before the first block is received.
    pub fn source_count(&self) -> usize {
        self.decoder.as_ref().map_or(0, |d| d.source_count())
    }

    /// Number of unique blocks received (excluding duplicates).
    ///
    /// This is more useful for progress tracking than [`Self::blocks_received`]
    /// since it excludes frames that were scanned multiple times.
    pub fn unique_blocks_received(&self) -> usize {
        self.decoder
            .as_ref()
            .map_or(0, |d| d.unique_blocks_received())
    }

    /// Get the detected transfer method.
    ///
    /// Returns `None` if block 0 hasn't been received yet.
    pub fn detected_method(&self) -> Option<TransferMethod> {
        self.detected_method
    }

    /// Get the decoded ceremony result.
    ///
    /// Returns `None` if decoding is not complete.
    ///
    /// # Result Contents
    ///
    /// - `metadata`: Ceremony settings (TTL, relay URL, transfer method, etc.)
    /// - `pad`: The reconstructed pad bytes
    /// - `blocks_used`: Number of blocks received to complete decoding
    pub fn get_result(&self) -> Option<FountainCeremonyResult> {
        let decoder = self.decoder.as_ref()?;
        let data = decoder.get_data()?;

        // Parse: [metadata_len: 4B][metadata][pad_bytes]
        // (transfer method is in frame header, not data)
        if data.len() < 4 {
            return None;
        }

        let metadata_len = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
        if data.len() < 4 + metadata_len {
            return None;
        }

        let metadata_bytes = &data[4..4 + metadata_len];
        let pad_bytes = data[4 + metadata_len..].to_vec();

        let metadata = crate::CeremonyMetadata::decode(metadata_bytes).ok()?;

        Some(FountainCeremonyResult {
            metadata,
            pad: pad_bytes,
            blocks_used: self.blocks_received,
        })
    }
}

/// Result of fountain ceremony decoding.
///
/// Contains both the ceremony metadata and the reconstructed pad.
#[derive(Debug, Clone)]
pub struct FountainCeremonyResult {
    /// Ceremony metadata (TTL, relay URL, disappearing messages settings).
    pub metadata: crate::CeremonyMetadata,
    /// Reconstructed pad bytes.
    pub pad: Vec<u8>,
    /// Number of blocks used for decoding.
    ///
    /// This is typically close to `source_count`, but may be
    /// higher if blocks were received out of order.
    pub blocks_used: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fountain_ceremony_roundtrip() {
        let metadata =
            crate::CeremonyMetadata::new(3600, 30, "https://relay.ash.test".to_string()).unwrap();
        let pad: Vec<u8> = (0..=255).cycle().take(5000).collect();

        let mut generator =
            create_fountain_ceremony(&metadata, &pad, 256, None, TransferMethod::Raptor).unwrap();
        let mut receiver = FountainFrameReceiver::new(None);

        let source_count = generator.source_count();

        let mut blocks = 0;
        while !receiver.is_complete() {
            let frame = generator.next_frame();
            receiver.add_frame(&frame).unwrap();
            blocks += 1;

            assert!(blocks <= source_count * 2, "Too many blocks needed");
        }

        let result = receiver.get_result().unwrap();
        assert_eq!(result.metadata.ttl_seconds, 3600);
        assert_eq!(result.metadata.disappearing_messages_seconds, 30);
        assert_eq!(result.pad, pad);
    }

    #[test]
    fn fountain_ceremony_with_passphrase() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = vec![0xAB; 2000];
        let passphrase = "secret phrase";

        // Test single block round-trip
        let mut generator = create_fountain_ceremony(
            &metadata,
            &pad,
            256,
            Some(passphrase),
            TransferMethod::Raptor,
        )
        .unwrap();
        let encrypted_frame = generator.next_frame();

        // Verify decryption works (strip method byte before decoding)
        let decrypted = decrypt_fountain_frame(&encrypted_frame, passphrase);
        let block = EncodedBlock::decode(&decrypted[1..]); // Skip method byte
        assert!(block.is_ok(), "Decrypted block should be valid");

        // Full roundtrip
        let mut generator = create_fountain_ceremony(
            &metadata,
            &pad,
            256,
            Some(passphrase),
            TransferMethod::Raptor,
        )
        .unwrap();
        let mut receiver = FountainFrameReceiver::new(Some(passphrase));

        while !receiver.is_complete() {
            let frame = generator.next_frame();
            receiver.add_frame(&frame).unwrap();
        }

        let result = receiver.get_result().unwrap();
        assert_eq!(result.pad, pad);
    }

    #[test]
    fn fountain_ceremony_out_of_order() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = (0..1000).map(|i| (i % 256) as u8).collect();

        let mut generator =
            create_fountain_ceremony(&metadata, &pad, 128, None, TransferMethod::Raptor).unwrap();
        let k = generator.source_count();

        // Generate extra blocks
        let frames: Vec<Vec<u8>> = (0..(k + 5)).map(|_| generator.next_frame()).collect();

        // Receive in reverse order
        let mut receiver = FountainFrameReceiver::new(None);
        for frame in frames.iter().rev() {
            if receiver.add_frame(frame).unwrap() {
                break;
            }
        }

        assert!(receiver.is_complete());
        let result = receiver.get_result().unwrap();
        assert_eq!(result.pad, pad);
    }

    #[test]
    fn fountain_ceremony_skip_frames() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = vec![0x42; 1500];

        let mut generator =
            create_fountain_ceremony(&metadata, &pad, 128, None, TransferMethod::Raptor).unwrap();
        let k = generator.source_count();

        // Generate many blocks
        let frames: Vec<Vec<u8>> = (0..(k * 3)).map(|_| generator.next_frame()).collect();

        // Receive every other block
        let mut receiver = FountainFrameReceiver::new(None);
        for (i, frame) in frames.iter().enumerate() {
            if i % 2 == 0 && receiver.add_frame(frame).unwrap() {
                break;
            }
        }

        // Add remaining if needed
        if !receiver.is_complete() {
            for (i, frame) in frames.iter().enumerate() {
                if i % 2 == 1 && receiver.add_frame(frame).unwrap() {
                    break;
                }
            }
        }

        assert!(receiver.is_complete());
        let result = receiver.get_result().unwrap();
        assert_eq!(result.pad, pad);
    }

    #[test]
    fn fountain_ceremony_progress() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = vec![0; 2000];

        let mut generator =
            create_fountain_ceremony(&metadata, &pad, 256, None, TransferMethod::Raptor).unwrap();
        let mut receiver = FountainFrameReceiver::new(None);

        assert_eq!(receiver.progress(), 0.0);
        assert_eq!(receiver.blocks_received(), 0);
        assert!(!receiver.is_complete());

        while !receiver.is_complete() {
            let frame = generator.next_frame();
            receiver.add_frame(&frame).unwrap();
        }

        assert_eq!(receiver.progress(), 1.0);
        assert!(receiver.is_complete());
    }

    #[test]
    fn fountain_all_pad_sizes() {
        let metadata = crate::CeremonyMetadata::default();

        let sizes = [
            ("64KB", 64 * 1024),
            ("256KB", 256 * 1024),
            ("1MB", 1024 * 1024),
        ];

        for (name, size) in sizes {
            let pad = vec![0u8; size];
            let generator =
                create_fountain_ceremony(&metadata, &pad, 256, None, TransferMethod::Raptor)
                    .unwrap();
            println!("{}: {} source blocks", name, generator.source_count());
        }
    }

    #[test]
    fn fountain_empty_pad_error() {
        let metadata = crate::CeremonyMetadata::default();
        let result = create_fountain_ceremony(&metadata, &[], 256, None, TransferMethod::Raptor);
        assert!(matches!(result, Err(Error::EmptyPayload)));
    }

    #[test]
    fn fountain_generator_deterministic() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = vec![0x42; 1000];

        let generator =
            create_fountain_ceremony(&metadata, &pad, 256, None, TransferMethod::Raptor).unwrap();

        // Same index produces same block
        let block1 = generator.generate_frame(5);
        let block2 = generator.generate_frame(5);
        assert_eq!(block1, block2);
    }

    #[test]
    fn transfer_method_lt_roundtrip() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = (0..=255).cycle().take(3000).collect();

        let mut generator =
            create_fountain_ceremony(&metadata, &pad, 256, None, TransferMethod::LT).unwrap();
        let mut receiver = FountainFrameReceiver::new(None);

        let source_count = generator.source_count();

        let mut blocks = 0;
        while !receiver.is_complete() {
            let frame = generator.next_frame();
            receiver.add_frame(&frame).unwrap();
            blocks += 1;
            assert!(blocks <= source_count * 3, "Too many blocks needed for LT");
        }

        let result = receiver.get_result().unwrap();
        assert_eq!(result.pad, pad);
    }

    #[test]
    fn transfer_method_sequential_roundtrip() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = (0..=255).cycle().take(2000).collect();

        let mut generator =
            create_fountain_ceremony(&metadata, &pad, 256, None, TransferMethod::Sequential)
                .unwrap();
        let mut receiver = FountainFrameReceiver::new(None);

        let source_count = generator.source_count();

        // Sequential mode: need exactly all source blocks
        for _ in 0..source_count {
            let frame = generator.next_frame();
            receiver.add_frame(&frame).unwrap();
        }

        // Should be complete after receiving all K source blocks
        assert!(receiver.is_complete());
        let result = receiver.get_result().unwrap();
        assert_eq!(result.pad, pad);
    }

    #[test]
    fn transfer_method_all_produce_same_result() {
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = vec![0xAB; 1500];

        // Test all methods produce same decoded pad
        for method in [
            TransferMethod::Raptor,
            TransferMethod::LT,
            TransferMethod::Sequential,
        ] {
            let mut generator =
                create_fountain_ceremony(&metadata, &pad, 256, None, method).unwrap();
            let mut receiver = FountainFrameReceiver::new(None);

            // Generate enough blocks
            let max_blocks = generator.source_count() * 2;
            for _ in 0..max_blocks {
                if receiver.is_complete() {
                    break;
                }
                let frame = generator.next_frame();
                receiver.add_frame(&frame).unwrap();
            }

            assert!(receiver.is_complete(), "{:?} should complete", method);
            let result = receiver.get_result().unwrap();
            assert_eq!(result.pad, pad, "{:?} should produce correct pad", method);
        }
    }

    #[test]
    fn sequential_encoder_cycles() {
        let data = vec![0u8; 300];
        let mut encoder = SequentialEncoder::new(&data, 100);

        // Should have 3 source blocks
        assert_eq!(encoder.source_count(), 3);

        // Generate 6 blocks (cycles twice)
        let blocks: Vec<_> = (0..6).map(|_| encoder.next_block()).collect();

        // Blocks 0 and 3 should have same data (cycled)
        assert_eq!(blocks[0].data, blocks[3].data);
        assert_eq!(blocks[1].data, blocks[4].data);
        assert_eq!(blocks[2].data, blocks[5].data);

        // But different indices
        assert_eq!(blocks[0].index, 0);
        assert_eq!(blocks[3].index, 3);
    }

    #[test]
    fn transfer_method_getter() {
        let metadata = crate::CeremonyMetadata::default();
        let pad = vec![0u8; 500];

        let gen_raptor =
            create_fountain_ceremony(&metadata, &pad, 128, None, TransferMethod::Raptor).unwrap();
        let gen_lt =
            create_fountain_ceremony(&metadata, &pad, 128, None, TransferMethod::LT).unwrap();
        let gen_seq =
            create_fountain_ceremony(&metadata, &pad, 128, None, TransferMethod::Sequential)
                .unwrap();

        assert_eq!(gen_raptor.method(), TransferMethod::Raptor);
        assert_eq!(gen_lt.method(), TransferMethod::LT);
        assert_eq!(gen_seq.method(), TransferMethod::Sequential);
    }

    #[test]
    fn transfer_method_detected_from_any_frame() {
        // Test that scanning can start from ANY frame (not just block 0)
        // This is the key fix: transfer method is in every frame's header
        let metadata = crate::CeremonyMetadata::default();
        let pad: Vec<u8> = (0..=255).cycle().take(3000).collect();

        let mut generator =
            create_fountain_ceremony(&metadata, &pad, 256, None, TransferMethod::LT).unwrap();

        // Generate many frames
        let frames: Vec<Vec<u8>> = (0..50).map(|_| generator.next_frame()).collect();

        // Simulate starting scan from frame 30 (skipping 0-29)
        let mut receiver = FountainFrameReceiver::new(None);

        // First frame received is frame 30 - should detect method immediately
        receiver.add_frame(&frames[30]).unwrap();
        assert_eq!(
            receiver.detected_method(),
            Some(TransferMethod::LT),
            "Should detect LT method from frame 30"
        );

        // Continue adding frames (including block 0 later)
        for (i, frame) in frames.iter().enumerate() {
            if i != 30 {
                // Skip the one we already added
                if receiver.add_frame(frame).unwrap() {
                    break;
                }
            }
        }

        assert!(receiver.is_complete());
        let result = receiver.get_result().unwrap();
        assert_eq!(result.pad, pad);
    }

    #[test]
    fn transfer_method_in_frame_header() {
        // Verify that the first byte of every frame is the transfer method
        let metadata = crate::CeremonyMetadata::default();
        let pad = vec![0x42; 1000];

        for method in [
            TransferMethod::Raptor,
            TransferMethod::LT,
            TransferMethod::Sequential,
        ] {
            let generator = create_fountain_ceremony(&metadata, &pad, 256, None, method).unwrap();

            // Check first 10 frames all have correct method byte
            for i in 0..10 {
                let frame = generator.generate_frame(i);
                let detected = TransferMethod::from_byte(frame[0]);
                assert_eq!(
                    detected, method,
                    "Frame {} should have {:?} in header",
                    i, method
                );
            }
        }
    }
}
