// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of "dart:convert";

/// Top-level combined codec for UTF-8 JSON encoding and decoding.
const JsonUtf8Codec jsonUtf8 = JsonUtf8Codec();

/// Decodes the UTF-8 encoded JSON [bytes] directly to a Dart object.
///
/// Shorthand for `jsonUtf8.decode(bytes)`.
Object? jsonUtf8Decode(
  List<int> bytes, {
  Object? Function(Object? key, Object? value)? reviver,
  bool allowMalformed = false,
}) => JsonUtf8Decoder(reviver, allowMalformed).convert(bytes);

/// Converts [value] directly to UTF-8 encoded JSON bytes as a [Uint8List].
///
/// Shorthand for `jsonUtf8.encode(value)`.
Uint8List jsonUtf8Encode(
  Object? value, {
  Object? Function(dynamic object)? toEncodable,
}) {
  final res = JsonUtf8Encoder(null, toEncodable).convert(value);
  return res is Uint8List ? res : Uint8List.fromList(res);
}

/// JSON token structural type discriminator.
enum JsonTokenType {
  none,
  beginObject,
  endObject,
  beginArray,
  endArray,
  propertyName,
  string,
  number,
  boolean,
  nullValue,
  endOfDocument,
}

/// Pre-compiled set of ASCII key names or enum strings for O(1) matching in pull parsers.
final class JsonKeyOptions {
  final List<String> keys;

  final Map<String, int> _indexMap;
  final int _minLen;
  final int _maxLen;

  // Single-key fast path
  final Uint8List? _singleKey;
  final int _singleKeyIndex;
  final int _singleFirstByte;
  final int _singleLastByte;

  // Unified O(1) hash table backed by parallel typed arrays.
  // All tables are indexed directly by `slot` to eliminate double indirection.
  final Uint8List _encodedKeys;
  final Int32List _tableOffsets;
  final Int32List _tableLengths;
  final Uint8List _tableFirstBytes;
  final Uint8List _tableLastBytes;
  final Int32List _tableKeyIndices;
  final int _hashMask;

  static final Uint8List _emptyUint8 = Uint8List(0);
  static final Int32List _emptyInt32 = Int32List(0);

  JsonKeyOptions._(
    this.keys,
    this._indexMap,
    this._minLen,
    this._maxLen,
    this._singleKey,
    this._singleKeyIndex,
    this._singleFirstByte,
    this._singleLastByte,
    this._encodedKeys,
    this._tableOffsets,
    this._tableLengths,
    this._tableFirstBytes,
    this._tableLastBytes,
    this._tableKeyIndices,
    this._hashMask,
  );

  /// Creates a [JsonKeyOptions] lookup table from the given [keys].
  ///
  /// Throws [ArgumentError] if [keys] is empty.
  factory JsonKeyOptions.of(List<String> keys) {
    if (keys.isEmpty) {
      throw ArgumentError.value(keys, 'keys', 'Must not be empty');
    }

    final utf8Keys = List<Uint8List>.generate(
      keys.length,
      (i) => Uint8List.fromList(utf8.encode(keys[i])),
      growable: false,
    );

    final indexMap = <String, int>{};
    for (var i = 0; i < keys.length; i++) {
      indexMap.putIfAbsent(keys[i], () => i);
    }

    var minLen = utf8Keys[0].length;
    var maxLen = utf8Keys[0].length;
    for (var i = 1; i < utf8Keys.length; i++) {
      final len = utf8Keys[i].length;
      if (len < minLen) minLen = len;
      if (len > maxLen) maxLen = len;
    }

    final uniqueIndices = indexMap.values.toList(growable: false);

    if (uniqueIndices.length == 1) {
      final firstIdx = uniqueIndices[0];
      final keyBytes = utf8Keys[firstIdx];
      return JsonKeyOptions._(
        List.unmodifiable(keys),
        indexMap,
        minLen,
        maxLen,
        keyBytes,
        firstIdx,
        keyBytes.isEmpty ? 0 : keyBytes[0],
        keyBytes.isEmpty ? 0 : keyBytes[keyBytes.length - 1],
        _emptyUint8,
        _emptyInt32,
        _emptyInt32,
        _emptyUint8,
        _emptyUint8,
        _emptyInt32,
        0,
      );
    }

    final count = uniqueIndices.length;
    var totalBytes = 0;
    for (var i = 0; i < count; i++) {
      totalBytes += utf8Keys[uniqueIndices[i]].length;
    }

    final encodedKeys = Uint8List(totalBytes);
    final offsets = Int32List(count);
    var currentOffset = 0;
    for (var i = 0; i < count; i++) {
      final bytes = utf8Keys[uniqueIndices[i]];
      offsets[i] = currentOffset;
      encodedKeys.setRange(currentOffset, currentOffset + bytes.length, bytes);
      currentOffset += bytes.length;
    }

    // Table capacity: power of two with load factor <= 0.25 to ensure ~1 probe.
    var cap = 16;
    while (cap < count * 4) {
      cap <<= 1;
    }
    final mask = cap - 1;
    final tableKeyIndices = Int32List(cap)..fillRange(0, cap, -1);
    final tableLengths = Int32List(cap);
    final tableOffsets = Int32List(cap);
    final tableFirstBytes = Uint8List(cap);
    final tableLastBytes = Uint8List(cap);

    for (var i = 0; i < count; i++) {
      final origIdx = uniqueIndices[i];
      final bytes = utf8Keys[origIdx];
      final len = bytes.length;
      final off = offsets[i];
      final h = _fastHash(encodedKeys, off, off + len, len);
      var slot = h & mask;
      while (tableKeyIndices[slot] != -1) {
        slot = (slot + 1) & mask;
      }
      tableKeyIndices[slot] = origIdx;
      tableLengths[slot] = len;
      tableOffsets[slot] = off;
      tableFirstBytes[slot] = len > 0 ? bytes[0] : 0;
      tableLastBytes[slot] = len > 0 ? bytes[len - 1] : 0;
    }

    return JsonKeyOptions._(
      List.unmodifiable(keys),
      indexMap,
      minLen,
      maxLen,
      null,
      0,
      0,
      0,
      encodedKeys,
      tableOffsets,
      tableLengths,
      tableFirstBytes,
      tableLastBytes,
      tableKeyIndices,
      mask,
    );
  }

  /// The index of [key], or `-1` if not recognized.
  int indexOf(String key) => _indexMap[key] ?? -1;

  int get length => keys.length;

  /// Matches the byte span `[start..end]` against pre-compiled keys in O(1).
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int selectKey(Uint8List source, int start, int end) {
    if (start < 0 || end > source.length || start > end) {
      return -1;
    }
    final spanLen = end - start;
    if (spanLen < _minLen || spanLen > _maxLen) {
      return -1;
    }

    final singleKey = _singleKey;
    if (singleKey != null) {
      if (spanLen != singleKey.length) return -1;
      if (spanLen == 0) return _singleKeyIndex;
      if (source[start] != _singleFirstByte) return -1;
      if (spanLen > 1 && source[end - 1] != _singleLastByte) return -1;
      for (var j = 1; j < spanLen - 1; j++) {
        if (source[start + j] != singleKey[j]) return -1;
      }
      return _singleKeyIndex;
    }

    final h = _fastHash(source, start, end, spanLen);
    final mask = _hashMask;
    var slot = h & mask;
    final firstByte = spanLen > 0 ? source[start] : 0;
    final lastByte = spanLen > 0 ? source[end - 1] : 0;

    final keyIndices = _tableKeyIndices;
    final lengths = _tableLengths;
    final firstBytes = _tableFirstBytes;
    final lastBytes = _tableLastBytes;
    final offsets = _tableOffsets;
    final encodedKeys = _encodedKeys;

    while (true) {
      final keyIdx = keyIndices[slot];
      if (keyIdx == -1) return -1;
      if (lengths[slot] == spanLen &&
          firstBytes[slot] == firstByte &&
          lastBytes[slot] == lastByte) {
        final off = offsets[slot];
        var match = true;
        for (var j = 1; j < spanLen - 1; j++) {
          if (source[start + j] != encodedKeys[off + j]) {
            match = false;
            break;
          }
        }
        if (match) return keyIdx;
      }
      slot = (slot + 1) & mask;
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  static int _fastHash(Uint8List source, int start, int end, int len) {
    if (len <= 4) {
      var h = len;
      for (var i = start; i < end; i++) {
        h = (h * 31) ^ source[i];
      }
      return h ^ (h >> 16) ^ (h >> 8);
    }
    final h =
        len ^
        (source[start] << 24) ^
        (source[start + 1] << 16) ^
        (source[start + (len >> 1)] << 8) ^
        source[end - 1];
    return h ^ (h >> 16) ^ (h >> 8);
  }
}

/// A combined [Codec] for encoding objects to UTF-8 JSON bytes and decoding
/// UTF-8 JSON bytes directly into Dart objects.
final class JsonUtf8Codec extends Codec<Object?, List<int>> {
  /// Indentation string used for pretty-printing, or `null` for compact output.
  final String? indent;

  /// Function called for objects that do not have a native JSON representation.
  final dynamic Function(dynamic object)? toEncodable;

  /// Reviver function applied to decoded key/value pairs.
  final Object? Function(Object? key, Object? value)? reviver;

  /// Whether the decoder allows malformed UTF-8 byte sequences.
  final bool allowMalformed;

  /// Buffer size used for chunked conversion.
  final int? bufferSize;

  /// Creates a [JsonUtf8Codec] with the given configuration.
  const JsonUtf8Codec({
    this.indent,
    this.toEncodable,
    this.reviver,
    this.allowMalformed = false,
    this.bufferSize,
  });

  @override
  JsonUtf8Encoder get encoder =>
      JsonUtf8Encoder(indent, toEncodable, bufferSize);

  @override
  JsonUtf8Decoder get decoder => JsonUtf8Decoder(reviver, allowMalformed);

  @override
  Object? decode(
    List<int> encoded, {
    Object? Function(Object? key, Object? value)? reviver,
    bool? allowMalformed,
  }) {
    if (reviver != null || allowMalformed != null) {
      return JsonUtf8Decoder(
        reviver ?? this.reviver,
        allowMalformed ?? this.allowMalformed,
      ).convert(encoded);
    }
    return decoder.convert(encoded);
  }

  @override
  Uint8List encode(
    Object? value, {
    Object? Function(dynamic object)? toEncodable,
  }) {
    if (toEncodable != null) {
      return JsonUtf8Encoder(indent, toEncodable, bufferSize).convert(value);
    }
    return encoder.convert(value);
  }
}

/// A [Converter] that decodes UTF-8 encoded JSON bytes directly into Dart
/// objects without creating an intermediate [String].
final class JsonUtf8Decoder extends Converter<List<int>, Object?> {
  /// Reviver function applied to decoded key/value pairs, or `null`.
  final Object? Function(Object? key, Object? value)? reviver;

  /// Whether the decoder allows malformed UTF-8 byte sequences.
  final bool allowMalformed;

  /// Creates a [JsonUtf8Decoder].
  const JsonUtf8Decoder([this.reviver, this.allowMalformed = false]);

  /// Decodes [input] directly into Dart objects without creating an
  /// intermediate [String].
  ///
  /// Nesting depth is bounded by the platform decoder: the native VM and
  /// Wasm decoders reject input nested more than 1,024 levels deep with a
  /// [FormatException], while web platforms delegate to the JavaScript
  /// `JSON.parse` and inherit its (effectively unbounded) behavior. Use
  /// [JsonTokenReader] when a guaranteed 1,024-level limit is required.
  @override
  Object? convert(List<int> input) {
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    final reader = JsonTokenReader.fromBytes(
      bytes,
      allowMalformed: allowMalformed,
    );
    final rev = reviver;
    final result = _parseValueFromReader(reader, rev);
    if (reader.peek() != JsonTokenType.endOfDocument) {
      throw FormatException('Unexpected extra data after JSON value');
    }
    return rev != null ? rev(null, result) : result;
  }

  @override
  ChunkedConversionSink<List<int>> startChunkedConversion(Sink<Object?> sink) {
    return Utf8Decoder(
      allowMalformed: allowMalformed,
    ).startChunkedConversion(JsonDecoder(reviver).startChunkedConversion(sink));
  }

  @override
  Stream<Object?> bind(Stream<List<int>> stream) {
    return super.bind(stream);
  }
}

// --- Private Zero-Allocation Span Parsing Helpers ---

/// Parses a 64-bit IEEE-754 double directly from a UTF-8 byte span
/// `[start..end]` without allocating an intermediate [String].
double _parseDoubleFromBytes(Uint8List bytes, int start, int end) {
  final res = _tryParseDoubleFromBytes(bytes, start, end);
  if (res == null) {
    throw FormatException(
      'Invalid double in byte span [$start, $end)',
      bytes,
      start,
    );
  }
  return res;
}

/// Parses a 64-bit IEEE-754 double directly from a UTF-8 byte span
/// `[start..end]`. Returns `null` if the byte slice is not a valid number.
double? _tryParseDoubleFromBytes(Uint8List bytes, int start, int end) {
  return _tryParseDoubleUtf8(bytes, start, end);
}

/// Parses a 64-bit signed integer directly from a base-10 UTF-8 byte span
/// `[start..end]` without allocating an intermediate [String].
int _parseIntFromBytes(Uint8List bytes, int start, int end) {
  final res = _tryParseIntFromBytes(bytes, start, end);
  if (res == null) {
    throw FormatException(
      'Invalid integer in byte span [$start, $end)',
      bytes,
      start,
    );
  }
  return res;
}

/// Parses a 64-bit signed integer directly from a base-10 UTF-8 byte span
/// `[start..end]`. Returns `null` if the byte slice is not a valid integer.
int? _tryParseIntFromBytes(Uint8List bytes, int start, int end) {
  return _tryParseIntUtf8(bytes, start, end);
}

/// Parses a boolean literal (`true` or `false`) from byte span `[start..end]`.
bool _parseBoolFromBytes(Uint8List bytes, int start, int end) {
  final res = _tryParseBoolFromBytes(bytes, start, end);
  if (res == null) {
    throw FormatException(
      'Invalid boolean in byte span [$start, $end)',
      bytes,
      start,
    );
  }
  return res;
}

/// Parses a boolean literal from byte span `[start..end]`, or `null` if invalid.
bool? _tryParseBoolFromBytes(Uint8List bytes, int start, int end) {
  return _tryParseBoolUtf8(bytes, start, end);
}

/// Decodes and unescapes a JSON string literal byte span `bytes[start..end]`
/// directly into a Dart [String], resolving standard JSON escape sequences.
String _decodeStringFromBytes(
  Uint8List bytes,
  int start,
  int end, {
  bool allowMalformed = false,
}) {
  return _decodeStringUtf8(bytes, start, end, allowMalformed: allowMalformed);
}

/// Scans [bytes] starting at [offset] and returns the end byte offset of the
/// complete JSON value (skipping nested objects, arrays, and strings).
int _skipValue(Uint8List bytes, int offset) {
  if (offset < 0 || offset > bytes.length) {
    throw RangeError.range(offset, 0, bytes.length, 'offset');
  }
  var i = offset;
  while (i < bytes.length &&
      (bytes[i] == 0x20 ||
          bytes[i] == 0x09 ||
          bytes[i] == 0x0A ||
          bytes[i] == 0x0D)) {
    i++;
  }
  if (i >= bytes.length) return i;
  final b = bytes[i];
  if (b == 123 || b == 91) {
    // object or array
    var depth = 1;
    final tracker = _SkipContainerTracker();
    tracker.pushContainer(0, b == 123);
    i++;

    while (i < bytes.length && depth > 0) {
      while (i < bytes.length &&
          (bytes[i] == 0x20 ||
              bytes[i] == 0x09 ||
              bytes[i] == 0x0A ||
              bytes[i] == 0x0D)) {
        i++;
      }
      if (i >= bytes.length) break;

      final c = bytes[i];
      final d = depth - 1;
      final isObject = tracker.isObject(d);
      final hasElements = tracker.hasElements(d);
      final st = tracker.getState(d);

      if (c == 125 || c == 93) {
        if (c == 125) {
          if (!isObject) {
            throw FormatException('Mismatched "}" at offset $i', bytes, i);
          }
        } else {
          if (isObject) {
            throw FormatException('Mismatched "]" at offset $i', bytes, i);
          }
        }
        if (st == 3) {
          // Valid close after value
        } else if (st == 0) {
          if (hasElements) {
            final closeChar = isObject ? '"}"' : '"]"';
            throw FormatException(
              'Trailing comma before $closeChar at offset $i',
              bytes,
              i,
            );
          }
          // Valid close of empty container: [] or {}
        } else if (st == 1) {
          throw FormatException('Expected ":" at offset $i', bytes, i);
        } else {
          throw FormatException(
            'Expected value in object at offset $i',
            bytes,
            i,
          );
        }
        i++;
        depth--;
        if (depth > 0) {
          final pd = depth - 1;
          tracker.setHasElements(pd);
          tracker.setState(pd, 3);
        }
      } else if (c == 44) {
        if (st != 3) {
          if (st == 0) {
            throw FormatException(
              'Unexpected "," in container at offset $i',
              bytes,
              i,
            );
          } else if (st == 1) {
            throw FormatException('Expected ":" at offset $i', bytes, i);
          } else {
            throw FormatException(
              'Expected value before "," at offset $i',
              bytes,
              i,
            );
          }
        }
        i++;
        tracker.setHasElements(d);
        tracker.setState(d, 0);
      } else if (c == 58) {
        if (!isObject || st != 1) {
          throw FormatException('Unexpected ":" at offset $i', bytes, i);
        }
        i++;
        tracker.setState(d, 2);
      } else if (c == 34) {
        if (isObject) {
          if (st == 0) {
            // String is a property key
            i = _skipStringLiteral(bytes, i + 1) + 1;
            tracker.setState(d, 1);
          } else if (st == 2) {
            // String is a property value
            i = _skipStringLiteral(bytes, i + 1) + 1;
            tracker.setHasElements(d);
            tracker.setState(d, 3);
          } else if (st == 1) {
            throw FormatException('Expected ":" at offset $i', bytes, i);
          } else {
            throw FormatException('Expected "," or "}" at offset $i', bytes, i);
          }
        } else {
          // Array element
          if (st == 0 || st == 2) {
            i = _skipStringLiteral(bytes, i + 1) + 1;
            tracker.setHasElements(d);
            tracker.setState(d, 3);
          } else {
            throw FormatException('Expected "," or "]" at offset $i', bytes, i);
          }
        }
      } else if (c == 123 || c == 91) {
        if (isObject) {
          if (st == 0) {
            throw FormatException(
              'Expected string key in object at offset $i',
              bytes,
              i,
            );
          } else if (st == 1) {
            throw FormatException('Expected ":" at offset $i', bytes, i);
          } else if (st == 3) {
            throw FormatException('Expected "," or "}" at offset $i', bytes, i);
          }
        } else {
          if (st == 3) {
            throw FormatException('Expected "," or "]" at offset $i', bytes, i);
          }
        }

        if (depth >= 1024) {
          throw FormatException(
            'Nesting depth exceeds limit of 1024 at offset $i',
            bytes,
            i,
          );
        }

        final newIsObj = (c == 123);
        tracker.pushContainer(depth, newIsObj);
        depth++;
        i++;
      } else {
        if (isObject) {
          if (st == 0) {
            throw FormatException(
              'Expected string key in object at offset $i',
              bytes,
              i,
            );
          } else if (st == 1) {
            throw FormatException('Expected ":" at offset $i', bytes, i);
          } else if (st == 3) {
            throw FormatException('Expected "," or "}" at offset $i', bytes, i);
          }
        } else {
          if (st == 3) {
            throw FormatException('Expected "," or "]" at offset $i', bytes, i);
          }
        }

        i = _skipScalar(bytes, i);
        tracker.setHasElements(d);
        tracker.setState(d, 3);
      }
    }

    if (depth > 0) {
      throw FormatException(
        'Unclosed container at offset $offset',
        bytes,
        offset,
      );
    }
    return i;
  }
  if (b == 34) {
    return _skipStringLiteral(bytes, i + 1) + 1;
  }
  return _skipScalar(bytes, i);
}

/// Fast-skips JSON whitespace (0x20, 0x09, 0x0A, 0x0D) starting at [offset]
/// and returns the offset of the next non-whitespace byte.
int _skipWhitespace(Uint8List bytes, int offset) {
  if (offset < 0 || offset > bytes.length) {
    throw RangeError.range(offset, 0, bytes.length, 'offset');
  }
  var i = offset;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) {
      i++;
    } else {
      break;
    }
  }
  return i;
}

/// Scans forward from [offset] past an unescaped closing quote (") without
/// parsing escapes, returning the byte offset after the closing quote.
int _skipString(Uint8List bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) {
    throw RangeError.range(
      offset,
      0,
      bytes.length == 0 ? 0 : bytes.length - 1,
      'offset',
    );
  }
  if (bytes[offset] != 34) {
    throw FormatException('Expected """ at offset $offset', bytes, offset);
  }
  return _skipStringLiteral(bytes, offset + 1) + 1;
}

/// An encoder that encodes an object directly into UTF-8 JSON bytes.
final class JsonUtf8Encoder extends Converter<Object?, List<int>> {
  /// Default buffer size used by the JSON-to-UTF-8 encoder (32 KB).
  static const int _defaultBufferSize = 32768;

  /// Indentation used in pretty-print mode, `null` if not pretty.
  final List<int>? _indent;

  /// Function called with each un-encodable object encountered.
  final Object? Function(dynamic)? _toEncodable;

  /// UTF-8 buffer size.
  final int _bufferSize;

  /// Creates a [JsonUtf8Encoder].
  ///
  /// The [indent] string is used for pretty-printing, or `null` for compact output.
  ///
  /// The [toEncodable] function is called on objects that are not natively encodable.
  ///
  /// The [bufferSize] specifies the chunk buffer size (in bytes) used during
  /// chunked conversion. It must be greater than zero. If omitted, defaults to
  /// 32 KB (32768 bytes).
  ///
  /// Throws a [RangeError] if [bufferSize] is zero or negative.
  JsonUtf8Encoder([
    String? indent,
    dynamic Function(dynamic object)? toEncodable,
    int? bufferSize,
  ]) : _indent = _utf8Encode(indent),
       _toEncodable = toEncodable,
       _bufferSize = _checkBufferSize(bufferSize);

  static int _checkBufferSize(int? bufferSize) {
    if (bufferSize == null) return _defaultBufferSize;
    // The copy loops flush and retry whenever the buffer is full. With a
    // zero-length buffer the flush cannot free any space, so the retry would
    // spin forever.
    if (bufferSize < 1) {
      throw RangeError.value(bufferSize, 'bufferSize', 'Must be positive');
    }
    return bufferSize;
  }

  static List<int>? _utf8Encode(String? string) {
    if (string == null) return null;
    if (string.isEmpty) return Uint8List(0);
    checkAscii:
    {
      for (var i = 0; i < string.length; i++) {
        if (string.codeUnitAt(i) >= 0x80) break checkAscii;
      }
      return string.codeUnits;
    }
    return utf8.encode(string);
  }

  @override
  Uint8List convert(Object? object) {
    var bytes = <Uint8List>[];
    void addChunk(Uint8List chunk, int start, int end) {
      if (start > 0 || end < chunk.length) {
        var length = end - start;
        chunk = Uint8List.view(
          chunk.buffer,
          chunk.offsetInBytes + start,
          length,
        );
      }
      bytes.add(chunk);
    }

    _JsonUtf8Stringifier.stringify(
      object,
      _indent,
      _toEncodable,
      _bufferSize,
      addChunk,
    );
    if (bytes.isEmpty) return Uint8List(0);
    if (bytes.length == 1) {
      final first = bytes[0];
      if (first.length < first.buffer.lengthInBytes) {
        return Uint8List.fromList(first);
      }
      return first;
    }
    var length = 0;
    for (var i = 0; i < bytes.length; i++) {
      length += bytes[i].length;
    }
    var result = Uint8List(length);
    for (var i = 0, offset = 0; i < bytes.length; i++) {
      var byteList = bytes[i];
      int end = offset + byteList.length;
      result.setRange(offset, end, byteList);
      offset = end;
    }
    return result;
  }

  @override
  ChunkedConversionSink<Object?> startChunkedConversion(Sink<List<int>> sink) {
    ByteConversionSink byteSink;
    if (sink is ByteConversionSink) {
      byteSink = sink;
    } else {
      byteSink = ByteConversionSink.from(sink);
    }
    return _JsonUtf8EncoderSink(byteSink, _toEncodable, _indent, _bufferSize);
  }

  @override
  Stream<List<int>> bind(Stream<Object?> stream) {
    return super.bind(stream);
  }
}

// --- Private Low-Level Formatting Helpers ---

/// Writes [value] with standard JSON escaping directly into [sink].
void _writeString(String value, BytesBuilder sink) {
  // Six bytes per code unit is only reached by a string made entirely of
  // control characters or isolated surrogates. Three covers every
  // unescaped code unit, including astral characters, which arrive as a
  // surrogate pair and encode to four bytes across two units. Sizing for
  // the worst case up front costs twice the output for ordinary text and,
  // with no floor, allocated 256 bytes for every short object key.
  final length = value.length;
  var buffer = Uint8List(length * 3 + 2);
  int written;
  try {
    written = _writeStringToBuffer(value, buffer, 0);
  } on RangeError {
    // Escape-heavy: retry once at the true worst case. The offset is zero
    // and the buffer is local, so capacity is the only possible cause.
    buffer = Uint8List(length * 6 + 2);
    written = _writeStringToBuffer(value, buffer, 0);
  }
  sink.add(Uint8List.sublistView(buffer, 0, written));
}

/// Writes [value] with standard JSON escaping directly into [buffer] starting
/// at [offset]. Returns the number of bytes written.
int _writeStringToBuffer(String value, Uint8List buffer, int offset) {
  return _writeStringToBufferUtf8(value, buffer, offset);
}

/// Formats [value] as a valid JSON floating-point literal directly into [sink].
void _writeDouble(double value, BytesBuilder sink) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'Must be finite');
  }
  final buf = Uint8List(32);
  final len = _writeDoubleToBuffer(value, buf, 0);
  sink.add(Uint8List.sublistView(buf, 0, len));
}

/// Formats [value] directly into [buffer] starting at [offset] as ASCII bytes.
/// Number of bytes written.
int _writeDoubleToBuffer(double value, Uint8List buffer, int offset) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'Must be finite');
  }
  final written = _writeDoubleToBufferUtf8(value, buffer, offset);
  if (written > 0) return written;
  final str = value.toString();
  final len = str.length;
  if (offset < 0 || offset + len > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= len ? buffer.length - len : 0,
      'offset',
    );
  }
  for (var i = 0; i < len; i++) {
    buffer[offset + i] = str.codeUnitAt(i);
  }
  return len;
}

/// Formats [value] as an ASCII integer literal directly into [sink].
void _writeInt(int value, BytesBuilder sink) {
  // See [_writeIntToBuffer] for why the limit is platform dependent.
  final limit = identical(1, 1.0) ? 9007199254740992.0 : 1e19;
  if (value >= limit || value <= -limit) {
    final str = value.toString();
    for (var i = 0; i < str.length; i++) {
      sink.addByte(str.codeUnitAt(i));
    }
    return;
  }
  final buf = Uint8List(24);
  final len = _writeIntToBuffer(value, buf, 0);
  sink.add(Uint8List.sublistView(buf, 0, len));
}

/// Formats [value] directly into [buffer] starting at [offset] as ASCII bytes.
/// Number of bytes written.
int _writeIntToBuffer(int value, Uint8List buffer, int offset) {
  if (value == 0) {
    if (offset < 0 || offset >= buffer.length) {
      throw RangeError.range(
        offset,
        0,
        buffer.length >= 1 ? buffer.length - 1 : 0,
        'offset',
      );
    }
    buffer[offset] = 48; // '0'
    return 1;
  }
  // Above this magnitude the value is formatted with `toString` instead of
  // the `_digitPairs` loop. On the VM and Wasm `int` is a signed 64-bit
  // integer and the loop is exact across the whole range, so the limit sits
  // above it. On the web `int` is a double: `~/` and `*` stop being exact
  // past 2^53, so `next * 100` can overshoot `temp`, which drives the
  // remainder negative and indexes outside `_digitPairs`.
  final limit = identical(1, 1.0) ? 9007199254740992.0 : 1e19;
  if (value >= limit || value <= -limit) {
    final str = value.toString();
    final len = str.length;
    if (offset < 0 || offset + len > buffer.length) {
      throw RangeError.range(
        offset,
        0,
        buffer.length >= len ? buffer.length - len : 0,
        'offset',
      );
    }
    for (var i = 0; i < len; i++) {
      buffer[offset + i] = str.codeUnitAt(i);
    }
    return len;
  }
  var v = value;
  final isNeg = v < 0;
  if (!isNeg) {
    v = -v;
  }
  final digitCount = _digitCountNegative(v);
  final totalLen = (isNeg ? 1 : 0) + digitCount;
  if (offset < 0 || offset + totalLen > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= totalLen ? buffer.length - totalLen : 0,
      'offset',
    );
  }
  var cursor = offset;
  if (isNeg) {
    buffer[cursor++] = 45; // '-'
  }
  final writePos = cursor + digitCount - 1;
  _emitDigitsBackwardNegative(buffer, writePos, v);
  return totalLen;
}

/// Writes a boolean literal (`true` or `false`) directly into [sink].
void _writeBool(bool value, BytesBuilder sink) {
  if (value) {
    sink.add(const [116, 114, 117, 101]); // 'true'
  } else {
    sink.add(const [102, 97, 108, 115, 101]); // 'false'
  }
}

/// Writes a boolean literal directly into [buffer] starting at [offset].
/// Number of bytes written.
int _writeBoolToBuffer(bool value, Uint8List buffer, int offset) {
  final len = value ? 4 : 5;
  if (offset < 0 || offset + len > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= len ? buffer.length - len : 0,
      'offset',
    );
  }
  if (value) {
    buffer[offset] = 116; // 't'
    buffer[offset + 1] = 114; // 'r'
    buffer[offset + 2] = 117; // 'u'
    buffer[offset + 3] = 101; // 'e'
    return 4;
  } else {
    buffer[offset] = 102; // 'f'
    buffer[offset + 1] = 97; // 'a'
    buffer[offset + 2] = 108; // 'l'
    buffer[offset + 3] = 115; // 's'
    buffer[offset + 4] = 101; // 'e'
    return 5;
  }
}

/// Writes a `null` literal directly into [sink].
void _writeNull(BytesBuilder sink) {
  sink.add(const [110, 117, 108, 108]); // 'null'
}

/// Writes a `null` literal directly into [buffer] starting at [offset].
/// Number of bytes written.
int _writeNullToBuffer(Uint8List buffer, int offset) {
  const len = 4;
  if (offset < 0 || offset + len > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= len ? buffer.length - len : 0,
      'offset',
    );
  }
  buffer[offset] = 110;
  buffer[offset + 1] = 117;
  buffer[offset + 2] = 108;
  buffer[offset + 3] = 108;
  return 4;
}

/// Writes a pre-encoded compile-time ASCII byte literal directly into [sink].
void _writeAsciiLiteral(Uint8List asciiBytes, BytesBuilder sink) {
  sink.add(asciiBytes);
}

/// Writes a pre-encoded ASCII byte literal directly into [buffer] at [offset].
/// Number of bytes written.
int _writeAsciiLiteralToBuffer(
  Uint8List asciiBytes,
  Uint8List buffer,
  int offset,
) {
  final len = asciiBytes.length;
  if (offset < 0 || offset + len > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= len ? buffer.length - len : 0,
      'offset',
    );
  }
  buffer.setRange(offset, offset + len, asciiBytes);
  return len;
}

/// Writes a raw JSON UTF-8 byte fragment directly into [sink].
void _writeRawJson(Uint8List rawJson, BytesBuilder sink) {
  sink.add(rawJson);
}

/// Writes a raw JSON UTF-8 byte fragment directly into [buffer] at [offset].
/// Number of bytes written.
int _writeRawJsonToBuffer(Uint8List rawJson, Uint8List buffer, int offset) {
  final len = rawJson.length;
  if (offset < 0 || offset + len > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= len ? buffer.length - len : 0,
      'offset',
    );
  }
  buffer.setRange(offset, offset + len, rawJson);
  return len;
}

/// Safely writes an object property separator (comma if not first) and key
/// prefix into [buffer], avoiding leading comma bugs on nullable/omitted fields.
int _writePropertyPrefixToBuffer(
  Uint8List buffer,
  int offset,
  Uint8List asciiKey, {
  required bool isFirst,
}) {
  final isFirstOffset = isFirst ? 0 : 1;
  final isColonTerminated =
      asciiKey.length >= 3 &&
      asciiKey.first == 0x22 &&
      asciiKey.last == 0x3A &&
      _isSingleQuotedSlice(asciiKey, 0, asciiKey.length - 1);
  if (isColonTerminated) {
    final requiredLen = isFirstOffset + asciiKey.length;
    if (offset < 0 || offset + requiredLen > buffer.length) {
      throw RangeError.range(
        offset,
        0,
        buffer.length >= requiredLen ? buffer.length - requiredLen : 0,
        'offset',
      );
    }
    var cursor = offset;
    if (!isFirst) {
      buffer[cursor++] = 44; // ','
    }
    final keyLen = asciiKey.length;
    buffer.setRange(cursor, cursor + keyLen, asciiKey);
    cursor += keyLen;
    return cursor - offset;
  }

  final isQuoted = _isSingleQuotedString(asciiKey);
  if (isQuoted) {
    final requiredLen = isFirstOffset + asciiKey.length + 1;
    if (offset < 0 || offset + requiredLen > buffer.length) {
      throw RangeError.range(
        offset,
        0,
        buffer.length >= requiredLen ? buffer.length - requiredLen : 0,
        'offset',
      );
    }
    var cursor = offset;
    if (!isFirst) {
      buffer[cursor++] = 44; // ','
    }
    final keyLen = asciiKey.length;
    buffer.setRange(cursor, cursor + keyLen, asciiKey);
    cursor += keyLen;
    buffer[cursor++] = 58; // ':'
    return cursor - offset;
  }

  var escapedContentLen = 0;
  for (var i = 0; i < asciiKey.length; i++) {
    final b = asciiKey[i];
    if (b == 0x22 || b == 0x5C) {
      escapedContentLen += 2;
    } else if (b < 0x20) {
      escapedContentLen += 6;
    } else {
      escapedContentLen += 1;
    }
  }

  final requiredLen = isFirstOffset + 2 + escapedContentLen + 1;
  if (offset < 0 || offset + requiredLen > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= requiredLen ? buffer.length - requiredLen : 0,
      'offset',
    );
  }

  var cursor = offset;
  if (!isFirst) {
    buffer[cursor++] = 44; // ','
  }
  buffer[cursor++] = 0x22; // '"'
  for (var i = 0; i < asciiKey.length; i++) {
    final b = asciiKey[i];
    if (b == 0x22) {
      buffer[cursor++] = 0x5C;
      buffer[cursor++] = 0x22;
    } else if (b == 0x5C) {
      buffer[cursor++] = 0x5C;
      buffer[cursor++] = 0x5C;
    } else if (b < 0x20) {
      buffer[cursor++] = 0x5C;
      buffer[cursor++] = 0x75; // 'u'
      buffer[cursor++] = 0x30; // '0'
      buffer[cursor++] = 0x30; // '0'
      buffer[cursor++] = _hexDigits.codeUnitAt((b >> 4) & 0xF);
      buffer[cursor++] = _hexDigits.codeUnitAt(b & 0xF);
    } else {
      buffer[cursor++] = b;
    }
  }
  buffer[cursor++] = 0x22; // '"'
  buffer[cursor++] = 58; // ':'
  return cursor - offset;
}

class _JsonUtf8EncoderSink extends ChunkedConversionSink<Object?> {
  final ByteConversionSink _sink;
  final List<int>? _indent;
  final Object? Function(dynamic)? _toEncodable;
  final int _bufferSize;
  bool _isDone = false;

  _JsonUtf8EncoderSink(
    this._sink,
    this._toEncodable,
    this._indent,
    this._bufferSize,
  );

  void _addChunk(Uint8List chunk, int start, int end) {
    _sink.addSlice(chunk, start, end, false);
  }

  @override
  void add(Object? object) {
    if (_isDone) {
      throw StateError("Only one call to add allowed");
    }
    _JsonUtf8Stringifier.stringify(
      object,
      _indent,
      _toEncodable,
      _bufferSize,
      _addChunk,
    );
    _isDone = true;
    _sink.close();
  }

  @override
  void close() {
    if (!_isDone) {
      _isDone = true;
      _sink.close();
    }
  }
}

class _JsonUtf8Stringifier extends _JsonStringifier {
  final int bufferSize;
  final void Function(Uint8List list, int start, int end) addChunk;
  Uint8List buffer;
  int index = 0;

  _JsonUtf8Stringifier(super.toEncodable, this.bufferSize, this.addChunk)
    : buffer = Uint8List(bufferSize);

  static void stringify(
    Object? object,
    List<int>? indent,
    dynamic Function(dynamic o)? toEncodable,
    int bufferSize,
    void Function(Uint8List chunk, int start, int end) addChunk,
  ) {
    _JsonUtf8Stringifier stringifier;
    if (indent != null) {
      stringifier = _JsonUtf8StringifierPretty(
        toEncodable,
        indent,
        bufferSize,
        addChunk,
      );
    } else {
      stringifier = _JsonUtf8Stringifier(toEncodable, bufferSize, addChunk);
    }
    stringifier.writeObject(object);
    stringifier.flush();
  }

  void flush() {
    if (index > 0) {
      addChunk(buffer, 0, index);
    }
    buffer = Uint8List(0);
    index = 0;
  }

  String? get _partialResult => null;

  @override
  void writeString(String string) => writeStringSlice(string, 0, string.length);

  void _flushBuffer() {
    if (index > 0) {
      addChunk(buffer, 0, index);
      index = 0;
    }
    buffer = Uint8List(bufferSize);
  }

  @override
  bool writeJsonValue(Object? object) {
    if (object is num) {
      if (!object.isFinite) return false;
      writeNumber(object);
      return true;
    } else if (identical(object, true)) {
      writeAsciiString('true');
      return true;
    } else if (identical(object, false)) {
      writeAsciiString('false');
      return true;
    } else if (object == null) {
      writeAsciiString('null');
      return true;
    } else if (object is String) {
      final maxLen = object.length * 6 + 2;
      if (index + maxLen <= buffer.length) {
        index += _writeStringToBuffer(object, buffer, index);
        return true;
      }
      if (maxLen <= bufferSize) {
        _flushBuffer();
        index += _writeStringToBuffer(object, buffer, index);
        return true;
      }
      writeByte(0x22);
      writeStringContent(object);
      writeByte(0x22);
      return true;
    } else if (object is List) {
      _checkCycle(object);
      writeList(object);
      _removeSeen(object);
      return true;
    } else if (object is Map) {
      _checkCycle(object);
      var success = writeMap(object);
      _removeSeen(object);
      return success;
    } else {
      return false;
    }
  }

  @override
  bool writeMap(Map<Object?, Object?> map) {
    if (map.isEmpty) {
      writeAsciiString("{}");
      return true;
    }
    var keyValueList = List<Object?>.filled(map.length * 2, null);
    var i = 0;
    var allStringKeys = true;
    map.forEach((key, value) {
      if (key is! String) {
        allStringKeys = false;
      }
      keyValueList[i++] = key;
      keyValueList[i++] = value;
    });
    if (!allStringKeys) return false;
    writeByte(0x7B); // '{'
    for (var i = 0; i < keyValueList.length; i += 2) {
      if (i > 0) writeByte(0x2C); // ','
      final key = keyValueList[i] as String;
      final maxLen = key.length * 6 + 3; // quotes + escapes + ':'
      if (index + maxLen <= buffer.length) {
        index += _writeStringToBuffer(key, buffer, index);
        buffer[index++] = 0x3A; // ':'
      } else if (maxLen <= bufferSize) {
        _flushBuffer();
        index += _writeStringToBuffer(key, buffer, index);
        buffer[index++] = 0x3A; // ':'
      } else {
        writeByte(0x22);
        writeStringContent(key);
        writeByte(0x22);
        writeByte(0x3A);
      }
      writeObject(keyValueList[i + 1]);
    }
    writeByte(0x7D); // '}'
    return true;
  }

  @override
  void writeList(List<Object?> list) {
    writeByte(0x5B); // '['
    if (list.isNotEmpty) {
      writeObject(list[0]);
      for (var i = 1; i < list.length; i++) {
        writeByte(0x2C); // ','
        writeObject(list[i]);
      }
    }
    writeByte(0x5D); // ']'
  }

  void writeNumber(num number) {
    if (number is int) {
      if (number > -1e19 && number < 1e19) {
        if (index + 24 <= buffer.length) {
          index += _writeIntToBuffer(number, buffer, index);
          return;
        }
        if (24 <= bufferSize) {
          _flushBuffer();
          index += _writeIntToBuffer(number, buffer, index);
          return;
        }
      }
      writeAsciiString(number.toString());
      return;
    } else if (number is double && number.isFinite) {
      if (index + 32 <= buffer.length) {
        index += _writeDoubleToBuffer(number, buffer, index);
        return;
      }
      if (32 <= bufferSize) {
        _flushBuffer();
        index += _writeDoubleToBuffer(number, buffer, index);
        return;
      }
    }
    writeAsciiString(number.toString());
  }

  void writeAsciiString(String string) {
    final len = string.length;
    if (index + len <= buffer.length) {
      for (var i = 0; i < len; i++) {
        buffer[index++] = string.codeUnitAt(i);
      }
      return;
    }
    if (len <= bufferSize) {
      _flushBuffer();
      for (var i = 0; i < len; i++) {
        buffer[index++] = string.codeUnitAt(i);
      }
      return;
    }
    var srcPos = 0;
    var remaining = len;
    while (remaining > 0) {
      final space = buffer.length - index;
      if (space == 0) {
        _flushBuffer();
        continue;
      }
      final toCopy = remaining < space ? remaining : space;
      for (var k = 0; k < toCopy; k++) {
        buffer[index++] = string.codeUnitAt(srcPos + k);
      }
      srcPos += toCopy;
      remaining -= toCopy;
    }
  }

  void writeStringSlice(String string, int start, int end) {
    var i = start;
    while (i < end) {
      var char = string.codeUnitAt(i);
      if (char <= 0x7f) {
        final asciiStart = i;
        i++;
        while (i < end) {
          if (string.codeUnitAt(i) > 0x7f) break;
          i++;
        }
        final asciiLen = i - asciiStart;
        var srcPos = asciiStart;
        var remaining = asciiLen;
        while (remaining > 0) {
          final space = buffer.length - index;
          if (space == 0) {
            _flushBuffer();
            continue;
          }
          final toCopy = remaining < space ? remaining : space;
          for (var k = 0; k < toCopy; k++) {
            buffer[index++] = string.codeUnitAt(srcPos + k);
          }
          srcPos += toCopy;
          remaining -= toCopy;
        }
      } else {
        if ((char & 0xF800) == 0xD800) {
          // Surrogate pair (isolated surrogates are filtered by writeStringContent).
          if (char < 0xDC00 && i + 1 < end) {
            final nextChar = string.codeUnitAt(i + 1);
            if ((nextChar & 0xFC00) == 0xDC00) {
              char = 0x10000 + ((char & 0x3ff) << 10) + (nextChar & 0x3ff);
              writeFourByteCharCode(char);
              i += 2;
              continue;
            }
          }
        }
        writeMultiByteCharCode(char);
        i++;
      }
    }
  }

  void writeCharCode(int charCode) {
    if (charCode <= 0x7f) {
      writeByte(charCode);
      return;
    }
    writeMultiByteCharCode(charCode);
  }

  void writeMultiByteCharCode(int charCode) {
    if (charCode <= 0x7ff) {
      writeByte(0xC0 | (charCode >> 6));
      writeByte(0x80 | (charCode & 0x3f));
      return;
    }
    if (charCode <= 0xffff) {
      writeByte(0xE0 | (charCode >> 12));
      writeByte(0x80 | ((charCode >> 6) & 0x3f));
      writeByte(0x80 | (charCode & 0x3f));
      return;
    }
    writeFourByteCharCode(charCode);
  }

  void writeFourByteCharCode(int charCode) {
    assert(charCode <= 0x10ffff);
    writeByte(0xF0 | (charCode >> 18));
    writeByte(0x80 | ((charCode >> 12) & 0x3f));
    writeByte(0x80 | ((charCode >> 6) & 0x3f));
    writeByte(0x80 | (charCode & 0x3f));
  }

  void writeByte(int byte) {
    assert(byte <= 0xff);
    if (index == buffer.length) {
      _flushBuffer();
    }
    buffer[index++] = byte;
  }
}

class _JsonUtf8StringifierPretty extends _JsonUtf8Stringifier
    with _JsonPrettyPrintMixin {
  final List<int> indent;
  _JsonUtf8StringifierPretty(
    dynamic Function(dynamic o)? toEncodable,
    this.indent,
    int bufferSize,
    void Function(Uint8List buffer, int start, int end) addChunk,
  ) : super(toEncodable, bufferSize, addChunk);

  void writeIndentation(int count) {
    var indent = this.indent;
    var indentLength = indent.length;
    if (indentLength == 1) {
      var char = indent[0];
      while (count > 0) {
        writeByte(char);
        count -= 1;
      }
      return;
    }
    while (count > 0) {
      count--;
      var end = index + indentLength;
      if (end <= buffer.length) {
        buffer.setRange(index, end, indent);
        index = end;
      } else {
        for (var i = 0; i < indentLength; i++) {
          writeByte(indent[i]);
        }
      }
    }
  }
}

/// High-performance imperative pull-based JSON token reader.
///
/// Enforces a maximum structural nesting depth limit of 1,024 levels of nested
/// objects and arrays as a contract guarantee, throwing a [FormatException]
/// if input exceeds 1,024 levels of nesting.
abstract interface class JsonTokenReader {
  /// Instantiates a pull-based token reader over [bytes].
  factory JsonTokenReader.fromBytes(Uint8List bytes, {bool allowMalformed}) =
      _JsonTokenReader;

  /// The backing UTF-8 byte buffer being read by this reader.
  ///
  /// This buffer is intended to be treated as read-only. Modifying the contents
  /// of this buffer while reading will corrupt reader state and produce undefined
  /// behavior.
  ///
  /// Callers can pair this buffer with coordinates returned from [readStringSpan]
  /// or [getTokenSpan] to perform zero-allocation parsing on UTF-8 sub-slices
  /// (e.g., parsing UUIDs, ISO-8601 timestamps, base64 payloads, or computing hashes).
  Uint8List get bytes;

  /// Peeks at the next token type without advancing the cursor.
  JsonTokenType peek();

  /// Advances past the opening `{` of an object.
  void beginObject();

  /// Advances past the closing `}` of an object.
  void endObject();

  /// Advances past the opening `[` of an array.
  void beginArray();

  /// Advances past the closing `]` of an array.
  void endArray();

  /// Whether the current object or array has more elements.
  bool hasNext();

  /// Reads the next object property name as a [String].
  String nextName();

  /// Matches the next property name against pre-compiled [options] in O(1).
  int selectName(JsonKeyOptions options);

  /// Matches the next string VALUE against pre-compiled [options] in O(1)
  /// without allocating a heap [String] (e.g. for parsing string enums).
  int selectString(JsonKeyOptions options);

  /// Reads a string value, decoding UTF-8 bytes and resolving escape sequences.
  String readString();

  /// Reads a string value and returns the raw byte coordinates `(start, end)`
  /// of its contents within [bytes] (excluding surrounding quotes), advancing the
  /// cursor past the token and any trailing structural delimiters.
  ///
  /// The returned coordinates span `bytes[start]` inclusive to `bytes[end]` exclusive.
  ///
  /// ### Escape Sequences
  /// The returned byte span contains raw, verbatim JSON text as it exists in [bytes].
  /// If the string contains escape sequences (such as `\n`, `\t`, or `\uXXXX`),
  /// they remain in their raw literal byte sequence.
  ///
  /// To obtain a decoded Dart [String] with escape sequences resolved, use [readString].
  ///
  /// ### Lifetime and Memory Pinning
  /// Coordinates are valid for the lifetime of [bytes]. If constructing long-lived
  /// views (such as `Uint8List.sublistView`), note that the view retains a reference
  /// to the entire backing buffer. For scalar types (e.g. `DateTime` or UUIDs), values
  /// should be parsed directly from the span during traversal to avoid pinning large
  /// JSON documents in memory.
  (int start, int end) readStringSpan();

  /// Reads an integer value.
  int readInt();

  /// Reads a double value (with automatic integer-to-double coercion).
  double readDouble();

  /// Reads a numeric token as a [num] (either [int] or [double]).
  num readNum();

  /// Reads a boolean value.
  bool readBool();

  /// Reads a null literal.
  void readNull();

  /// Skips the entire next value (including nested objects and arrays).
  void skipValue();

  /// The raw byte span `(start, end)` of the current token.
  (int start, int end) getTokenSpan();
}

enum _ContainerType { object, array }

final class _JsonTokenReader implements JsonTokenReader {
  static const int _maxDepth = 1024;
  static const int _stringCacheSize = 128;
  static const int _stringCacheMask = 127;
  static const int _maxCachedStringLength = 64;

  final Uint8List _bytes;
  final bool allowMalformed;
  int _offset = 0;
  Uint8List _stack = Uint8List(64);
  int _stackLength = 0;
  int _topType = -1; // -1: none, 0: object, 1: array
  int _topState = 0; // 0: start, 1: afterName, 2: afterValue, 3: afterComma
  bool _hasReadRoot = false;
  final List<String?> _stringCache = List<String?>.filled(
    _stringCacheSize,
    null,
  );

  @override
  Uint8List get bytes => _bytes;

  _JsonTokenReader(this._bytes, {this.allowMalformed = false}) {
    if (_bytes.length >= 3 &&
        _bytes[0] == 0xEF &&
        _bytes[1] == 0xBB &&
        _bytes[2] == 0xBF) {
      _offset = 3;
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void _skipWs() {
    while (_offset < _bytes.length && _isWs(_bytes[_offset])) {
      _offset++;
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void _beforeReadingName() {
    _skipWs();
    if (_stackLength == 0 || _topType != 0) {
      throw FormatException(
        'Cannot read property name outside of an object at offset $_offset',
      );
    }
    if (_topState == 1) {
      throw FormatException(
        'Expected property value before next property name at offset $_offset',
      );
    }
    if (_topState == 2) {
      if (_offset < _bytes.length && _bytes[_offset] == 44) {
        _offset++;
        _topState = 3;
        _skipWs();
      } else {
        throw FormatException(
          'Expected "," before property name at offset $_offset',
        );
      }
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void _beforeReadingValue() {
    _skipWs();
    if (_stackLength > 0) {
      if (_topType == 0) {
        if (_topState != 1) {
          throw FormatException(
            'Expected property name before value at offset $_offset',
          );
        }
      } else {
        if (_topState == 2) {
          if (_offset < _bytes.length && _bytes[_offset] == 44) {
            _offset++;
            _topState = 3;
            _skipWs();
          } else {
            throw FormatException(
              'Expected "," before array element at offset $_offset',
            );
          }
        }
      }
    } else {
      if (_hasReadRoot) {
        throw FormatException(
          'Cannot read multiple root values',
          _bytes,
          _offset,
        );
      }
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void _afterReadingValue() {
    if (_stackLength > 0) {
      _topState = 2;
    } else {
      _hasReadRoot = true;
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  static JsonTokenType _valueTokenType(int b) {
    switch (b) {
      case 123: // '{'
        return JsonTokenType.beginObject;
      case 91: // '['
        return JsonTokenType.beginArray;
      case 34: // '"'
        return JsonTokenType.string;
      case 116: // 't'
      case 102: // 'f'
        return JsonTokenType.boolean;
      case 110: // 'n'
        return JsonTokenType.nullValue;
      case 45: // '-'
      case 48:
      case 49:
      case 50:
      case 51:
      case 52:
      case 53:
      case 54:
      case 55:
      case 56:
      case 57:
        return JsonTokenType.number;
      default:
        return JsonTokenType.none;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  JsonTokenType peek() {
    final _len = _bytes.length;
    var i = _offset;
    while (i < _len && _isWs(_bytes[i])) {
      i++;
    }
    if (i >= _len) {
      if (_stackLength > 0 && _topState == 3) {
        throw FormatException(
          'Unexpected end of document after comma',
          _bytes,
          _offset,
        );
      }
      return JsonTokenType.endOfDocument;
    }

    if (_stackLength > 0) {
      if (_topType == 0) {
        switch (_topState) {
          case 0:
            if (_bytes[i] == 125) return JsonTokenType.endObject;
            if (_bytes[i] == 34) return JsonTokenType.propertyName;
            return JsonTokenType.none;
          case 1:
            return _valueTokenType(_bytes[i]);
          case 3:
            if (_bytes[i] == 34) return JsonTokenType.propertyName;
            if (_bytes[i] == 125 || _bytes[i] == 93) {
              throw FormatException(
                'Trailing comma before closing delimiter',
                _bytes,
                _offset,
              );
            }
            return JsonTokenType.none;
          case 2:
            if (_bytes[i] == 125) return JsonTokenType.endObject;
            if (_bytes[i] == 44) {
              i++;
              while (i < _len && _isWs(_bytes[i])) {
                i++;
              }
              if (i >= _len) {
                throw FormatException(
                  'Unexpected end of document after comma',
                  _bytes,
                  _offset,
                );
              }
              if (_bytes[i] == 125 || _bytes[i] == 93) {
                throw FormatException(
                  'Trailing comma before closing delimiter',
                  _bytes,
                  _offset,
                );
              }
              if (_bytes[i] == 34) return JsonTokenType.propertyName;
              return JsonTokenType.none;
            }
            throw FormatException(
              'Expected comma or closing delimiter',
              _bytes,
              _offset,
            );
        }
      } else {
        // _ContainerType.array
        switch (_topState) {
          case 0:
            if (_bytes[i] == 93) return JsonTokenType.endArray;
            return _valueTokenType(_bytes[i]);
          case 3:
            if (_bytes[i] == 93 || _bytes[i] == 125) {
              throw FormatException(
                'Trailing comma before closing delimiter',
                _bytes,
                _offset,
              );
            }
            return _valueTokenType(_bytes[i]);
          case 2:
            if (_bytes[i] == 93) return JsonTokenType.endArray;
            if (_bytes[i] == 44) {
              i++;
              while (i < _len && _isWs(_bytes[i])) {
                i++;
              }
              if (i >= _len) {
                throw FormatException(
                  'Unexpected end of document after comma',
                  _bytes,
                  _offset,
                );
              }
              if (_bytes[i] == 93 || _bytes[i] == 125) {
                throw FormatException(
                  'Trailing comma before closing delimiter',
                  _bytes,
                  _offset,
                );
              }
              return _valueTokenType(_bytes[i]);
            }
            throw FormatException(
              'Expected comma or closing delimiter',
              _bytes,
              _offset,
            );
          case 1:
            return JsonTokenType.none;
        }
      }
    } else {
      if (_hasReadRoot) {
        return JsonTokenType.none;
      }
      return _valueTokenType(_bytes[i]);
    }
    throw StateError("unreachable");
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void beginObject() {
    _beforeReadingValue();
    if (_offset < _bytes.length && _bytes[_offset] == 123) {
      _offset++;
      if (_stackLength >= _maxDepth) {
        throw FormatException(
          'Nesting depth exceeds limit of $_maxDepth at offset $_offset',
        );
      }
      if (_stackLength > 0) {
        if (_stackLength >= _stack.length) {
          final newStack = Uint8List(_stack.length * 2);
          newStack.setRange(0, _stack.length, _stack);
          _stack = newStack;
        }
        _stack[_stackLength - 1] = (_topType << 2) | _topState;
      }
      _stackLength++;
      _topType = 0;
      _topState = 0;
    } else {
      throw FormatException('Expected "{" at offset $_offset');
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void endObject() {
    _skipWs();
    if (_stackLength == 0 || _topType != 0) {
      throw FormatException('Expected "}" at offset $_offset');
    }
    if (_topState == 3) {
      throw FormatException('Trailing comma before "}" at offset $_offset');
    }
    if (_topState == 1) {
      throw FormatException(
        'Expected value after property name before "}" at offset $_offset',
      );
    }
    if (_offset < _bytes.length && _bytes[_offset] == 125) {
      _offset++;
      _stackLength--;
      if (_stackLength > 0) {
        final packed = _stack[_stackLength - 1];
        _topType = packed >> 2;
        _topState = packed & 3;
      } else {
        _topType = -1;
        _topState = 0;
      }
      _afterReadingValue();
    } else {
      throw FormatException('Expected "}" at offset $_offset');
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void beginArray() {
    _beforeReadingValue();
    if (_offset < _bytes.length && _bytes[_offset] == 91) {
      _offset++;
      if (_stackLength >= _maxDepth) {
        throw FormatException(
          'Nesting depth exceeds limit of $_maxDepth at offset $_offset',
        );
      }
      if (_stackLength > 0) {
        if (_stackLength >= _stack.length) {
          final newStack = Uint8List(_stack.length * 2);
          newStack.setRange(0, _stack.length, _stack);
          _stack = newStack;
        }
        _stack[_stackLength - 1] = (_topType << 2) | _topState;
      }
      _stackLength++;
      _topType = 1;
      _topState = 0;
    } else {
      throw FormatException('Expected "[" at offset $_offset');
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void endArray() {
    _skipWs();
    if (_stackLength == 0 || _topType != 1) {
      throw FormatException('Expected "]" at offset $_offset');
    }
    if (_topState == 3) {
      throw FormatException('Trailing comma before "]" at offset $_offset');
    }
    if (_offset < _bytes.length && _bytes[_offset] == 93) {
      _offset++;
      _stackLength--;
      if (_stackLength > 0) {
        final packed = _stack[_stackLength - 1];
        _topType = packed >> 2;
        _topState = packed & 3;
      } else {
        _topType = -1;
        _topState = 0;
      }
      _afterReadingValue();
    } else {
      throw FormatException('Expected "]" at offset $_offset');
    }
  }

  @pragma('vm:never-inline')
  void _restoreState(
    int offset,
    int stackLength,
    int topType,
    int topState,
    bool hasReadRoot,
  ) {
    _offset = offset;
    _stackLength = stackLength;
    _topType = topType;
    _topState = topState;
    _hasReadRoot = hasReadRoot;
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  bool hasNext() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      _skipWs();
      if (_stackLength > 0) {
        final closeChar = _topType == 0 ? 125 : 93;
        final closeStr = _topType == 0 ? '"}"' : '"]"';

        if (_topState == 3) {
          if (_offset >= _bytes.length) {
            throw FormatException(
              'Unexpected end of document after comma',
              _bytes,
              _offset,
            );
          }
          if (_bytes[_offset] == 125 || _bytes[_offset] == 93) {
            throw FormatException(
              'Trailing comma before $closeStr at offset $_offset',
            );
          }
          return true;
        } else if (_topState == 0) {
          if (_offset >= _bytes.length) return false;
          if (_bytes[_offset] == closeChar) {
            return false;
          }
          return true;
        } else if (_topState == 2) {
          if (_offset >= _bytes.length) return false;
          if (_bytes[_offset] == closeChar) {
            return false;
          }
          if (_bytes[_offset] == 44) {
            _offset++;
            _topState = 3;
            _skipWs();
            if (_offset >= _bytes.length) {
              throw FormatException(
                'Unexpected end of document after comma',
                _bytes,
                _offset,
              );
            }
            if (_bytes[_offset] == 125 || _bytes[_offset] == 93) {
              throw FormatException(
                'Trailing comma before $closeStr at offset $_offset',
              );
            }
            return true;
          }
          throw FormatException('Expected "," or $closeStr at offset $_offset');
        } else if (_topState == 1) {
          if (_offset >= _bytes.length) {
            throw FormatException(
              'Unexpected end of document after property name',
              _bytes,
              _offset,
            );
          }
          return true;
        }
      } else {
        if (_hasReadRoot || _offset >= _bytes.length) {
          return false;
        }
      }
      final b = _bytes[_offset];
      return b != 125 && b != 93;
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  (int, int) _scanStringSpan() {
    _skipWs();
    if (_offset >= _bytes.length || _bytes[_offset] != 34) {
      throw FormatException('Expected string at offset $_offset');
    }
    final start = _offset + 1;
    final end = _skipStringLiteral(_bytes, start);
    _offset = end + 1;
    return (start, end);
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  (int, int, bool) _scanNameSpanAndConsumeColon() {
    _beforeReadingName();
    var i = _offset;
    while (i < _bytes.length && _isWs(_bytes[i])) {
      i++;
    }
    if (i >= _bytes.length || _bytes[i] != 34) {
      throw FormatException('Expected string at offset $i', _bytes, i);
    }
    final start = i + 1;
    var hasEscapes = false;
    var maxByte = 0;
    var end = start;
    while (true) {
      if (end >= _bytes.length) {
        throw FormatException(
          'Unterminated string literal at offset $start',
          _bytes,
          start,
        );
      }
      final b = _bytes[end];
      if (b == 34) {
        break;
      }
      if (b < 32) {
        throw FormatException(
          'Unescaped control character in string at offset $end',
          _bytes,
          end,
        );
      }
      if (b == 92) {
        hasEscapes = true;
        end += 2;
        if (end > _bytes.length) {
          throw FormatException(
            'Unterminated string escape at offset ${end - 2}',
            _bytes,
            end - 2,
          );
        }
      } else {
        maxByte |= b;
        end++;
      }
    }
    i = end + 1;

    // Fused colon consumption & trailing whitespace
    if (i < _bytes.length && _bytes[i] == 58) {
      i++;
    } else {
      while (i < _bytes.length && _isWs(_bytes[i])) {
        i++;
      }
      if (i >= _bytes.length || _bytes[i] != 58) {
        throw FormatException('Expected ":" at offset $i', _bytes, i);
      }
      i++;
    }
    while (i < _bytes.length && _isWs(_bytes[i])) {
      i++;
    }
    _offset = i;
    _topState = 1;
    return (start, end, hasEscapes || maxByte >= 0x80);
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  String _decodeCachedString(int start, int end) {
    final len = end - start;
    if (len == 0) return '';
    if (len > _maxCachedStringLength) {
      return _decodeStringUtf8(
        _bytes,
        start,
        end,
        allowMalformed: allowMalformed,
      );
    }

    var h = len;
    for (var i = start; i < end; i++) {
      h = (h * 31 + _bytes[i]) & 0x3fffffff;
    }
    final slot = h & _stringCacheMask;
    final cached = _stringCache[slot];
    if (cached != null && cached.length == len) {
      var match = true;
      for (var i = 0; i < len; i++) {
        final b = _bytes[start + i];
        if (b > 0x7F || b != cached.codeUnitAt(i)) {
          match = false;
          break;
        }
      }
      if (match) {
        return cached;
      }
    }

    final s = _decodeStringUtf8(
      _bytes,
      start,
      end,
      allowMalformed: allowMalformed,
    );
    _stringCache[slot] = s;
    return s;
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  String nextName() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      final (start, end, _) = _scanNameSpanAndConsumeColon();
      return _decodeCachedString(start, end);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int selectName(JsonKeyOptions options) {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      _beforeReadingName();
      var i = _offset;
      if (i >= _bytes.length || _bytes[i] != 34) {
        throw FormatException('Expected string at offset $i', _bytes, i);
      }
      final start = i + 1;
      var hasEscapes = false;
      var maxByte = 0;
      var end = start;
      while (true) {
        if (end >= _bytes.length) {
          throw FormatException(
            'Unterminated string literal at offset $start',
            _bytes,
            start,
          );
        }
        final b = _bytes[end];
        if (b == 34) {
          break;
        }
        if (b < 32) {
          throw FormatException(
            'Unescaped control character in string at offset $end',
            _bytes,
            end,
          );
        }
        if (b == 92) {
          hasEscapes = true;
          end += 2;
          if (end > _bytes.length) {
            throw FormatException(
              'Unterminated string escape at offset ${end - 2}',
              _bytes,
              end - 2,
            );
          }
        } else {
          maxByte |= b;
          end++;
        }
      }
      i = end + 1;

      // Fused colon consumption & trailing whitespace
      if (i < _bytes.length && _bytes[i] == 58) {
        i++;
      } else {
        while (i < _bytes.length && _isWs(_bytes[i])) {
          i++;
        }
        if (i >= _bytes.length || _bytes[i] != 58) {
          throw FormatException('Expected ":" at offset $i', _bytes, i);
        }
        i++;
      }
      while (i < _bytes.length && _isWs(_bytes[i])) {
        i++;
      }
      _offset = i;
      _topState = 1;

      if (!hasEscapes && maxByte <= 0x7F) {
        return options.selectKey(_bytes, start, end);
      }

      final unescaped = _decodeCachedString(start, end);
      return options.indexOf(unescaped);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int selectString(JsonKeyOptions options) {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      _beforeReadingValue();
      var i = _offset;
      if (i >= _bytes.length || _bytes[i] != 34) {
        throw FormatException('Expected string at offset $i', _bytes, i);
      }
      final start = i + 1;
      final end = _skipStringLiteral(_bytes, start);
      i = end + 1;

      var j = i;
      while (j < _bytes.length && _isWs(_bytes[j])) {
        j++;
      }
      if (_stackLength > 0) {
        if (j < _bytes.length && _bytes[j] == 44) {
          j++;
          while (j < _bytes.length && _isWs(_bytes[j])) {
            j++;
          }
          _topState = 3;
          _offset = j;
        } else {
          _topState = 2;
          _offset = j;
        }
      } else {
        _hasReadRoot = true;
        _offset = j;
      }

      if (_isVerbatimUtf8(_bytes, start, end)) {
        return options.selectKey(_bytes, start, end);
      }

      final unescaped = _decodeCachedString(start, end);
      return options.indexOf(unescaped);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  (int start, int end) readStringSpan() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      _beforeReadingValue();
      var i = _offset;
      if (i >= _bytes.length || _bytes[i] != 34) {
        throw FormatException('Expected string at offset $i', _bytes, i);
      }
      final start = i + 1;
      final end = _skipStringLiteral(_bytes, start);
      i = end + 1;

      var j = i;
      while (j < _bytes.length && _isWs(_bytes[j])) {
        j++;
      }
      if (_stackLength > 0) {
        if (j < _bytes.length && _bytes[j] == 44) {
          j++;
          while (j < _bytes.length && _isWs(_bytes[j])) {
            j++;
          }
          _topState = 3;
          _offset = j;
        } else {
          _topState = 2;
          _offset = j;
        }
      } else {
        _hasReadRoot = true;
        _offset = j;
      }

      return (start, end);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  String readString() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      final (start, end) = readStringSpan();
      return _decodeCachedString(start, end);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  (int, int) _scanScalarSpan() {
    _beforeReadingValue();
    var i = _offset;
    final start = i;
    while (i < _bytes.length) {
      final b = _bytes[i];
      if (b == 44 || b == 125 || b == 93 || _isWs(b)) {
        break;
      }
      i++;
    }
    final end = i;

    var j = i;
    while (j < _bytes.length && _isWs(_bytes[j])) {
      j++;
    }
    if (_stackLength > 0) {
      if (j < _bytes.length && _bytes[j] == 44) {
        j++;
        while (j < _bytes.length && _isWs(_bytes[j])) {
          j++;
        }
        _topState = 3;
        _offset = j;
      } else {
        _topState = 2;
        _offset = j;
      }
    } else {
      _hasReadRoot = true;
      _offset = j;
    }
    return (start, end);
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int readInt() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      _beforeReadingValue();
      var i = _offset;
      if (i >= _bytes.length) {
        throw FormatException('Unexpected end of document', _bytes, i);
      }
      final start = i;
      if (_bytes[i] == 45) {
        i++;
        if (i >= _bytes.length) {
          throw FormatException('Expected digit after "-"', _bytes, i);
        }
      }

      final firstDigit = _bytes[i];
      if (firstDigit == 48) {
        i++;
        if (i < _bytes.length && _bytes[i] >= 48 && _bytes[i] <= 57) {
          throw FormatException(
            'Leading zero cannot be followed by another digit',
            _bytes,
            i,
          );
        }
      } else if (firstDigit >= 49 && firstDigit <= 57) {
        while (i < _bytes.length && _bytes[i] >= 48 && _bytes[i] <= 57) {
          i++;
        }
      } else {
        throw FormatException('Expected digit in number', _bytes, i);
      }

      if (i < _bytes.length) {
        final b = _bytes[i];
        if (b == 46 || b == 101 || b == 69) {
          throw FormatException(
            'Invalid integer (found fractional or exponent component)',
            _bytes,
            i,
          );
        }
        if (b != 44 && b != 125 && b != 93 && !_isWs(b)) {
          throw FormatException(
            'Unexpected character after number: ${String.fromCharCode(b)}',
            _bytes,
            i,
          );
        }
      }

      final end = i;
      final val = _parseIntFromBytes(_bytes, start, end);

      var j = i;
      while (j < _bytes.length && _isWs(_bytes[j])) {
        j++;
      }
      if (_stackLength > 0) {
        if (j < _bytes.length && _bytes[j] == 44) {
          j++;
          while (j < _bytes.length && _isWs(_bytes[j])) {
            j++;
          }
          _topState = 3;
          _offset = j;
        } else {
          _topState = 2;
          _offset = j;
        }
      } else {
        _hasReadRoot = true;
        _offset = j;
      }

      return val;
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  double readDouble() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      _beforeReadingValue();
      var i = _offset;
      if (i >= _bytes.length) {
        throw FormatException('Unexpected end of document', _bytes, i);
      }
      final start = i;
      var isNegative = false;
      if (_bytes[i] == 45) {
        isNegative = true;
        i++;
        if (i >= _bytes.length) {
          throw FormatException('Expected digit after "-"', _bytes, i);
        }
      }

      int mantissa = 0;
      int digitCount = 0;
      int decimalExp = 0;
      bool truncatedDigits = false;

      // Integer part
      final firstDigit = _bytes[i];
      if (firstDigit == 48) {
        i++;
        if (i < _bytes.length && _bytes[i] >= 48 && _bytes[i] <= 57) {
          throw FormatException(
            'Leading zero cannot be followed by another digit',
            _bytes,
            i,
          );
        }
      } else if (firstDigit >= 49 && firstDigit <= 57) {
        while (i < _bytes.length && _bytes[i] >= 48 && _bytes[i] <= 57) {
          if (digitCount < 19) {
            mantissa = mantissa * 10 + (_bytes[i] - 48);
            digitCount++;
          } else {
            truncatedDigits = true;
            decimalExp++;
          }
          i++;
        }
      } else {
        throw FormatException('Expected digit in number', _bytes, i);
      }

      // Fraction part (optional)
      if (i < _bytes.length && _bytes[i] == 46) {
        i++;
        if (i >= _bytes.length || _bytes[i] < 48 || _bytes[i] > 57) {
          throw FormatException(
            'Expected digit after decimal point',
            _bytes,
            i,
          );
        }
        while (i < _bytes.length && _bytes[i] >= 48 && _bytes[i] <= 57) {
          if (mantissa == 0 && _bytes[i] == 48) {
            decimalExp--;
          } else if (digitCount < 19) {
            mantissa = mantissa * 10 + (_bytes[i] - 48);
            digitCount++;
            decimalExp--;
          } else {
            truncatedDigits = true;
          }
          i++;
        }
      }

      // Exponent part (optional)
      if (i < _bytes.length && (_bytes[i] == 101 || _bytes[i] == 69)) {
        i++;
        var expNeg = false;
        if (i < _bytes.length && (_bytes[i] == 43 || _bytes[i] == 45)) {
          if (_bytes[i] == 45) expNeg = true;
          i++;
        }
        if (i >= _bytes.length || _bytes[i] < 48 || _bytes[i] > 57) {
          throw FormatException('Expected digit in exponent', _bytes, i);
        }
        var explicitExp = 0;
        var expSaturated = false;
        while (i < _bytes.length && _bytes[i] >= 48 && _bytes[i] <= 57) {
          if (explicitExp < 10000) {
            explicitExp = explicitExp * 10 + (_bytes[i] - 48);
          } else {
            expSaturated = true;
          }
          i++;
        }
        decimalExp += expNeg ? -explicitExp : explicitExp;
        // Clamp extreme exponents to ±100,000 to prevent integer overflow while
        // preserving exact zero/infinite float scaling during fast-path parsing.
        if (expSaturated) {
          decimalExp = expNeg ? -100000 : 100000;
        }
      }

      if (i < _bytes.length) {
        final b = _bytes[i];
        if (b != 44 && b != 125 && b != 93 && !_isWs(b)) {
          throw FormatException(
            'Unexpected character after number: ${String.fromCharCode(b)}',
            _bytes,
            i,
          );
        }
      }

      final end = i;

      var j = i;
      while (j < _bytes.length && _isWs(_bytes[j])) {
        j++;
      }
      if (_stackLength > 0) {
        if (j < _bytes.length && _bytes[j] == 44) {
          j++;
          while (j < _bytes.length && _isWs(_bytes[j])) {
            j++;
          }
          _topState = 3;
          _offset = j;
        } else {
          _topState = 2;
          _offset = j;
        }
      } else {
        _hasReadRoot = true;
        _offset = j;
      }

      if (mantissa == 0) {
        return isNegative ? -0.0 : 0.0;
      }

      if (decimalExp == 0 &&
          !truncatedDigits &&
          _unsignedLe(mantissa, 0x001FFFFFFFFFFFFF)) {
        return isNegative ? -mantissa.toDouble() : mantissa.toDouble();
      }

      var result = _tryParseDoubleFastEiselLemire(
        mantissa,
        decimalExp,
        isNegative,
      );
      if (result != null && truncatedDigits) {
        final resultPlus1 = _tryParseDoubleFastEiselLemire(
          mantissa + 1,
          decimalExp,
          isNegative,
        );
        if (resultPlus1 != result) {
          result = null;
        }
      }
      if (result != null) return result;

      return _parseDoubleFromBytes(_bytes, start, end);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  num readNum() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      final (start, end) = _scanScalarSpan();
      final asInt = _tryParseIntFromBytes(_bytes, start, end);
      if (asInt != null) return asInt;
      return _parseDoubleFromBytes(_bytes, start, end);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  bool readBool() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      final (start, end) = _scanScalarSpan();
      return _parseBoolFromBytes(_bytes, start, end);
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void readNull() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      final (start, end) = _scanScalarSpan();
      if (!_isNullUtf8(_bytes, start, end)) {
        throw FormatException('Expected null at offset $start');
      }
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void skipValue() {
    final initialOffset = _offset;
    final initialStackLen = _stackLength;
    final initialTopType = _topType;
    final initialTopState = _topState;
    final hadReadRoot = _hasReadRoot;
    try {
      if (_stackLength > 0 && _topType == 0 && _topState != 1) {
        _scanNameSpanAndConsumeColon();
        skipValue();
        return;
      }
      _beforeReadingValue();
      if (_offset >= _bytes.length) {
        throw FormatException('Unexpected end of document', _bytes, _offset);
      }
      final b = _bytes[_offset];
      if (b == 123 || b == 91) {
        _offset = _skipValue(_bytes, _offset);
      } else if (b == 34) {
        _scanStringSpan();
      } else {
        _offset = _skipScalar(_bytes, _offset);
      }
      _afterReadingValue();
    } catch (_) {
      _restoreState(
        initialOffset,
        initialStackLen,
        initialTopType,
        initialTopState,
        hadReadRoot,
      );
      rethrow;
    }
  }

  @override
  (int start, int end) getTokenSpan() {
    if (_hasReadRoot) {
      throw FormatException(
        'Cannot read token span past root value',
        _bytes,
        _offset,
      );
    }
    var i = _offset;
    while (i < _bytes.length && _isWs(_bytes[i])) {
      i++;
    }
    if (_stackLength > 0) {
      if (_topState == 2) {
        if (i < _bytes.length && _bytes[i] == 44) {
          i++;
          while (i < _bytes.length && _isWs(_bytes[i])) {
            i++;
          }
          if (i >= _bytes.length) {
            throw FormatException(
              'Unexpected end of document after comma',
              _bytes,
              _offset,
            );
          }
          if (_bytes[i] == 125 || _bytes[i] == 93) {
            throw FormatException(
              'Trailing comma before closing delimiter',
              _bytes,
              _offset,
            );
          }
        } else {
          final closeChar = _topType == 0 ? 125 : 93;
          final closeStr = _topType == 0 ? '"}"' : '"]"';
          if (i < _bytes.length && _bytes[i] != closeChar) {
            throw FormatException(
              'Expected "," or $closeStr at offset $i',
              _bytes,
              i,
            );
          }
        }
      } else if (_topState == 3) {
        if (i >= _bytes.length) {
          throw FormatException(
            'Unexpected end of document after comma',
            _bytes,
            _offset,
          );
        }
        if (_bytes[i] == 125 || _bytes[i] == 93) {
          throw FormatException(
            'Trailing comma before closing delimiter',
            _bytes,
            _offset,
          );
        }
      }
    }
    if (i >= _bytes.length) {
      throw FormatException('Unexpected end of document');
    }
    final b = _bytes[i];
    if (b == 123 || b == 125 || b == 91 || b == 93 || b == 58 || b == 44) {
      return (i, i + 1);
    }
    if (b == 34) {
      final start = i + 1;
      var j = start;
      while (j < _bytes.length) {
        final c = _bytes[j];
        if (c < 0x20) {
          throw FormatException(
            'Unescaped control character in string literal at offset $j',
            _bytes,
            j,
          );
        }
        if (c == 92) {
          j = _validateEscape(_bytes, j + 1, _bytes.length);
        } else if (c == 34) {
          return (start, j);
        } else {
          j++;
        }
      }
      throw FormatException('Unterminated string literal at offset $start');
    } else {
      final start = i;
      var j = start;
      while (j < _bytes.length) {
        final c = _bytes[j];
        if (c == 44 || c == 125 || c == 93 || c == 58 || _isWs(c)) {
          break;
        }
        j++;
      }
      return (start, j);
    }
  }
}

/// High-performance push-based JSON token writer.
///
/// Enforces a maximum structural nesting depth limit of 1,024 levels of nested
/// objects and arrays as a contract guarantee, throwing a [StateError]
/// if input exceeds 1,024 levels of nesting.
abstract interface class JsonTokenWriter {
  /// Instantiates a token writer emitting to [sink].
  factory JsonTokenWriter.toSink(BytesBuilder sink) = JsonUtf8TokenWriter;

  void beginObject();
  void endObject();
  void beginArray();
  void endArray();
  void writeName(String name);
  void writeNameBytes(Uint8List asciiKey);
  void writeAsciiLiteral(Uint8List preEncoded);
  void writeRawJson(Uint8List rawJson);
  void writeString(String value);
  void writeInt(int value);
  void writeDouble(double value);
  void writeBool(bool value);
  void writeNull();

  /// Flushes any pending buffered state to the underlying sink.
  void flush();
}

final class JsonUtf8TokenWriter implements JsonTokenWriter {
  static const int _maxDepth = 1024;
  static const int _chunkSize = 32768;

  final BytesBuilder _sink;
  Uint8List _buffer = Uint8List(_chunkSize);
  int _cursor = 0;

  Uint8List _typeStack = Uint8List(64);
  Uint8List _stateStack = Uint8List(64);
  int _stackLength = 0;
  int _topType = -1; // -1: none, 0: object, 1: array
  int _topState = 0; // in object: 0: empty, 1: key, 2: value; in array: 0: first, 1: not first
  bool _hasRootValue = false;

  JsonUtf8TokenWriter(this._sink);

  void _ensureCapacity(int needed) {
    if (_cursor + needed > _buffer.length) {
      _flushBuffer();
      if (needed > _buffer.length) {
        _buffer = Uint8List(needed > _chunkSize ? needed : _chunkSize);
      }
    }
  }

  void _flushBuffer() {
    if (_cursor > 0) {
      _sink.add(Uint8List.sublistView(_buffer, 0, _cursor));
      _buffer = Uint8List(_chunkSize);
      _cursor = 0;
    }
  }

  void _writeDirectByte(int byte) {
    if (_cursor >= _buffer.length) {
      _flushBuffer();
    }
    _buffer[_cursor++] = byte;
  }

  @override
  void flush() => _flushBuffer();

  void _beforeValue() {
    if (_stackLength > 0) {
      if (_topType == 0) {
        if (_topState != 1) {
          throw StateError('Expected property name before value in object');
        }
        _topState = 2;
      } else {
        if (_topState != 0) {
          _writeDirectByte(44); // ','
        }
        _topState = 1;
      }
    } else {
      if (_hasRootValue) {
        throw StateError('Cannot write multiple root values');
      }
      _hasRootValue = true;
    }
  }

  @override
  void beginObject() {
    if (_stackLength >= _maxDepth) {
      throw StateError('Nesting depth exceeds limit of $_maxDepth');
    }
    _beforeValue();
    _writeDirectByte(123); // '{'
    if (_stackLength > 0) {
      if (_stackLength >= _typeStack.length) {
        final newCap = _typeStack.length * 2;
        final newTypeStack = Uint8List(newCap);
        newTypeStack.setRange(0, _typeStack.length, _typeStack);
        _typeStack = newTypeStack;
        final newStateStack = Uint8List(newCap);
        newStateStack.setRange(0, _stateStack.length, _stateStack);
        _stateStack = newStateStack;
      }
      _typeStack[_stackLength - 1] = _topType;
      _stateStack[_stackLength - 1] = _topState;
    }
    _stackLength++;
    _topType = 0;
    _topState = 0;
  }

  @override
  void endObject() {
    if (_stackLength == 0 || _topType != 0) {
      throw StateError('Cannot endObject: not inside an object');
    }
    if (_topState == 1) {
      throw StateError('Cannot endObject: expected value after property name');
    }
    _writeDirectByte(125); // '}'
    _stackLength--;
    if (_stackLength > 0) {
      _topType = _typeStack[_stackLength - 1];
      _topState = _stateStack[_stackLength - 1];
    } else {
      _topType = -1;
      _topState = 0;
      _flushBuffer();
    }
  }

  @override
  void beginArray() {
    if (_stackLength >= _maxDepth) {
      throw StateError('Nesting depth exceeds limit of $_maxDepth');
    }
    _beforeValue();
    _writeDirectByte(91); // '['
    if (_stackLength > 0) {
      if (_stackLength >= _typeStack.length) {
        final newCap = _typeStack.length * 2;
        final newTypeStack = Uint8List(newCap);
        newTypeStack.setRange(0, _typeStack.length, _typeStack);
        _typeStack = newTypeStack;
        final newStateStack = Uint8List(newCap);
        newStateStack.setRange(0, _stateStack.length, _stateStack);
        _stateStack = newStateStack;
      }
      _typeStack[_stackLength - 1] = _topType;
      _stateStack[_stackLength - 1] = _topState;
    }
    _stackLength++;
    _topType = 1;
    _topState = 0;
  }

  @override
  void endArray() {
    if (_stackLength == 0 || _topType != 1) {
      throw StateError('Cannot endArray: not inside an array');
    }
    _writeDirectByte(93); // ']'
    _stackLength--;
    if (_stackLength > 0) {
      _topType = _typeStack[_stackLength - 1];
      _topState = _stateStack[_stackLength - 1];
    } else {
      _topType = -1;
      _topState = 0;
      _flushBuffer();
    }
  }

  @override
  void writeName(String name) {
    if (_stackLength == 0 || _topType != 0) {
      throw StateError('Cannot writeName: not inside an object');
    }
    if (_topState == 1) {
      throw StateError(
        'Cannot writeName: already expecting a value for previous property',
      );
    }
    if (_topState == 2) {
      _writeDirectByte(44); // ','
    }
    _topState = 1;
    final len = name.length;
    if (len <= 32) {
      var isAscii = true;
      for (var i = 0; i < len; i++) {
        final c = name.codeUnitAt(i);
        if (c < 0x20 || c == 0x22 || c == 0x5C || c >= 0x80) {
          isAscii = false;
          break;
        }
      }
      if (isAscii) {
        _ensureCapacity(len + 3);
        _buffer[_cursor++] = 0x22; // '"'
        for (var i = 0; i < len; i++) {
          _buffer[_cursor++] = name.codeUnitAt(i);
        }
        _buffer[_cursor++] = 0x22; // '"'
        _buffer[_cursor++] = 0x3A; // ':'
        return;
      }
    }
    _ensureCapacity(len * 6 + 4);
    final written = _writeStringToBuffer(name, _buffer, _cursor);
    _cursor += written;
    _buffer[_cursor++] = 0x3A; // ':'
  }

  @override
  void writeNameBytes(Uint8List asciiKey) {
    if (_stackLength == 0 || _topType != 0) {
      throw StateError('Cannot writeNameBytes: not inside an object');
    }
    if (_topState == 1) {
      throw StateError(
        'Cannot writeNameBytes: already expecting a value for previous property',
      );
    }
    if (_topState == 2) {
      _writeDirectByte(44); // ','
    }
    _topState = 1;
    final isColonTerminated =
        asciiKey.length >= 3 &&
        asciiKey.first == 0x22 &&
        asciiKey.last == 0x3A &&
        _isSingleQuotedSlice(asciiKey, 0, asciiKey.length - 1);
    if (isColonTerminated) {
      final len = asciiKey.length;
      _ensureCapacity(len);
      _buffer.setRange(_cursor, _cursor + len, asciiKey);
      _cursor += len;
      return;
    }
    final isQuoted = _isSingleQuotedString(asciiKey);
    if (isQuoted) {
      final len = asciiKey.length;
      _ensureCapacity(len + 1);
      _buffer.setRange(_cursor, _cursor + len, asciiKey);
      _cursor += len;
      _buffer[_cursor++] = 0x3A; // ':'
    } else {
      _ensureCapacity(asciiKey.length * 6 + 3);
      _buffer[_cursor++] = 0x22; // '"'
      for (var i = 0; i < asciiKey.length; i++) {
        final b = asciiKey[i];
        if (b == 0x22) {
          _buffer[_cursor++] = 0x5C;
          _buffer[_cursor++] = 0x22;
        } else if (b == 0x5C) {
          _buffer[_cursor++] = 0x5C;
          _buffer[_cursor++] = 0x5C;
        } else if (b < 0x20) {
          _buffer[_cursor++] = 0x5C;
          _buffer[_cursor++] = 0x75; // 'u'
          _buffer[_cursor++] = 0x30; // '0'
          _buffer[_cursor++] = 0x30; // '0'
          _buffer[_cursor++] = _hexDigits.codeUnitAt((b >> 4) & 0xF);
          _buffer[_cursor++] = _hexDigits.codeUnitAt(b & 0xF);
        } else {
          _buffer[_cursor++] = b;
        }
      }
      _buffer[_cursor++] = 0x22; // '"'
      _buffer[_cursor++] = 0x3A; // ':'
    }
  }

  @override
  void writeAsciiLiteral(Uint8List preEncoded) {
    _beforeValue();
    final len = preEncoded.length;
    _ensureCapacity(len);
    _buffer.setRange(_cursor, _cursor + len, preEncoded);
    _cursor += len;
    if (_stackLength == 0) {
      _flushBuffer();
    }
  }

  @override
  void writeRawJson(Uint8List rawJson) {
    _beforeValue();
    final len = rawJson.length;
    _ensureCapacity(len);
    _buffer.setRange(_cursor, _cursor + len, rawJson);
    _cursor += len;
    if (_stackLength == 0) {
      _flushBuffer();
    }
  }

  @override
  void writeString(String value) {
    _beforeValue();
    final len = value.length;
    if (len <= 32) {
      var isAscii = true;
      for (var i = 0; i < len; i++) {
        final c = value.codeUnitAt(i);
        if (c < 0x20 || c == 0x22 || c == 0x5C || c >= 0x80) {
          isAscii = false;
          break;
        }
      }
      if (isAscii) {
        _ensureCapacity(len + 2);
        _buffer[_cursor++] = 0x22; // '"'
        for (var i = 0; i < len; i++) {
          _buffer[_cursor++] = value.codeUnitAt(i);
        }
        _buffer[_cursor++] = 0x22; // '"'
        if (_stackLength == 0) {
          _flushBuffer();
        }
        return;
      }
    }
    _ensureCapacity(len * 6 + 2);
    final written = _writeStringToBuffer(value, _buffer, _cursor);
    _cursor += written;
    if (_stackLength == 0) {
      _flushBuffer();
    }
  }

  @override
  void writeInt(int value) {
    _beforeValue();
    _ensureCapacity(24);
    final written = _writeIntToBuffer(value, _buffer, _cursor);
    _cursor += written;
    if (_stackLength == 0) {
      _flushBuffer();
    }
  }

  @override
  void writeDouble(double value) {
    _beforeValue();
    _ensureCapacity(32);
    final written = _writeDoubleToBuffer(value, _buffer, _cursor);
    _cursor += written;
    if (_stackLength == 0) {
      _flushBuffer();
    }
  }

  @override
  void writeBool(bool value) {
    _beforeValue();
    if (value) {
      _ensureCapacity(4);
      _buffer[_cursor++] = 116; // 't'
      _buffer[_cursor++] = 114; // 'r'
      _buffer[_cursor++] = 117; // 'u'
      _buffer[_cursor++] = 101; // 'e'
    } else {
      _ensureCapacity(5);
      _buffer[_cursor++] = 102; // 'f'
      _buffer[_cursor++] = 97; // 'a'
      _buffer[_cursor++] = 108; // 'l'
      _buffer[_cursor++] = 115; // 's'
      _buffer[_cursor++] = 101; // 'e'
    }
    if (_stackLength == 0) {
      _flushBuffer();
    }
  }

  @override
  void writeNull() {
    _beforeValue();
    _ensureCapacity(4);
    _buffer[_cursor++] = 110; // 'n'
    _buffer[_cursor++] = 117; // 'u'
    _buffer[_cursor++] = 108; // 'l'
    _buffer[_cursor++] = 108; // 'l'
    if (_stackLength == 0) {
      _flushBuffer();
    }
  }
}

// =============================================================================
// Pure Dart Private Span Helpers (Fallbacks & Shared Algorithms)
// =============================================================================

const String _digitPairs =
    "00010203040506070809"
    "10111213141516171819"
    "20212223242526272829"
    "30313233343536373839"
    "40414243444546474849"
    "50515253545556575859"
    "60616263646566676869"
    "70717273747576777879"
    "80818283848586878889"
    "90919293949596979899";

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
void _emitDigitsBackwardNegative(Uint8List buffer, int writePos, int negVal) {
  var temp = negVal;
  while (temp <= -100) {
    final next = temp ~/ 100;
    final rem = -(temp - next * 100);
    final pairIdx = rem << 1;
    buffer[writePos] = _digitPairs.codeUnitAt(pairIdx + 1);
    buffer[writePos - 1] = _digitPairs.codeUnitAt(pairIdx);
    writePos -= 2;
    temp = next;
  }
  if (temp <= -10) {
    final rem = -temp;
    final pairIdx = rem << 1;
    buffer[writePos] = _digitPairs.codeUnitAt(pairIdx + 1);
    buffer[writePos - 1] = _digitPairs.codeUnitAt(pairIdx);
  } else {
    buffer[writePos] = 48 - temp;
  }
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _digitCountNegative(int v) {
  if (v > -10) return 1;
  if (v > -100) return 2;
  if (v > -1000) return 3;
  if (v > -10000) return 4;
  if (v > -100000) return 5;
  if (v > -1000000) return 6;
  if (v > -10000000) return 7;
  if (v > -100000000) return 8;
  if (v > -1000000000) return 9;
  if (v > -10000000000) return 10;
  if (v > -100000000000) return 11;
  if (v > -1000000000000) return 12;
  if (v > -10000000000000) return 13;
  if (v > -100000000000000) return 14;
  if (v > -1000000000000000) return 15;
  if (v > -10000000000000000) return 16;
  if (v > -100000000000000000) return 17;
  if (v > -1000000000000000000) return 18;
  if (v > -10000000000000000000.0) return 19;
  // Start one power past the 19-digit test above: at v == -1e19 the loop must
  // not run, otherwise a 20-digit value is reported as 21 digits.
  var count = 20;
  var limit = -100000000000000000000.0;
  while (v <= limit && count < 320) {
    limit *= 10;
    count++;
  }
  return count;
}

const String _hexDigits = "0123456789abcdef";

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
bool _isHexDigit(int b) => hexDigitValue(b) >= 0;

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
bool _isValidEscapeChar(int b) =>
    b == 34 ||
    b == 92 ||
    b == 47 ||
    b == 98 ||
    b == 102 ||
    b == 110 ||
    b == 114 ||
    b == 116 ||
    b == 117;

/// High-performance 1,024-level container state tracker for [_skipValue].
final class _SkipContainerTracker {
  final Uint8List _data = Uint8List(1024);

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  bool isObject(int d) => (_data[d] & 1) != 0;

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  bool hasElements(int d) => (_data[d] & 2) != 0;

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  int getState(int d) => (_data[d] >> 2) & 3;

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void setHasElements(int d) {
    _data[d] |= 2;
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void setState(int d, int state) {
    _data[d] = (_data[d] & ~12) | (state << 2);
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void pushContainer(int d, bool isObj) {
    _data[d] = isObj ? 1 : 0;
  }
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _skipStringLiteral(Uint8List bytes, int offset) {
  var i = offset;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x20) {
      throw FormatException(
        'Unescaped control character in string literal at offset $i',
        bytes,
        i,
      );
    }
    if (b == 92) {
      i = _validateEscape(bytes, i + 1, bytes.length);
    } else if (b == 34) {
      return i;
    } else {
      i++;
    }
  }
  throw FormatException(
    'Unterminated string literal at offset ${offset > 0 ? offset - 1 : 0}',
    bytes,
    offset > 0 ? offset - 1 : 0,
  );
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _validateEscape(Uint8List bytes, int escOffset, int endOffset) {
  if (escOffset >= endOffset) {
    throw FormatException(
      'Unterminated escape sequence at offset ${escOffset - 1}',
      bytes,
      escOffset - 1,
    );
  }
  final esc = bytes[escOffset];
  if (esc == 117) {
    // 'u'
    if (escOffset + 5 > endOffset) {
      throw FormatException(
        'Incomplete unicode escape at offset ${escOffset - 1}',
        bytes,
        escOffset - 1,
      );
    }
    for (var k = 1; k <= 4; k++) {
      final hc = bytes[escOffset + k];
      if (!_isHexDigit(hc)) {
        throw FormatException(
          'Invalid hex digit "${String.fromCharCode(hc)}" at offset ${escOffset + k}',
          bytes,
          escOffset + k,
        );
      }
    }
    return escOffset + 5;
  }
  if (!_isValidEscapeChar(esc)) {
    throw FormatException(
      'Invalid escape character "${String.fromCharCode(esc)}" at offset $escOffset',
      bytes,
      escOffset,
    );
  }
  return escOffset + 1;
}

int _writeStringToBufferUtf8(String value, Uint8List buffer, int offset) {
  final len = value.length;
  if (offset < 0 || offset > buffer.length) {
    throw RangeError.range(offset, 0, buffer.length, 'offset');
  }

  // Fast path: check if string is pure ASCII and requires no escaping
  var isPureAscii = true;
  for (var i = 0; i < len; i++) {
    final c = value.codeUnitAt(i);
    if (c < 0x20 || c == 0x22 || c == 0x5C || c >= 0x80) {
      isPureAscii = false;
      break;
    }
  }

  if (isPureAscii) {
    final requiredLen = len + 2;
    if (offset + requiredLen > buffer.length) {
      throw RangeError.range(
        offset,
        0,
        buffer.length >= requiredLen ? buffer.length - requiredLen : 0,
        'offset',
      );
    }
    buffer[offset] = 0x22; // '"'
    for (var i = 0; i < len; i++) {
      buffer[offset + 1 + i] = value.codeUnitAt(i);
    }
    buffer[offset + 1 + len] = 0x22; // '"'
    return requiredLen;
  }

  // General path: calculate exact required length first to ensure atomic rollback
  var requiredLen = 2; // For opening and closing quotes
  for (var i = 0; i < len; i++) {
    final c = value.codeUnitAt(i);
    switch (c) {
      case 0x22: // '"'
      case 0x5C: // '\\'
      case 0x08: // '\b'
      case 0x0C: // '\f'
      case 0x0A: // '\n'
      case 0x0D: // '\r'
      case 0x09: // '\t'
        requiredLen += 2;
        break;
      default:
        if (c < 0x20) {
          requiredLen += 6; // \u00XX
        } else if (c <= 0x7F) {
          requiredLen += 1;
        } else if (c <= 0x7FF) {
          requiredLen += 2;
        } else if (c >= 0xD800 && c <= 0xDBFF) {
          if (i + 1 < len) {
            final c2 = value.codeUnitAt(i + 1);
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
              i++;
              requiredLen += 4;
              break;
            }
          }
          // Isolated high surrogate -> \uXXXX (6 bytes)
          requiredLen += 6;
        } else if (c >= 0xDC00 && c <= 0xDFFF) {
          // Isolated low surrogate -> \uXXXX (6 bytes)
          requiredLen += 6;
        } else {
          requiredLen += 3;
        }
        break;
    }
  }

  if (offset + requiredLen > buffer.length) {
    throw RangeError.range(
      offset,
      0,
      buffer.length >= requiredLen ? buffer.length - requiredLen : 0,
      'offset',
    );
  }

  var cursor = offset;
  buffer[cursor++] = 0x22; // '"'

  for (var i = 0; i < len; i++) {
    final c = value.codeUnitAt(i);
    switch (c) {
      case 0x22:
        buffer[cursor++] = 0x5C;
        buffer[cursor++] = 0x22;
        break;
      case 0x5C:
        buffer[cursor++] = 0x5C;
        buffer[cursor++] = 0x5C;
        break;
      case 0x08:
        buffer[cursor++] = 0x5C;
        buffer[cursor++] = 0x62; // 'b'
        break;
      case 0x0C:
        buffer[cursor++] = 0x5C;
        buffer[cursor++] = 0x66; // 'f'
        break;
      case 0x0A:
        buffer[cursor++] = 0x5C;
        buffer[cursor++] = 0x6E; // 'n'
        break;
      case 0x0D:
        buffer[cursor++] = 0x5C;
        buffer[cursor++] = 0x72; // 'r'
        break;
      case 0x09:
        buffer[cursor++] = 0x5C;
        buffer[cursor++] = 0x74; // 't'
        break;
      default:
        if (c < 0x20) {
          buffer[cursor++] = 0x5C;
          buffer[cursor++] = 0x75; // 'u'
          buffer[cursor++] = 0x30; // '0'
          buffer[cursor++] = 0x30; // '0'
          buffer[cursor++] = _hexDigits.codeUnitAt((c >> 4) & 0xF);
          buffer[cursor++] = _hexDigits.codeUnitAt(c & 0xF);
        } else if (c <= 0x7F) {
          buffer[cursor++] = c;
        } else if (c <= 0x7FF) {
          buffer[cursor++] = 0xC0 | (c >> 6);
          buffer[cursor++] = 0x80 | (c & 0x3F);
        } else if (c >= 0xD800 && c <= 0xDBFF) {
          if (i + 1 < len) {
            final c2 = value.codeUnitAt(i + 1);
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
              i++;
              final codePoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
              buffer[cursor++] = 0xF0 | (codePoint >> 18);
              buffer[cursor++] = 0x80 | ((codePoint >> 12) & 0x3F);
              buffer[cursor++] = 0x80 | ((codePoint >> 6) & 0x3F);
              buffer[cursor++] = 0x80 | (codePoint & 0x3F);
              break;
            }
          }
          // Isolated high surrogate -> \uXXXX
          buffer[cursor++] = 0x5C;
          buffer[cursor++] = 0x75; // 'u'
          buffer[cursor++] = _hexDigits.codeUnitAt((c >> 12) & 0xF);
          buffer[cursor++] = _hexDigits.codeUnitAt((c >> 8) & 0xF);
          buffer[cursor++] = _hexDigits.codeUnitAt((c >> 4) & 0xF);
          buffer[cursor++] = _hexDigits.codeUnitAt(c & 0xF);
        } else if (c >= 0xDC00 && c <= 0xDFFF) {
          // Isolated low surrogate -> \uXXXX
          buffer[cursor++] = 0x5C;
          buffer[cursor++] = 0x75; // 'u'
          buffer[cursor++] = _hexDigits.codeUnitAt((c >> 12) & 0xF);
          buffer[cursor++] = _hexDigits.codeUnitAt((c >> 8) & 0xF);
          buffer[cursor++] = _hexDigits.codeUnitAt((c >> 4) & 0xF);
          buffer[cursor++] = _hexDigits.codeUnitAt(c & 0xF);
        } else {
          buffer[cursor++] = 0xE0 | (c >> 12);
          buffer[cursor++] = 0x80 | ((c >> 6) & 0x3F);
          buffer[cursor++] = 0x80 | (c & 0x3F);
        }
        break;
    }
  }

  buffer[cursor++] = 0x22; // '"'
  return cursor - offset;
}

@pragma('vm:prefer-inline')
int _tryScaleToExactMantissa(double absVal, double p10) {
  final scaled = absVal * p10;
  if (scaled > 9007199254740991.0) {
    return -1;
  }
  final intVal = scaled.round();
  if (intVal / p10 != absVal) {
    return -1;
  }
  return intVal;
}

int _writeDoubleToBufferUtf8(double value, Uint8List buffer, int offset) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'Must be finite');
  }
  if (offset < 0 || offset > buffer.length) {
    throw RangeError.range(offset, 0, buffer.length, 'offset');
  }

  // 1. Zero handling
  if (value == 0.0) {
    if (value.isNegative) {
      if (offset + 4 > buffer.length) {
        throw RangeError.range(
          offset,
          0,
          buffer.length >= 4 ? buffer.length - 4 : 0,
          'offset',
        );
      }
      buffer[offset] = 0x2D; // '-'
      buffer[offset + 1] = 0x30; // '0'
      buffer[offset + 2] = 0x2E; // '.'
      buffer[offset + 3] = 0x30; // '0'
      return 4;
    } else {
      if (offset + 3 > buffer.length) {
        throw RangeError.range(
          offset,
          0,
          buffer.length >= 3 ? buffer.length - 3 : 0,
          'offset',
        );
      }
      buffer[offset] = 0x30; // '0'
      buffer[offset + 1] = 0x2E; // '.'
      buffer[offset + 2] = 0x30; // '0'
      return 3;
    }
  }

  // 2. Integer float fast path (up to 15 digits)
  final isNeg = value.isNegative;
  final absVal = isNeg ? -value : value;
  final trunc = absVal.truncateToDouble();

  if (absVal == trunc && absVal <= 9007199254740991.0) {
    final intVal = absVal.toInt();
    final negVal = -intVal;
    final digitCount = _digitCountNegative(negVal);
    final totalLen = (isNeg ? 1 : 0) + digitCount + 2; // +2 for '.0'
    if (offset + totalLen > buffer.length) {
      throw RangeError.range(
        offset,
        0,
        buffer.length >= totalLen ? buffer.length - totalLen : 0,
        'offset',
      );
    }
    var cursor = offset;
    if (isNeg) {
      buffer[cursor++] = 0x2D; // '-'
    }
    final writePos = cursor + digitCount - 1;
    _emitDigitsBackwardNegative(buffer, writePos, negVal);
    cursor += digitCount;
    buffer[cursor++] = 0x2E; // '.'
    buffer[cursor++] = 0x30; // '0'
    return totalLen;
  }

  // 3. Decimal fraction fast path (exact representation within 53-bit mantissa)
  if (absVal >= 1e-15 && absVal <= 1e15) {
    final intPart = absVal.toInt();
    final intPartDigits = intPart == 0 ? 0 : _digitCountNegative(-intPart);
    var maxFrac = 15 - intPartDigits;
    if (maxFrac > 0 && maxFrac <= 15) {
      var intVal = _tryScaleToExactMantissa(absVal, POWERS_OF_TEN[maxFrac]);
      if (intVal < 0) {
        maxFrac += 1;
        intVal = _tryScaleToExactMantissa(absVal, POWERS_OF_TEN[maxFrac]);
      }
      if (intVal >= 0) {
        // Exactly representable! Strip trailing zeros to get shortest representation.
        var k = maxFrac;
        while (k >= 4 && intVal % 10000 == 0) {
          intVal ~/= 10000;
          k -= 4;
        }
        while (k >= 2 && intVal % 100 == 0) {
          intVal ~/= 100;
          k -= 2;
        }
        if (k > 0 && intVal % 10 == 0) {
          intVal ~/= 10;
          k--;
        }
        if (k == 0) {
          // Integer float, append '.0'
          final negVal = -intVal;
          final digitCount = _digitCountNegative(negVal);
          final totalLen = (isNeg ? 1 : 0) + digitCount + 2;
          if (offset + totalLen > buffer.length) {
            throw RangeError.range(
              offset,
              0,
              buffer.length >= totalLen ? buffer.length - totalLen : 0,
              'offset',
            );
          }
          var cursor = offset;
          if (isNeg) {
            buffer[cursor++] = 0x2D; // '-'
          }
          final writePos = cursor + digitCount - 1;
          _emitDigitsBackwardNegative(buffer, writePos, negVal);
          cursor += digitCount;
          buffer[cursor++] = 0x2E; // '.'
          buffer[cursor++] = 0x30; // '0'
          return totalLen;
        }

        final negVal = -intVal;
        final numDigits = _digitCountNegative(negVal);
        if (numDigits > k) {
          // >= 1, e.g. 3.14 (k=2, intVal=314, numDigits=3)
          final totalLen = (isNeg ? 1 : 0) + numDigits + 1; // +1 for '.'
          if (offset + totalLen > buffer.length) {
            throw RangeError.range(
              offset,
              0,
              buffer.length >= totalLen ? buffer.length - totalLen : 0,
              'offset',
            );
          }
          var cursor = offset;
          if (isNeg) {
            buffer[cursor++] = 0x2D; // '-'
          }
          final digitsStart = cursor;
          var writePos = digitsStart + numDigits;
          var temp = negVal;
          var digitsWritten = 0;
          while (digitsWritten < k) {
            final next = temp ~/ 10;
            final rem = -(temp - next * 10);
            buffer[writePos--] = 48 + rem;
            temp = next;
            digitsWritten++;
          }
          buffer[writePos--] = 0x2E; // '.'
          _emitDigitsBackwardNegative(buffer, writePos, temp);
          return totalLen;
        } else {
          // < 1, e.g. 0.05 (k=2, intVal=5, numDigits=1)
          final leadingZeros = k - numDigits;
          final totalLen =
              (isNeg ? 1 : 0) +
              2 +
              leadingZeros +
              numDigits; // '0.' + zeros + digits
          if (offset + totalLen > buffer.length) {
            throw RangeError.range(
              offset,
              0,
              buffer.length >= totalLen ? buffer.length - totalLen : 0,
              'offset',
            );
          }
          var cursor = offset;
          if (isNeg) {
            buffer[cursor++] = 0x2D; // '-'
          }
          buffer[cursor++] = 0x30; // '0'
          buffer[cursor++] = 0x2E; // '.'
          for (var z = 0; z < leadingZeros; z++) {
            buffer[cursor++] = 0x30; // '0'
          }
          final writePos = cursor + numDigits - 1;
          _emitDigitsBackwardNegative(buffer, writePos, negVal);
          return totalLen;
        }
      }
    }
  }
  // 4. Return 0 when exact 53-bit mantissa scaling is not possible.
  // TODO(kevmoo): Pure-Dart Dragonbox/Ryu Port:
  // Port a pure-Dart shortest float formatting algorithm (Dragonbox/Grisu2)
  // directly into Uint8List buffers to eliminate fallback to C++ Grisu2 or
  // value.toString() on numbers with > 15 digits or subnormals.
  return 0;
}

Object? _parseValueFromReader(
  JsonTokenReader reader,
  Object? Function(Object? key, Object? value)? reviver,
) {
  final type = reader.peek();
  switch (type) {
    case JsonTokenType.beginObject:
      reader.beginObject();
      final map = <String, dynamic>{};
      while (reader.hasNext()) {
        final key = reader.nextName();
        var value = _parseValueFromReader(reader, reviver);
        if (reviver != null) {
          value = reviver(key, value);
        }
        map[key] = value;
      }
      reader.endObject();
      return map;
    case JsonTokenType.beginArray:
      reader.beginArray();
      final list = <dynamic>[];
      while (reader.hasNext()) {
        final index = list.length;
        var value = _parseValueFromReader(reader, reviver);
        if (reviver != null) {
          value = reviver(index, value);
        }
        list.add(value);
      }
      reader.endArray();
      return list;
    case JsonTokenType.string:
      return reader.readString();
    case JsonTokenType.number:
      return reader.readNum();
    case JsonTokenType.boolean:
      return reader.readBool();
    case JsonTokenType.nullValue:
      reader.readNull();
      return null;
    default:
      throw FormatException('Unexpected JSON token: $type');
  }
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
bool _isWs(int b) => b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D;

int _skipScalar(Uint8List bytes, int offset) {
  if (offset >= bytes.length) {
    throw FormatException('Unexpected end of document', bytes, offset);
  }
  final b = bytes[offset];
  if (b == 116) {
    // 'true'
    if (offset + 4 > bytes.length ||
        bytes[offset + 1] != 114 ||
        bytes[offset + 2] != 117 ||
        bytes[offset + 3] != 101) {
      throw FormatException('Expected true at offset $offset', bytes, offset);
    }
    if (offset + 4 < bytes.length &&
        bytes[offset + 4] != 44 &&
        bytes[offset + 4] != 125 &&
        bytes[offset + 4] != 93 &&
        !_isWs(bytes[offset + 4])) {
      throw FormatException(
        'Invalid JSON token starting with true at offset $offset',
        bytes,
        offset,
      );
    }
    return offset + 4;
  }
  if (b == 102) {
    // 'false'
    if (offset + 5 > bytes.length ||
        bytes[offset + 1] != 97 ||
        bytes[offset + 2] != 108 ||
        bytes[offset + 3] != 115 ||
        bytes[offset + 4] != 101) {
      throw FormatException('Expected false at offset $offset', bytes, offset);
    }
    if (offset + 5 < bytes.length &&
        bytes[offset + 5] != 44 &&
        bytes[offset + 5] != 125 &&
        bytes[offset + 5] != 93 &&
        !_isWs(bytes[offset + 5])) {
      throw FormatException(
        'Invalid JSON token starting with false at offset $offset',
        bytes,
        offset,
      );
    }
    return offset + 5;
  }
  if (b == 110) {
    // 'null'
    if (offset + 4 > bytes.length ||
        bytes[offset + 1] != 117 ||
        bytes[offset + 2] != 108 ||
        bytes[offset + 3] != 108) {
      throw FormatException('Expected null at offset $offset', bytes, offset);
    }
    if (offset + 4 < bytes.length &&
        bytes[offset + 4] != 44 &&
        bytes[offset + 4] != 125 &&
        bytes[offset + 4] != 93 &&
        !_isWs(bytes[offset + 4])) {
      throw FormatException(
        'Invalid JSON token starting with null at offset $offset',
        bytes,
        offset,
      );
    }
    return offset + 4;
  }
  if (b == 45 || (b >= 48 && b <= 57)) {
    return _scanNumberSpan(bytes, offset);
  }
  throw FormatException(
    'Invalid JSON value starting with "${String.fromCharCode(b)}" at offset $offset',
    bytes,
    offset,
  );
}

int _scanNumberSpan(Uint8List bytes, int offset) {
  var i = offset;
  if (i >= bytes.length) {
    throw FormatException('Unexpected end of document', bytes, offset);
  }
  if (bytes[i] == 45) {
    // '-'
    i++;
    if (i >= bytes.length) {
      throw FormatException('Invalid number at offset $offset', bytes, offset);
    }
  }

  // Integer part:
  if (bytes[i] == 48) {
    // '0'
    i++;
    // Leading zero cannot be followed by another digit
    if (i < bytes.length && bytes[i] >= 48 && bytes[i] <= 57) {
      throw FormatException(
        'Leading zeros are not permitted at offset $offset',
        bytes,
        offset,
      );
    }
  } else if (bytes[i] >= 49 && bytes[i] <= 57) {
    // '1'..'9'
    while (i < bytes.length && bytes[i] >= 48 && bytes[i] <= 57) {
      i++;
    }
  } else {
    throw FormatException('Invalid number at offset $offset', bytes, offset);
  }

  // Fraction part (optional):
  if (i < bytes.length && bytes[i] == 46) {
    // '.'
    i++;
    if (i >= bytes.length || bytes[i] < 48 || bytes[i] > 57) {
      throw FormatException(
        'Decimal point must be followed by at least one digit at offset $offset',
        bytes,
        offset,
      );
    }
    while (i < bytes.length && bytes[i] >= 48 && bytes[i] <= 57) {
      i++;
    }
  }

  // Exponent part (optional):
  if (i < bytes.length && (bytes[i] == 101 || bytes[i] == 69)) {
    // 'e' or 'E'
    i++;
    if (i < bytes.length && (bytes[i] == 43 || bytes[i] == 45)) {
      i++;
    }
    if (i >= bytes.length || bytes[i] < 48 || bytes[i] > 57) {
      throw FormatException(
        'Exponent must be followed by at least one digit at offset $offset',
        bytes,
        offset,
      );
    }
    while (i < bytes.length && bytes[i] >= 48 && bytes[i] <= 57) {
      i++;
    }
  }

  // Ensure trailing character is a valid delimiter
  if (i < bytes.length &&
      bytes[i] != 44 &&
      bytes[i] != 125 &&
      bytes[i] != 93 &&
      !_isWs(bytes[i])) {
    throw FormatException(
      'Unexpected character in number literal at offset $i',
      bytes,
      i,
    );
  }

  return i;
}

// Precomputed 128-bit power-of-10 lookup tables for Eisel-Lemire (q in [-342, 308]).
// 651 entries.
Int64List? _initInt64From32(List<int> words) {
  if (identical(1, 1.0)) return null;
  final list = Int64List(words.length ~/ 2);
  for (var i = 0; i < list.length; i++) {
    final lo = words[i * 2];
    final hi = words[i * 2 + 1];
    list[i] = (hi << 32) | lo;
  }
  return list;
}

const List<int> _power10_H_32 = <int>[
  0x923bd65a, 0xeef453d6, // q = -342
  0x1b6565f8, 0x9558b466, // q = -341
  0xa23ebf76, 0xbaaee17f, // q = -340
  0x8ace6f53, 0xe95a99df, // q = -339
  0xb6c10594, 0x91d8a02b, // q = -338
  0xa47146f9, 0xb64ec836, // q = -337
  0x4d8d98b7, 0xe3e27a44, // q = -336
  0xb0787f72, 0x8e6d8c6a, // q = -335
  0x5c969f4f, 0xb208ef85, // q = -334
  0xb3bc4723, 0xde8b2b66, // q = -333
  0x3055ac76, 0x8b16fb20, // q = -332
  0x3c6b1793, 0xaddcb9e8, // q = -331
  0x4b85dd78, 0xd953e862, // q = -330
  0x6f33aa6b, 0x87d4713d, // q = -329
  0xcb009506, 0xa9c98d8c, // q = -328
  0xfdc0ba48, 0xd43bf0ef, // q = -327
  0xfe98746d, 0x84a57695, // q = -326
  0x7e3e9188, 0xa5ced43b, // q = -325
  0x5dce35ea, 0xcf42894a, // q = -324
  0x7aa0e1b2, 0x818995ce, // q = -323
  0x19491a1f, 0xa1ebfb42, // q = -322
  0x9f9b60a6, 0xca66fa12, // q = -321
  0x478238d0, 0xfd00b897, // q = -320
  0x8cb16382, 0x9e20735e, // q = -319
  0x2fddbc62, 0xc5a89036, // q = -318
  0xbbd52b7b, 0xf712b443, // q = -317
  0x55653b2d, 0x9a6bb0aa, // q = -316
  0xeabe89f8, 0xc1069cd4, // q = -315
  0x256e2c76, 0xf148440a, // q = -314
  0x5764dbca, 0x96cd2a86, // q = -313
  0xed3e12bc, 0xbc807527, // q = -312
  0xe88d976b, 0xeba09271, // q = -311
  0x31587ea3, 0x93445b87, // q = -310
  0xfdae9e4c, 0xb8157268, // q = -309
  0x3d1a45df, 0xe61acf03, // q = -308
  0x06306bab, 0x8fd0c162, // q = -307
  0x87bc8696, 0xb3c4f1ba, // q = -306
  0x29aba83c, 0xe0b62e29, // q = -305
  0xba0b4925, 0x8c71dcd9, // q = -304
  0x288e1b6f, 0xaf8e5410, // q = -303
  0x32b1a24a, 0xdb71e914, // q = -302
  0x9faf056e, 0x892731ac, // q = -301
  0xc79ac6ca, 0xab70fe17, // q = -300
  0xb981787d, 0xd64d3d9d, // q = -299
  0x93f0eb4e, 0x85f04682, // q = -298
  0x38ed2621, 0xa76c5823, // q = -297
  0x07286faa, 0xd1476e2c, // q = -296
  0x847945ca, 0x82cca4db, // q = -295
  0x6597973c, 0xa37fce12, // q = -294
  0xfefd7d0c, 0xcc5fc196, // q = -293
  0xbebcdc4f, 0xff77b1fc, // q = -292
  0xf73609b1, 0x9faacf3d, // q = -291
  0x75038c1d, 0xc795830d, // q = -290
  0xd2446f25, 0xf97ae3d0, // q = -289
  0x836ac577, 0x9becce62, // q = -288
  0x244576d5, 0xc2e801fb, // q = -287
  0xed56d48a, 0xf3a20279, // q = -286
  0x345644d6, 0x9845418c, // q = -285
  0x416bd60c, 0xbe5691ef, // q = -284
  0x11c6cb8f, 0xedec366b, // q = -283
  0xeb1c3f39, 0x94b3a202, // q = -282
  0xa5e34f07, 0xb9e08a83, // q = -281
  0x8f5c22c9, 0xe858ad24, // q = -280
  0xd99995be, 0x91376c36, // q = -279
  0x8ffffb2d, 0xb5854744, // q = -278
  0xb3fff9f9, 0xe2e69915, // q = -277
  0x907ffc3b, 0x8dd01fad, // q = -276
  0xf49ffb4a, 0xb1442798, // q = -275
  0x31c7fa1d, 0xdd95317f, // q = -274
  0x7f1cfc52, 0x8a7d3eef, // q = -273
  0x5ee43b66, 0xad1c8eab, // q = -272
  0x369d4a40, 0xd863b256, // q = -271
  0xe2224e68, 0x873e4f75, // q = -270
  0x5aaae202, 0xa90de353, // q = -269
  0x31559a83, 0xd3515c28, // q = -268
  0x1ed58091, 0x8412d999, // q = -267
  0x668ae0b6, 0xa5178fff, // q = -266
  0x402d98e3, 0xce5d73ff, // q = -265
  0x881c7f8e, 0x80fa687f, // q = -264
  0x6a239f72, 0xa139029f, // q = -263
  0x44ac874e, 0xc9874347, // q = -262
  0x15d7a922, 0xfbe91419, // q = -261
  0xada6c9b5, 0x9d71ac8f, // q = -260
  0x99107c22, 0xc4ce17b3, // q = -259
  0x7f549b2b, 0xf6019da0, // q = -258
  0x4f94e0fb, 0x99c10284, // q = -257
  0x637a1939, 0xc0314325, // q = -256
  0xbc589f88, 0xf03d93ee, // q = -255
  0x35b763b5, 0x96267c75, // q = -254
  0x83253ca2, 0xbbb01b92, // q = -253
  0x23ee8bcb, 0xea9c2277, // q = -252
  0x7675175f, 0x92a1958a, // q = -251
  0x14125d36, 0xb749faed, // q = -250
  0x5916f484, 0xe51c79a8, // q = -249
  0x37ae58d2, 0x8f31cc09, // q = -248
  0x8599ef07, 0xb2fe3f0b, // q = -247
  0x67006ac9, 0xdfbdcece, // q = -246
  0x006042bd, 0x8bd6a141, // q = -245
  0x4078536d, 0xaecc4991, // q = -244
  0x90966848, 0xda7f5bf5, // q = -243
  0x7a5e012d, 0x888f9979, // q = -242
  0xd8f58178, 0xaab37fd7, // q = -241
  0xcf32e1d6, 0xd5605fcd, // q = -240
  0xa17fcd26, 0x855c3be0, // q = -239
  0xc9dfc06f, 0xa6b34ad8, // q = -238
  0xfc57b08b, 0xd0601d8e, // q = -237
  0x5db6ce57, 0x823c1279, // q = -236
  0xb52481ed, 0xa2cb1717, // q = -235
  0xa26da268, 0xcb7ddcdd, // q = -234
  0x0b090b02, 0xfe5d5415, // q = -233
  0x26e5a6e1, 0x9efa548d, // q = -232
  0x709f109a, 0xc6b8e9b0, // q = -231
  0x8cc6d4c0, 0xf867241c, // q = -230
  0xd7fc44f8, 0x9b407691, // q = -229
  0x4dfb5636, 0xc2109436, // q = -228
  0xe17a2bc4, 0xf294b943, // q = -227
  0x6cec5b5a, 0x979cf3ca, // q = -226
  0x08277231, 0xbd8430bd, // q = -225
  0x4a314ebd, 0xece53cec, // q = -224
  0xae5ed136, 0x940f4613, // q = -223
  0x99f68584, 0xb9131798, // q = -222
  0xc07426e5, 0xe757dd7e, // q = -221
  0x3848984f, 0x9096ea6f, // q = -220
  0x065abe63, 0xb4bca50b, // q = -219
  0xc7f16dfb, 0xe1ebce4d, // q = -218
  0x9cf6e4bd, 0x8d3360f0, // q = -217
  0xc4349dec, 0xb080392c, // q = -216
  0xf541c567, 0xdca04777, // q = -215
  0xf9491b60, 0x89e42caa, // q = -214
  0xb79b6239, 0xac5d37d5, // q = -213
  0x25823ac7, 0xd77485cb, // q = -212
  0xf77164bc, 0x86a8d39e, // q = -211
  0xb54dbdeb, 0xa8530886, // q = -210
  0x62a12d66, 0xd267caa8, // q = -209
  0x3da4bc60, 0x8380dea9, // q = -208
  0x8d0deb78, 0xa4611653, // q = -207
  0x70516656, 0xcd795be8, // q = -206
  0x4632dff6, 0x806bd971, // q = -205
  0x97bf97f3, 0xa086cfcd, // q = -204
  0xfdaf7df0, 0xc8a883c0, // q = -203
  0x3d1b5d6c, 0xfad2a4b1, // q = -202
  0xc6311a63, 0x9cc3a6ee, // q = -201
  0x77bd60fc, 0xc3f490aa, // q = -200
  0x15acb93b, 0xf4f1b4d5, // q = -199
  0x2d8bf3c5, 0x99171105, // q = -198
  0x78eef0b6, 0xbf5cd546, // q = -197
  0x172aace4, 0xef340a98, // q = -196
  0x0e7aac0e, 0x9580869f, // q = -195
  0xd2195712, 0xbae0a846, // q = -194
  0x869facd7, 0xe998d258, // q = -193
  0x5423cc06, 0x91ff8377, // q = -192
  0x292cbf08, 0xb67f6455, // q = -191
  0x7377eeca, 0xe41f3d6a, // q = -190
  0x882af53e, 0x8e938662, // q = -189
  0x2a35b28d, 0xb23867fb, // q = -188
  0xf4c31f31, 0xdec681f9, // q = -187
  0x38f9f37e, 0x8b3c113c, // q = -186
  0x4738705e, 0xae0b158b, // q = -185
  0x19068c76, 0xd98ddaee, // q = -184
  0xcfa417c9, 0x87f8a8d4, // q = -183
  0x038d1dbc, 0xa9f6d30a, // q = -182
  0x8470652b, 0xd47487cc, // q = -181
  0xd2c63f3b, 0x84c8d4df, // q = -180
  0xc777cf09, 0xa5fb0a17, // q = -179
  0xb955c2cc, 0xcf79cc9d, // q = -178
  0x93d599bf, 0x81ac1fe2, // q = -177
  0x38cb002f, 0xa21727db, // q = -176
  0x06fdc03b, 0xca9cf1d2, // q = -175
  0x88bd304a, 0xfd442e46, // q = -174
  0x15763e2e, 0x9e4a9cec, // q = -173
  0x1ad3cdba, 0xc5dd4427, // q = -172
  0xe188c128, 0xf7549530, // q = -171
  0x8cf578b9, 0x9a94dd3e, // q = -170
  0x3032d6e7, 0xc13a148e, // q = -169
  0xbc3f8ca1, 0xf18899b1, // q = -168
  0x15a7b7e5, 0x96f5600f, // q = -167
  0xdb11a5de, 0xbcb2b812, // q = -166
  0x91d60f56, 0xebdf6617, // q = -165
  0xbb25c995, 0x936b9fce, // q = -164
  0x69ef3bfb, 0xb84687c2, // q = -163
  0x046b0afa, 0xe65829b3, // q = -162
  0xe2c2e6dc, 0x8ff71a0f, // q = -161
  0xdb73a093, 0xb3f4e093, // q = -160
  0xd25088b8, 0xe0f218b8, // q = -159
  0x83725573, 0x8c974f73, // q = -158
  0x644eeacf, 0xafbd2350, // q = -157
  0x7d62a583, 0xdbac6c24, // q = -156
  0xce5da772, 0x894bc396, // q = -155
  0x81f5114f, 0xab9eb47c, // q = -154
  0xa27255a2, 0xd686619b, // q = -153
  0x45877585, 0x8613fd01, // q = -152
  0x96e952e7, 0xa798fc41, // q = -151
  0xfca3a7a0, 0xd17f3b51, // q = -150
  0x3de648c4, 0x82ef8513, // q = -149
  0x0d5fdaf5, 0xa3ab6658, // q = -148
  0x10b7d1b3, 0xcc963fee, // q = -147
  0x94e5c61f, 0xffbbcfe9, // q = -146
  0xfd0f9bd3, 0x9fd561f1, // q = -145
  0x7c5382c8, 0xc7caba6e, // q = -144
  0x1b68637b, 0xf9bd690a, // q = -143
  0x51213e2d, 0x9c1661a6, // q = -142
  0xe5698db8, 0xc31bfa0f, // q = -141
  0xdec3f126, 0xf3e2f893, // q = -140
  0x6b3a76b7, 0x986ddb5c, // q = -139
  0x86091465, 0xbe895233, // q = -138
  0x678b597f, 0xee2ba6c0, // q = -137
  0x40b717ef, 0x94db4838, // q = -136
  0x50e4ddeb, 0xba121a46, // q = -135
  0xe51e1566, 0xe896a0d7, // q = -134
  0xef32cd60, 0x915e2486, // q = -133
  0xaaff80b8, 0xb5b5ada8, // q = -132
  0xd5bf60e6, 0xe3231912, // q = -131
  0xc5979c8f, 0x8df5efab, // q = -130
  0xb6fd83b3, 0xb1736b96, // q = -129
  0x64bce4a0, 0xddd0467c, // q = -128
  0xbef60ee4, 0x8aa22c0d, // q = -127
  0x2eb3929d, 0xad4ab711, // q = -126
  0x7a607744, 0xd89d64d5, // q = -125
  0x6c7c4a8b, 0x87625f05, // q = -124
  0xc79b5d2d, 0xa93af6c6, // q = -123
  0x79823479, 0xd389b478, // q = -122
  0x4bf160cb, 0x843610cb, // q = -121
  0x1eedb8fe, 0xa54394fe, // q = -120
  0xa6a9273e, 0xce947a3d, // q = -119
  0x8829b887, 0x811ccc66, // q = -118
  0x2a3426a8, 0xa163ff80, // q = -117
  0x34c13052, 0xc9bcff60, // q = -116
  0x41f17c67, 0xfc2c3f38, // q = -115
  0x2936edc0, 0x9d9ba783, // q = -114
  0xf384a931, 0xc5029163, // q = -113
  0xf065d37d, 0xf64335bc, // q = -112
  0x163fa42e, 0x99ea0196, // q = -111
  0x9bcf8d39, 0xc06481fb, // q = -110
  0x82c37088, 0xf07da27a, // q = -109
  0x91ba2655, 0x964e858c, // q = -108
  0xb628afea, 0xbbe226ef, // q = -107
  0xa3b2dbe5, 0xeadab0ab, // q = -106
  0x464fc96f, 0x92c8ae6b, // q = -105
  0x17e3bbcb, 0xb77ada06, // q = -104
  0x9ddcaabd, 0xe5599087, // q = -103
  0xc2a9eab6, 0x8f57fa54, // q = -102
  0xf3546564, 0xb32df8e9, // q = -101
  0x70297ebd, 0xdff97724, // q = -100
  0xc619ef36, 0x8bfbea76, // q = -99
  0x77a06b03, 0xaefae514, // q = -98
  0x958885c4, 0xdab99e59, // q = -97
  0xfd75539b, 0x88b402f7, // q = -96
  0xfcd2a881, 0xaae103b5, // q = -95
  0x7c0752a2, 0xd59944a3, // q = -94
  0x2d8493a5, 0x857fcae6, // q = -93
  0xb8e5b88e, 0xa6dfbd9f, // q = -92
  0xa71f26b2, 0xd097ad07, // q = -91
  0xc873782f, 0x825ecc24, // q = -90
  0xfa90563b, 0xa2f67f2d, // q = -89
  0x79346bca, 0xcbb41ef9, // q = -88
  0xd78186bc, 0xfea126b7, // q = -87
  0xe6b0f436, 0x9f24b832, // q = -86
  0xa05d3143, 0xc6ede63f, // q = -85
  0x88747d94, 0xf8a95fcf, // q = -84
  0xb548ce7c, 0x9b69dbe1, // q = -83
  0x229b021b, 0xc24452da, // q = -82
  0xab41c2a2, 0xf2d56790, // q = -81
  0x6b0919a5, 0x97c560ba, // q = -80
  0x05cb600f, 0xbdb6b8e9, // q = -79
  0x473e3813, 0xed246723, // q = -78
  0x0c86e30b, 0x9436c076, // q = -77
  0x8fa89bce, 0xb9447093, // q = -76
  0x7392c2c2, 0xe7958cb8, // q = -75
  0x483bb9b9, 0x90bd77f3, // q = -74
  0x1a4aa828, 0xb4ecd5f0, // q = -73
  0x20dd5232, 0xe2280b6c, // q = -72
  0x948a535f, 0x8d590723, // q = -71
  0x79ace837, 0xb0af48ec, // q = -70
  0x98182244, 0xdcdb1b27, // q = -69
  0xbf0f156b, 0x8a08f0f8, // q = -68
  0xeed2dac5, 0xac8b2d36, // q = -67
  0xaa879177, 0xd7adf884, // q = -66
  0xea94baea, 0x86ccbb52, // q = -65
  0xa539e9a5, 0xa87fea27, // q = -64
  0x8e88640e, 0xd29fe4b1, // q = -63
  0xf9153e89, 0x83a3eeee, // q = -62
  0xb75a8e2b, 0xa48ceaaa, // q = -61
  0x653131b6, 0xcdb02555, // q = -60
  0x5f3ebf11, 0x808e1755, // q = -59
  0xb70e6ed6, 0xa0b19d2a, // q = -58
  0x64d20a8b, 0xc8de0475, // q = -57
  0xbe068d2e, 0xfb158592, // q = -56
  0xb6c4183d, 0x9ced737b, // q = -55
  0xa4751e4c, 0xc428d05a, // q = -54
  0x4d9265df, 0xf5330471, // q = -53
  0xd07b7fab, 0x993fe2c6, // q = -52
  0x849a5f96, 0xbf8fdb78, // q = -51
  0xa5c0f77c, 0xef73d256, // q = -50
  0x27989aad, 0x95a86376, // q = -49
  0xb17ec159, 0xbb127c53, // q = -48
  0x9dde71af, 0xe9d71b68, // q = -47
  0x62ab070d, 0x92267121, // q = -46
  0xbb55c8d1, 0xb6b00d69, // q = -45
  0x2a2b3b05, 0xe45c10c4, // q = -44
  0x9a5b04e3, 0x8eb98a7a, // q = -43
  0x40f1c61c, 0xb267ed19, // q = -42
  0x912e37a3, 0xdf01e85f, // q = -41
  0xbabce2c6, 0x8b61313b, // q = -40
  0xa96c1b77, 0xae397d8a, // q = -39
  0x53c72255, 0xd9c7dced, // q = -38
  0x545c7575, 0x881cea14, // q = -37
  0x697392d2, 0xaa242499, // q = -36
  0xc3d07787, 0xd4ad2dbf, // q = -35
  0xda624ab4, 0x84ec3c97, // q = -34
  0xd0fadd61, 0xa6274bbd, // q = -33
  0x453994ba, 0xcfb11ead, // q = -32
  0x4b43fcf4, 0x81ceb32c, // q = -31
  0x5e14fc31, 0xa2425ff7, // q = -30
  0x359a3b3e, 0xcad2f7f5, // q = -29
  0x8300ca0d, 0xfd87b5f2, // q = -28
  0x91e07e48, 0x9e74d1b7, // q = -27
  0x76589dda, 0xc6120625, // q = -26
  0xd3eec551, 0xf79687ae, // q = -25
  0x44753b52, 0x9abe14cd, // q = -24
  0x95928a27, 0xc16d9a00, // q = -23
  0xbaf72cb1, 0xf1c90080, // q = -22
  0x74da7bee, 0x971da050, // q = -21
  0x92111aea, 0xbce50864, // q = -20
  0xb69561a5, 0xec1e4a7d, // q = -19
  0x921d5d07, 0x9392ee8e, // q = -18
  0x36a4b449, 0xb877aa32, // q = -17
  0xc44de15b, 0xe69594be, // q = -16
  0x3ab0acd9, 0x901d7cf7, // q = -15
  0x095cd80f, 0xb424dc35, // q = -14
  0x4bb40e13, 0xe12e1342, // q = -13
  0x6f5088cb, 0x8cbccc09, // q = -12
  0xcb24aafe, 0xafebff0b, // q = -11
  0xbdedd5be, 0xdbe6fece, // q = -10
  0x36b4a597, 0x89705f41, // q = -9
  0x8461cefc, 0xabcc7711, // q = -8
  0xe57a42bc, 0xd6bf94d5, // q = -7
  0xaf6c69b5, 0x8637bd05, // q = -6
  0x1b478423, 0xa7c5ac47, // q = -5
  0xe219652b, 0xd1b71758, // q = -4
  0x8d4fdf3b, 0x83126e97, // q = -3
  0x70a3d70a, 0xa3d70a3d, // q = -2
  0xcccccccc, 0xcccccccc, // q = -1
  0x00000000, 0x80000000, // q = 0
  0x00000000, 0xa0000000, // q = 1
  0x00000000, 0xc8000000, // q = 2
  0x00000000, 0xfa000000, // q = 3
  0x00000000, 0x9c400000, // q = 4
  0x00000000, 0xc3500000, // q = 5
  0x00000000, 0xf4240000, // q = 6
  0x00000000, 0x98968000, // q = 7
  0x00000000, 0xbebc2000, // q = 8
  0x00000000, 0xee6b2800, // q = 9
  0x00000000, 0x9502f900, // q = 10
  0x00000000, 0xba43b740, // q = 11
  0x00000000, 0xe8d4a510, // q = 12
  0x00000000, 0x9184e72a, // q = 13
  0x80000000, 0xb5e620f4, // q = 14
  0xa0000000, 0xe35fa931, // q = 15
  0x04000000, 0x8e1bc9bf, // q = 16
  0xc5000000, 0xb1a2bc2e, // q = 17
  0x76400000, 0xde0b6b3a, // q = 18
  0x89e80000, 0x8ac72304, // q = 19
  0xac620000, 0xad78ebc5, // q = 20
  0x177a8000, 0xd8d726b7, // q = 21
  0x6eac9000, 0x87867832, // q = 22
  0x0a57b400, 0xa968163f, // q = 23
  0xcceda100, 0xd3c21bce, // q = 24
  0x401484a0, 0x84595161, // q = 25
  0x9019a5c8, 0xa56fa5b9, // q = 26
  0xf4200f3a, 0xcecb8f27, // q = 27
  0xf8940984, 0x813f3978, // q = 28
  0x36b90be5, 0xa18f07d7, // q = 29
  0x04674ede, 0xc9f2c9cd, // q = 30
  0x45812296, 0xfc6f7c40, // q = 31
  0x2b70b59d, 0x9dc5ada8, // q = 32
  0x364ce305, 0xc5371912, // q = 33
  0xc3e01bc6, 0xf684df56, // q = 34
  0x3a6c115c, 0x9a130b96, // q = 35
  0xc90715b3, 0xc097ce7b, // q = 36
  0xbb48db20, 0xf0bdc21a, // q = 37
  0xb50d88f4, 0x96769950, // q = 38
  0xe250eb31, 0xbc143fa4, // q = 39
  0x1ae525fd, 0xeb194f8e, // q = 40
  0xd0cf37be, 0x92efd1b8, // q = 41
  0x050305ad, 0xb7abc627, // q = 42
  0xc643c719, 0xe596b7b0, // q = 43
  0x7bea5c6f, 0x8f7e32ce, // q = 44
  0x1ae4f38b, 0xb35dbf82, // q = 45
  0xa19e306e, 0xe0352f62, // q = 46
  0xa502de45, 0x8c213d9d, // q = 47
  0x0e4395d6, 0xaf298d05, // q = 48
  0x51d47b4c, 0xdaf3f046, // q = 49
  0xf324cd0f, 0x88d8762b, // q = 50
  0xefee0053, 0xab0e93b6, // q = 51
  0xabe98068, 0xd5d238a4, // q = 52
  0xeb71f041, 0x85a36366, // q = 53
  0xa64e6c51, 0xa70c3c40, // q = 54
  0xcfe20765, 0xd0cf4b50, // q = 55
  0x81ed449f, 0x82818f12, // q = 56
  0x226895c7, 0xa321f2d7, // q = 57
  0xeb02bb39, 0xcbea6f8c, // q = 58
  0x25c36a08, 0xfee50b70, // q = 59
  0x179a2245, 0x9f4f2726, // q = 60
  0x9d80aad6, 0xc722f0ef, // q = 61
  0x84e0d58b, 0xf8ebad2b, // q = 62
  0x330c8577, 0x9b934c3b, // q = 63
  0xffcfa6d5, 0xc2781f49, // q = 64
  0x7fc3908a, 0xf316271c, // q = 65
  0xcfda3a56, 0x97edd871, // q = 66
  0x43d0c8ec, 0xbde94e8e, // q = 67
  0xd4c4fb27, 0xed63a231, // q = 68
  0x24fb1cf8, 0x945e455f, // q = 69
  0xee39e436, 0xb975d6b6, // q = 70
  0xa9c85d44, 0xe7d34c64, // q = 71
  0xea1d3a4a, 0x90e40fbe, // q = 72
  0xa4a488dd, 0xb51d13ae, // q = 73
  0x4dcdab14, 0xe264589a, // q = 74
  0x70a08aec, 0x8d7eb760, // q = 75
  0x8cc8ada8, 0xb0de6538, // q = 76
  0xaffad912, 0xdd15fe86, // q = 77
  0x2dfcc7ab, 0x8a2dbf14, // q = 78
  0x397bf996, 0xacb92ed9, // q = 79
  0x87daf7fb, 0xd7e77a8f, // q = 80
  0xb4e8dafd, 0x86f0ac99, // q = 81
  0x222311bc, 0xa8acd7c0, // q = 82
  0x2aabd62b, 0xd2d80db0, // q = 83
  0x1aab65db, 0x83c7088e, // q = 84
  0xa1563f52, 0xa4b8cab1, // q = 85
  0x09abcf26, 0xcde6fd5e, // q = 86
  0xc60b6178, 0x80b05e5a, // q = 87
  0x778e39d6, 0xa0dc75f1, // q = 88
  0xd571c84c, 0xc913936d, // q = 89
  0x4ace3a5f, 0xfb587849, // q = 90
  0xcec0e47b, 0x9d174b2d, // q = 91
  0x42711d9a, 0xc45d1df9, // q = 92
  0x930d6500, 0xf5746577, // q = 93
  0xbbe85f20, 0x9968bf6a, // q = 94
  0x6ae276e8, 0xbfc2ef45, // q = 95
  0xc59b14a2, 0xefb3ab16, // q = 96
  0x3b80ece5, 0x95d04aee, // q = 97
  0xca61281f, 0xbb445da9, // q = 98
  0x3cf97226, 0xea157514, // q = 99
  0xa61be758, 0x924d692c, // q = 100
  0xcfa2e12e, 0xb6e0c377, // q = 101
  0xc38b997a, 0xe498f455, // q = 102
  0x9a373fec, 0x8edf98b5, // q = 103
  0x00c50fe7, 0xb2977ee3, // q = 104
  0xc0f653e1, 0xdf3d5e9b, // q = 105
  0x5899f46c, 0x8b865b21, // q = 106
  0xaec07187, 0xae67f1e9, // q = 107
  0x1a708de9, 0xda01ee64, // q = 108
  0x908658b2, 0x884134fe, // q = 109
  0x34a7eede, 0xaa51823e, // q = 110
  0xc1d1ea96, 0xd4e5e2cd, // q = 111
  0x9923329e, 0x850fadc0, // q = 112
  0xbf6bff45, 0xa6539930, // q = 113
  0xef46ff16, 0xcfe87f7c, // q = 114
  0x158c5f6e, 0x81f14fae, // q = 115
  0x9aef7749, 0xa26da399, // q = 116
  0x01ab551c, 0xcb090c80, // q = 117
  0x02162a63, 0xfdcb4fa0, // q = 118
  0x014dda7e, 0x9e9f11c4, // q = 119
  0x01a1511d, 0xc646d635, // q = 120
  0x4209a565, 0xf7d88bc2, // q = 121
  0x6946075f, 0x9ae75759, // q = 122
  0xc3978937, 0xc1a12d2f, // q = 123
  0xb47d6b84, 0xf209787b, // q = 124
  0x50ce6332, 0x9745eb4d, // q = 125
  0xa501fbff, 0xbd176620, // q = 126
  0xce427aff, 0xec5d3fa8, // q = 127
  0x80e98cdf, 0x93ba47c9, // q = 128
  0xe123f017, 0xb8a8d9bb, // q = 129
  0xd96cec1d, 0xe6d3102a, // q = 130
  0xc7e41392, 0x9043ea1a, // q = 131
  0x79dd1877, 0xb454e4a1, // q = 132
  0xd8545e94, 0xe16a1dc9, // q = 133
  0x2734bb1d, 0x8ce2529e, // q = 134
  0xb101e9e4, 0xb01ae745, // q = 135
  0x1d42645d, 0xdc21a117, // q = 136
  0x72497eba, 0x899504ae, // q = 137
  0x0edbde69, 0xabfa45da, // q = 138
  0x9292d603, 0xd6f8d750, // q = 139
  0x5b9bc5c2, 0x865b8692, // q = 140
  0xf282b732, 0xa7f26836, // q = 141
  0xaf2364ff, 0xd1ef0244, // q = 142
  0xed761f1f, 0x8335616a, // q = 143
  0xa8d3a6e7, 0xa402b9c5, // q = 144
  0x130890a1, 0xcd036837, // q = 145
  0x6be55a64, 0x80222122, // q = 146
  0x06deb0fd, 0xa02aa96b, // q = 147
  0xc8965d3d, 0xc83553c5, // q = 148
  0x3abbf48c, 0xfa42a8b7, // q = 149
  0x84b578d7, 0x9c69a972, // q = 150
  0x25e2d70d, 0xc38413cf, // q = 151
  0xef5b8cd1, 0xf46518c2, // q = 152
  0xd5993802, 0x98bf2f79, // q = 153
  0x4aff8603, 0xbeeefb58, // q = 154
  0x5dbf6784, 0xeeaaba2e, // q = 155
  0xfa97a0b2, 0x952ab45c, // q = 156
  0x393d88df, 0xba756174, // q = 157
  0x478ceb17, 0xe912b9d1, // q = 158
  0xccb812ee, 0x91abb422, // q = 159
  0x7fe617aa, 0xb616a12b, // q = 160
  0x5fdf9d94, 0xe39c4976, // q = 161
  0xfbebc27d, 0x8e41ade9, // q = 162
  0x7ae6b31c, 0xb1d21964, // q = 163
  0x99a05fe3, 0xde469fbd, // q = 164
  0x80043bee, 0x8aec23d6, // q = 165
  0x20054ae9, 0xada72ccc, // q = 166
  0x28069da4, 0xd910f7ff, // q = 167
  0x79042286, 0x87aa9aff, // q = 168
  0x57452b28, 0xa99541bf, // q = 169
  0x2d1675f2, 0xd3fa922f, // q = 170
  0x7c2e09b7, 0x847c9b5d, // q = 171
  0xdb398c25, 0xa59bc234, // q = 172
  0x1207ef2e, 0xcf02b2c2, // q = 173
  0x4b44f57d, 0x8161afb9, // q = 174
  0x9e1632dc, 0xa1ba1ba7, // q = 175
  0x859bbf93, 0xca28a291, // q = 176
  0xe702af78, 0xfcb2cb35, // q = 177
  0xb061adab, 0x9defbf01, // q = 178
  0x1c7a1916, 0xc56baec2, // q = 179
  0xa3989f5b, 0xf6c69a72, // q = 180
  0xa63f6399, 0x9a3c2087, // q = 181
  0x8fcf3c7f, 0xc0cb28a9, // q = 182
  0xf3c30b9f, 0xf0fdf2d3, // q = 183
  0x7859e743, 0x969eb7c4, // q = 184
  0x96706114, 0xbc4665b5, // q = 185
  0xfc0c7959, 0xeb57ff22, // q = 186
  0xdd87cbd8, 0x9316ff75, // q = 187
  0x54e9bece, 0xb7dcbf53, // q = 188
  0x2a242e81, 0xe5d3ef28, // q = 189
  0x1a569d10, 0x8fa47579, // q = 190
  0x60ec4455, 0xb38d92d7, // q = 191
  0x3927556a, 0xe070f78d, // q = 192
  0x43b89562, 0x8c469ab8, // q = 193
  0x54a6babb, 0xaf584166, // q = 194
  0xe9d0696a, 0xdb2e51bf, // q = 195
  0xf22241e2, 0x88fcf317, // q = 196
  0xeeaad25a, 0xab3c2fdd, // q = 197
  0x6a5586f1, 0xd60b3bd5, // q = 198
  0x62757456, 0x85c70565, // q = 199
  0xbb12d16c, 0xa738c6be, // q = 200
  0x69d785c7, 0xd106f86e, // q = 201
  0x0226b39c, 0x82a45b45, // q = 202
  0x42b06084, 0xa34d7216, // q = 203
  0xd35c78a5, 0xcc20ce9b, // q = 204
  0xc83396ce, 0xff290242, // q = 205
  0xbd203e41, 0x9f79a169, // q = 206
  0x2c684dd1, 0xc75809c4, // q = 207
  0x37826145, 0xf92e0c35, // q = 208
  0x42b17ccb, 0x9bbcc7a1, // q = 209
  0x935ddbfe, 0xc2abf989, // q = 210
  0xf83552fe, 0xf356f7eb, // q = 211
  0x7b2153de, 0x98165af3, // q = 212
  0x59e9a8d6, 0xbe1bf1b0, // q = 213
  0x7064130c, 0xeda2ee1c, // q = 214
  0xc63e8be7, 0x9485d4d1, // q = 215
  0x37ce2ee1, 0xb9a74a06, // q = 216
  0xc5c1ba99, 0xe8111c87, // q = 217
  0xdb9914a0, 0x910ab1d4, // q = 218
  0x127f59c8, 0xb54d5e4a, // q = 219
  0x971f303a, 0xe2a0b5dc, // q = 220
  0xde737e24, 0x8da471a9, // q = 221
  0x56105dad, 0xb10d8e14, // q = 222
  0x6b947518, 0xdd50f199, // q = 223
  0xe33cc92f, 0x8a5296ff, // q = 224
  0xdc0bfb7b, 0xace73cbf, // q = 225
  0xd30efa5a, 0xd8210bef, // q = 226
  0xe3e95c78, 0x8714a775, // q = 227
  0x5ce3b396, 0xa8d9d153, // q = 228
  0x341ca07c, 0xd31045a8, // q = 229
  0x2091e44d, 0x83ea2b89, // q = 230
  0x68b65d60, 0xa4e4b66b, // q = 231
  0x42e3f4b9, 0xce1de406, // q = 232
  0xe9ce78f3, 0x80d2ae83, // q = 233
  0xe4421730, 0xa1075a24, // q = 234
  0x1d529cfc, 0xc94930ae, // q = 235
  0xa4a7443c, 0xfb9b7cd9, // q = 236
  0x06e88aa5, 0x9d412e08, // q = 237
  0x08a2ad4e, 0xc491798a, // q = 238
  0x8acb58a2, 0xf5b5d7ec, // q = 239
  0xd6bf1765, 0x9991a6f3, // q = 240
  0xcc6edd3f, 0xbff610b0, // q = 241
  0xff8a948e, 0xeff394dc, // q = 242
  0x1fb69cd9, 0x95f83d0a, // q = 243
  0xa7a4440f, 0xbb764c4c, // q = 244
  0xd18d5513, 0xea53df5f, // q = 245
  0xe2f8552c, 0x92746b9b, // q = 246
  0xdbb66a77, 0xb7118682, // q = 247
  0x92a40515, 0xe4d5e823, // q = 248
  0x3ba6832d, 0x8f05b116, // q = 249
  0xca9023f8, 0xb2c71d5b, // q = 250
  0xbd342cf6, 0xdf78e4b2, // q = 251
  0xb6409c1a, 0x8bab8eef, // q = 252
  0xa3d0c320, 0xae9672ab, // q = 253
  0x8cc4f3e8, 0xda3c0f56, // q = 254
  0x17fb1871, 0x88658996, // q = 255
  0x9df9de8d, 0xaa7eebfb, // q = 256
  0x85785631, 0xd51ea6fa, // q = 257
  0x936b35de, 0x8533285c, // q = 258
  0xb8460356, 0xa67ff273, // q = 259
  0xa657842c, 0xd01fef10, // q = 260
  0x67f6b29b, 0x8213f56a, // q = 261
  0x01f45f42, 0xa298f2c5, // q = 262
  0x42717713, 0xcb3f2f76, // q = 263
  0xd30dd4d7, 0xfe0efb53, // q = 264
  0x63e8a506, 0x9ec95d14, // q = 265
  0x7ce2ce48, 0xc67bb459, // q = 266
  0xdc1b81da, 0xf81aa16f, // q = 267
  0xe9913128, 0x9b10a4e5, // q = 268
  0x63f57d72, 0xc1d4ce1f, // q = 269
  0x3cf2dccf, 0xf24a01a7, // q = 270
  0x8617ca01, 0x976e4108, // q = 271
  0xa79dbc82, 0xbd49d14a, // q = 272
  0x51852ba2, 0xec9c459d, // q = 273
  0x52f33b45, 0x93e1ab82, // q = 274
  0xe7b00a17, 0xb8da1662, // q = 275
  0xa19c0c9d, 0xe7109bfb, // q = 276
  0x450187e2, 0x906a617d, // q = 277
  0x9641e9da, 0xb484f9dc, // q = 278
  0xbbd26451, 0xe1a63853, // q = 279
  0x55637eb2, 0x8d07e334, // q = 280
  0x6abc5e5f, 0xb049dc01, // q = 281
  0xc56b75f7, 0xdc5c5301, // q = 282
  0x1b6329ba, 0x89b9b3e1, // q = 283
  0x623bf429, 0xac2820d9, // q = 284
  0xbacaf133, 0xd732290f, // q = 285
  0xd4bed6c0, 0x867f59a9, // q = 286
  0x49ee8c70, 0xa81f3014, // q = 287
  0x5c6a2f8c, 0xd226fc19, // q = 288
  0xd9c25db7, 0x83585d8f, // q = 289
  0xd032f525, 0xa42e74f3, // q = 290
  0xc43fb26f, 0xcd3a1230, // q = 291
  0x7aa7cf85, 0x80444b5e, // q = 292
  0x1951c366, 0xa0555e36, // q = 293
  0x9fa63440, 0xc86ab5c3, // q = 294
  0x878fc150, 0xfa856334, // q = 295
  0xd4b9d8d2, 0x9c935e00, // q = 296
  0x09e84f07, 0xc3b83581, // q = 297
  0x4c6262c8, 0xf4a642e1, // q = 298
  0xcfbd7dbd, 0x98e7e9cc, // q = 299
  0x03acdd2c, 0xbf21e440, // q = 300
  0x04981478, 0xeeea5d50, // q = 301
  0x02df0ccb, 0x95527a52, // q = 302
  0x8396cffd, 0xbaa718e6, // q = 303
  0x247c83fd, 0xe950df20, // q = 304
  0x16cdd27e, 0x91d28b74, // q = 305
  0x1c81471d, 0xb6472e51, // q = 306
  0x63a198e5, 0xe3d8f9e5, // q = 307
  0x5e44ff8f, 0x8e679c2f, // q = 308
];

const List<int> _power10_L_32 = <int>[
  0x06a13b40, 0x113faa29, // q = -342
  0xa424c508, 0x4ac7ca59, // q = -341
  0x0d2df64a, 0x5d79bcf0, // q = -340
  0x107973dd, 0xf4d82c2c, // q = -339
  0x8a4be86a, 0x79071b9b, // q = -338
  0x6cdee285, 0x9748e282, // q = -337
  0x08169b26, 0xfd1b1b23, // q = -336
  0xe50e20f8, 0xfe30f0f5, // q = -335
  0x5e51a936, 0xbdbd2d33, // q = -334
  0x35e61383, 0xad2c7880, // q = -333
  0x21afcc32, 0x4c3bcb50, // q = -332
  0x2a1bbf3e, 0xdf4abe24, // q = -331
  0x34a2af0e, 0xd71d6dad, // q = -330
  0x40e5ad69, 0x8672648c, // q = -329
  0x511f18c3, 0x680efdaf, // q = -328
  0x2566def3, 0x0212bd1b, // q = -327
  0xf7604b58, 0x014bb630, // q = -326
  0x35385e2e, 0x419ea3bd, // q = -325
  0x828675ba, 0x52064cac, // q = -324
  0xd1940994, 0x7343efeb, // q = -323
  0xc5f90bf9, 0x1014ebe6, // q = -322
  0x77774ef7, 0xd41a26e0, // q = -321
  0x955522b5, 0x8920b098, // q = -320
  0x5d5535b1, 0x55b46e5f, // q = -319
  0x34aa831e, 0xeb2189f7, // q = -318
  0x01d523e5, 0xa5e9ec75, // q = -317
  0x2125366f, 0x47b233c9, // q = -316
  0x696e840b, 0x999ec0bb, // q = -315
  0x43ca250e, 0xc00670ea, // q = -314
  0x6a5e5729, 0x38040692, // q = -313
  0x04f5ecf3, 0xc6050837, // q = -312
  0xc633682f, 0xf7864a44, // q = -311
  0xfbe0211e, 0x7ab3ee6a, // q = -310
  0xbad82965, 0x5960ea05, // q = -309
  0x298e33be, 0x6fb92487, // q = -308
  0x79f8e057, 0xa5d3b6d4, // q = -307
  0x9877186d, 0x8f48a489, // q = -306
  0xfe94de88, 0x331acdab, // q = -305
  0x7f1d0b15, 0x9ff0c08b, // q = -304
  0x5ee44dda, 0x07ecf0ae, // q = -303
  0xf69d6151, 0xc9e82cd9, // q = -302
  0x3a225cd3, 0xbe311c08, // q = -301
  0x48aaf407, 0x6dbd630a, // q = -300
  0xdad5b109, 0x092cbbcc, // q = -299
  0x08c58ea6, 0x25bbf560, // q = -298
  0x0af6f24f, 0xaf2af2b8, // q = -297
  0x0db4aee2, 0x1af5af66, // q = -296
  0xc890ed4e, 0x50d98d9f, // q = -295
  0xbab528a1, 0xe50ff107, // q = -294
  0xa96272c9, 0x1e53ed49, // q = -293
  0x13bb0f7b, 0x25e8e89c, // q = -292
  0x8c54e9ad, 0x77b19161, // q = -291
  0xef6a2418, 0xd59df5b9, // q = -290
  0x6b44ad1e, 0x4b057328, // q = -289
  0x430aec33, 0x4ee367f9, // q = -288
  0x93cda740, 0x229c41f7, // q = -287
  0x78c11110, 0x6b435275, // q = -286
  0x6b78aaaa, 0x830a1389, // q = -285
  0xc656d554, 0x23cc986b, // q = -284
  0xb7ec8aa9, 0x2cbfbe86, // q = -283
  0x32f3d6aa, 0x7bf7d714, // q = -282
  0x3fb0cc54, 0xdaf5ccd9, // q = -281
  0x8f9cff69, 0xd1b3400f, // q = -280
  0xb9c21fa2, 0x23100809, // q = -279
  0x2832a78b, 0xabd40a0c, // q = -278
  0x323f516d, 0x16c90c8f, // q = -277
  0x7f6792e4, 0xae3da7d9, // q = -276
  0xdf41779d, 0x99cd11cf, // q = -275
  0xd711d584, 0x40405643, // q = -274
  0x666b2573, 0x482835ea, // q = -273
  0x0005eed0, 0xda324365, // q = -272
  0x40076a83, 0x90bed43e, // q = -271
  0xe804a292, 0x5a7744a6, // q = -270
  0xa205cb37, 0x711515d0, // q = -269
  0xca873e04, 0x0d5a5b44, // q = -268
  0xfe9486c3, 0xe858790a, // q = -267
  0xbe39a873, 0x626e974d, // q = -266
  0x2dc81290, 0xfb0a3d21, // q = -265
  0xbc9d0b9a, 0x7ce66634, // q = -264
  0xebc44e81, 0x1c1fffc1, // q = -263
  0x66b56221, 0xa327ffb2, // q = -262
  0x0062baa9, 0x4bf1ff9f, // q = -261
  0x603db4aa, 0x6f773fc3, // q = -260
  0x384d21d4, 0xcb550fb4, // q = -259
  0x46606a49, 0x7e2a53a1, // q = -258
  0xcbfc426e, 0x2eda7444, // q = -257
  0xfefb5309, 0xfa911155, // q = -256
  0x7eba27cb, 0x793555ab, // q = -255
  0x2f3458df, 0x4bc1558b, // q = -254
  0xfb016f17, 0x9eb1aaed, // q = -253
  0x79c1cadd, 0x465e15a9, // q = -252
  0xec191eca, 0x0bfacd89, // q = -251
  0x671f667c, 0xcef980ec, // q = -250
  0x80e7401b, 0x82b7e127, // q = -249
  0xb0908811, 0xd1b2ecb8, // q = -248
  0xdcb4aa16, 0x861fa7e6, // q = -247
  0x93e1d49b, 0x67a791e0, // q = -246
  0x5c6d24e1, 0xe0c8bb2c, // q = -245
  0x73886e19, 0x58fae9f7, // q = -244
  0x506a899f, 0xaf39a475, // q = -243
  0x52429604, 0x6d8406c9, // q = -242
  0xa6d33b84, 0xc8e5087b, // q = -241
  0x90880a65, 0xfb1e4a9a, // q = -240
  0x9a550680, 0x5cf2eea0, // q = -239
  0xc0ea481f, 0xf42faa48, // q = -238
  0xf124da27, 0xf13b94da, // q = -237
  0xd6b70859, 0x76c53d08, // q = -236
  0x0c64ca6f, 0x54768c4b, // q = -235
  0xcf7dfd0a, 0xa9942f5d, // q = -234
  0x435d7c4d, 0xd3f93b35, // q = -233
  0x4a1a6db0, 0xc47bc501, // q = -232
  0x9ca1091c, 0x359ab641, // q = -231
  0x03c94b63, 0xc30163d2, // q = -230
  0x425dcf1e, 0x79e0de63, // q = -229
  0x12f542e5, 0x985915fc, // q = -228
  0x17b2939e, 0x3e6f5b7b, // q = -227
  0xeecf9c43, 0xa705992c, // q = -226
  0x2a838354, 0x50c6ff78, // q = -225
  0x35246429, 0xa4f8bf56, // q = -224
  0xe136be9a, 0x871b7795, // q = -223
  0x59846e40, 0x28e2557b, // q = -222
  0x2fe589d0, 0x331aeada, // q = -221
  0x5def7622, 0x3ff0d2c8, // q = -220
  0x756b53aa, 0x0fed077a, // q = -219
  0x12c62895, 0xd3e84959, // q = -218
  0xabbbd95d, 0x64712dd7, // q = -217
  0x96aacfb4, 0xbd8d794d, // q = -216
  0xfc5583a1, 0xecf0d7a0, // q = -215
  0x9db57245, 0xf41686c4, // q = -214
  0xc522ced6, 0x311c2875, // q = -213
  0x366b828c, 0x7d633293, // q = -212
  0x02033198, 0xae5dff9c, // q = -211
  0x0283fdfd, 0xd9f57f83, // q = -210
  0xc324fd7c, 0xd072df63, // q = -209
  0x59f71e6e, 0x4247cb9e, // q = -208
  0xf074e609, 0x52d9be85, // q = -207
  0x6c921f8c, 0x67902e27, // q = -206
  0xa3db53b7, 0x00ba1cd8, // q = -205
  0xccd228a5, 0x80e8a40e, // q = -204
  0x8006b2ce, 0x6122cd12, // q = -203
  0x20085f82, 0x796b8057, // q = -202
  0x74053bb1, 0xcbe33036, // q = -201
  0x11068a9d, 0xbedbfc44, // q = -200
  0x15482d45, 0xee92fb55, // q = -199
  0x2d4d1c4b, 0x751bdd15, // q = -198
  0x78a0635e, 0xd262d45a, // q = -197
  0x16c87c35, 0x86fb8971, // q = -196
  0xae3d4da1, 0xd45d35e6, // q = -195
  0x59cca10a, 0x89748360, // q = -194
  0x703fc94c, 0x2bd1a438, // q = -193
  0x4627ddd0, 0x7b6306a3, // q = -192
  0x17b1d543, 0x1a3bc84c, // q = -191
  0x1d9e4a94, 0x20caba5f, // q = -190
  0x7282ee9d, 0x547eb47b, // q = -189
  0x4f23aa44, 0xe99e619a, // q = -188
  0xe2ec94d5, 0x6405fa00, // q = -187
  0x8dd3dd05, 0xde83bc40, // q = -186
  0xb148d446, 0x9624ab50, // q = -185
  0xdd9b0958, 0x3badd624, // q = -184
  0x0a80e5d7, 0xe54ca5d7, // q = -183
  0xcd211f4d, 0x5e9fcf4c, // q = -182
  0x00696720, 0x7647c320, // q = -181
  0x0041e074, 0x29ecd9f4, // q = -180
  0x00525891, 0xf4681071, // q = -179
  0x4066eeb5, 0x7182148d, // q = -178
  0x48405531, 0xc6f14cd8, // q = -177
  0x5a506a7d, 0xb8ada00e, // q = -176
  0xf0e4851d, 0xa6d90811, // q = -175
  0x6d1da664, 0x908f4a16, // q = -174
  0x043287ff, 0x9a598e4e, // q = -173
  0x853f29fe, 0x40eff1e1, // q = -172
  0xe68ef47d, 0xd12bee59, // q = -171
  0x301958cf, 0x82bb74f8, // q = -170
  0x3c1faf02, 0xe36a5236, // q = -169
  0xcb279ac2, 0xdc44e6c3, // q = -168
  0x5ef8c0ba, 0x29ab103a, // q = -167
  0xf6b6f0e8, 0x7415d448, // q = -166
  0x3464ad22, 0x111b495b, // q = -165
  0x00beec35, 0xcab10dd9, // q = -164
  0x40eea743, 0x3d5d514f, // q = -163
  0x112a5113, 0x0cb4a5a3, // q = -162
  0xeaba72ac, 0x47f0e785, // q = -161
  0x65690f57, 0x59ed2167, // q = -160
  0x3ec3532d, 0x306869c1, // q = -159
  0xc73a13fc, 0x1e414218, // q = -158
  0xf90898fb, 0xe5d1929e, // q = -157
  0xb74abf3a, 0xdf45f746, // q = -156
  0x328eb784, 0x6b8bba8c, // q = -155
  0x3f326565, 0x066ea92f, // q = -154
  0x0efefebe, 0xc80a537b, // q = -153
  0xe95f5f37, 0xbd06742c, // q = -152
  0x23b73705, 0x2c481138, // q = -151
  0x2ca504c6, 0xf75a1586, // q = -150
  0xdbe722fc, 0x9a984d73, // q = -149
  0xd2e0ebbb, 0xc13e60d0, // q = -148
  0x079926a9, 0x318df905, // q = -147
  0x497f7053, 0xfdf17746, // q = -146
  0xedefa634, 0xfeb6ea8b, // q = -145
  0xe96b8fc1, 0xfe64a52e, // q = -144
  0xa3c673b1, 0x3dfdce7a, // q = -143
  0xa65c084f, 0x06bea10c, // q = -142
  0xcff30a63, 0x486e494f, // q = -141
  0xc3efccfb, 0x5a89dba3, // q = -140
  0x5a75e01d, 0xf8962946, // q = -139
  0xf1135824, 0xf6bbb397, // q = -138
  0xed582e2d, 0x746aa07d, // q = -137
  0xb4571cdd, 0xa8c2a44e, // q = -136
  0x616ce414, 0x92f34d62, // q = -135
  0xf9c81d18, 0x77b020ba, // q = -134
  0xdc1d122f, 0x0ace1474, // q = -133
  0x132456bb, 0x0d819992, // q = -132
  0x97ed6c6a, 0x10e1fff6, // q = -131
  0x1ef463c2, 0xca8d3ffa, // q = -130
  0xa6b17cb3, 0xbd308ff8, // q = -129
  0xd05ddbdf, 0xac7cb3f6, // q = -128
  0x423aa96c, 0x6bcdf07a, // q = -127
  0xd2c953c7, 0x86c16c98, // q = -126
  0x077ba8b8, 0xe871c7bf, // q = -125
  0x64ad4973, 0x11471cd7, // q = -124
  0x3dd89bd0, 0xd598e40d, // q = -123
  0x8d4ec2c4, 0x4aff1d10, // q = -122
  0x585139bb, 0xcedf722a, // q = -121
  0xee658829, 0xc2974eb4, // q = -120
  0x29feea33, 0x733d2262, // q = -119
  0x5a3f5260, 0x0806357d, // q = -118
  0xb0cf26f8, 0xca07c2dc, // q = -117
  0xdd02f0b6, 0xfc89b393, // q = -116
  0xd443ace3, 0xbbac2078, // q = -115
  0x84aa4c0e, 0xd54b944b, // q = -114
  0x65d4df12, 0x0a9e795e, // q = -113
  0xff4a16d6, 0x4d4617b5, // q = -112
  0xbf8e4e46, 0x504bced1, // q = -111
  0x2f71e1d7, 0xe45ec286, // q = -110
  0xbb4e5a4d, 0x5d767327, // q = -109
  0xd510f870, 0x3a6a07f8, // q = -108
  0x0a55368c, 0x890489f7, // q = -107
  0xccea842f, 0x2b45ac74, // q = -106
  0x0012929e, 0x3b0b8bc9, // q = -105
  0x40173745, 0x09ce6ebb, // q = -104
  0x101d0516, 0xcc420a6a, // q = -103
  0x4a12232e, 0x9fa94682, // q = -102
  0xdc96abfa, 0x47939822, // q = -101
  0x93bc56f8, 0x59787e2b, // q = -100
  0x3c55b65b, 0x57eb4edb, // q = -99
  0x0b6b23f2, 0xede62292, // q = -98
  0x8e45ecee, 0xe95fab36, // q = -97
  0x18ebb415, 0x11dbcb02, // q = -96
  0x9f26a11a, 0xd652bdc2, // q = -95
  0x46f04960, 0x4be76d33, // q = -94
  0x0c562ddc, 0x6f70a440, // q = -93
  0x0f6bb953, 0xcb4ccd50, // q = -92
  0x1346a7a8, 0x7e2000a4, // q = -91
  0x8c0c28c9, 0x8ed40066, // q = -90
  0x2f0f32fb, 0x72890080, // q = -89
  0x3ad2ffba, 0x4f2b40a0, // q = -88
  0x4987bfa9, 0xe2f610c8, // q = -87
  0x2df4d7ca, 0x0dd9ca7d, // q = -86
  0x79720dbc, 0x91503d1c, // q = -85
  0x97ce912b, 0x75a44c63, // q = -84
  0x3ee11abb, 0xc986afbe, // q = -83
  0xce996169, 0xfbe85bad, // q = -82
  0x423fb9c4, 0xfae27299, // q = -81
  0xc967d41b, 0xdccd879f, // q = -80
  0xbbc1c921, 0x5400e987, // q = -79
  0xaab23b69, 0x290123e9, // q = -78
  0x0aaf6522, 0xf9a0b672, // q = -77
  0x8d5b3e6a, 0xf808e40e, // q = -76
  0x30b20e05, 0xb60b1d12, // q = -75
  0x5e6f48c3, 0xb1c6f22b, // q = -74
  0x360b1af4, 0x1e38aeb6, // q = -73
  0xc38de1b1, 0x25c6da63, // q = -72
  0x5a38ad0f, 0x579c487e, // q = -71
  0xf0c6d852, 0x2d835a9d, // q = -70
  0x6cf88e66, 0xf8e43145, // q = -69
  0x641b5900, 0x1b8e9ecb, // q = -68
  0x3d222f40, 0xe272467e, // q = -67
  0xcc6abb10, 0x5b0ed81d, // q = -66
  0x9fc2b4ea, 0x98e94712, // q = -65
  0x47b36225, 0x3f2398d7, // q = -64
  0x19a03aae, 0x8eec7f0d, // q = -63
  0x300424ad, 0x1953cf68, // q = -62
  0x3c052dd8, 0x5fa8c342, // q = -61
  0xcb06794e, 0x3792f412, // q = -60
  0xbee40bd1, 0xe2bbd88b, // q = -59
  0xae9d0ec5, 0x5b6aceae, // q = -58
  0x5a445276, 0xf245825a, // q = -57
  0xf0d56713, 0xeed6e2f0, // q = -56
  0x9685606c, 0x55464dd6, // q = -55
  0x3c26b887, 0xaa97e14c, // q = -54
  0x4b3066a9, 0xd53dd99f, // q = -53
  0x8efe402a, 0xe546a803, // q = -52
  0x72bdd034, 0xde985204, // q = -51
  0x8f6d4441, 0x963e6685, // q = -50
  0x79a44aa9, 0xdde70013, // q = -49
  0x580d5d53, 0x5560c018, // q = -48
  0x6e10b4a7, 0xaab8f01e, // q = -47
  0x04ca70e9, 0xcab39613, // q = -46
  0xc5fd0d23, 0x3d607b97, // q = -45
  0xb77c506b, 0x8cb89a7d, // q = -44
  0x92adb243, 0x77f3608e, // q = -43
  0x37591ed4, 0x55f038b2, // q = -42
  0xc52f6689, 0x6b6c46de, // q = -41
  0x3b3da016, 0x2323ac4b, // q = -40
  0x0a0d081b, 0xabec975e, // q = -39
  0x8c904a22, 0x96e7bd35, // q = -38
  0x77da2e55, 0x7e50d641, // q = -37
  0xd5d0b9ea, 0xdde50bd1, // q = -36
  0x4b44e865, 0x955e4ec6, // q = -35
  0xef0b113f, 0xbd5af13b, // q = -34
  0xeacdd58f, 0xecb1ad8a, // q = -33
  0xa5814af3, 0x67de18ed, // q = -32
  0x8770ced8, 0x80eacf94, // q = -31
  0xa94d028e, 0xa1258379, // q = -30
  0x13a04331, 0x096ee458, // q = -29
  0x188853fd, 0x8bca9d6e, // q = -28
  0xcf55347e, 0x775ea264, // q = -27
  0x032a819e, 0x95364afe, // q = -26
  0x83f52205, 0x3a83ddbd, // q = -25
  0x72793543, 0xc4926a96, // q = -24
  0x0f178294, 0x75b7053c, // q = -23
  0x12dd6339, 0x5324c68b, // q = -22
  0xebca5e04, 0xd3f6fc16, // q = -21
  0xa6bcf585, 0x88f4bb1c, // q = -20
  0xd06c32e6, 0x2b31e9e3, // q = -19
  0x62439fd0, 0x3aff322e, // q = -18
  0xfad487c3, 0x09befeb9, // q = -17
  0x7989a9b4, 0x4c2ebe68, // q = -16
  0x4bf60a11, 0x0f9d3701, // q = -15
  0x9ef38c95, 0x538484c1, // q = -14
  0x06b06fba, 0x2865a5f2, // q = -13
  0x442e45d4, 0xf93f87b7, // q = -12
  0x1539d749, 0xf78f69a5, // q = -11
  0x5a884d1c, 0xb573440e, // q = -10
  0xf8953031, 0x31680a88, // q = -9
  0x36ba7c3e, 0xfdc20d2b, // q = -8
  0x04691b4d, 0x3d329076, // q = -7
  0xc2c1b110, 0xa63f9a49, // q = -6
  0x33721d54, 0x0fcf80dc, // q = -5
  0x404ea4a9, 0xd3c36113, // q = -4
  0x083126ea, 0x645a1cac, // q = -3
  0x0a3d70a4, 0x3d70a3d7, // q = -2
  0xcccccccd, 0xcccccccc, // q = -1
  0x00000000, 0x00000000, // q = 0
  0x00000000, 0x00000000, // q = 1
  0x00000000, 0x00000000, // q = 2
  0x00000000, 0x00000000, // q = 3
  0x00000000, 0x00000000, // q = 4
  0x00000000, 0x00000000, // q = 5
  0x00000000, 0x00000000, // q = 6
  0x00000000, 0x00000000, // q = 7
  0x00000000, 0x00000000, // q = 8
  0x00000000, 0x00000000, // q = 9
  0x00000000, 0x00000000, // q = 10
  0x00000000, 0x00000000, // q = 11
  0x00000000, 0x00000000, // q = 12
  0x00000000, 0x00000000, // q = 13
  0x00000000, 0x00000000, // q = 14
  0x00000000, 0x00000000, // q = 15
  0x00000000, 0x00000000, // q = 16
  0x00000000, 0x00000000, // q = 17
  0x00000000, 0x00000000, // q = 18
  0x00000000, 0x00000000, // q = 19
  0x00000000, 0x00000000, // q = 20
  0x00000000, 0x00000000, // q = 21
  0x00000000, 0x00000000, // q = 22
  0x00000000, 0x00000000, // q = 23
  0x00000000, 0x00000000, // q = 24
  0x00000000, 0x00000000, // q = 25
  0x00000000, 0x00000000, // q = 26
  0x00000000, 0x00000000, // q = 27
  0x00000000, 0x40000000, // q = 28
  0x00000000, 0x50000000, // q = 29
  0x00000000, 0xa4000000, // q = 30
  0x00000000, 0x4d000000, // q = 31
  0x00000000, 0xf0200000, // q = 32
  0x00000000, 0x6c280000, // q = 33
  0x00000000, 0xc7320000, // q = 34
  0x00000000, 0x3c7f4000, // q = 35
  0x00000000, 0x4b9f1000, // q = 36
  0x00000000, 0x1e86d400, // q = 37
  0x00000000, 0x13144480, // q = 38
  0x00000000, 0x17d955a0, // q = 39
  0x00000000, 0x5dcfab08, // q = 40
  0x00000000, 0x5aa1cae5, // q = 41
  0x40000000, 0xf14a3d9e, // q = 42
  0xd0000000, 0x6d9ccd05, // q = 43
  0xa2000000, 0xe4820023, // q = 44
  0x8a800000, 0xdda2802c, // q = 45
  0xad200000, 0xd50b2037, // q = 46
  0xcc340000, 0x4526f422, // q = 47
  0x7f410000, 0x9670b12b, // q = 48
  0x5f114000, 0x3c0cdd76, // q = 49
  0xfb6ac800, 0xa5880a69, // q = 50
  0x7a457a00, 0x8eea0d04, // q = 51
  0x98d6d880, 0x72a49045, // q = 52
  0x7f864750, 0x47a6da2b, // q = 53
  0x5f67d924, 0x999090b6, // q = 54
  0xf741cf6d, 0xfff4b4e3, // q = 55
  0x7a8921a5, 0xbff8f10e, // q = 56
  0x192b6a0e, 0xaff72d52, // q = 57
  0x9f764491, 0x9bf4f8a6, // q = 58
  0x4753d5b5, 0x02f236d0, // q = 59
  0x2c946591, 0x01d76242, // q = 60
  0xb7b97ef6, 0x424d3ad2, // q = 61
  0x65a7deb3, 0xd2e08987, // q = 62
  0x9f88eb30, 0x63cc55f4, // q = 63
  0xc76b25fc, 0x3cbf6b71, // q = 64
  0x3945ef7b, 0x8bef464e, // q = 65
  0xe3cbb5ad, 0x97758bf0, // q = 66
  0x1cbea318, 0x3d52eeed, // q = 67
  0x63ee4bde, 0x4ca7aaa8, // q = 68
  0x3e74ef6b, 0x8fe8caa9, // q = 69
  0x8e122b45, 0xb3e2fd53, // q = 70
  0x7196b617, 0x60dbbca8, // q = 71
  0x46fe31ce, 0xbc8955e9, // q = 72
  0x98bdbe42, 0x6babab63, // q = 73
  0x7eed2dd2, 0xc696963c, // q = 74
  0xcf543ca3, 0xfc1e1de5, // q = 75
  0x43294bcc, 0x3b25a55f, // q = 76
  0x13f39ebf, 0x49ef0eb7, // q = 77
  0x6c784338, 0x6e356932, // q = 78
  0x07965405, 0x49c2c37f, // q = 79
  0xc97be907, 0xdc33745e, // q = 80
  0x3ded71a4, 0x69a028bb, // q = 81
  0x0d68ce0d, 0xc40832ea, // q = 82
  0x90c30191, 0xf50a3fa4, // q = 83
  0xda79e0fb, 0x792667c6, // q = 84
  0x91185939, 0x577001b8, // q = 85
  0xb55e6f87, 0xed4c0226, // q = 86
  0x315b05b5, 0x544f8158, // q = 87
  0x3db1c722, 0x696361ae, // q = 88
  0xcd1e38ea, 0x03bc3a19, // q = 89
  0x4065c724, 0x04ab48a0, // q = 90
  0x283f9c77, 0x62eb0d64, // q = 91
  0x324f8395, 0x3ba5d0bd, // q = 92
  0x7ee3647a, 0xca8f44ec, // q = 93
  0xcf4e1ecc, 0x7e998b13, // q = 94
  0xc321a67f, 0x9e3fedd8, // q = 95
  0xf3ea101f, 0xc5cfe94e, // q = 96
  0x58724a13, 0xbba1f1d1, // q = 97
  0xae8edc98, 0x2a8a6e45, // q = 98
  0x1a3293be, 0xf52d09d7, // q = 99
  0x705f9c57, 0x593c2626, // q = 100
  0x0c77836d, 0x6f8b2fb0, // q = 101
  0x0f956448, 0x0b6dfb9c, // q = 102
  0x89bd5ead, 0x4724bd41, // q = 103
  0xec2cb658, 0x58edec91, // q = 104
  0x6737e3ee, 0x2f2967b6, // q = 105
  0x0082ee75, 0xbd79e0d2, // q = 106
  0x80a3aa12, 0xecd85906, // q = 107
  0x20cc9496, 0xe80e6f48, // q = 108
  0x147fdcde, 0x3109058d, // q = 109
  0x599fd416, 0xbd4b46f0, // q = 110
  0x7007c91b, 0x6c9e18ac, // q = 111
  0xc604ddb1, 0x03e2cf6b, // q = 112
  0xb786151d, 0x84db8346, // q = 113
  0x65679a64, 0xe6126418, // q = 114
  0x3f60c07f, 0x4fcb7e8f, // q = 115
  0x0f38f09e, 0xe3be5e33, // q = 116
  0xd3072cc6, 0x5cadf5bf, // q = 117
  0xc7c8f7f7, 0x73d9732f, // q = 118
  0xdcdd9afb, 0x2867e7fd, // q = 119
  0x541501b9, 0xb281e1fd, // q = 120
  0xa91a4227, 0x1f225a7c, // q = 121
  0xe9b06959, 0x3375788d, // q = 122
  0x641c83af, 0x0052d6b1, // q = 123
  0xbd23a49b, 0xc0678c5d, // q = 124
  0x963646e1, 0xf840b7ba, // q = 125
  0x3bc3d899, 0xb650e5a9, // q = 126
  0x8ab4cebf, 0xa3e51f13, // q = 127
  0x36b10138, 0xc66f336c, // q = 128
  0x445d4185, 0xb80b0047, // q = 129
  0x157491e6, 0xa60dc059, // q = 130
  0xad68db30, 0x87c89837, // q = 131
  0x98c311fc, 0x29babe45, // q = 132
  0xfef3d67b, 0xf4296dd6, // q = 133
  0x5f58660d, 0x1899e4a6, // q = 134
  0xf72e7f90, 0x5ec05dcf, // q = 135
  0xf4fa1f74, 0x76707543, // q = 136
  0x791c53a9, 0x6a06494a, // q = 137
  0x17636893, 0x0487db9d, // q = 138
  0x5d3c42b7, 0x45a9d284, // q = 139
  0xba45a9b3, 0x0b8a2392, // q = 140
  0x68d7141f, 0x8e6cac77, // q = 141
  0x430cd927, 0x3207d795, // q = 142
  0x49e807b9, 0x7f44e6bd, // q = 143
  0x9c6209a7, 0x5f16206c, // q = 144
  0xc37a8c10, 0x36dba887, // q = 145
  0xda2c978a, 0xc2494954, // q = 146
  0x10b7bd6d, 0xf2db9baa, // q = 147
  0x94e5acc8, 0x6f928294, // q = 148
  0xba1f17fa, 0xcb772339, // q = 149
  0x14536efc, 0xff2a7604, // q = 150
  0x19684abb, 0xfef51385, // q = 151
  0x5fc25d6a, 0x7eb25866, // q = 152
  0xfbd97a62, 0xef2f773f, // q = 153
  0xfacfd8fb, 0xaafb550f, // q = 154
  0xf983cf39, 0x95ba2a53, // q = 155
  0x7bf26184, 0xdd945a74, // q = 156
  0x9aeef9e5, 0x94f97111, // q = 157
  0x01aab85e, 0x7a37cd56, // q = 158
  0xc10ab33b, 0xac62e055, // q = 159
  0x314d600a, 0x577b986b, // q = 160
  0xfda0b80c, 0xed5a7e85, // q = 161
  0xbe847308, 0x14588f13, // q = 162
  0xae258fc9, 0x596eb2d8, // q = 163
  0xd9aef3bc, 0x6fca5f8e, // q = 164
  0x480d5855, 0x25de7bb9, // q = 165
  0x9a10ae6b, 0xaf561aa7, // q = 166
  0x8094da05, 0x1b2ba151, // q = 167
  0xf05d0843, 0x90fb44d2, // q = 168
  0xac744a54, 0x353a1607, // q = 169
  0x97915ce9, 0x42889b89, // q = 170
  0xfebada12, 0x69956135, // q = 171
  0x7e699096, 0x43fab983, // q = 172
  0x5e03f4bc, 0x94f967e4, // q = 173
  0xbac278f6, 0x1d1be0ee, // q = 174
  0x69731733, 0x6462d92a, // q = 175
  0x03cfdcff, 0x7d7b8f75, // q = 176
  0x44c3d43f, 0x5cda7352, // q = 177
  0x6afa64a8, 0x3a088813, // q = 178
  0x45b8fdd1, 0x088aaa18, // q = 179
  0x57273d46, 0x8aad549e, // q = 180
  0xf678864c, 0x36ac54e2, // q = 181
  0xb416a7de, 0x84576a1b, // q = 182
  0xa11c51d6, 0x656d44a2, // q = 183
  0xa4b1b326, 0x9f644ae5, // q = 184
  0x0dde1fef, 0x873d5d9f, // q = 185
  0xd155a7eb, 0xa90cb506, // q = 186
  0x42d588f3, 0x09a7f124, // q = 187
  0x538aeb30, 0x0c11ed6d, // q = 188
  0xa86da5fb, 0x8f1668c8, // q = 189
  0x694487bd, 0xf96e017d, // q = 190
  0xc395a9ad, 0x37c981dc, // q = 191
  0xf47b1418, 0x85bbe253, // q = 192
  0x78ccec8f, 0x93956d74, // q = 193
  0x970027b3, 0x387ac8d1, // q = 194
  0xfcc0319f, 0x06997b05, // q = 195
  0xbdf81f04, 0x441fece3, // q = 196
  0xad7626c4, 0xd527e81c, // q = 197
  0xd8d3b075, 0x8a71e223, // q = 198
  0x67844e4a, 0xf6872d56, // q = 199
  0x016561dc, 0xb428f8ac, // q = 200
  0x01beba53, 0xe13336d7, // q = 201
  0x61173474, 0xecc00246, // q = 202
  0xf95d0191, 0x27f002d7, // q = 203
  0xf7b441f5, 0x31ec038d, // q = 204
  0x75a15272, 0x7e670471, // q = 205
  0xe984d387, 0x0f0062c6, // q = 206
  0xa3e60869, 0x52c07b78, // q = 207
  0xccdf8a83, 0xa7709a56, // q = 208
  0x400bb692, 0x88a66076, // q = 209
  0xd00ea436, 0x6acff893, // q = 210
  0xc4124d44, 0x0583f6b8, // q = 211
  0x7a8b704b, 0xc3727a33, // q = 212
  0x592e4c5d, 0x744f18c0, // q = 213
  0x6f79df74, 0x1162def0, // q = 214
  0x45ac2ba9, 0x8addcb56, // q = 215
  0xd7173693, 0x6d953e2b, // q = 216
  0xccdd0438, 0xc8fa8db6, // q = 217
  0x400a22a3, 0x1d9c9892, // q = 218
  0xd00cab4c, 0x2503beb6, // q = 219
  0x840fd61e, 0x2e44ae64, // q = 220
  0xd289e5d3, 0x5ceaecfe, // q = 221
  0x872c5f48, 0x7425a83e, // q = 222
  0x28f7771a, 0xd12f124e, // q = 223
  0xd99aaa70, 0x82bd6b70, // q = 224
  0x1001550c, 0x636cc64d, // q = 225
  0x5401aa4f, 0x3c47f7e0, // q = 226
  0x34810a72, 0x65acfaec, // q = 227
  0x41a14d0e, 0x7f1839a7, // q = 228
  0x1209a051, 0x1ede4811, // q = 229
  0xab460433, 0x934aed0a, // q = 230
  0x56178540, 0xf81da84d, // q = 231
  0xab9d668f, 0x36251260, // q = 232
  0x6b42601a, 0xc1d72b7c, // q = 233
  0x8612f820, 0xb24cf65b, // q = 234
  0x6797b628, 0xdee033f2, // q = 235
  0x017da3b2, 0x169840ef, // q = 236
  0x60ee864f, 0x8e1f2895, // q = 237
  0xb92a27e3, 0xf1a6f2ba, // q = 238
  0x6774b1dc, 0xae10af69, // q = 239
  0xe0a8ef2a, 0xacca6da1, // q = 240
  0x58d32af4, 0x17fd090a, // q = 241
  0xef07f5b1, 0xddfc4b4c, // q = 242
  0x1564f98f, 0x4abdaf10, // q = 243
  0x1abe37f2, 0x9d6d1ad4, // q = 244
  0x216dc5ee, 0x84c86189, // q = 245
  0xb4e49bb5, 0x32fd3cf5, // q = 246
  0x221dc2a2, 0x3fbc8c33, // q = 247
  0xeaa5334b, 0x0fabaf3f, // q = 248
  0xf2a7400f, 0x29cb4d87, // q = 249
  0xef511013, 0x743e20e9, // q = 250
  0x6b255417, 0x914da924, // q = 251
  0xc2f7548f, 0x1ad089b6, // q = 252
  0x73b529b2, 0xa184ac24, // q = 253
  0x90a2741f, 0xc9e5d72d, // q = 254
  0x7a658893, 0x7e2fa67c, // q = 255
  0x98feeab8, 0xddbb901b, // q = 256
  0x7f3ea566, 0x552a7422, // q = 257
  0x8f872760, 0xd53a8895, // q = 258
  0xf368f138, 0x8a892aba, // q = 259
  0xb0432d86, 0x2d2b7569, // q = 260
  0x0e29fc74, 0x9c3b2962, // q = 261
  0x91b47b90, 0x8349f3ba, // q = 262
  0x36219a74, 0x241c70a9, // q = 263
  0x83aa0111, 0xed238cd3, // q = 264
  0x324a40ab, 0xf4363804, // q = 265
  0x3edcd0d6, 0xb143c605, // q = 266
  0x8e94050b, 0xdd94b786, // q = 267
  0x191c8327, 0xca7cf2b4, // q = 268
  0x1f63a3f1, 0xfd1c2f61, // q = 269
  0x673c8ced, 0xbc633b39, // q = 270
  0xe085d814, 0xd5be0503, // q = 271
  0xd8a74e19, 0x4b2d8644, // q = 272
  0x0ed1219f, 0xddf8e7d6, // q = 273
  0xc942b504, 0xcabb90e5, // q = 274
  0x3b936244, 0x3d6a751f, // q = 275
  0x0a783ad5, 0x0cc51267, // q = 276
  0x668b24c6, 0x27fb2b80, // q = 277
  0x802dedf7, 0xb1f9f660, // q = 278
  0xa0396974, 0x5e7873f8, // q = 279
  0x6423e1e9, 0xdb0b487b, // q = 280
  0x3d2cda63, 0x91ce1a9a, // q = 281
  0xcc7810fc, 0x7641a140, // q = 282
  0x7fcb0a9e, 0xa9e904c8, // q = 283
  0x9fbdcd45, 0x546345fa, // q = 284
  0x47ad4096, 0xa97c1779, // q = 285
  0xcccc485e, 0x49ed8eab, // q = 286
  0xbfff5a75, 0x5c68f256, // q = 287
  0x6fff3112, 0x73832eec, // q = 288
  0xc5ff7eac, 0xc831fd53, // q = 289
  0xb77f5e56, 0xba3e7ca8, // q = 290
  0xe55f35ec, 0x28ce1bd2, // q = 291
  0xcf5b81b4, 0x7980d163, // q = 292
  0xc3326220, 0xd7e105bc, // q = 293
  0xf3fefaa8, 0x8dd9472b, // q = 294
  0xf0feb952, 0xb14f98f6, // q = 295
  0x569f33d4, 0x6ed1bf9a, // q = 296
  0xec4700c9, 0x0a862f80, // q = 297
  0x2758c0fb, 0xcd27bb61, // q = 298
  0xb897789d, 0x8038d51c, // q = 299
  0xe6bd56c4, 0xe0470a63, // q = 300
  0xe06cac75, 0x1858ccfc, // q = 301
  0x0c43ebc9, 0x0f37801e, // q = 302
  0x8f54e6bb, 0xd3056025, // q = 303
  0xf32a206a, 0x47c6b82e, // q = 304
  0x57fa5442, 0x4cdc331d, // q = 305
  0xadf8e953, 0xe0133fe4, // q = 306
  0xd97723a7, 0x58180fdd, // q = 307
  0xa7ea7649, 0x570f09ea, // q = 308
];

final Int64List? _power10_H = _initInt64From32(_power10_H_32);
final Int64List? _power10_L = _initInt64From32(_power10_L_32);

final Int32List _power10_Exp = Int32List.fromList(const <int>[
  -1136, // q = -342
  -1132, // q = -341
  -1129, // q = -340
  -1126, // q = -339
  -1122, // q = -338
  -1119, // q = -337
  -1116, // q = -336
  -1112, // q = -335
  -1109, // q = -334
  -1106, // q = -333
  -1102, // q = -332
  -1099, // q = -331
  -1096, // q = -330
  -1092, // q = -329
  -1089, // q = -328
  -1086, // q = -327
  -1082, // q = -326
  -1079, // q = -325
  -1076, // q = -324
  -1072, // q = -323
  -1069, // q = -322
  -1066, // q = -321
  -1063, // q = -320
  -1059, // q = -319
  -1056, // q = -318
  -1053, // q = -317
  -1049, // q = -316
  -1046, // q = -315
  -1043, // q = -314
  -1039, // q = -313
  -1036, // q = -312
  -1033, // q = -311
  -1029, // q = -310
  -1026, // q = -309
  -1023, // q = -308
  -1019, // q = -307
  -1016, // q = -306
  -1013, // q = -305
  -1009, // q = -304
  -1006, // q = -303
  -1003, // q = -302
  -999, // q = -301
  -996, // q = -300
  -993, // q = -299
  -989, // q = -298
  -986, // q = -297
  -983, // q = -296
  -979, // q = -295
  -976, // q = -294
  -973, // q = -293
  -970, // q = -292
  -966, // q = -291
  -963, // q = -290
  -960, // q = -289
  -956, // q = -288
  -953, // q = -287
  -950, // q = -286
  -946, // q = -285
  -943, // q = -284
  -940, // q = -283
  -936, // q = -282
  -933, // q = -281
  -930, // q = -280
  -926, // q = -279
  -923, // q = -278
  -920, // q = -277
  -916, // q = -276
  -913, // q = -275
  -910, // q = -274
  -906, // q = -273
  -903, // q = -272
  -900, // q = -271
  -896, // q = -270
  -893, // q = -269
  -890, // q = -268
  -886, // q = -267
  -883, // q = -266
  -880, // q = -265
  -876, // q = -264
  -873, // q = -263
  -870, // q = -262
  -867, // q = -261
  -863, // q = -260
  -860, // q = -259
  -857, // q = -258
  -853, // q = -257
  -850, // q = -256
  -847, // q = -255
  -843, // q = -254
  -840, // q = -253
  -837, // q = -252
  -833, // q = -251
  -830, // q = -250
  -827, // q = -249
  -823, // q = -248
  -820, // q = -247
  -817, // q = -246
  -813, // q = -245
  -810, // q = -244
  -807, // q = -243
  -803, // q = -242
  -800, // q = -241
  -797, // q = -240
  -793, // q = -239
  -790, // q = -238
  -787, // q = -237
  -783, // q = -236
  -780, // q = -235
  -777, // q = -234
  -774, // q = -233
  -770, // q = -232
  -767, // q = -231
  -764, // q = -230
  -760, // q = -229
  -757, // q = -228
  -754, // q = -227
  -750, // q = -226
  -747, // q = -225
  -744, // q = -224
  -740, // q = -223
  -737, // q = -222
  -734, // q = -221
  -730, // q = -220
  -727, // q = -219
  -724, // q = -218
  -720, // q = -217
  -717, // q = -216
  -714, // q = -215
  -710, // q = -214
  -707, // q = -213
  -704, // q = -212
  -700, // q = -211
  -697, // q = -210
  -694, // q = -209
  -690, // q = -208
  -687, // q = -207
  -684, // q = -206
  -680, // q = -205
  -677, // q = -204
  -674, // q = -203
  -671, // q = -202
  -667, // q = -201
  -664, // q = -200
  -661, // q = -199
  -657, // q = -198
  -654, // q = -197
  -651, // q = -196
  -647, // q = -195
  -644, // q = -194
  -641, // q = -193
  -637, // q = -192
  -634, // q = -191
  -631, // q = -190
  -627, // q = -189
  -624, // q = -188
  -621, // q = -187
  -617, // q = -186
  -614, // q = -185
  -611, // q = -184
  -607, // q = -183
  -604, // q = -182
  -601, // q = -181
  -597, // q = -180
  -594, // q = -179
  -591, // q = -178
  -587, // q = -177
  -584, // q = -176
  -581, // q = -175
  -578, // q = -174
  -574, // q = -173
  -571, // q = -172
  -568, // q = -171
  -564, // q = -170
  -561, // q = -169
  -558, // q = -168
  -554, // q = -167
  -551, // q = -166
  -548, // q = -165
  -544, // q = -164
  -541, // q = -163
  -538, // q = -162
  -534, // q = -161
  -531, // q = -160
  -528, // q = -159
  -524, // q = -158
  -521, // q = -157
  -518, // q = -156
  -514, // q = -155
  -511, // q = -154
  -508, // q = -153
  -504, // q = -152
  -501, // q = -151
  -498, // q = -150
  -494, // q = -149
  -491, // q = -148
  -488, // q = -147
  -485, // q = -146
  -481, // q = -145
  -478, // q = -144
  -475, // q = -143
  -471, // q = -142
  -468, // q = -141
  -465, // q = -140
  -461, // q = -139
  -458, // q = -138
  -455, // q = -137
  -451, // q = -136
  -448, // q = -135
  -445, // q = -134
  -441, // q = -133
  -438, // q = -132
  -435, // q = -131
  -431, // q = -130
  -428, // q = -129
  -425, // q = -128
  -421, // q = -127
  -418, // q = -126
  -415, // q = -125
  -411, // q = -124
  -408, // q = -123
  -405, // q = -122
  -401, // q = -121
  -398, // q = -120
  -395, // q = -119
  -391, // q = -118
  -388, // q = -117
  -385, // q = -116
  -382, // q = -115
  -378, // q = -114
  -375, // q = -113
  -372, // q = -112
  -368, // q = -111
  -365, // q = -110
  -362, // q = -109
  -358, // q = -108
  -355, // q = -107
  -352, // q = -106
  -348, // q = -105
  -345, // q = -104
  -342, // q = -103
  -338, // q = -102
  -335, // q = -101
  -332, // q = -100
  -328, // q = -99
  -325, // q = -98
  -322, // q = -97
  -318, // q = -96
  -315, // q = -95
  -312, // q = -94
  -308, // q = -93
  -305, // q = -92
  -302, // q = -91
  -298, // q = -90
  -295, // q = -89
  -292, // q = -88
  -289, // q = -87
  -285, // q = -86
  -282, // q = -85
  -279, // q = -84
  -275, // q = -83
  -272, // q = -82
  -269, // q = -81
  -265, // q = -80
  -262, // q = -79
  -259, // q = -78
  -255, // q = -77
  -252, // q = -76
  -249, // q = -75
  -245, // q = -74
  -242, // q = -73
  -239, // q = -72
  -235, // q = -71
  -232, // q = -70
  -229, // q = -69
  -225, // q = -68
  -222, // q = -67
  -219, // q = -66
  -215, // q = -65
  -212, // q = -64
  -209, // q = -63
  -205, // q = -62
  -202, // q = -61
  -199, // q = -60
  -195, // q = -59
  -192, // q = -58
  -189, // q = -57
  -186, // q = -56
  -182, // q = -55
  -179, // q = -54
  -176, // q = -53
  -172, // q = -52
  -169, // q = -51
  -166, // q = -50
  -162, // q = -49
  -159, // q = -48
  -156, // q = -47
  -152, // q = -46
  -149, // q = -45
  -146, // q = -44
  -142, // q = -43
  -139, // q = -42
  -136, // q = -41
  -132, // q = -40
  -129, // q = -39
  -126, // q = -38
  -122, // q = -37
  -119, // q = -36
  -116, // q = -35
  -112, // q = -34
  -109, // q = -33
  -106, // q = -32
  -102, // q = -31
  -99, // q = -30
  -96, // q = -29
  -93, // q = -28
  -89, // q = -27
  -86, // q = -26
  -83, // q = -25
  -79, // q = -24
  -76, // q = -23
  -73, // q = -22
  -69, // q = -21
  -66, // q = -20
  -63, // q = -19
  -59, // q = -18
  -56, // q = -17
  -53, // q = -16
  -49, // q = -15
  -46, // q = -14
  -43, // q = -13
  -39, // q = -12
  -36, // q = -11
  -33, // q = -10
  -29, // q = -9
  -26, // q = -8
  -23, // q = -7
  -19, // q = -6
  -16, // q = -5
  -13, // q = -4
  -9, // q = -3
  -6, // q = -2
  -3, // q = -1
  1, // q = 0
  4, // q = 1
  7, // q = 2
  10, // q = 3
  14, // q = 4
  17, // q = 5
  20, // q = 6
  24, // q = 7
  27, // q = 8
  30, // q = 9
  34, // q = 10
  37, // q = 11
  40, // q = 12
  44, // q = 13
  47, // q = 14
  50, // q = 15
  54, // q = 16
  57, // q = 17
  60, // q = 18
  64, // q = 19
  67, // q = 20
  70, // q = 21
  74, // q = 22
  77, // q = 23
  80, // q = 24
  84, // q = 25
  87, // q = 26
  90, // q = 27
  94, // q = 28
  97, // q = 29
  100, // q = 30
  103, // q = 31
  107, // q = 32
  110, // q = 33
  113, // q = 34
  117, // q = 35
  120, // q = 36
  123, // q = 37
  127, // q = 38
  130, // q = 39
  133, // q = 40
  137, // q = 41
  140, // q = 42
  143, // q = 43
  147, // q = 44
  150, // q = 45
  153, // q = 46
  157, // q = 47
  160, // q = 48
  163, // q = 49
  167, // q = 50
  170, // q = 51
  173, // q = 52
  177, // q = 53
  180, // q = 54
  183, // q = 55
  187, // q = 56
  190, // q = 57
  193, // q = 58
  196, // q = 59
  200, // q = 60
  203, // q = 61
  206, // q = 62
  210, // q = 63
  213, // q = 64
  216, // q = 65
  220, // q = 66
  223, // q = 67
  226, // q = 68
  230, // q = 69
  233, // q = 70
  236, // q = 71
  240, // q = 72
  243, // q = 73
  246, // q = 74
  250, // q = 75
  253, // q = 76
  256, // q = 77
  260, // q = 78
  263, // q = 79
  266, // q = 80
  270, // q = 81
  273, // q = 82
  276, // q = 83
  280, // q = 84
  283, // q = 85
  286, // q = 86
  290, // q = 87
  293, // q = 88
  296, // q = 89
  299, // q = 90
  303, // q = 91
  306, // q = 92
  309, // q = 93
  313, // q = 94
  316, // q = 95
  319, // q = 96
  323, // q = 97
  326, // q = 98
  329, // q = 99
  333, // q = 100
  336, // q = 101
  339, // q = 102
  343, // q = 103
  346, // q = 104
  349, // q = 105
  353, // q = 106
  356, // q = 107
  359, // q = 108
  363, // q = 109
  366, // q = 110
  369, // q = 111
  373, // q = 112
  376, // q = 113
  379, // q = 114
  383, // q = 115
  386, // q = 116
  389, // q = 117
  392, // q = 118
  396, // q = 119
  399, // q = 120
  402, // q = 121
  406, // q = 122
  409, // q = 123
  412, // q = 124
  416, // q = 125
  419, // q = 126
  422, // q = 127
  426, // q = 128
  429, // q = 129
  432, // q = 130
  436, // q = 131
  439, // q = 132
  442, // q = 133
  446, // q = 134
  449, // q = 135
  452, // q = 136
  456, // q = 137
  459, // q = 138
  462, // q = 139
  466, // q = 140
  469, // q = 141
  472, // q = 142
  476, // q = 143
  479, // q = 144
  482, // q = 145
  486, // q = 146
  489, // q = 147
  492, // q = 148
  495, // q = 149
  499, // q = 150
  502, // q = 151
  505, // q = 152
  509, // q = 153
  512, // q = 154
  515, // q = 155
  519, // q = 156
  522, // q = 157
  525, // q = 158
  529, // q = 159
  532, // q = 160
  535, // q = 161
  539, // q = 162
  542, // q = 163
  545, // q = 164
  549, // q = 165
  552, // q = 166
  555, // q = 167
  559, // q = 168
  562, // q = 169
  565, // q = 170
  569, // q = 171
  572, // q = 172
  575, // q = 173
  579, // q = 174
  582, // q = 175
  585, // q = 176
  588, // q = 177
  592, // q = 178
  595, // q = 179
  598, // q = 180
  602, // q = 181
  605, // q = 182
  608, // q = 183
  612, // q = 184
  615, // q = 185
  618, // q = 186
  622, // q = 187
  625, // q = 188
  628, // q = 189
  632, // q = 190
  635, // q = 191
  638, // q = 192
  642, // q = 193
  645, // q = 194
  648, // q = 195
  652, // q = 196
  655, // q = 197
  658, // q = 198
  662, // q = 199
  665, // q = 200
  668, // q = 201
  672, // q = 202
  675, // q = 203
  678, // q = 204
  681, // q = 205
  685, // q = 206
  688, // q = 207
  691, // q = 208
  695, // q = 209
  698, // q = 210
  701, // q = 211
  705, // q = 212
  708, // q = 213
  711, // q = 214
  715, // q = 215
  718, // q = 216
  721, // q = 217
  725, // q = 218
  728, // q = 219
  731, // q = 220
  735, // q = 221
  738, // q = 222
  741, // q = 223
  745, // q = 224
  748, // q = 225
  751, // q = 226
  755, // q = 227
  758, // q = 228
  761, // q = 229
  765, // q = 230
  768, // q = 231
  771, // q = 232
  775, // q = 233
  778, // q = 234
  781, // q = 235
  784, // q = 236
  788, // q = 237
  791, // q = 238
  794, // q = 239
  798, // q = 240
  801, // q = 241
  804, // q = 242
  808, // q = 243
  811, // q = 244
  814, // q = 245
  818, // q = 246
  821, // q = 247
  824, // q = 248
  828, // q = 249
  831, // q = 250
  834, // q = 251
  838, // q = 252
  841, // q = 253
  844, // q = 254
  848, // q = 255
  851, // q = 256
  854, // q = 257
  858, // q = 258
  861, // q = 259
  864, // q = 260
  868, // q = 261
  871, // q = 262
  874, // q = 263
  877, // q = 264
  881, // q = 265
  884, // q = 266
  887, // q = 267
  891, // q = 268
  894, // q = 269
  897, // q = 270
  901, // q = 271
  904, // q = 272
  907, // q = 273
  911, // q = 274
  914, // q = 275
  917, // q = 276
  921, // q = 277
  924, // q = 278
  927, // q = 279
  931, // q = 280
  934, // q = 281
  937, // q = 282
  941, // q = 283
  944, // q = 284
  947, // q = 285
  951, // q = 286
  954, // q = 287
  957, // q = 288
  961, // q = 289
  964, // q = 290
  967, // q = 291
  971, // q = 292
  974, // q = 293
  977, // q = 294
  980, // q = 295
  984, // q = 296
  987, // q = 297
  990, // q = 298
  994, // q = 299
  997, // q = 300
  1000, // q = 301
  1004, // q = 302
  1007, // q = 303
  1010, // q = 304
  1014, // q = 305
  1017, // q = 306
  1020, // q = 307
  1024, // q = 308
]);

// Unsigned 64-bit comparisons.
//
// On the VM and Wasm `int` is a signed 64-bit integer, so a mantissa that has
// wrapped past 2^63 compares as negative; flipping the sign bit restores
// unsigned ordering. On the web `int` is a double and bitwise operators are
// evaluated with 32-bit semantics: `x ^ 0x8000000000000000` truncates its
// operands to 32 bits and yields `ToUint32(x)`, so the sign trick silently
// compares the low 32 bits of each side. Web values reaching these helpers are
// non-negative doubles, so a plain comparison is both correct and exact there.

@pragma('vm:prefer-inline')
bool _unsignedLe(int a, int b) => identical(1, 1.0)
    ? a <= b
    : (a ^ 0x8000000000000000) <= (b ^ 0x8000000000000000);

@pragma('vm:prefer-inline')
bool _unsignedLt(int a, int b) => identical(1, 1.0)
    ? a < b
    : (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000);

@pragma('vm:prefer-inline')
int _clz64(int w) {
  if (w < 0) return 0;
  if (w == 0) return 64;
  return 64 - w.bitLength;
}

@pragma('vm:prefer-inline')
int _mul64x64High(int a, int b) {
  final aLo = a & 0xFFFFFFFF;
  final aHi = a >>> 32;
  final bLo = b & 0xFFFFFFFF;
  final bHi = b >>> 32;

  final p0 = aLo * bLo;
  final p1 = aLo * bHi;
  final p2 = aHi * bLo;
  final p3 = aHi * bHi;

  final cy0 = (p0 >>> 32) + (p1 & 0xFFFFFFFF) + (p2 & 0xFFFFFFFF);
  return p3 + (p1 >>> 32) + (p2 >>> 32) + (cy0 >>> 32);
}

final ByteData _sharedFloat64Buffer = ByteData(8);

@pragma('vm:prefer-inline')
double _doubleFromBits(int bits) {
  _sharedFloat64Buffer.setInt64(0, bits, Endian.host);
  return _sharedFloat64Buffer.getFloat64(0, Endian.host);
}

@pragma('vm:prefer-inline')
double? _tryParseDoubleFastEiselLemire(
  int mantissa,
  int decimalExp,
  bool isNegative,
) {
  // 1. Zero mantissa fast path (preserves -0.0)
  if (mantissa == 0) {
    return isNegative ? -0.0 : 0.0;
  }

  // 2. Exponent-zero integer bypass (exact up to 53 bits: 9007199254740991)
  if (decimalExp == 0 && _unsignedLe(mantissa, 0x001FFFFFFFFFFFFF)) {
    return isNegative ? -mantissa.toDouble() : mantissa.toDouble();
  }

  // Range of exponents supported by the power-of-10 table
  if (decimalExp < -342 || decimalExp > 308 || identical(1, 1.0)) {
    return null;
  }

  final power10_H = _power10_H;
  final power10_L = _power10_L;
  if (power10_H == null || power10_L == null) return null;

  final qIndex = decimalExp + 342;

  // Normalize mantissa to have MSB at bit 63
  final lz = _clz64(mantissa);
  final normMantissa = mantissa << lz;

  // 192-bit full multiplication: normMantissa * (H_q * 2^64 + L_q)
  final p1Hi = _mul64x64High(normMantissa, power10_L[qIndex]);

  final aLo = normMantissa & 0xFFFFFFFF;
  final aHi = normMantissa >>> 32;
  final bLo = power10_H[qIndex] & 0xFFFFFFFF;
  final bHi = power10_H[qIndex] >>> 32;

  final p0 = aLo * bLo;
  final p1 = aLo * bHi;
  final p2 = aHi * bLo;
  final p3 = aHi * bHi;

  final cy0 = (p0 >>> 32) + (p1 & 0xFFFFFFFF) + (p2 & 0xFFFFFFFF);
  final p2Lo = (p0 & 0xFFFFFFFF) | ((cy0 & 0xFFFFFFFF) << 32);
  var p2Hi = p3 + (p1 >>> 32) + (p2 >>> 32) + (cy0 >>> 32);

  final lo = p2Lo + p1Hi;
  if (_unsignedLt(lo, p1Hi)) {
    p2Hi++;
  }
  var hi = p2Hi;

  // Since normMantissa >= 2^63 and H_q >= 2^63,
  // the product >= 2^190, so hi is either 63-bit or 64-bit.
  // If bit 63 of hi is 0 (hi < 2^63), shift left by 1.
  final isBit63Set = (hi & 0x8000000000000000) != 0;
  var finalShift = 0;
  if (!isBit63Set) {
    hi = (hi << 1) | (lo >>> 63);
    finalShift = 1;
  }
  final shiftedLo = isBit63Set ? lo : (lo << 1);

  // Binary exponent
  final biasedExp = _power10_Exp[qIndex] - lz - finalShift + 1023 + 63;
  if (biasedExp <= 0 || biasedExp >= 2047) {
    return null; // subnormal or overflow -> fallback
  }

  // Error bounds check for exact round-to-nearest
  final low11 = hi & 0x7FF;
  if (low11 == 0x3FF) {
    final loPlusErr = shiftedLo + 1;
    if (_unsignedLt(loPlusErr, shiftedLo)) {
      return null;
    }
  } else if (low11 == 0x400) {
    if (shiftedLo == 0) {
      return null;
    }
  }

  // Round to nearest, ties to even
  var mantissaBits = hi + 0x400;
  var finalExp = biasedExp;
  if (_unsignedLt(mantissaBits, hi)) {
    mantissaBits = (mantissaBits >>> 1) | 0x8000000000000000;
    finalExp++;
    if (finalExp >= 2047) return null;
  }

  // No ties-to-even adjustment is needed here: an exact halfway case is
  // `low11 == 0x400 && shiftedLo == 0`, which the ambiguity check above has
  // already rejected with `null` so that the correctly rounding fallback
  // parser handles it.

  final fractionBits = (mantissaBits >>> 11) & 0x000FFFFFFFFFFFFF;
  final signBit = isNegative ? 0x8000000000000000 : 0;
  final floatBits = signBit | (finalExp << 52) | fractionBits;

  return _doubleFromBits(floatBits);
}

double? _tryParseDoubleUtf8(
  Uint8List source,
  int start,
  int end, {
  bool allowFallback = true,
}) {
  if (start >= end || start < 0 || end > source.length) return null;

  var i = start;
  while (i < end &&
      (source[i] == 0x20 ||
          source[i] == 0x09 ||
          source[i] == 0x0A ||
          source[i] == 0x0D)) {
    i++;
  }
  if (i >= end) return null;

  var actualEnd = end;
  while (actualEnd > i &&
      (source[actualEnd - 1] == 0x20 ||
          source[actualEnd - 1] == 0x09 ||
          source[actualEnd - 1] == 0x0A ||
          source[actualEnd - 1] == 0x0D)) {
    actualEnd--;
  }
  if (i >= actualEnd) return null;

  final sliceStart = i;
  var isNegative = false;
  if (source[i] == 45) {
    // '-'
    isNegative = true;
    i++;
    if (i >= actualEnd) return null;
  }

  int mantissa = 0;
  int digitCount = 0;
  int decimalExp = 0;
  bool truncatedDigits = false;

  // Integer part:
  if (source[i] == 48) {
    // '0'
    i++;
    // Leading zero cannot be followed by another digit
    if (i < actualEnd && source[i] >= 48 && source[i] <= 57) {
      return null;
    }
  } else if (source[i] >= 49 && source[i] <= 57) {
    // '1'..'9'
    while (i < actualEnd && source[i] >= 48 && source[i] <= 57) {
      if (digitCount < 19) {
        mantissa = mantissa * 10 + (source[i] - 48);
        digitCount++;
      } else {
        truncatedDigits = true;
        decimalExp++;
      }
      i++;
    }
  } else {
    return null;
  }

  // Fraction part (optional):
  if (i < actualEnd && source[i] == 46) {
    // '.'
    i++;
    if (i >= actualEnd || source[i] < 48 || source[i] > 57) {
      return null;
    }
    while (i < actualEnd && source[i] >= 48 && source[i] <= 57) {
      if (mantissa == 0 && source[i] == 48) {
        decimalExp--;
      } else if (digitCount < 19) {
        mantissa = mantissa * 10 + (source[i] - 48);
        digitCount++;
        decimalExp--;
      } else {
        truncatedDigits = true;
      }
      i++;
    }
  }

  // Exponent part (optional):
  if (i < actualEnd && (source[i] == 101 || source[i] == 69)) {
    // 'e' or 'E'
    i++;
    var expNegative = false;
    if (i < actualEnd && (source[i] == 43 || source[i] == 45)) {
      // '+' or '-'
      if (source[i] == 45) expNegative = true;
      i++;
    }
    if (i >= actualEnd || source[i] < 48 || source[i] > 57) {
      return null;
    }
    var explicitExp = 0;
    var expSaturated = false;
    while (i < actualEnd && source[i] >= 48 && source[i] <= 57) {
      if (explicitExp < 10000) {
        explicitExp = explicitExp * 10 + (source[i] - 48);
      } else {
        expSaturated = true;
      }
      i++;
    }
    decimalExp += expNegative ? -explicitExp : explicitExp;
    if (expSaturated) {
      // See the matching note in _JsonTokenReader.readDouble: a truncated
      // exponent can be cancelled back into range by the mantissa digit
      // count, so pin it outside the Eisel-Lemire window instead.
      decimalExp = expNegative ? -100000 : 100000;
    }
  }

  if (i != actualEnd) return null;

  // Zero mantissa fast path (preserves -0.0)
  if (mantissa == 0) {
    return isNegative ? -0.0 : 0.0;
  }

  // Exponent-zero integer bypass (exact up to 53 bits)
  if (decimalExp == 0 &&
      !truncatedDigits &&
      _unsignedLe(mantissa, 0x001FFFFFFFFFFFFF)) {
    return isNegative ? -mantissa.toDouble() : mantissa.toDouble();
  }

  // Eisel-Lemire 64-bit float parser
  var result = _tryParseDoubleFastEiselLemire(mantissa, decimalExp, isNegative);
  if (result != null && truncatedDigits) {
    final resultPlus1 = _tryParseDoubleFastEiselLemire(
      mantissa + 1,
      decimalExp,
      isNegative,
    );
    if (resultPlus1 != result) {
      result = null;
    }
  }
  if (result != null) return result;

  if (!allowFallback) return null;

  // Fallback to exact platform float parser
  return double.tryParse(String.fromCharCodes(source, sliceStart, actualEnd));
}

const List<int> _maxInt64Digits = [
  57,
  50,
  50,
  51,
  51,
  55,
  50,
  48,
  51,
  54,
  56,
  53,
  52,
  55,
  55,
  53,
  56,
  48,
  55,
]; // '9223372036854775807'
const List<int> _minInt64Digits = [
  57,
  50,
  50,
  51,
  51,
  55,
  50,
  48,
  51,
  54,
  56,
  53,
  52,
  55,
  55,
  53,
  56,
  48,
  56,
]; // '9223372036854775808'

int? _tryParseIntUtf8(Uint8List source, int start, int end) {
  if (start >= end || start < 0 || end > source.length) return null;

  var i = start;
  while (i < end &&
      (source[i] == 0x20 ||
          source[i] == 0x09 ||
          source[i] == 0x0A ||
          source[i] == 0x0D)) {
    i++;
  }
  if (i >= end) return null;

  var actualEnd = end;
  while (actualEnd > i &&
      (source[actualEnd - 1] == 0x20 ||
          source[actualEnd - 1] == 0x09 ||
          source[actualEnd - 1] == 0x0A ||
          source[actualEnd - 1] == 0x0D)) {
    actualEnd--;
  }
  if (i >= actualEnd) return null;

  var negative = false;
  if (source[i] == 45) {
    // '-'
    negative = true;
    i++;
    if (i >= actualEnd) return null;
  }

  // Integer part:
  if (source[i] == 48) {
    // '0'
    i++;
    // Leading zero cannot be followed by another digit
    if (i < actualEnd) return null;
    return 0;
  }

  if (source[i] < 49 || source[i] > 57) {
    // '1'..'9'
    return null;
  }

  final digitsStart = i;
  while (i < actualEnd) {
    final byte = source[i];
    if (byte < 48 || byte > 57) return null;
    i++;
  }

  final numDigits = actualEnd - digitsStart;
  if (numDigits > 19) return null;
  if (numDigits == 19) {
    final limit = negative ? _minInt64Digits : _maxInt64Digits;
    for (var k = 0; k < 19; k++) {
      final d = source[digitsStart + k];
      final lim = limit[k];
      if (d < lim) break;
      if (d > lim) return null;
    }
  }

  if (identical(1, 1.0) && numDigits >= 16) {
    final d = _tryParseDoubleUtf8(source, start, end);
    return d?.toInt();
  }

  int value = 0;
  for (var k = digitsStart; k < actualEnd; k++) {
    value = value * 10 - (source[k] - 48);
  }
  return negative ? value : -value;
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
bool? _tryParseBoolUtf8(Uint8List source, int start, int end) {
  final len = end - start;
  if (start < 0 || end > source.length || len < 4 || len > 5) return null;

  if (len == 4 &&
      source[start] == 116 &&
      source[start + 1] == 114 &&
      source[start + 2] == 117 &&
      source[start + 3] == 101) {
    return true;
  }
  if (len == 5 &&
      source[start] == 102 &&
      source[start + 1] == 97 &&
      source[start + 2] == 108 &&
      source[start + 3] == 115 &&
      source[start + 4] == 101) {
    return false;
  }
  return null;
}

bool _equalsAsciiUtf8(
  Uint8List source,
  int start,
  int end,
  String asciiString,
) {
  if (start < 0 || end > source.length || end - start != asciiString.length) {
    return false;
  }
  for (var i = 0; i < asciiString.length; i++) {
    final c = asciiString.codeUnitAt(i);
    if (c > 0x7F || source[start + i] != c) return false;
  }
  return true;
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
bool _isNullUtf8(Uint8List source, int start, int end) {
  return (end - start == 4) &&
      start >= 0 &&
      end <= source.length &&
      source[start] == 110 &&
      source[start + 1] == 117 &&
      source[start + 2] == 108 &&
      source[start + 3] == 108;
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
bool _isVerbatimUtf8(Uint8List source, int start, int end) {
  if (start < 0 || end > source.length || start > end) return false;
  for (var i = start; i < end; i++) {
    final b = source[i];
    if (b < 0x20 || b > 0x7E || b == 0x22 || b == 0x5C) {
      return false; // Non-ASCII, control char, quote, or backslash
    }
  }
  return true;
}

const _utf8DecoderStrict = Utf8Decoder(allowMalformed: false);
const _utf8DecoderMalformed = Utf8Decoder(allowMalformed: true);

@pragma('vm:prefer-inline')
Utf8Decoder _getUtf8Decoder(bool allowMalformed) =>
    allowMalformed ? _utf8DecoderMalformed : _utf8DecoderStrict;

String _decodeStringUtf8(
  Uint8List source,
  int start,
  int end, {
  bool allowMalformed = false,
}) {
  if (start < 0 || end > source.length || start > end) {
    throw RangeError('Invalid byte span [$start, $end)');
  }
  if (start == end) return '';
  var maxByte = 0;
  var hasBackslash = false;
  for (var i = start; i < end; i++) {
    final b = source[i];
    if (b < 0x20) {
      throw FormatException(
        'Unescaped control character in string literal at offset $i',
        source,
        i,
      );
    }
    maxByte |= b;
    if (b == 92) {
      hasBackslash = true;
      break;
    }
  }

  if (!hasBackslash) {
    if (maxByte <= 0x7F) {
      return String.fromCharCodes(source, start, end);
    }
    return _getUtf8Decoder(allowMalformed).convert(source, start, end);
  }

  final buffer = StringBuffer();
  var i = start;
  var runStart = start;
  while (i < end) {
    final b = source[i];
    if (b < 0x20) {
      throw FormatException(
        'Unescaped control character in string literal at offset $i',
        source,
        i,
      );
    }
    if (b == 92) {
      // '\\'
      if (i > runStart) {
        var runMax = 0;
        for (var k = runStart; k < i; k++) {
          runMax |= source[k];
        }
        if (runMax <= 0x7F) {
          buffer.write(String.fromCharCodes(source, runStart, i));
        } else {
          buffer.write(
            _getUtf8Decoder(allowMalformed).convert(source, runStart, i),
          );
        }
      }
      i++; // skip '\\'
      if (i >= end) {
        throw FormatException('Unexpected EOF in escape sequence', source, i);
      }
      final esc = source[i++];
      switch (esc) {
        case 34: // '"'
          buffer.writeCharCode(34);
        case 92: // '\\'
          buffer.writeCharCode(92);
        case 47: // '/'
          buffer.writeCharCode(47);
        case 98: // 'b'
          buffer.writeCharCode(8);
        case 102: // 'f'
          buffer.writeCharCode(12);
        case 110: // 'n'
          buffer.writeCharCode(10);
        case 114: // 'r'
          buffer.writeCharCode(13);
        case 116: // 't'
          buffer.writeCharCode(9);
        case 117: // \uXXXX
          if (i + 4 > end) {
            throw FormatException('Incomplete unicode escape', source, i);
          }
          final codeUnit = _parseHex4(source, i);
          i += 4;
          if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
            if (i + 6 <= end && source[i] == 92 && source[i + 1] == 117) {
              final low = _parseHex4(source, i + 2);
              if (low >= 0xDC00 && low <= 0xDFFF) {
                i += 6;
                final codePoint =
                    0x10000 + ((codeUnit - 0xD800) << 10) + (low - 0xDC00);
                buffer.writeCharCode(codePoint);
                break;
              }
            }
          }
          buffer.writeCharCode(codeUnit);
        default:
          throw FormatException(
            'Invalid escape character: ${String.fromCharCode(esc)}',
            source,
            i - 1,
          );
      }
      runStart = i;
    } else {
      i++;
    }
  }
  if (i > runStart) {
    var runMax = 0;
    for (var k = runStart; k < i; k++) {
      runMax |= source[k];
    }
    if (runMax <= 0x7F) {
      buffer.write(String.fromCharCodes(source, runStart, i));
    } else {
      buffer.write(
        _getUtf8Decoder(allowMalformed).convert(source, runStart, i),
      );
    }
  }
  return buffer.toString();
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
int _parseHex4(Uint8List source, int offset) {
  var v = 0;
  for (var i = 0; i < 4; i++) {
    final b = source[offset + i];
    final digit = hexDigitValue(b);
    if (digit < 0) {
      throw FormatException(
        'Invalid hex digit: ${String.fromCharCode(b)}',
        source,
        offset + i,
      );
    }
    v = (v << 4) | digit;
  }
  return v;
}

@pragma('vm:prefer-inline')
@pragma('wasm:prefer-inline')
bool _isSingleQuotedString(Uint8List bytes) {
  return _isSingleQuotedSlice(bytes, 0, bytes.length);
}

bool _isSingleQuotedSlice(Uint8List bytes, int start, int end) {
  if (start < 0 ||
      end > bytes.length ||
      end - start < 2 ||
      bytes[start] != 0x22 ||
      bytes[end - 1] != 0x22) {
    return false;
  }
  var i = start + 1;
  final last = end - 1;
  while (i < last) {
    final b = bytes[i];
    if (b == 0x22 || b < 0x20) {
      return false;
    }
    if (b == 0x5C) {
      if (i + 1 >= last) return false;
      final next = bytes[i + 1];
      if (next == 0x22 || // '"'
          next == 0x5C || // '\'
          next == 0x2F || // '/'
          next == 0x62 || // 'b'
          next == 0x66 || // 'f'
          next == 0x6E || // 'n'
          next == 0x72 || // 'r'
          next == 0x74) {
        // 't'
        i += 2;
      } else if (next == 0x75) {
        // 'u'
        if (i + 5 >= last + 1) return false;
        for (var j = i + 2; j <= i + 5; j++) {
          final c = bytes[j];
          final isHex =
              (c >= 48 && c <= 57) ||
              (c >= 65 && c <= 70) ||
              (c >= 97 && c <= 102);
          if (!isHex) return false;
        }
        i += 6;
      } else {
        return false;
      }
    } else {
      i++;
    }
  }
  return i == last;
}
