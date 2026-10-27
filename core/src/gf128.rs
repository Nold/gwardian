//! GF(2^128) finite field arithmetic for polynomial hashing.
//!
//! This module implements arithmetic in the Galois field GF(2^128) used by
//! GHASH and other polynomial-based authentication schemes.
//!
//! # GHASH Compatibility
//!
//! This implementation matches the GHASH specification (NIST SP 800-38D):
//! - Reduction polynomial: x^128 + x^7 + x^2 + x + 1
//! - Bit ordering: GHASH convention (bit 0 is MSB of first byte)
//! - Byte ordering: Big-endian block representation
//!
//! # Security Properties
//!
//! - **Constant-time**: All operations run in constant time regardless of input values
//! - **No branches on secrets**: Conditional operations use arithmetic masking
//! - **No table lookups**: Avoids cache-timing attacks
//!
//! # Example
//!
//! ```
//! use ash_core::gf128::GF128;
//!
//! let a = GF128::from_bytes(&[0x66, 0xe9, 0x4b, 0xd4, 0xef, 0x8a, 0x2c, 0x3b,
//!                             0x88, 0x4c, 0xfa, 0x59, 0xca, 0x34, 0x2b, 0x2e]);
//! let b = GF128::from_bytes(&[0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92,
//!                             0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2, 0xfe, 0x78]);
//!
//! let c = a.mul(&b);
//! // Result can be verified against GHASH test vectors
//! ```

/// A 128-bit element in GF(2^128).
///
/// Internally stored as two 64-bit words in big-endian order.
/// `hi` contains bits 0-63 (MSB side), `lo` contains bits 64-127 (LSB side).
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct GF128 {
    /// High 64 bits (bits 0-63 in GHASH notation)
    hi: u64,
    /// Low 64 bits (bits 64-127 in GHASH notation)
    lo: u64,
}

impl GF128 {
    /// The zero element (additive identity).
    pub const ZERO: GF128 = GF128 { hi: 0, lo: 0 };

    /// Create a new GF128 element from two 64-bit words.
    ///
    /// # Arguments
    ///
    /// * `hi` - High 64 bits (bits 0-63)
    /// * `lo` - Low 64 bits (bits 64-127)
    #[inline]
    pub const fn new(hi: u64, lo: u64) -> Self {
        Self { hi, lo }
    }

    /// Create a GF128 element from a 16-byte array.
    ///
    /// Bytes are interpreted in big-endian order (GHASH convention):
    /// - bytes[0..8] → high 64 bits
    /// - bytes[8..16] → low 64 bits
    #[inline]
    pub fn from_bytes(bytes: &[u8; 16]) -> Self {
        let hi = u64::from_be_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]);
        let lo = u64::from_be_bytes([
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ]);
        Self { hi, lo }
    }

    /// Create a GF128 element from a byte slice.
    ///
    /// If the slice is shorter than 16 bytes, it is zero-padded on the right.
    /// If longer, only the first 16 bytes are used.
    ///
    /// This matches GHASH padding behavior for partial blocks.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Self {
        let mut bytes = [0u8; 16];
        let len = slice.len().min(16);
        bytes[..len].copy_from_slice(&slice[..len]);
        Self::from_bytes(&bytes)
    }

    /// Convert to a 16-byte array in big-endian order.
    #[inline]
    pub fn to_bytes(&self) -> [u8; 16] {
        let mut bytes = [0u8; 16];
        bytes[0..8].copy_from_slice(&self.hi.to_be_bytes());
        bytes[8..16].copy_from_slice(&self.lo.to_be_bytes());
        bytes
    }

    /// Addition in GF(2^128) is XOR.
    ///
    /// This is the same as subtraction in characteristic 2 fields.
    #[inline]
    pub fn add(&self, other: &Self) -> Self {
        Self {
            hi: self.hi ^ other.hi,
            lo: self.lo ^ other.lo,
        }
    }

    /// XOR (alias for add, since they're identical in GF(2^128)).
    #[inline]
    pub fn xor(&self, other: &Self) -> Self {
        self.add(other)
    }

    /// Multiplication in GF(2^128) using GHASH reduction polynomial.
    ///
    /// Reduction polynomial: x^128 + x^7 + x^2 + x + 1 (0xE1...0)
    ///
    /// This implementation uses the standard shift-and-add algorithm
    /// with constant-time conditional XOR operations.
    ///
    /// # Algorithm
    ///
    /// For each bit of `other` (from MSB to LSB):
    /// 1. If the bit is set, XOR accumulator with current `self`
    /// 2. Shift `self` right by 1
    /// 3. If the LSB was 1, XOR with the reduction constant R
    ///
    /// The reduction constant R = 0xE1 << 56 comes from the polynomial
    /// x^128 + x^7 + x^2 + x + 1 reflected for the GHASH convention.
    pub fn mul(&self, other: &Self) -> Self {
        // Reduction constant: when bit 127 is shifted out, XOR with this
        // R = 0xE1 << 56 (in high word) because:
        // x^128 mod p = x^7 + x^2 + x + 1 = 0b11100001 = 0xE1
        const R: u64 = 0xE1 << 56;

        let mut z = GF128::ZERO;
        let mut v = *self;

        // Process all 128 bits of `other`
        // High word first (bits 0-63), then low word (bits 64-127)
        for &word in &[other.hi, other.lo] {
            for i in 0..64 {
                // Check if bit (63-i) is set (processing MSB to LSB)
                let bit = (word >> (63 - i)) & 1;

                // Constant-time conditional XOR: if bit=1, XOR v into z
                let mask = 0u64.wrapping_sub(bit); // 0 or 0xFFFFFFFFFFFFFFFF
                z.hi ^= v.hi & mask;
                z.lo ^= v.lo & mask;

                // Shift v right by 1 (multiply by x)
                // Save LSB before shift for reduction
                let lsb = v.lo & 1;

                // Right shift: v >>= 1
                v.lo = (v.lo >> 1) | (v.hi << 63);
                v.hi >>= 1;

                // Constant-time conditional reduction
                // If LSB was 1, XOR with R in high word
                let reduce_mask = 0u64.wrapping_sub(lsb);
                v.hi ^= R & reduce_mask;
            }
        }

        z
    }

    /// Check if this element is zero.
    #[inline]
    pub fn is_zero(&self) -> bool {
        self.hi == 0 && self.lo == 0
    }

    /// Get the high 64 bits.
    #[inline]
    pub fn high(&self) -> u64 {
        self.hi
    }

    /// Get the low 64 bits.
    #[inline]
    pub fn low(&self) -> u64 {
        self.lo
    }
}

impl Default for GF128 {
    fn default() -> Self {
        Self::ZERO
    }
}

impl std::fmt::Debug for GF128 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "GF128({:016x}{:016x})", self.hi, self.lo)
    }
}

impl std::ops::BitXor for GF128 {
    type Output = Self;

    #[inline]
    fn bitxor(self, rhs: Self) -> Self::Output {
        self.add(&rhs)
    }
}

impl std::ops::BitXorAssign for GF128 {
    #[inline]
    fn bitxor_assign(&mut self, rhs: Self) {
        self.hi ^= rhs.hi;
        self.lo ^= rhs.lo;
    }
}

/// XOR two 16-byte arrays.
///
/// Utility function for masking authentication tags.
#[inline]
pub fn xor_bytes_16(a: &[u8; 16], b: &[u8; 16]) -> [u8; 16] {
    let mut result = [0u8; 16];
    for i in 0..16 {
        result[i] = a[i] ^ b[i];
    }
    result
}

/// Constant-time comparison of two 16-byte arrays.
///
/// Returns true if and only if all bytes are equal.
/// Runs in constant time regardless of where differences occur.
#[inline]
pub fn constant_time_eq_16(a: &[u8; 16], b: &[u8; 16]) -> bool {
    let mut diff = 0u8;
    for i in 0..16 {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

/// Constant-time comparison of two 32-byte arrays.
///
/// Returns true if and only if all bytes are equal.
/// Runs in constant time regardless of where differences occur.
#[inline]
pub fn constant_time_eq_32(a: &[u8; 32], b: &[u8; 32]) -> bool {
    let mut diff = 0u8;
    for i in 0..32 {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_element() {
        let zero = GF128::ZERO;
        assert!(zero.is_zero());
        assert_eq!(zero.to_bytes(), [0u8; 16]);
    }

    #[test]
    fn from_bytes_roundtrip() {
        let bytes: [u8; 16] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
            0x0f, 0x10,
        ];
        let elem = GF128::from_bytes(&bytes);
        assert_eq!(elem.to_bytes(), bytes);
    }

    #[test]
    fn from_slice_padding() {
        // Short slice should be zero-padded on the right
        let short = [0x01, 0x02, 0x03];
        let elem = GF128::from_slice(&short);
        let expected = [
            0x01, 0x02, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ];
        assert_eq!(elem.to_bytes(), expected);
    }

    #[test]
    fn addition_is_xor() {
        let a = GF128::from_bytes(&[
            0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00,
            0xFF, 0x00,
        ]);
        let b = GF128::from_bytes(&[
            0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F,
            0x0F, 0x0F,
        ]);
        let c = a.add(&b);
        let expected = [
            0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F,
            0xF0, 0x0F,
        ];
        assert_eq!(c.to_bytes(), expected);
    }

    #[test]
    fn addition_self_inverse() {
        let a = GF128::from_bytes(&[
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,
            0xDE, 0xF0,
        ]);
        let b = a.add(&a);
        assert!(b.is_zero(), "a + a should equal zero in GF(2^128)");
    }

    #[test]
    fn multiply_by_zero() {
        let a = GF128::from_bytes(&[
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,
            0xDE, 0xF0,
        ]);
        let zero = GF128::ZERO;
        let result = a.mul(&zero);
        assert!(result.is_zero(), "a * 0 should equal 0");

        let result2 = zero.mul(&a);
        assert!(result2.is_zero(), "0 * a should equal 0");
    }

    #[test]
    fn multiply_by_one() {
        // In GHASH convention, "1" is 0x80 0x00 0x00 ... (bit 0 set)
        let one = GF128::from_bytes(&[
            0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ]);
        let a = GF128::from_bytes(&[
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,
            0xDE, 0xF0,
        ]);
        let result = a.mul(&one);
        assert_eq!(result, a, "a * 1 should equal a");
    }

    #[test]
    fn multiplication_commutative() {
        let a = GF128::from_bytes(&[
            0x66, 0xe9, 0x4b, 0xd4, 0xef, 0x8a, 0x2c, 0x3b, 0x88, 0x4c, 0xfa, 0x59, 0xca, 0x34,
            0x2b, 0x2e,
        ]);
        let b = GF128::from_bytes(&[
            0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92, 0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2,
            0xfe, 0x78,
        ]);

        let ab = a.mul(&b);
        let ba = b.mul(&a);
        assert_eq!(ab, ba, "Multiplication should be commutative");
    }

    #[test]
    fn multiplication_associative() {
        let a = GF128::from_bytes(&[
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54,
            0x32, 0x10,
        ]);
        let b = GF128::from_bytes(&[
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
            0xff, 0x00,
        ]);
        let c = GF128::from_bytes(&[
            0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99,
        ]);

        let ab_c = a.mul(&b).mul(&c);
        let a_bc = a.mul(&b.mul(&c));
        assert_eq!(ab_c, a_bc, "Multiplication should be associative");
    }

    #[test]
    fn multiplication_distributive() {
        let a = GF128::from_bytes(&[
            0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x0f, 0xed, 0xcb, 0xa9, 0x87, 0x65,
            0x43, 0x21,
        ]);
        let b = GF128::from_bytes(&[
            0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0x98, 0x76, 0x54, 0x32, 0x10, 0xfe,
            0xdc, 0xba,
        ]);
        let c = GF128::from_bytes(&[
            0x55, 0x44, 0x33, 0x22, 0x11, 0x00, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
            0x77, 0x66,
        ]);

        // a * (b + c) should equal (a * b) + (a * c)
        let left = a.mul(&b.add(&c));
        let right = a.mul(&b).add(&a.mul(&c));
        assert_eq!(
            left, right,
            "Multiplication should be distributive over addition"
        );
    }

    // GHASH test vector from NIST SP 800-38D
    // This is the core multiplication test that verifies GHASH compatibility
    #[test]
    fn ghash_test_vector_multiplication() {
        // Test Case 2 from the NIST document
        // H = 66e94bd4ef8a2c3b884cfa59ca342b2e
        let h = GF128::from_bytes(&[
            0x66, 0xe9, 0x4b, 0xd4, 0xef, 0x8a, 0x2c, 0x3b, 0x88, 0x4c, 0xfa, 0x59, 0xca, 0x34,
            0x2b, 0x2e,
        ]);

        // X = 0388dace60b6a392f328c2b971b2fe78
        let x = GF128::from_bytes(&[
            0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92, 0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2,
            0xfe, 0x78,
        ]);

        // Expected: H * X = 5e2ec746917062882c85b0685353deb7
        let expected = GF128::from_bytes(&[
            0x5e, 0x2e, 0xc7, 0x46, 0x91, 0x70, 0x62, 0x88, 0x2c, 0x85, 0xb0, 0x68, 0x53, 0x53,
            0xde, 0xb7,
        ]);

        let result = h.mul(&x);
        assert_eq!(
            result, expected,
            "GHASH multiplication test vector failed\nGot:      {:?}\nExpected: {:?}",
            result, expected
        );
    }

    #[test]
    fn xor_bytes_16_test() {
        let a = [
            0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00,
            0xFF, 0x00,
        ];
        let b = [
            0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F,
            0x0F, 0x0F,
        ];
        let result = xor_bytes_16(&a, &b);
        let expected = [
            0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F,
            0xF0, 0x0F,
        ];
        assert_eq!(result, expected);
    }

    #[test]
    fn constant_time_eq_16_equal() {
        let a = [1u8; 16];
        let b = [1u8; 16];
        assert!(constant_time_eq_16(&a, &b));
    }

    #[test]
    fn constant_time_eq_16_different() {
        let a = [1u8; 16];
        let mut b = [1u8; 16];
        b[15] = 2; // Differ in last byte
        assert!(!constant_time_eq_16(&a, &b));

        let mut c = [1u8; 16];
        c[0] = 2; // Differ in first byte
        assert!(!constant_time_eq_16(&a, &c));
    }

    #[test]
    fn constant_time_eq_32_equal() {
        let a = [0xABu8; 32];
        let b = [0xABu8; 32];
        assert!(constant_time_eq_32(&a, &b));
    }

    #[test]
    fn constant_time_eq_32_different() {
        let a = [0xABu8; 32];
        let mut b = [0xABu8; 32];
        b[16] = 0xCD; // Differ in middle
        assert!(!constant_time_eq_32(&a, &b));
    }

    #[test]
    fn bitxor_operator() {
        let a = GF128::from_bytes(&[0xFF; 16]);
        let b = GF128::from_bytes(&[0x0F; 16]);
        let c = a ^ b;
        assert_eq!(c.to_bytes(), [0xF0; 16]);
    }

    #[test]
    fn bitxor_assign_operator() {
        let mut a = GF128::from_bytes(&[0xFF; 16]);
        let b = GF128::from_bytes(&[0x0F; 16]);
        a ^= b;
        assert_eq!(a.to_bytes(), [0xF0; 16]);
    }

    #[test]
    fn debug_format() {
        let elem = GF128::new(0x0123456789abcdef, 0xfedcba9876543210);
        let debug = format!("{:?}", elem);
        assert!(debug.contains("0123456789abcdef"));
        assert!(debug.contains("fedcba9876543210"));
    }

    // Additional GHASH-style test: verify that repeated multiplication
    // (as used in polynomial evaluation) works correctly
    #[test]
    fn polynomial_evaluation_pattern() {
        let h = GF128::from_bytes(&[
            0x66, 0xe9, 0x4b, 0xd4, 0xef, 0x8a, 0x2c, 0x3b, 0x88, 0x4c, 0xfa, 0x59, 0xca, 0x34,
            0x2b, 0x2e,
        ]);

        let block1 = GF128::from_bytes(&[
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
            0x0f, 0x10,
        ]);
        let block2 = GF128::from_bytes(&[
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e,
            0x1f, 0x20,
        ]);

        // Horner's method: ((block1 * h) + block2) * h
        let acc = block1.mul(&h);
        let acc = acc.add(&block2);
        let result = acc.mul(&h);

        // Just verify it produces a valid result (non-zero for non-zero inputs)
        assert!(!result.is_zero());

        // Verify determinism
        let acc2 = block1.mul(&h).add(&block2).mul(&h);
        assert_eq!(result, acc2);
    }
}
