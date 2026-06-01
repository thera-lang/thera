/// Byte-level primitives for the bytecode wire format.
///
/// A direct port of the runtime's `serialize.rs` `Writer`: LEB128 varints
/// (unsigned for indices/lengths, signed for `Int` immediates), fixed
/// little-endian fields, and length-prefixed bytes/strings. See
/// docs/bytecode.md, "Serialized format".
library;

import 'dart:convert';
import 'dart:typed_data';

/// Appends encoded values to a growable byte buffer.
class Writer {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  /// The bytes written so far.
  Uint8List toBytes() => _buf.toBytes();

  /// Number of bytes written so far.
  int get length => _buf.length;

  void writeU8(int v) => _buf.addByte(v & 0xff);

  void writeU32Le(int v) {
    final bd = ByteData(4)..setUint32(0, v, Endian.little);
    _buf.add(bd.buffer.asUint8List());
  }

  void writeF64(double v) {
    final bd = ByteData(8)..setFloat64(0, v, Endian.little);
    _buf.add(bd.buffer.asUint8List());
  }

  /// Append raw bytes with no length prefix (e.g. a magic number).
  void writeRaw(List<int> data) => _buf.add(data);

  /// Unsigned LEB128.
  void writeUvarint(int v) {
    // Use the unsigned right shift so the full 64-bit range encodes the same
    // way the runtime's `u64` path does.
    while (true) {
      var byte = v & 0x7f;
      v = v >>> 7;
      if (v != 0) byte |= 0x80;
      _buf.addByte(byte);
      if (v == 0) break;
    }
  }

  /// Signed LEB128.
  void writeIvarint(int v) {
    while (true) {
      var byte = v & 0x7f;
      v >>= 7; // arithmetic shift preserves the sign
      final sign = (byte & 0x40) != 0;
      final done = (v == 0 && !sign) || (v == -1 && sign);
      if (!done) byte |= 0x80;
      _buf.addByte(byte);
      if (done) break;
    }
  }

  /// Length-prefixed raw bytes (uvarint length, then the data).
  void writeBytes(List<int> data) {
    writeUvarint(data.length);
    _buf.add(data);
  }

  /// Length-prefixed UTF-8 string.
  void writeStr(String s) => writeBytes(utf8.encode(s));
}
