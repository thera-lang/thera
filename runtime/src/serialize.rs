//! Byte-level primitives for the bytecode wire format.
//!
//! LEB128 varints (unsigned for indices/lengths, signed for `i64` immediates)
//! per docs/bytecode.md, plus fixed little-endian fields and length-prefixed
//! bytes/strings. This is the foundation the module/instruction codec builds on.

/// Appends encoded values to a growable byte buffer.
#[derive(Debug, Default)]
pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Consume the writer and return the encoded bytes.
    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    pub fn write_u8(&mut self, v: u8) {
        self.buf.push(v);
    }

    pub fn write_u32_le(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn write_f64(&mut self, v: f64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    /// Append raw bytes with no length prefix (e.g. a magic number).
    pub fn write_raw(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }

    /// Unsigned LEB128.
    pub fn write_uvarint(&mut self, mut v: u64) {
        loop {
            let mut byte = (v & 0x7f) as u8;
            v >>= 7;
            if v != 0 {
                byte |= 0x80;
            }
            self.buf.push(byte);
            if v == 0 {
                break;
            }
        }
    }

    /// Signed LEB128.
    pub fn write_ivarint(&mut self, mut v: i64) {
        loop {
            let mut byte = (v & 0x7f) as u8;
            v >>= 7; // arithmetic shift preserves the sign
            let sign = byte & 0x40 != 0;
            let done = (v == 0 && !sign) || (v == -1 && sign);
            if !done {
                byte |= 0x80;
            }
            self.buf.push(byte);
            if done {
                break;
            }
        }
    }

    /// Length-prefixed raw bytes (uvarint length, then the data).
    pub fn write_bytes(&mut self, data: &[u8]) {
        self.write_uvarint(data.len() as u64);
        self.buf.extend_from_slice(data);
    }

    /// Length-prefixed UTF-8 string.
    pub fn write_str(&mut self, s: &str) {
        self.write_bytes(s.as_bytes());
    }
}

/// An error encountered while decoding the wire form.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// The input ended before a value was fully read.
    UnexpectedEof,
    /// A LEB128 varint did not terminate within 64 bits.
    VarintOverflow,
    /// A string field was not valid UTF-8.
    InvalidUtf8,
    /// The input did not start with the expected magic bytes.
    BadMagic,
    /// The format version is not supported by this runtime.
    UnsupportedVersion(u32),
    /// An instruction opcode byte was not recognized.
    UnknownOpcode(u8),
}

/// Reads encoded values from a byte slice, tracking the read position.
pub struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    /// Number of unread bytes.
    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.pos
    }

    pub fn is_empty(&self) -> bool {
        self.remaining() == 0
    }

    /// Take exactly `n` bytes, advancing the position.
    fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.pos.checked_add(n).ok_or(DecodeError::UnexpectedEof)?;
        let slice = self
            .bytes
            .get(self.pos..end)
            .ok_or(DecodeError::UnexpectedEof)?;
        self.pos = end;
        Ok(slice)
    }

    /// Read exactly `n` raw bytes (no length prefix).
    pub fn read_raw(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        self.take(n)
    }

    pub fn read_u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }

    pub fn read_u32_le(&mut self) -> Result<u32, DecodeError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn read_f64(&mut self) -> Result<f64, DecodeError> {
        let mut arr = [0u8; 8];
        arr.copy_from_slice(self.take(8)?);
        Ok(f64::from_le_bytes(arr))
    }

    pub fn read_uvarint(&mut self) -> Result<u64, DecodeError> {
        let mut result = 0u64;
        let mut shift = 0u32;
        loop {
            let byte = self.read_u8()?;
            if shift >= 64 {
                return Err(DecodeError::VarintOverflow);
            }
            result |= u64::from(byte & 0x7f) << shift;
            shift += 7;
            if byte & 0x80 == 0 {
                break;
            }
        }
        Ok(result)
    }

    pub fn read_ivarint(&mut self) -> Result<i64, DecodeError> {
        let mut result = 0i64;
        let mut shift = 0u32;
        loop {
            let byte = self.read_u8()?;
            if shift >= 64 {
                return Err(DecodeError::VarintOverflow);
            }
            result |= i64::from(byte & 0x7f) << shift;
            shift += 7;
            if byte & 0x80 == 0 {
                // sign-extend if the value's sign bit is set and there is room
                if shift < 64 && byte & 0x40 != 0 {
                    result |= -1i64 << shift;
                }
                break;
            }
        }
        Ok(result)
    }

    pub fn read_bytes(&mut self) -> Result<&'a [u8], DecodeError> {
        let len = self.read_uvarint()? as usize;
        self.take(len)
    }

    pub fn read_str(&mut self) -> Result<String, DecodeError> {
        let bytes = self.read_bytes()?;
        std::str::from_utf8(bytes)
            .map(str::to_string)
            .map_err(|_| DecodeError::InvalidUtf8)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_u(v: u64) -> u64 {
        let mut w = Writer::new();
        w.write_uvarint(v);
        Reader::new(&w.into_bytes()).read_uvarint().unwrap()
    }

    fn round_i(v: i64) -> i64 {
        let mut w = Writer::new();
        w.write_ivarint(v);
        Reader::new(&w.into_bytes()).read_ivarint().unwrap()
    }

    #[test]
    fn uvarint_round_trips() {
        for v in [0, 1, 127, 128, 300, 16384, u32::MAX as u64, u64::MAX] {
            assert_eq!(round_u(v), v, "uvarint {v}");
        }
    }

    #[test]
    fn ivarint_round_trips() {
        for v in [0, 1, -1, 63, 64, -64, -65, 1000, -1000, i64::MIN, i64::MAX] {
            assert_eq!(round_i(v), v, "ivarint {v}");
        }
    }

    #[test]
    fn uvarint_is_compact_for_small_values() {
        let mut w = Writer::new();
        w.write_uvarint(127);
        assert_eq!(w.into_bytes().len(), 1);

        let mut w = Writer::new();
        w.write_uvarint(128);
        assert_eq!(w.into_bytes().len(), 2);
    }

    #[test]
    fn fixed_and_text_fields_round_trip() {
        let mut w = Writer::new();
        w.write_u8(0xAB);
        w.write_u32_le(0xDEAD_BEEF);
        w.write_f64(3.5);
        w.write_str("héllo");
        w.write_bytes(&[1, 2, 3]);

        let bytes = w.into_bytes();
        let mut r = Reader::new(&bytes);
        assert_eq!(r.read_u8(), Ok(0xAB));
        assert_eq!(r.read_u32_le(), Ok(0xDEAD_BEEF));
        assert_eq!(r.read_f64(), Ok(3.5));
        assert_eq!(r.read_str(), Ok("héllo".to_string()));
        assert_eq!(r.read_bytes(), Ok(&[1, 2, 3][..]));
        assert!(r.is_empty());
    }

    #[test]
    fn eof_on_empty_reader() {
        let mut r = Reader::new(&[]);
        assert_eq!(r.read_u8(), Err(DecodeError::UnexpectedEof));
    }

    #[test]
    fn truncated_varint_is_eof() {
        // a lone continuation byte with no terminator
        let mut r = Reader::new(&[0x80]);
        assert_eq!(r.read_uvarint(), Err(DecodeError::UnexpectedEof));
    }

    #[test]
    fn overlong_varint_overflows() {
        let bytes = [0x80u8; 11];
        let mut r = Reader::new(&bytes);
        assert_eq!(r.read_uvarint(), Err(DecodeError::VarintOverflow));
    }

    #[test]
    fn invalid_utf8_string() {
        // length 1, then an invalid UTF-8 byte
        let mut r = Reader::new(&[0x01, 0xFF]);
        assert_eq!(r.read_str(), Err(DecodeError::InvalidUtf8));
    }
}
