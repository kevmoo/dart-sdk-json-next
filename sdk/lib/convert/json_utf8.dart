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
  if (identical(1.0, 1)) {
    final string = value.toString();
    for (var i = 0; i < string.length; i++) {
      buffer[offset + i] = string.codeUnitAt(i);
    }
    return string.length;
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
  int _currentBufferSize;
  final void Function(Uint8List list, int start, int end) addChunk;
  Uint8List buffer;
  int index = 0;

  _JsonUtf8Stringifier(super.toEncodable, this.bufferSize, this.addChunk)
    : _currentBufferSize = bufferSize > 256 ? 256 : bufferSize,
      buffer = Uint8List(bufferSize > 256 ? 256 : bufferSize);

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
      if (_currentBufferSize < bufferSize) {
        final next = _currentBufferSize * 2;
        _currentBufferSize = next < bufferSize ? next : bufferSize;
      }
    }
    buffer = Uint8List(_currentBufferSize);
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
        if (index + maxLen <= buffer.length) {
          index += _writeStringToBuffer(object, buffer, index);
          return true;
        }
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
        if (index + maxLen <= buffer.length) {
          index += _writeStringToBuffer(key, buffer, index);
          buffer[index++] = 0x3A; // ':'
        } else {
          writeByte(0x22);
          writeStringContent(key);
          writeByte(0x22);
          writeByte(0x3A);
        }
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
    if (identical(1.0, 1)) {
      writeAsciiString(number.toString());
      return;
    }
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
  void _completeRootValue(int afterWsOffset) {
    if (afterWsOffset < _bytes.length) {
      throw FormatException(
        'Unexpected character after root value at offset $afterWsOffset',
        _bytes,
        afterWsOffset,
      );
    }
    _hasReadRoot = true;
    _offset = afterWsOffset;
  }

  @pragma('vm:prefer-inline')
  @pragma('wasm:prefer-inline')
  void _afterReadingValue() {
    if (_stackLength > 0) {
      _topState = 2;
    } else {
      _skipWs();
      _completeRootValue(_offset);
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
      if (_stackLength > 0) {
        throw FormatException(
          'Unexpected end of document inside unclosed container',
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
        if (_offset >= _bytes.length) {
          throw FormatException(
            'Unexpected end of document inside unclosed container',
            _bytes,
            _offset,
          );
        }

        final closeChar = _topType == 0 ? 125 : 93;
        final closeStr = _topType == 0 ? '"}"' : '"]"';

        if (_topState == 3) {
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
        _offset = j;
        _skipWs();
        _completeRootValue(_offset);
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
        _offset = j;
        _skipWs();
        _completeRootValue(_offset);
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
        _offset = j;
        _skipWs();
        _completeRootValue(_offset);
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
        _offset = j;
        _skipWs();
        _completeRootValue(_offset);
      }

      if (mantissa == 0) {
        return isNegative ? -0.0 : 0.0;
      }

      if (decimalExp == 0 &&
          !truncatedDigits &&
          unsignedLeInternal(mantissa, 0x001FFFFFFFFFFFFF)) {
        return isNegative ? -mantissa.toDouble() : mantissa.toDouble();
      }

      var result = tryParseDoubleFastEiselLemireInternal(
        mantissa,
        decimalExp,
        isNegative,
      );
      if (result != null && truncatedDigits) {
        final resultPlus1 = tryParseDoubleFastEiselLemireInternal(
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
  if (identical(1.0, 1)) return 0;
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

// Unsigned 64-bit comparisons.
//
// On the VM and Wasm `int` is a signed 64-bit integer, so a mantissa that has
// wrapped past 2^63 compares as negative; flipping the sign bit restores
// unsigned ordering. On the web `int` is a double and bitwise operators are
// evaluated with 32-bit semantics: `x ^ 0x8000000000000000` truncates its
// operands to 32 bits and yields `ToUint32(x)`, so the sign trick silently
// compares the low 32 bits of each side. Web values reaching these helpers are
// non-negative doubles, so a plain comparison is both correct and exact there.

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
      unsignedLeInternal(mantissa, 0x001FFFFFFFFFFFFF)) {
    return isNegative ? -mantissa.toDouble() : mantissa.toDouble();
  }

  // Eisel-Lemire 64-bit float parser
  var result = tryParseDoubleFastEiselLemireInternal(
    mantissa,
    decimalExp,
    isNegative,
  );
  if (result != null && truncatedDigits) {
    final resultPlus1 = tryParseDoubleFastEiselLemireInternal(
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
