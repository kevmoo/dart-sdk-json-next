// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:convert";
import "dart:typed_data";

import "package:expect/expect.dart";

void main() {
  testTokenReaderPrimitives();
  testTokenReaderNestedStructures();
  testTokenReaderSelectName();
  testTokenReaderSelectString();
  testTokenReaderSkipValue();
  testTokenWriter();
  testDomainModelStreaming();
  testTokenReaderCommas();
  testTokenReaderPeekAndTokenSpan();
  testTokenWriterStateMachine();
  testMaxNestingDepthLimits();
  testTokenReaderOutsideObject();
  testTokenWriterMultipleRoots();
  testTokenReaderPeekWithCommas();
  testTokenReaderUtf8Bom();
  testDeepObjectTrees();
  testTokenReaderNonDestructivePeek();
  testTokenReaderControlCharacters();
  testTokenReaderComplexNestingSkipValue();
  testContainerDelimiterSpans();
  testPeekMissingCommaError();
  testWriteNameBytesPreQuoted();
  testSkipValueMaxDepthLimit();
  testSelectNameEscapedKeys();
  testSelectStringEscapedEnums();
  testTokenReaderCursorRollbackOnFormatException();
  testAllowMalformedUtf8();
  testSelectNameSurrogatePairsAndNonAscii();
  testNextNameAndReadStringRollback();
  testTrailingCommaPeekRejection();
  testTokenReaderMultipleRoots();
  testTokenReaderSkipValueControlChars();
  testTokenReaderSkipValueRollback();
  testWriteNameBytesColonTerminated();
  testSkipValueScalarGrammarValidation();
  testTruncatedDocumentTrailingCommaEof();
  testSelectNameMultiByteUtf8Keys();
  testDeepMixedContainerSkipValue1024Levels();
  testClosureFreeScalarStreamingAndRollback();
  testZeroAllocationColonTerminatedKeys();
  testTokenReaderSkipValueInvalidEscapes();
  testSelectNameMalformedUtf8();
  testSelectStringMalformedUtf8();
  testTokenReaderSkipObjectMember();
  testCanonicalLargeIntegers();
  testContainerSyntaxCorruptionInSkipValue();
  testGetTokenSpanTrailingCommaAndEofRejection();
  testTokenReaderUnifiedRollbackSemantics();
  testReadStringSpanAndBytes();
  testStringCacheDirectMapped();
}

void testTokenReaderPrimitives() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // String
  var reader = JsonTokenReader.fromBytes(b('"hello world"'));
  Expect.equals(JsonTokenType.string, reader.peek());
  Expect.equals('hello world', reader.readString());

  // Int
  reader = JsonTokenReader.fromBytes(b('12345'));
  Expect.equals(JsonTokenType.number, reader.peek());
  Expect.equals(12345, reader.readInt());

  // Double
  reader = JsonTokenReader.fromBytes(b('3.14159'));
  Expect.equals(JsonTokenType.number, reader.peek());
  Expect.equals(3.14159, reader.readDouble());

  // Double from Int
  reader = JsonTokenReader.fromBytes(b('42'));
  Expect.equals(42.0, reader.readDouble());

  // Num
  reader = JsonTokenReader.fromBytes(b('100'));
  Expect.equals(100, reader.readNum());
  reader = JsonTokenReader.fromBytes(b('100.5'));
  Expect.equals(100.5, reader.readNum());

  // Bool
  reader = JsonTokenReader.fromBytes(b('true'));
  Expect.equals(JsonTokenType.boolean, reader.peek());
  Expect.isTrue(reader.readBool());

  reader = JsonTokenReader.fromBytes(b('false'));
  Expect.equals(JsonTokenType.boolean, reader.peek());
  Expect.isFalse(reader.readBool());

  // Null
  reader = JsonTokenReader.fromBytes(b('null'));
  Expect.equals(JsonTokenType.nullValue, reader.peek());
  reader.readNull();
}

void testTokenReaderNestedStructures() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Empty object
  var reader = JsonTokenReader.fromBytes(b('{}'));
  Expect.equals(JsonTokenType.beginObject, reader.peek());
  reader.beginObject();
  Expect.isFalse(reader.hasNext());
  reader.endObject();

  // Simple object
  reader = JsonTokenReader.fromBytes(b('{"a": 1, "b": "two", "c": true}'));
  reader.beginObject();
  Expect.isTrue(reader.hasNext());
  Expect.equals('a', reader.nextName());
  Expect.equals(1, reader.readInt());

  Expect.isTrue(reader.hasNext());
  Expect.equals('b', reader.nextName());
  Expect.equals('two', reader.readString());

  Expect.isTrue(reader.hasNext());
  Expect.equals('c', reader.nextName());
  Expect.isTrue(reader.readBool());

  Expect.isFalse(reader.hasNext());
  reader.endObject();

  // Array
  reader = JsonTokenReader.fromBytes(b('[10, 20, 30]'));
  Expect.equals(JsonTokenType.beginArray, reader.peek());
  reader.beginArray();
  Expect.isTrue(reader.hasNext());
  Expect.equals(10, reader.readInt());
  Expect.isTrue(reader.hasNext());
  Expect.equals(20, reader.readInt());
  Expect.isTrue(reader.hasNext());
  Expect.equals(30, reader.readInt());
  Expect.isFalse(reader.hasNext());
  reader.endArray();
}

void testTokenReaderSelectName() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final options = JsonKeyOptions.of(['id', 'title', 'active', 'tags']);
  final reader = JsonTokenReader.fromBytes(
    b('{"title": "Dart 4", "id": 42, "unknown": "skip", "active": true}'),
  );

  reader.beginObject();

  // "title" -> index 1
  Expect.equals(1, reader.selectName(options));
  Expect.equals('Dart 4', reader.readString());

  // "id" -> index 0
  Expect.equals(0, reader.selectName(options));
  Expect.equals(42, reader.readInt());

  // "unknown" -> index -1
  Expect.equals(-1, reader.selectName(options));
  reader.skipValue();

  // "active" -> index 2
  Expect.equals(2, reader.selectName(options));
  Expect.isTrue(reader.readBool());

  Expect.isFalse(reader.hasNext());
  reader.endObject();
}

void testTokenReaderSelectString() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final roles = JsonKeyOptions.of(['admin', 'member', 'guest']);
  final reader = JsonTokenReader.fromBytes(b('["guest", "admin", "member"]'));

  reader.beginArray();
  Expect.equals(2, reader.selectString(roles)); // "guest"
  Expect.equals(0, reader.selectString(roles)); // "admin"
  Expect.equals(1, reader.selectString(roles)); // "member"
  Expect.isFalse(reader.hasNext());
  reader.endArray();
}

void testTokenReaderSkipValue() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final reader = JsonTokenReader.fromBytes(
    b('{"skipMe": {"nested": [1, 2, {"a": "b"}]}, "keepMe": 100}'),
  );

  reader.beginObject();
  Expect.equals('skipMe', reader.nextName());
  reader.skipValue();

  Expect.isTrue(reader.hasNext());
  Expect.equals('keepMe', reader.nextName());
  Expect.equals(100, reader.readInt());
  reader.endObject();
}

void testTokenWriter() {
  final sink = BytesBuilder();
  final writer = JsonTokenWriter.toSink(sink);

  writer.beginObject();
  writer.writeName('name');
  writer.writeString('Alice');
  writer.writeName('age');
  writer.writeInt(30);
  writer.writeName('score');
  writer.writeDouble(95.5);
  writer.writeName('verified');
  writer.writeBool(true);
  writer.writeName('details');
  writer.writeNull();
  writer.writeName('tags');
  writer.beginArray();
  writer.writeString('dart');
  writer.writeString('wasm');
  writer.endArray();
  writer.endObject();

  final jsonStr = utf8.decode(sink.takeBytes());
  final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

  Expect.equals('Alice', decoded['name']);
  Expect.equals(30, decoded['age']);
  Expect.equals(95.5, decoded['score']);
  Expect.equals(true, decoded['verified']);
  Expect.isNull(decoded['details']);
  Expect.listEquals(['dart', 'wasm'], decoded['tags'] as List);
}

void testDomainModelStreaming() {
  // Coordinate Domain Model streaming test
  final coordJson = '{"latitude": 37.7749, "longitude": -122.4194}';
  final bytes = Uint8List.fromList(utf8.encode(coordJson));

  final keys = JsonKeyOptions.of(['latitude', 'longitude', 'lat', 'lon']);
  final reader = JsonTokenReader.fromBytes(bytes);

  double? lat;
  double? lon;

  reader.beginObject();
  while (reader.hasNext()) {
    switch (reader.selectName(keys)) {
      case 0: // latitude
      case 2: // lat
        lat = reader.readDouble();
      case 1: // longitude
      case 3: // lon
        lon = reader.readDouble();
      default:
        reader.skipValue();
    }
  }
  reader.endObject();

  Expect.equals(37.7749, lat);
  Expect.equals(-122.4194, lon);
}

void testTokenReaderCommas() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Trailing comma in object
  final r1 = JsonTokenReader.fromBytes(b('{"a": 1,}'));
  r1.beginObject();
  Expect.isTrue(r1.hasNext());
  Expect.equals('a', r1.nextName());
  Expect.equals(1, r1.readInt());
  Expect.throwsFormatException(() => r1.hasNext());

  // Missing comma in object
  final r2 = JsonTokenReader.fromBytes(b('{"a": 1 "b": 2}'));
  r2.beginObject();
  Expect.isTrue(r2.hasNext());
  Expect.equals('a', r2.nextName());
  Expect.equals(1, r2.readInt());
  Expect.throwsFormatException(() => r2.hasNext());

  // Trailing comma in array
  final r3 = JsonTokenReader.fromBytes(b('[1, 2,]'));
  r3.beginArray();
  Expect.isTrue(r3.hasNext());
  Expect.equals(1, r3.readInt());
  Expect.isTrue(r3.hasNext());
  Expect.equals(2, r3.readInt());
  Expect.throwsFormatException(() => r3.hasNext());

  // Trailing comma in single-item array
  final r4 = JsonTokenReader.fromBytes(b('[1,]'));
  r4.beginArray();
  Expect.isTrue(r4.hasNext());
  Expect.equals(1, r4.readInt());
  Expect.throwsFormatException(() => r4.hasNext());

  // Missing comma in array
  final r5 = JsonTokenReader.fromBytes(b('[1 2]'));
  r5.beginArray();
  Expect.isTrue(r5.hasNext());
  Expect.equals(1, r5.readInt());
  Expect.throwsFormatException(() => r5.hasNext());
}

void testTokenReaderPeekAndTokenSpan() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final bytes = b('{"key": "val", "num": 42}');
  final r = JsonTokenReader.fromBytes(bytes);
  r.beginObject();

  // Inside object before key: peek must return propertyName
  Expect.equals(JsonTokenType.propertyName, r.peek());

  // getTokenSpan is non-destructive
  final (s1, e1) = r.getTokenSpan();
  Expect.equals('key', utf8.decode(bytes.sublist(s1, e1)));
  Expect.equals(JsonTokenType.propertyName, r.peek());
  final (s1b, e1b) = r.getTokenSpan();
  Expect.equals(s1, s1b);
  Expect.equals(e1, e1b);

  Expect.equals('key', r.nextName());

  // After nextName (after colon): peek returns string
  Expect.equals(JsonTokenType.string, r.peek());
  Expect.equals('val', r.readString());

  Expect.isTrue(r.hasNext());
  Expect.equals(JsonTokenType.propertyName, r.peek());
  Expect.equals('num', r.nextName());

  Expect.equals(JsonTokenType.number, r.peek());
  final (s2, e2) = r.getTokenSpan();
  Expect.equals('42', utf8.decode(bytes.sublist(s2, e2)));
  Expect.equals(42, r.readInt());

  Expect.isFalse(r.hasNext());
  r.endObject();
}

void testTokenWriterStateMachine() {
  // Disallow writeName in array
  final w1 = JsonTokenWriter.toSink(BytesBuilder());
  w1.beginArray();
  Expect.throwsStateError(() => w1.writeName('a'));

  // Disallow value before writeName in object
  final w2 = JsonTokenWriter.toSink(BytesBuilder());
  w2.beginObject();
  Expect.throwsStateError(() => w2.writeInt(1));
  Expect.throwsStateError(() => w2.writeString('val'));
  Expect.throwsStateError(() => w2.writeBool(true));
  Expect.throwsStateError(() => w2.writeNull());
  Expect.throwsStateError(() => w2.beginObject());
  Expect.throwsStateError(() => w2.beginArray());

  // Disallow consecutive writeName in object
  final w3 = JsonTokenWriter.toSink(BytesBuilder());
  w3.beginObject();
  w3.writeName('a');
  Expect.throwsStateError(() => w3.writeName('b'));

  // Disallow endObject when expecting value
  final w4 = JsonTokenWriter.toSink(BytesBuilder());
  w4.beginObject();
  w4.writeName('a');
  Expect.throwsStateError(() => w4.endObject());

  // Disallow mismatched container ends
  final w5 = JsonTokenWriter.toSink(BytesBuilder());
  w5.beginObject();
  Expect.throwsStateError(() => w5.endArray());

  final w6 = JsonTokenWriter.toSink(BytesBuilder());
  w6.beginArray();
  Expect.throwsStateError(() => w6.endObject());

  // Disallow non-finite double
  final w7 = JsonTokenWriter.toSink(BytesBuilder());
  w7.beginArray();
  Expect.throwsArgumentError(() => w7.writeDouble(double.nan));
}

void testMaxNestingDepthLimits() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Reader object depth limit (1024 succeeds, 1025 fails)
  final okNestedObj = '{"a": ' * 1024 + '42' + '}' * 1024;
  final rOkObj = JsonTokenReader.fromBytes(b(okNestedObj));
  for (var i = 0; i < 1024; i++) {
    rOkObj.beginObject();
    Expect.equals('a', rOkObj.nextName());
  }
  Expect.equals(42, rOkObj.readInt());
  for (var i = 0; i < 1024; i++) {
    rOkObj.endObject();
  }

  final nestedObj = '{' * 1025 + '}' * 1025;
  final rObj = JsonTokenReader.fromBytes(b(nestedObj));
  Expect.throwsFormatException(() {
    for (var i = 0; i < 1025; i++) {
      rObj.beginObject();
    }
  });

  // Reader array depth limit (1024 succeeds, 1025 fails)
  final okNestedArr = '[' * 1024 + ']' * 1024;
  final rOkArr = JsonTokenReader.fromBytes(b(okNestedArr));
  for (var i = 0; i < 1024; i++) {
    rOkArr.beginArray();
  }
  for (var i = 0; i < 1024; i++) {
    rOkArr.endArray();
  }

  final nestedArr = '[' * 1025 + ']' * 1025;
  final rArr = JsonTokenReader.fromBytes(b(nestedArr));
  Expect.throwsFormatException(() {
    for (var i = 0; i < 1025; i++) {
      rArr.beginArray();
    }
  });

  // Writer depth limit (1024 succeeds, 1025 fails)
  final wOk = JsonTokenWriter.toSink(BytesBuilder());
  for (var i = 0; i < 1024; i++) {
    wOk.beginArray();
  }
  for (var i = 0; i < 1024; i++) {
    wOk.endArray();
  }

  final w = JsonTokenWriter.toSink(BytesBuilder());
  Expect.throws(() {
    for (var i = 0; i < 1025; i++) {
      w.beginArray();
    }
  }, (e) => e is StateError || e is FormatException);
}

void testTokenReaderOutsideObject() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Cannot nextName at root
  final rRoot = JsonTokenReader.fromBytes(b('"hello": 123'));
  Expect.throwsFormatException(() => rRoot.nextName());

  // Cannot nextName in array
  final rArr = JsonTokenReader.fromBytes(b('["item": 123]'));
  rArr.beginArray();
  Expect.throwsFormatException(() => rArr.nextName());

  // Cannot nextName when waiting for value (afterName)
  final rObj = JsonTokenReader.fromBytes(b('{"a": "b": "c"}'));
  rObj.beginObject();
  Expect.equals('a', rObj.nextName());
  Expect.throwsFormatException(() => rObj.nextName());
}

void testTokenWriterMultipleRoots() {
  // Disallow multiple primitive root values
  final w1 = JsonTokenWriter.toSink(BytesBuilder());
  w1.writeInt(1);
  Expect.throwsStateError(() => w1.writeInt(2));

  // Disallow root value after container
  final w2 = JsonTokenWriter.toSink(BytesBuilder());
  w2.beginObject();
  w2.endObject();
  Expect.throwsStateError(() => w2.writeInt(1));

  // Disallow container after root value
  final w3 = JsonTokenWriter.toSink(BytesBuilder());
  w3.writeString('root');
  Expect.throwsStateError(() => w3.beginArray());
}

void testTokenReaderPeekWithCommas() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Peek across array comma
  final rArr = JsonTokenReader.fromBytes(b('[10, 20]'));
  rArr.beginArray();
  Expect.equals(10, rArr.readInt());
  Expect.equals(JsonTokenType.number, rArr.peek());
  final (s, e) = rArr.getTokenSpan();
  Expect.equals('20', utf8.decode(b('[10, 20]').sublist(s, e)));
  Expect.equals(20, rArr.readInt());
  Expect.equals(JsonTokenType.endArray, rArr.peek());
  rArr.endArray();

  // Peek across object comma
  final rObj = JsonTokenReader.fromBytes(b('{"a": 1, "b": 2}'));
  rObj.beginObject();
  Expect.equals('a', rObj.nextName());
  Expect.equals(1, rObj.readInt());
  Expect.equals(JsonTokenType.propertyName, rObj.peek());
  final (s2, e2) = rObj.getTokenSpan();
  Expect.equals('b', utf8.decode(b('{"a": 1, "b": 2}').sublist(s2, e2)));
  Expect.equals('b', rObj.nextName());
  Expect.equals(2, rObj.readInt());
  Expect.equals(JsonTokenType.endObject, rObj.peek());
  rObj.endObject();
}

void testTokenReaderUtf8Bom() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Leading BOM followed by JSON
  final withBom = Uint8List.fromList([
    0xEF,
    0xBB,
    0xBF,
    0x74,
    0x72,
    0x75,
    0x65,
  ]); // BOM + 'true'
  final r1 = JsonTokenReader.fromBytes(withBom);
  Expect.equals(JsonTokenType.boolean, r1.peek());
  Expect.isTrue(r1.readBool());

  // BOM followed by object
  final objWithBom = Uint8List.fromList([
    0xEF,
    0xBB,
    0xBF,
    ...utf8.encode('{"id": 42}'),
  ]);
  final r2 = JsonTokenReader.fromBytes(objWithBom);
  Expect.equals(JsonTokenType.beginObject, r2.peek());
  r2.beginObject();
  Expect.equals('id', r2.nextName());
  Expect.equals(42, r2.readInt());
  r2.endObject();

  // BOM in middle of document should return none for peek and throw on read
  final midBom = b('{"a": \xEF\xBB\xBF 1}');
  final r3 = JsonTokenReader.fromBytes(midBom);
  r3.beginObject();
  Expect.equals('a', r3.nextName());
  Expect.equals(JsonTokenType.none, r3.peek());
  Expect.throwsFormatException(() => r3.readInt());
}

void testDeepObjectTrees() {
  // Test depth up to 1024
  var nested = '{"a": ' * 1024 + '42' + '}' * 1024;
  final bytes = Uint8List.fromList(utf8.encode(nested));
  final reader = JsonTokenReader.fromBytes(bytes);
  for (var i = 0; i < 1024; i++) {
    reader.beginObject();
    Expect.equals('a', reader.nextName());
  }
  Expect.equals(42, reader.readInt());
  for (var i = 0; i < 1024; i++) {
    reader.endObject();
  }

  // Test depth > 1024 throws FormatException
  var deep = '{"a": ' * 1025 + '42' + '}' * 1025;
  final deepBytes = Uint8List.fromList(utf8.encode(deep));
  final deepReader = JsonTokenReader.fromBytes(deepBytes);
  Expect.throwsFormatException(() {
    for (var i = 0; i < 1025; i++) {
      deepReader.beginObject();
      deepReader.nextName();
    }
  });
}

void testTokenReaderNonDestructivePeek() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Whitespace in front of value: peek() should not mutate _offset
  final bytes = b('   42');
  final reader = JsonTokenReader.fromBytes(bytes);
  Expect.equals(JsonTokenType.number, reader.peek());
  Expect.equals(JsonTokenType.number, reader.peek());
  Expect.equals(42, reader.readInt());

  // 2. Whitespace in front of object: peek() should not mutate _offset
  final objBytes = b('   {"k": 1}');
  final objReader = JsonTokenReader.fromBytes(objBytes);
  Expect.equals(JsonTokenType.beginObject, objReader.peek());
  Expect.equals(JsonTokenType.beginObject, objReader.peek());
  objReader.beginObject();
  Expect.equals(JsonTokenType.propertyName, objReader.peek());
  Expect.equals('k', objReader.nextName());
  Expect.equals(1, objReader.readInt());
  objReader.endObject();
}

void testTokenReaderControlCharacters() {
  // Unescaped control characters in strings must throw FormatException
  final bVal = Uint8List.fromList([0x22, 0x0A, 0x22]); // '"\n"'
  final rVal = JsonTokenReader.fromBytes(bVal);
  Expect.throwsFormatException(() => rVal.readString());

  final bName = Uint8List.fromList([
    0x7B,
    0x22,
    0x01,
    0x22,
    0x3A,
    0x31,
    0x7D,
  ]); // '{"\x01":1}'
  final rName = JsonTokenReader.fromBytes(bName);
  rName.beginObject();
  Expect.throwsFormatException(() => rName.nextName());

  final rSpan = JsonTokenReader.fromBytes(bVal);
  Expect.throwsFormatException(() => rSpan.getTokenSpan());
}

void testTokenReaderComplexNestingSkipValue() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final complexJson = b('{"skip": [{"a": [1, 2]}, {"b": [3, 4]}], "keep": 99}');
  final r = JsonTokenReader.fromBytes(complexJson);
  r.beginObject();
  Expect.equals('skip', r.nextName());
  r.skipValue();
  Expect.isTrue(r.hasNext());
  Expect.equals('keep', r.nextName());
  Expect.equals(99, r.readInt());
  r.endObject();

  // Nested array skipValue with inner objects
  final arrJson = b('[[{"x": [1, 2]}], 42]');
  final rArr = JsonTokenReader.fromBytes(arrJson);
  rArr.beginArray();
  rArr.skipValue(); // skips '[{"x": [1, 2]}]'
  Expect.isTrue(rArr.hasNext());
  Expect.equals(42, rArr.readInt());
  rArr.endArray();
}

void testContainerDelimiterSpans() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Single-byte delimiter spans for unspaced and spaced containers
  final unspacedObj = b('{"a":1}');
  final r1 = JsonTokenReader.fromBytes(unspacedObj);
  final (s1, e1) = r1.getTokenSpan();
  Expect.equals(0, s1);
  Expect.equals(1, e1);
  Expect.equals('{', utf8.decode(unspacedObj.sublist(s1, e1)));

  r1.beginObject();
  Expect.equals('a', r1.nextName());
  Expect.equals(1, r1.readInt());
  final (s1Close, e1Close) = r1.getTokenSpan();
  Expect.equals(6, s1Close);
  Expect.equals(7, e1Close);
  Expect.equals('}', utf8.decode(unspacedObj.sublist(s1Close, e1Close)));
  r1.endObject();

  final spacedObj = b('  {  "a"  :  1  }  ');
  final r2 = JsonTokenReader.fromBytes(spacedObj);
  final (s2, e2) = r2.getTokenSpan();
  Expect.equals(2, s2);
  Expect.equals(3, e2);
  Expect.equals('{', utf8.decode(spacedObj.sublist(s2, e2)));

  final unspacedArr = b('[1,2]');
  final r3 = JsonTokenReader.fromBytes(unspacedArr);
  final (s3, e3) = r3.getTokenSpan();
  Expect.equals(0, s3);
  Expect.equals(1, e3);
  Expect.equals('[', utf8.decode(unspacedArr.sublist(s3, e3)));

  r3.beginArray();
  Expect.equals(1, r3.readInt());
  Expect.equals(2, r3.readInt());
  final (s3Close, e3Close) = r3.getTokenSpan();
  Expect.equals(4, s3Close);
  Expect.equals(5, e3Close);
  Expect.equals(']', utf8.decode(unspacedArr.sublist(s3Close, e3Close)));
  r3.endArray();
}

void testPeekMissingCommaError() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // In an object, after reading a value, next must be comma or '}'.
  // If followed directly by another key without comma, peek() must throw FormatException.
  final rObj = JsonTokenReader.fromBytes(b('{"a": 1 "b": 2}'));
  rObj.beginObject();
  Expect.equals('a', rObj.nextName());
  Expect.equals(1, rObj.readInt());
  Expect.throwsFormatException(() => rObj.peek());

  // In an array, after reading a value, next must be comma or ']'.
  // If followed directly by another element without comma, peek() must throw FormatException.
  final rArr = JsonTokenReader.fromBytes(b('[1 2]'));
  rArr.beginArray();
  Expect.equals(1, rArr.readInt());
  Expect.throwsFormatException(() => rArr.peek());
}

void testWriteNameBytesPreQuoted() {
  // Pre-quoted key constant (Pattern B: utf8.encode('"x"'))
  final sink1 = BytesBuilder();
  final w1 = JsonTokenWriter.toSink(sink1);
  w1.beginObject();
  w1.writeNameBytes(Uint8List.fromList(utf8.encode('"key"')));
  w1.writeInt(42);
  w1.endObject();
  final out1 = utf8.decode(sink1.takeBytes());
  Expect.equals('{"key":42}', out1);

  // Raw unquoted key constant
  final sink2 = BytesBuilder();
  final w2 = JsonTokenWriter.toSink(sink2);
  w2.beginObject();
  w2.writeNameBytes(Uint8List.fromList(utf8.encode('key')));
  w2.writeInt(42);
  w2.endObject();
  final out2 = utf8.decode(sink2.takeBytes());
  Expect.equals('{"key":42}', out2);
}

void testSkipValueMaxDepthLimit() {
  // 1025 levels of nested array
  final open = '[' * 1025;
  final close = ']' * 1025;
  final deepArray = Uint8List.fromList(utf8.encode('$open$close'));
  final r = JsonTokenReader.fromBytes(deepArray);
  Expect.throwsFormatException(() => r.skipValue());

  // 1024 levels of nested array should succeed
  final okOpen = '[' * 1024;
  final okClose = ']' * 1024;
  final okArray = Uint8List.fromList(utf8.encode('$okOpen$okClose'));
  final rOk = JsonTokenReader.fromBytes(okArray);
  rOk.skipValue();

  // Mixed containers at depth 1024: 512 objects containing arrays
  var mixed1024 = '';
  for (var i = 0; i < 512; i++) {
    mixed1024 += '{"k":[';
  }
  mixed1024 += '42';
  for (var i = 0; i < 512; i++) {
    mixed1024 += ']}';
  }
  final rMixed = JsonTokenReader.fromBytes(
    Uint8List.fromList(utf8.encode(mixed1024)),
  );
  rMixed.skipValue();

  // Mixed containers at depth 1025: exceeds limit
  var mixed1025 = '';
  for (var i = 0; i < 512; i++) {
    mixed1025 += '{"k":[';
  }
  mixed1025 += '{"k": 42}';
  for (var i = 0; i < 512; i++) {
    mixed1025 += ']}';
  }
  final rMixed1025 = JsonTokenReader.fromBytes(
    Uint8List.fromList(utf8.encode(mixed1025)),
  );
  Expect.throwsFormatException(() => rMixed1025.skipValue());
}

void testSelectNameEscapedKeys() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final options = JsonKeyOptions.of(['id', 'title', 'active', r'a"b', r'c\d']);
  final reader = JsonTokenReader.fromBytes(
    b(
      r'{"\u0069\u0064": 42, "\u0074\u0069\u0074\u006c\u0065": "Dart 4", "active": true, "unknown_\u0031": 99, "a\"b": 100, "c\\d": 200}',
    ),
  );

  reader.beginObject();

  // "\u0069\u0064" -> matches 'id' (index 0)
  Expect.equals(0, reader.selectName(options));
  Expect.equals(42, reader.readInt());

  // "\u0074\u0069\u0074\u006c\u0065" -> matches 'title' (index 1)
  Expect.equals(1, reader.selectName(options));
  Expect.equals('Dart 4', reader.readString());

  // "active" -> verbatim ASCII match (index 2)
  Expect.equals(2, reader.selectName(options));
  Expect.isTrue(reader.readBool());

  // "unknown_\u0031" -> unknown key -> returns -1
  Expect.equals(-1, reader.selectName(options));
  reader.skipValue();

  // "a\"b" -> escaped quote -> index 3
  Expect.equals(3, reader.selectName(options));
  Expect.equals(100, reader.readInt());

  // "c\\d" -> escaped backslash -> index 4
  Expect.equals(4, reader.selectName(options));
  Expect.equals(200, reader.readInt());

  Expect.isFalse(reader.hasNext());
  reader.endObject();
}

void testSelectStringEscapedEnums() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final roleOptions = JsonKeyOptions.of(['admin', 'user', 'guest']);
  final reader = JsonTokenReader.fromBytes(
    b(
      r'["\u0061\u0064\u006d\u0069\u006e", "user", "\u0067\u0075\u0065\u0073\u0074", "\u006f\u0074\u0068\u0065\u0072"]',
    ),
  );

  reader.beginArray();

  // "\u0061\u0064\u006d\u0069\u006e" -> matches 'admin' (index 0)
  Expect.equals(0, reader.selectString(roleOptions));

  // "user" -> matches 'user' (index 1)
  Expect.equals(1, reader.selectString(roleOptions));

  // "\u0067\u0075\u0065\u0073\u0074" -> matches 'guest' (index 2)
  Expect.equals(2, reader.selectString(roleOptions));

  // "\u006f\u0074\u0068\u0065\u0072" -> "other" -> unmatched enum -> returns -1
  Expect.equals(-1, reader.selectString(roleOptions));

  Expect.isFalse(reader.hasNext());
  reader.endArray();
}

void testTokenReaderCursorRollbackOnFormatException() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Test rollback in object value on readInt
  {
    final reader = JsonTokenReader.fromBytes(
      b('{"key": "not_an_int", "other": 123}'),
    );
    reader.beginObject();
    Expect.equals('key', reader.nextName());

    // Expect FormatException when reading int on string literal
    Expect.throwsFormatException(() => reader.readInt());

    // After caught FormatException, cursor and container state must be preserved
    final (start, end) = reader.getTokenSpan();
    Expect.equals(
      'not_an_int',
      utf8.decode(b('{"key": "not_an_int", "other": 123}').sublist(start, end)),
    );
    Expect.equals('not_an_int', reader.readString());

    Expect.isTrue(reader.hasNext());
    Expect.equals('other', reader.nextName());
    Expect.equals(123, reader.readInt());
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // Test rollback in object value on readString with malformed UTF-8
  {
    final rawBytes = Uint8List.fromList([
      ...b('{"bad": "'),
      0xFF,
      ...b('", "good": "ok"}'),
    ]);
    final reader = JsonTokenReader.fromBytes(rawBytes);
    reader.beginObject();
    Expect.equals('bad', reader.nextName());

    // Malformed UTF-8 0xFF passes readStringSpan but throws in _decodeCachedString
    Expect.throwsFormatException(() => reader.readString());

    // Cursor was rolled back so readStringSpan can still read the raw byte span
    final (start, end) = reader.readStringSpan();
    Expect.equals(1, end - start);
    Expect.equals(0xFF, rawBytes[start]);
    Expect.isTrue(reader.hasNext());
    Expect.equals('good', reader.nextName());
    Expect.equals('ok', reader.readString());
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // Test rollback on readDouble, readBool, readNull in array
  {
    final raw = '[10, "abc", true, null, 30]';
    final bytes = b(raw);
    final reader = JsonTokenReader.fromBytes(bytes);
    reader.beginArray();
    Expect.equals(10, reader.readInt());

    // Attempt to read double on "abc" (throws FormatException)
    Expect.throwsFormatException(() => reader.readDouble());
    final (start1, end1) = reader.getTokenSpan();
    Expect.equals('abc', utf8.decode(bytes.sublist(start1, end1)));
    Expect.equals('abc', reader.readString());

    // Next element is `true`, attempt to readNull (throws FormatException)
    Expect.throwsFormatException(() => reader.readNull());
    final (start2, end2) = reader.getTokenSpan();
    Expect.equals('true', utf8.decode(bytes.sublist(start2, end2)));
    Expect.isTrue(reader.readBool());

    // Next element is `null`, attempt to readBool (throws FormatException)
    Expect.throwsFormatException(() => reader.readBool());
    final (start3, end3) = reader.getTokenSpan();
    Expect.equals('null', utf8.decode(bytes.sublist(start3, end3)));
    reader.readNull();

    // Next element in array
    Expect.isTrue(reader.hasNext());
    Expect.equals(30, reader.readInt());
    Expect.isFalse(reader.hasNext());
    reader.endArray();
  }
}

void testAllowMalformedUtf8() {
  // Invalid UTF-8 bytes: [0x22, 0xFF, 0xFE, 0x22] -> "\xFF\xFE" in string quotes
  final malformedBytes = Uint8List.fromList([0x22, 0xFF, 0xFE, 0x22]);

  // Default decoder (allowMalformed: false) throws FormatException
  Expect.throwsFormatException(() => jsonUtf8Decode(malformedBytes));
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(malformedBytes).readString(),
  );

  // allowMalformed: true replaces invalid bytes with \uFFFD
  final decoded = jsonUtf8Decode(malformedBytes, allowMalformed: true);
  Expect.equals('\uFFFD\uFFFD', decoded);

  final reader = JsonTokenReader.fromBytes(
    malformedBytes,
    allowMalformed: true,
  );
  Expect.equals('\uFFFD\uFFFD', reader.readString());
}

void testSelectNameSurrogatePairsAndNonAscii() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final options = JsonKeyOptions.of(['😀', 'é', 'café', 'regular']);
  // 1. Escaped surrogate pair: \uD83D\uDE00 -> 😀
  // 2. Escaped non-ASCII: \u00e9 -> é
  // 3. Raw non-ASCII UTF-8: café
  // 4. Verbatim ASCII: regular
  final reader = JsonTokenReader.fromBytes(
    b(r'{"\uD83D\uDE00": 1, "\u00e9": 2, "café": 3, "regular": 4}'),
  );

  reader.beginObject();

  Expect.equals(0, reader.selectName(options));
  Expect.equals(1, reader.readInt());

  Expect.equals(1, reader.selectName(options));
  Expect.equals(2, reader.readInt());

  Expect.equals(2, reader.selectName(options));
  Expect.equals(3, reader.readInt());

  Expect.equals(3, reader.selectName(options));
  Expect.equals(4, reader.readInt());

  Expect.isFalse(reader.hasNext());
  reader.endObject();
}

void testNextNameAndReadStringRollback() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Calling nextName when expecting value throws FormatException and rolls back
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": 100}'));
    reader.beginObject();
    Expect.equals('a', reader.nextName());

    // Mistakenly call nextName again instead of reading value
    Expect.throwsFormatException(() => reader.nextName());

    // Reader state preserved: readInt succeeds
    Expect.equals(100, reader.readInt());
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // 2. Calling readString on numeric token throws FormatException and rolls back
  {
    final reader = JsonTokenReader.fromBytes(b('[123, "abc"]'));
    reader.beginArray();

    Expect.throwsFormatException(() => reader.readString());

    // Reader state preserved: readInt succeeds
    Expect.equals(123, reader.readInt());

    Expect.isTrue(reader.hasNext());
    Expect.equals('abc', reader.readString());
    Expect.isFalse(reader.hasNext());
    reader.endArray();
  }
}

void testAllowMalformedUtf8WithEscapes() {
  // String containing both invalid UTF-8 bytes and unicode escape:
  // bytes: '"' + [0xFF, 0xFE] + '\u0061' + '"'
  final bytes = Uint8List.fromList([
    0x22,
    0xFF,
    0xFE,
    0x5C,
    0x75,
    0x30,
    0x30,
    0x36,
    0x31,
    0x22,
  ]);

  // allowMalformed: false throws FormatException
  Expect.throwsFormatException(() => jsonUtf8Decode(bytes));
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(bytes).readString(),
  );

  // allowMalformed: true replaces malformed bytes with \uFFFD and decodes escape
  final decoded = jsonUtf8Decode(bytes, allowMalformed: true);
  Expect.equals('\uFFFD\uFFFDa', decoded);

  final reader = JsonTokenReader.fromBytes(bytes, allowMalformed: true);
  Expect.equals('\uFFFD\uFFFDa', reader.readString());
}

void testTrailingCommaPeekRejection() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Trailing comma before '}' in object: peek() must throw FormatException
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1, }'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
  }

  // Trailing comma with multiple properties
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1, "b": 2, }'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.equals('b', r.nextName());
    Expect.equals(2, r.readInt());
    Expect.throwsFormatException(() => r.peek());
  }

  // Trailing comma before ']' in array: peek() must throw FormatException
  {
    final r = JsonTokenReader.fromBytes(b('[1, 2, ]'));
    r.beginArray();
    Expect.equals(1, r.readInt());
    Expect.equals(2, r.readInt());
    Expect.throwsFormatException(() => r.peek());
  }

  // Single-element array with trailing comma
  {
    final r = JsonTokenReader.fromBytes(b('[true, ]'));
    r.beginArray();
    Expect.equals(true, r.readBool());
    Expect.throwsFormatException(() => r.peek());
  }

  // Mismatched closing delimiter after comma in array: peek() must throw FormatException
  {
    final r = JsonTokenReader.fromBytes(b('[1, }'));
    r.beginArray();
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
  }

  // Mismatched closing delimiter after comma in object: peek() must throw FormatException
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1, ]'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
  }

  // Invalid value (non-string key) after comma in object: peek() must return none
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1, 2}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.equals(JsonTokenType.none, r.peek());
  }

  // Invalid value (non-string key) at start of object: peek() must return none
  {
    final r = JsonTokenReader.fromBytes(b('{123}'));
    r.beginObject();
    Expect.equals(JsonTokenType.none, r.peek());
  }

  // Bare closing brackets or delimiters at root level: peek() must return none
  {
    Expect.equals(JsonTokenType.none, JsonTokenReader.fromBytes(b('}')).peek());
    Expect.equals(JsonTokenType.none, JsonTokenReader.fromBytes(b(']')).peek());
    Expect.equals(JsonTokenType.none, JsonTokenReader.fromBytes(b(',')).peek());
    Expect.equals(JsonTokenType.none, JsonTokenReader.fromBytes(b(':')).peek());
  }

  // hasNext() throws FormatException on mismatched delimiter after comma
  {
    final rArr = JsonTokenReader.fromBytes(b('[1, }'));
    rArr.beginArray();
    Expect.equals(1, rArr.readInt());
    Expect.throwsFormatException(() => rArr.hasNext());

    final rObj = JsonTokenReader.fromBytes(b('{"a": 1, ]'));
    rObj.beginObject();
    Expect.equals('a', rObj.nextName());
    Expect.equals(1, rObj.readInt());
    Expect.throwsFormatException(() => rObj.hasNext());
  }
}

void testTokenReaderMultipleRoots() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Disallow multiple primitive root values
  {
    final r1 = JsonTokenReader.fromBytes(b('1 2'));
    Expect.equals(1, r1.readInt());
    Expect.isFalse(r1.hasNext());
    Expect.equals(JsonTokenType.none, r1.peek());
    Expect.throwsFormatException(() => r1.readInt());
  }

  // Disallow root value after container
  {
    final r2 = JsonTokenReader.fromBytes(b('{"a": 1} 42'));
    r2.beginObject();
    Expect.equals('a', r2.nextName());
    Expect.equals(1, r2.readInt());
    r2.endObject();
    Expect.isFalse(r2.hasNext());
    Expect.equals(JsonTokenType.none, r2.peek());
    Expect.throwsFormatException(() => r2.readInt());
  }

  // Clean EOF after container: peek returns endOfDocument
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1}   '));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    r.endObject();
    Expect.isFalse(r.hasNext());
    Expect.equals(JsonTokenType.endOfDocument, r.peek());
  }

  // Clean EOF after primitive: peek returns endOfDocument
  {
    final r = JsonTokenReader.fromBytes(b('100'));
    Expect.equals(100, r.readInt());
    Expect.isFalse(r.hasNext());
    Expect.equals(JsonTokenType.endOfDocument, r.peek());
  }

  // Disallow container after root value
  {
    final r3 = JsonTokenReader.fromBytes(b('"root" [1, 2]'));
    Expect.equals('root', r3.readString());
    Expect.isFalse(r3.hasNext());
    Expect.equals(JsonTokenType.none, r3.peek());
    Expect.throwsFormatException(() => r3.beginArray());
  }

  // Disallow container after container
  {
    final r4 = JsonTokenReader.fromBytes(b('{} {}'));
    r4.beginObject();
    r4.endObject();
    Expect.isFalse(r4.hasNext());
    Expect.equals(JsonTokenType.none, r4.peek());
    Expect.throwsFormatException(() => r4.beginObject());
  }

  // Disallow bool after bool
  {
    final r5 = JsonTokenReader.fromBytes(b('true false'));
    Expect.isTrue(r5.readBool());
    Expect.isFalse(r5.hasNext());
    Expect.equals(JsonTokenType.none, r5.peek());
    Expect.throwsFormatException(() => r5.readBool());
  }

  // Disallow null after null
  {
    final r6 = JsonTokenReader.fromBytes(b('null null'));
    r6.readNull();
    Expect.isFalse(r6.hasNext());
    Expect.equals(JsonTokenType.none, r6.peek());
    Expect.throwsFormatException(() => r6.readNull());
  }

  // Disallow skipValue after root value
  {
    final r7 = JsonTokenReader.fromBytes(b('[1, 2] 3'));
    r7.beginArray();
    Expect.equals(1, r7.readInt());
    Expect.equals(2, r7.readInt());
    r7.endArray();
    Expect.isFalse(r7.hasNext());
    Expect.equals(JsonTokenType.none, r7.peek());
    Expect.throwsFormatException(() => r7.skipValue());
  }

  // Disallow double reading after root double
  {
    final r8 = JsonTokenReader.fromBytes(b('0.123456789012345 3.14'));
    Expect.equals(0.123456789012345, r8.readDouble());
    Expect.isFalse(r8.hasNext());
    Expect.equals(JsonTokenType.none, r8.peek());
    Expect.throwsFormatException(() => r8.readDouble());
  }

  // Disallow getTokenSpan after root value (Round 19 Item 1.1)
  {
    final r = JsonTokenReader.fromBytes(b('123 456'));
    Expect.equals(123, r.readInt());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('{} []'));
    r.beginObject();
    r.endObject();
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('[] {}'));
    r.beginArray();
    r.endArray();
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('"hello" "world"'));
    Expect.equals('hello', r.readString());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('true false'));
    Expect.isTrue(r.readBool());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('null null'));
    r.readNull();
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('123.45 67.89'));
    Expect.equals(123.45, r.readDouble());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('123'));
    Expect.equals(123, r.readInt());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('456 789'));
    r.skipValue();
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('{"k": "v"} [1, 2]'));
    r.skipValue();
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
  {
    final r = JsonTokenReader.fromBytes(b('   "hello"   '));
    final (s1, e1) = r.getTokenSpan();
    final (s2, e2) = r.getTokenSpan();
    Expect.equals(s1, s2);
    Expect.equals(e1, e2);
    Expect.equals('hello', r.readString());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
}

void testTokenReaderSkipValueControlChars() {
  // Reject unescaped control char in nested string within skipValue
  {
    final bytes = Uint8List.fromList([
      123,
      0x22,
      0x61,
      0x22,
      58,
      0x22,
      0x0A,
      0x22,
      125, // {"a": "\n"} where \n is byte 0x0A
    ]);
    final r = JsonTokenReader.fromBytes(bytes);
    Expect.throwsFormatException(() => r.skipValue());
  }

  {
    final bytes = Uint8List.fromList([
      91, 0x22, 0x00, 0x22, 93, // ["\x00"]
    ]);
    final r = JsonTokenReader.fromBytes(bytes);
    Expect.throwsFormatException(() => r.skipValue());
  }
}

void testTokenReaderSkipValueRollback() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Rollback on invalid scalar token in object value
  {
    final r = JsonTokenReader.fromBytes(
      b(r'{"keep": 10, "broken": @#$%^&*, "after": 20}'),
    );
    r.beginObject();
    Expect.equals('keep', r.nextName());
    Expect.equals(10, r.readInt());

    Expect.equals('broken', r.nextName());
    // skipValue on invalid scalar @#$%^&* throws and rolls back
    Expect.throwsFormatException(() => r.skipValue());

    // Reader state is preserved: peek() sees the invalid scalar
    Expect.equals(JsonTokenType.none, r.peek());
  }

  // 2. Rollback on invalid scalar token in array
  {
    final r = JsonTokenReader.fromBytes(b(r'[1, @#$%^&*, 3]'));
    r.beginArray();
    Expect.equals(1, r.readInt());

    // skipValue on invalid scalar @#$%^&* in array throws and rolls back
    Expect.throwsFormatException(() => r.skipValue());

    // Reader state is preserved in array
    Expect.equals(JsonTokenType.none, r.peek());
  }

  // 3. Rollback on mismatched container delimiter in skipValue
  {
    final r = JsonTokenReader.fromBytes(b('{"data": {"a": 1], "after": 2}'));
    r.beginObject();
    Expect.equals('data', r.nextName());

    Expect.throwsFormatException(() => r.skipValue());
    Expect.equals(JsonTokenType.beginObject, r.peek());
  }

  // 4. Negative zero variations in stream array
  {
    final r = JsonTokenReader.fromBytes(b('[-0, 0, -0.0, 0.0, -0e0, -0e5]'));
    r.beginArray();

    // -0 as readNum -> 0 (int)
    final v1 = r.readNum();
    Expect.type<int>(v1);
    Expect.equals(0, v1);

    // 0 as readNum -> 0 (int)
    final v2 = r.readNum();
    Expect.type<int>(v2);
    Expect.equals(0, v2);

    // -0.0 as readNum -> -0.0 (double)
    final v3 = r.readNum();
    Expect.type<double>(v3);
    Expect.equals(-0.0, v3);
    Expect.isTrue(v3.isNegative);

    // 0.0 as readNum -> 0.0 (double)
    final v4 = r.readNum();
    Expect.type<double>(v4);
    Expect.equals(0.0, v4);
    Expect.isFalse(v4.isNegative);

    // -0e0 as readNum -> -0.0 (double)
    final v5 = r.readNum();
    Expect.type<double>(v5);
    Expect.equals(-0.0, v5);
    Expect.isTrue(v5.isNegative);

    // -0e5 as readNum -> -0.0 (double)
    final v6 = r.readNum();
    Expect.type<double>(v6);
    Expect.equals(-0.0, v6);
    Expect.isTrue(v6.isNegative);

    Expect.isFalse(r.hasNext());
    r.endArray();
  }
}

void testWriteNameBytesColonTerminated() {
  final sink1 = BytesBuilder();
  final w1 = JsonTokenWriter.toSink(sink1);
  w1.beginObject();
  w1.writeNameBytes(Uint8List.fromList(utf8.encode('"id":')));
  w1.writeInt(123);
  w1.endObject();
  final out1 = utf8.decode(sink1.takeBytes());
  Expect.equals('{"id":123}', out1);

  final sink2 = BytesBuilder();
  final w2 = JsonTokenWriter.toSink(sink2);
  w2.beginObject();
  w2.writeNameBytes(Uint8List.fromList(utf8.encode('"complex:key":')));
  w2.writeString('val');
  w2.endObject();
  final out2 = utf8.decode(sink2.takeBytes());
  Expect.equals('{"complex:key":"val"}', out2);
}

void testSkipValueScalarGrammarValidation() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Invalid boolean tails
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('true_junk')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('false_alarm')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('nullify')).skipValue(),
  );

  // Invalid number tails and malformed numbers
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('123abc456')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('-xyz')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('-')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('0123')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('+123')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('1.e2')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('1e')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('1e+')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('1.0e-')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('1.')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('-.5')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('-0123')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('123:456')).skipValue(),
  );
  Expect.throwsFormatException(
    () => JsonTokenReader.fromBytes(b('"unterminated')).skipValue(),
  );
}

void testTruncatedDocumentTrailingCommaEof() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // In object: truncated after comma
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1,'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
    Expect.throwsFormatException(() => r.hasNext());
  }
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1,   '));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
    Expect.throwsFormatException(() => r.hasNext());
  }

  // In array: truncated after comma
  {
    final r = JsonTokenReader.fromBytes(b('[1,'));
    r.beginArray();
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
    Expect.throwsFormatException(() => r.hasNext());
  }
  {
    final r = JsonTokenReader.fromBytes(b('[1,   '));
    r.beginArray();
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
    Expect.throwsFormatException(() => r.hasNext());
  }

  // In nested containers: truncated after comma
  {
    final r = JsonTokenReader.fromBytes(b('[[1,'));
    r.beginArray();
    r.beginArray();
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
    Expect.throwsFormatException(() => r.hasNext());
  }
  {
    final r = JsonTokenReader.fromBytes(b('[{"a": 1,'));
    r.beginArray();
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.peek());
    Expect.throwsFormatException(() => r.hasNext());
  }
}

void testMissingCommaEnforcementInGetTokenSpan() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // In object: missing comma between values
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1 "b": 2}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }

  // In array: missing comma between elements
  {
    final r = JsonTokenReader.fromBytes(b('[1 2]'));
    r.beginArray();
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.getTokenSpan());
  }
}

void testSelectNameMultiByteUtf8Keys() {
  final options = JsonKeyOptions.of(['id', 'café', '名前', 'résumé', '🚀']);
  final json = Uint8List.fromList(
    utf8.encode('{"café": 1, "名前": 2, "résumé": 3, "🚀": 4}'),
  );
  final r = JsonTokenReader.fromBytes(json);
  r.beginObject();
  Expect.equals(1, r.selectName(options)); // 'café'
  Expect.equals(1, r.readInt());
  Expect.isTrue(r.hasNext());
  Expect.equals(2, r.selectName(options)); // '名前'
  Expect.equals(2, r.readInt());
  Expect.isTrue(r.hasNext());
  Expect.equals(3, r.selectName(options)); // 'résumé'
  Expect.equals(3, r.readInt());
  Expect.isTrue(r.hasNext());
  Expect.equals(4, r.selectName(options)); // '🚀'
  Expect.equals(4, r.readInt());
  Expect.isFalse(r.hasNext());
  r.endObject();

  // Test selectName with escaped multi-byte UTF-8 keys (fallback path)
  final escapedJson = Uint8List.fromList(
    utf8.encode('{"caf\\u00e9": 10, "\\u540d\\u524d": 20}'),
  );
  final rEsc = JsonTokenReader.fromBytes(escapedJson);
  rEsc.beginObject();
  Expect.equals(1, rEsc.selectName(options)); // 'café'
  Expect.equals(10, rEsc.readInt());
  Expect.isTrue(rEsc.hasNext());
  Expect.equals(2, rEsc.selectName(options)); // '名前'
  Expect.equals(20, rEsc.readInt());
  Expect.isFalse(rEsc.hasNext());
  rEsc.endObject();

  // Test selectString with multi-byte UTF-8
  final stringOptions = JsonKeyOptions.of(['admin', 'café', 'ユーザー']);
  final arrJson = Uint8List.fromList(utf8.encode('["café", "ユーザー"]'));
  final rArr = JsonTokenReader.fromBytes(arrJson);
  rArr.beginArray();
  Expect.equals(1, rArr.selectString(stringOptions)); // 'café'
  Expect.isTrue(rArr.hasNext());
  Expect.equals(2, rArr.selectString(stringOptions)); // 'ユーザー'
  Expect.isFalse(rArr.hasNext());
  rArr.endArray();
}

void testDeepMixedContainerSkipValue1024Levels() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Exact 31-level nested containers: {"a":[{"b":...}]}
  var json31 = '';
  for (var i = 0; i < 15; i++) {
    json31 += '{"k":[';
  }
  json31 += '{"k": 1}'; // 31 levels
  for (var i = 0; i < 15; i++) {
    json31 += ']}';
  }
  final r31 = JsonTokenReader.fromBytes(b(json31));
  r31.skipValue();
  Expect.equals(JsonTokenType.endOfDocument, r31.peek());
  Expect.isFalse(r31.hasNext());

  // 2. Exact 63-level nested containers
  var json63 = '';
  for (var i = 0; i < 31; i++) {
    json63 += '{"k":[';
  }
  json63 += '{"k": 1}'; // 63 levels
  for (var i = 0; i < 31; i++) {
    json63 += ']}';
  }
  final r63 = JsonTokenReader.fromBytes(b(json63));
  r63.skipValue();
  Expect.equals(JsonTokenType.endOfDocument, r63.peek());
  Expect.isFalse(r63.hasNext());

  // 3. Exact 512-level nested containers: 256 pairs of {"k":[
  var json512 = '';
  for (var i = 0; i < 256; i++) {
    json512 += '{"k":[';
  }
  json512 += '42';
  for (var i = 0; i < 256; i++) {
    json512 += ']}';
  }
  final r512 = JsonTokenReader.fromBytes(b(json512));
  r512.skipValue();
  Expect.equals(JsonTokenType.endOfDocument, r512.peek());
  Expect.isFalse(r512.hasNext());

  // 4. Exact 1000-level nested containers: 500 pairs of {"k":[
  var json1000 = '';
  for (var i = 0; i < 500; i++) {
    json1000 += '{"k":[';
  }
  json1000 += '42';
  for (var i = 0; i < 500; i++) {
    json1000 += ']}';
  }
  final r1000 = JsonTokenReader.fromBytes(b(json1000));
  r1000.skipValue();
  Expect.equals(JsonTokenType.endOfDocument, r1000.peek());
  Expect.isFalse(r1000.hasNext());

  // 5. 1024-level alternating objects and arrays: 512 pairs of {"k":[
  var deepJson = '';
  for (var i = 0; i < 512; i++) {
    deepJson += '{"k":[';
  }
  deepJson += '42';
  for (var i = 0; i < 512; i++) {
    deepJson += ']}';
  }
  final r = JsonTokenReader.fromBytes(b(deepJson));
  r.skipValue();
  Expect.equals(JsonTokenType.endOfDocument, r.peek());
  Expect.isFalse(r.hasNext());

  // 5b. 1024-level deep container followed by trailing token
  final deepWithTrailing = b('[$deepJson, "trailing"]');
  final rTrailing = JsonTokenReader.fromBytes(deepWithTrailing);
  rTrailing.beginArray();
  rTrailing.skipValue();
  Expect.equals(JsonTokenType.string, rTrailing.peek());
  Expect.equals('trailing', rTrailing.readString());
  Expect.isFalse(rTrailing.hasNext());
  rTrailing.endArray();

  // 6. Mismatched delimiter at depth 512: array closed with '}' at depth 513
  var mismatchArrayAt513 = '';
  for (var i = 0; i < 256; i++) {
    mismatchArrayAt513 += '{"k":['; // 512 levels
  }
  mismatchArrayAt513 += '['; // 513th level: array
  mismatchArrayAt513 += '}'; // Wrong closing delimiter '}' instead of ']'
  for (var i = 0; i < 256; i++) {
    mismatchArrayAt513 += ']}';
  }
  final rMismatchArray = JsonTokenReader.fromBytes(b(mismatchArrayAt513));
  Expect.throwsFormatException(() => rMismatchArray.skipValue());

  // 7. Mismatched delimiter at depth 1000: object closed with ']' at depth 1001
  var mismatchObjectAt1001 = '';
  for (var i = 0; i < 500; i++) {
    mismatchObjectAt1001 += '{"k":['; // 1000 levels
  }
  mismatchObjectAt1001 += '{"k": 10]'; // 1001st level object closed with ']'
  for (var i = 0; i < 500; i++) {
    mismatchObjectAt1001 += ']}';
  }
  final rMismatchObj = JsonTokenReader.fromBytes(b(mismatchObjectAt1001));
  Expect.throwsFormatException(() => rMismatchObj.skipValue());

  // 8. Maximum depth limit (> 1024) throws FormatException
  var deep1025 = '';
  for (var i = 0; i < 512; i++) {
    deep1025 += '{"k":[';
  }
  deep1025 += '{"k": 1}'; // 1025th level
  for (var i = 0; i < 512; i++) {
    deep1025 += ']}';
  }
  final r1025 = JsonTokenReader.fromBytes(b(deep1025));
  Expect.throwsFormatException(() => r1025.skipValue());
}

void testClosureFreeScalarStreamingAndRollback() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Direct typed reads across a stream
  final streamJson = b(
    '[123, -456, 3.14159, -0.0, true, false, null, "text", 999999999999]',
  );
  final r = JsonTokenReader.fromBytes(streamJson);
  r.beginArray();
  Expect.equals(123, r.readInt());
  Expect.equals(-456, r.readInt());
  Expect.equals(3.14159, r.readDouble());
  final n0 = r.readDouble();
  Expect.equals(-0.0, n0);
  Expect.isTrue(n0.isNegative);
  Expect.isTrue(r.readBool());
  Expect.isFalse(r.readBool());
  r.readNull();
  Expect.equals('text', r.readString());
  Expect.equals(999999999999, r.readNum());
  Expect.isFalse(r.hasNext());
  r.endArray();

  // 2. Rollback on readInt() FormatException
  {
    final rFail = JsonTokenReader.fromBytes(b('[invalid, 123]'));
    rFail.beginArray();
    Expect.throwsFormatException(() => rFail.readInt());
    Expect.equals(JsonTokenType.none, rFail.peek());
  }

  // 3. Rollback on readDouble() FormatException
  {
    final rFail = JsonTokenReader.fromBytes(b('["not_a_double", 123]'));
    rFail.beginArray();
    Expect.throwsFormatException(() => rFail.readDouble());
    Expect.equals(JsonTokenType.string, rFail.peek());
    Expect.equals('not_a_double', rFail.readString());
  }

  // 4. Rollback on readBool() FormatException
  {
    final rFail = JsonTokenReader.fromBytes(b('[123, true]'));
    rFail.beginArray();
    Expect.throwsFormatException(() => rFail.readBool());
    Expect.equals(JsonTokenType.number, rFail.peek());
    Expect.equals(123, rFail.readInt());
  }

  // 5. Rollback on readNull() FormatException
  {
    final rFail = JsonTokenReader.fromBytes(b('[true, null]'));
    rFail.beginArray();
    Expect.throwsFormatException(() => rFail.readNull());
    Expect.equals(JsonTokenType.boolean, rFail.peek());
    Expect.isTrue(rFail.readBool());
    rFail.readNull();
  }
}

void testZeroAllocationColonTerminatedKeys() {
  final sink = BytesBuilder();
  final w = JsonTokenWriter.toSink(sink);
  w.beginObject();
  w.writeNameBytes(Uint8List.fromList(utf8.encode('"user_id":')));
  w.writeInt(42);
  w.writeNameBytes(Uint8List.fromList(utf8.encode('"user_name":')));
  w.writeString('Alice');
  w.writeNameBytes(Uint8List.fromList(utf8.encode(r'"escaped\nkey":')));
  w.writeBool(true);
  w.endObject();
  final json = utf8.decode(sink.takeBytes());
  Expect.equals(
    r'{"user_id":42,"user_name":"Alice","escaped\nkey":true}',
    json,
  );
}

void testTokenReaderSkipValueInvalidEscapes() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // Valid escapes in reader.skipValue()
  final valid = [
    r'"hello \n world \t \" \\ \/ \b \f \r \u1234 done"',
    r'{"key": "hello \n \" \\ \/ \b \f \r \t \uFFFF"}',
    r'["valid", "\"", "\\", "\/", "\b", "\f", "\n", "\r", "\t", "\u1234"]',
  ];
  for (final s in valid) {
    final reader = JsonTokenReader.fromBytes(b(s));
    reader.skipValue();
    Expect.equals(JsonTokenType.endOfDocument, reader.peek());
  }

  // Invalid escapes in scalar strings
  final invalidScalars = [
    r'"\z"',
    r'"\0"',
    r'"\a"',
    r'"\1"',
    r'"\u12"',
    r'"\u"',
    r'"\u123"',
    r'"\u12g4"',
  ];
  for (final s in invalidScalars) {
    final reader = JsonTokenReader.fromBytes(b(s));
    Expect.throwsFormatException(
      () => reader.skipValue(),
      'reader.skipValue() should throw on invalid escape in $s',
    );
  }

  // Unterminated backslash at EOF in scalar string
  final unterminatedScalar = Uint8List.fromList([0x22, 0x5C]); // '"\'
  final rUnterm = JsonTokenReader.fromBytes(unterminatedScalar);
  Expect.throwsFormatException(() => rUnterm.skipValue());

  // Invalid escapes inside container with state rollback check
  final invalidContainers = [
    r'{"key": "\z"}',
    r'{"k\z": 1}',
    r'{"k": "\u12"}',
    r'{"k": "\u123G"}',
    r'["\z"]',
    r'["\0"]',
    r'["\a"]',
    r'["\u12"]',
    r'["\u123G"]',
  ];
  for (final c in invalidContainers) {
    final reader = JsonTokenReader.fromBytes(b(c));
    Expect.throwsFormatException(
      () => reader.skipValue(),
      'reader.skipValue() should throw on invalid escape in container $c',
    );
  }

  // Unterminated escape at EOF inside container
  final unterminatedInArray = Uint8List.fromList([0x5B, 0x22, 0x5C]); // '["\'
  final rArray = JsonTokenReader.fromBytes(unterminatedInArray);
  Expect.throwsFormatException(() => rArray.skipValue());

  final unterminatedInObject = Uint8List.fromList([0x7B, 0x22, 0x5C]); // '{"\'
  final rObject = JsonTokenReader.fromBytes(unterminatedInObject);
  Expect.throwsFormatException(() => rObject.skipValue());

  // Verify rollback on skipValue() failure inside array
  final rRollback = JsonTokenReader.fromBytes(b(r'[1, "\z", 3]'));
  rRollback.beginArray();
  Expect.equals(1, rRollback.readInt());
  Expect.throwsFormatException(() => rRollback.skipValue());
  // Offset was rolled back, peek() should still see string
  Expect.equals(JsonTokenType.string, rRollback.peek());
}

void testSelectNameMalformedUtf8() {
  final options = JsonKeyOptions.of(['id', 'name', 'café']);

  // 1. Invalid UTF-8 bytes in key with allowMalformed: false (default) throws FormatException
  // Byte 0xFF is invalid UTF-8
  final malformedKey1 = Uint8List.fromList([
    0x7B,
    0x22,
    0xFF,
    0x22,
    0x3A,
    0x31,
    0x7D,
  ]); // {"\xFF": 1}
  final r1 = JsonTokenReader.fromBytes(malformedKey1);
  r1.beginObject();
  Expect.throwsFormatException(() => r1.selectName(options));

  // Truncated multi-byte UTF-8 sequence: 0xC3 followed by quote
  final malformedKey2 = Uint8List.fromList([
    0x7B,
    0x22,
    0xC3,
    0x22,
    0x3A,
    0x31,
    0x7D,
  ]); // {"\xC3": 1}
  final r2 = JsonTokenReader.fromBytes(malformedKey2);
  r2.beginObject();
  Expect.throwsFormatException(() => r2.selectName(options));

  // Multi-byte invalid sequence: 0xFF, 0xFE
  final malformedKey3 = Uint8List.fromList([
    0x7B,
    0x22,
    0xFF,
    0xFE,
    0x22,
    0x3A,
    0x31,
    0x7D,
  ]);
  final r3 = JsonTokenReader.fromBytes(malformedKey3);
  r3.beginObject();
  Expect.throwsFormatException(() => r3.selectName(options));

  // 2. With allowMalformed: true, invalid UTF-8 does not throw, decodes with replacement chars and returns -1
  final r4 = JsonTokenReader.fromBytes(malformedKey1, allowMalformed: true);
  r4.beginObject();
  Expect.equals(-1, r4.selectName(options));
  Expect.equals(1, r4.readInt());
  r4.endObject();
}

void testSelectStringMalformedUtf8() {
  final options = JsonKeyOptions.of(['admin', 'guest', 'café']);

  // 1. Invalid UTF-8 bytes in enum string with allowMalformed: false (default) throws FormatException
  // Byte 0xFF is invalid UTF-8
  final malformedString1 = Uint8List.fromList([
    0x5B,
    0x22,
    0xFF,
    0x22,
    0x5D,
  ]); // ["\xFF"]
  final r1 = JsonTokenReader.fromBytes(malformedString1);
  r1.beginArray();
  Expect.throwsFormatException(() => r1.selectString(options));

  // Truncated multi-byte UTF-8 sequence: 0xC3 followed by quote
  final malformedString2 = Uint8List.fromList([
    0x5B,
    0x22,
    0xC3,
    0x22,
    0x5D,
  ]); // ["\xC3"]
  final r2 = JsonTokenReader.fromBytes(malformedString2);
  r2.beginArray();
  Expect.throwsFormatException(() => r2.selectString(options));

  // Multi-byte invalid sequence: 0xFF, 0xFE
  final malformedString3 = Uint8List.fromList([
    0x5B,
    0x22,
    0xFF,
    0xFE,
    0x22,
    0x5D,
  ]);
  final r3 = JsonTokenReader.fromBytes(malformedString3);
  r3.beginArray();
  Expect.throwsFormatException(() => r3.selectString(options));

  // 2. With allowMalformed: true, invalid UTF-8 does not throw, returns -1
  final r4 = JsonTokenReader.fromBytes(malformedString1, allowMalformed: true);
  r4.beginArray();
  Expect.equals(-1, r4.selectString(options));
  r4.endArray();
}

void testTokenReaderSkipObjectMember() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Basic object member skipping when positioned before property name
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": 1, "b": 2, "c": 3}'));
    reader.beginObject();
    Expect.equals(JsonTokenType.propertyName, reader.peek());
    reader.skipValue(); // skips "a": 1
    Expect.isTrue(reader.hasNext());
    Expect.equals('b', reader.nextName());
    Expect.equals(2, reader.readInt());
    reader.skipValue(); // skips "c": 3
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // 2. Skipping members with complex nested containers (objects, arrays, strings with escapes)
  {
    final json =
        '{"meta": {"id": 1, "tags": ["x", "y"]}, "target": "keep", "skipList": [10, 20]}';
    final reader = JsonTokenReader.fromBytes(b(json));
    reader.beginObject();
    reader.skipValue(); // skips "meta": {...}
    Expect.isTrue(reader.hasNext());
    Expect.equals('target', reader.nextName());
    Expect.equals('keep', reader.readString());
    reader.skipValue(); // skips "skipList": [...]
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // 3. Consecutive skipValue calls skipping all members
  {
    final reader = JsonTokenReader.fromBytes(
      b('{"k1": 1, "k2": 2, "k3": 3, "k4": 4}'),
    );
    reader.beginObject();
    reader.skipValue(); // skips "k1": 1
    reader.skipValue(); // skips "k2": 2
    reader.skipValue(); // skips "k3": 3
    Expect.isTrue(reader.hasNext());
    Expect.equals('k4', reader.nextName());
    Expect.equals(4, reader.readInt());
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // 4. Object member skipping with formatting / whitespace
  {
    final formatted = '''
{
  "first": 100,
  "second": 200
}''';
    final reader = JsonTokenReader.fromBytes(b(formatted));
    reader.beginObject();
    reader.skipValue(); // skips "first": 100
    Expect.isTrue(reader.hasNext());
    Expect.equals('second', reader.nextName());
    Expect.equals(200, reader.readInt());
    reader.endObject();
  }

  // 5. Positioned after property name (existing skipValue behavior)
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": [1, 2], "b": 2}'));
    reader.beginObject();
    Expect.equals('a', reader.nextName());
    reader.skipValue(); // skips [1, 2]
    Expect.isTrue(reader.hasNext());
    Expect.equals('b', reader.nextName());
    Expect.equals(2, reader.readInt());
    reader.endObject();
  }

  // 6. Rollback on FormatException in member skip
  {
    final malformed = b('{"a": [1, 2, "unterminated');
    final reader = JsonTokenReader.fromBytes(malformed);
    reader.beginObject();
    Expect.throwsFormatException(() => reader.skipValue());
    // Cursor rolled back: peek is still propertyName
    Expect.equals(JsonTokenType.propertyName, reader.peek());
  }

  // 7. Empty string key member skipping
  {
    final reader = JsonTokenReader.fromBytes(b('{"": 123, "b": 456}'));
    reader.beginObject();
    reader.skipValue(); // skips "": 123
    Expect.isTrue(reader.hasNext());
    Expect.equals('b', reader.nextName());
    Expect.equals(456, reader.readInt());
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // 8. Escaped key member skipping
  {
    final reader = JsonTokenReader.fromBytes(b('{"\\u0061": 10, "b": 20}'));
    reader.beginObject();
    reader.skipValue(); // skips "\u0061": 10
    Expect.isTrue(reader.hasNext());
    Expect.equals('b', reader.nextName());
    Expect.equals(20, reader.readInt());
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }

  // 9. Primitive values in member skipping (booleans, floats, null, strings)
  {
    final reader = JsonTokenReader.fromBytes(
      b(
        '{"b1": true, "b2": false, "n": null, "d": 3.14159, "s": "hello", "end": 1}',
      ),
    );
    reader.beginObject();
    reader.skipValue(); // b1: true
    reader.skipValue(); // b2: false
    reader.skipValue(); // n: null
    reader.skipValue(); // d: 3.14159
    reader.skipValue(); // s: "hello"
    Expect.isTrue(reader.hasNext());
    Expect.equals('end', reader.nextName());
    Expect.equals(1, reader.readInt());
    reader.endObject();
  }

  // 10. Calling skipValue on empty object throws FormatException and rolls back
  {
    final reader = JsonTokenReader.fromBytes(b('{}'));
    reader.beginObject();
    Expect.throwsFormatException(() => reader.skipValue());
    Expect.equals(JsonTokenType.endObject, reader.peek());
    reader.endObject();
  }

  // 11. Calling skipValue when positioned at endObject after reading all members
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": 1}'));
    reader.beginObject();
    reader.skipValue();
    Expect.equals(JsonTokenType.endObject, reader.peek());
    Expect.throwsFormatException(() => reader.skipValue());
    reader.endObject();
  }

  // 12. Missing colon in object member throws FormatException and rolls back
  {
    final reader = JsonTokenReader.fromBytes(b('{"a" 123}'));
    reader.beginObject();
    Expect.throwsFormatException(() => reader.skipValue());
    Expect.equals(JsonTokenType.propertyName, reader.peek());
  }

  // 13. Missing value after colon throws FormatException and rolls back
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": }'));
    reader.beginObject();
    Expect.throwsFormatException(() => reader.skipValue());
    Expect.equals(JsonTokenType.propertyName, reader.peek());
  }

  // 14. Interleaved selectName and member skipValue
  {
    final options = JsonKeyOptions.of(['keep1', 'skip1', 'keep2']);
    final json = '{"keep1": 10, "skip_other": [1, 2], "keep2": 20}';
    final reader = JsonTokenReader.fromBytes(b(json));
    reader.beginObject();
    Expect.equals(0, reader.selectName(options)); // keep1
    Expect.equals(10, reader.readInt());
    reader.skipValue(); // skips "skip_other": [1, 2]
    Expect.equals(2, reader.selectName(options)); // keep2
    Expect.equals(20, reader.readInt());
    Expect.isFalse(reader.hasNext());
    reader.endObject();
  }
}

void testCanonicalLargeIntegers() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Positive 64-bit integer overflow (2^63 = 9223372036854775808)
  // readInt / parseInt throw FormatException (exact integer required)
  final posOverflowStr = "9223372036854775808";
  final posOverflowBytes = b(posOverflowStr);

  final rPos = JsonTokenReader.fromBytes(posOverflowBytes);
  Expect.throwsFormatException(() => rPos.readInt());

  // readNum returns 9223372036854775808.0 (double), matching json_test.dart:171
  final rPosNum = JsonTokenReader.fromBytes(posOverflowBytes);
  final posNumResult = rPosNum.readNum();
  Expect.type<double>(posNumResult);
  Expect.equals(9223372036854775808.0, posNumResult);

  // jsonUtf8Decode returns 9223372036854775808.0 (double), matching standard jsonDecode
  final posDecoded = jsonUtf8Decode(posOverflowBytes);
  Expect.type<double>(posDecoded);
  Expect.equals(9223372036854775808.0, posDecoded);
  Expect.equals(jsonDecode(posOverflowStr), posDecoded);

  // 2. Negative 64-bit integer overflow (-2^63 - 1 = -9223372036854775809)
  final negOverflowStr = "-9223372036854775809";
  final negOverflowBytes = b(negOverflowStr);

  final rNeg = JsonTokenReader.fromBytes(negOverflowBytes);
  Expect.throwsFormatException(() => rNeg.readInt());

  final rNegNum = JsonTokenReader.fromBytes(negOverflowBytes);
  final negNumResult = rNegNum.readNum();
  Expect.type<double>(negNumResult);
  Expect.equals(-9223372036854775809.0, negNumResult);

  final negDecoded = jsonUtf8Decode(negOverflowBytes);
  Expect.type<double>(negDecoded);
  Expect.equals(-9223372036854775809.0, negDecoded);
  Expect.equals(jsonDecode(negOverflowStr), negDecoded);

  // 3. Valid 64-bit bounds (2^63 - 1 = 9223372036854775807, -2^63 = -9223372036854775808, and 9223372036854774784)
  final maxIntStr = "9223372036854775807";
  final maxIntBytes = b(maxIntStr);
  final rMax = JsonTokenReader.fromBytes(maxIntBytes);
  Expect.equals(int.parse(maxIntStr), rMax.readInt());
  final rMaxNum = JsonTokenReader.fromBytes(maxIntBytes);
  Expect.equals(int.parse(maxIntStr), rMaxNum.readNum());

  final minIntStr = "-9223372036854775808";
  final minIntBytes = b(minIntStr);
  final rMin = JsonTokenReader.fromBytes(minIntBytes);
  Expect.equals(int.parse(minIntStr), rMin.readInt());
  final rMinNum = JsonTokenReader.fromBytes(minIntBytes);
  Expect.equals(int.parse(minIntStr), rMinNum.readNum());

  final regIntStr = "9223372036854774784";
  final regIntBytes = b(regIntStr);
  final rReg = JsonTokenReader.fromBytes(regIntBytes);
  Expect.equals(int.parse(regIntStr), rReg.readInt());
  final rRegNum = JsonTokenReader.fromBytes(regIntBytes);
  Expect.equals(int.parse(regIntStr), rRegNum.readNum());

  // 4. Large integers inside arrays
  final arrJson =
      "[9223372036854775808, -9223372036854775809, 9223372036854774784, -9223372036854775808]";
  final arrBytes = b(arrJson);
  final arrDecoded = jsonUtf8Decode(arrBytes) as List<dynamic>;
  Expect.equals(9223372036854775808.0, arrDecoded[0]);
  Expect.type<double>(arrDecoded[0]);
  Expect.equals(-9223372036854775809.0, arrDecoded[1]);
  Expect.type<double>(arrDecoded[1]);
  Expect.equals(int.parse("9223372036854774784"), arrDecoded[2]);
  if (!identical(1, 1.0)) {
    Expect.type<int>(arrDecoded[2]);
  }
  Expect.equals(int.parse("-9223372036854775808"), arrDecoded[3]);
  if (!identical(1, 1.0)) {
    Expect.type<int>(arrDecoded[3]);
  }
}

void testContainerSyntaxCorruptionInSkipValue() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  final corruptContainers = [
    '[123., 456]',
    '{"a": @#\$%}',
    '[undefined, nullify]',
    '{"a": 1, "b": 2,}',
    '[1, 2,]',
    '{"a": 1 "b": 2}',
    '[1 2 3]',
    '{"a" 123}',
    '{"a":}',
    '{"a":,}',
    '[,]',
    '[: ]',
    '{ : }',
    '{ , }',
    '{"a": 1, 2: 3}',
    '[{"a": [1 2]}]',
    '[{"a": [1, 2,], "b": 3}]',
    '[{"a": 1 "b": 2}]',
    '{"a": {"b": [123., 456]}}',
    '{"a": {"b": @#\$%}}',
    '{"a": 1]}',
    '[1, 2}',
    '{"a": [1, 2}',
    '[{"a": 1]',
    '{"a"}',
    '{"a": , "b": 1}',
    '[1,,2]',
    '{"a": 1,, "b": 2}',
    '{"a": "b" "c": "d"}',
    '["a" "b"]',
    '[true false]',
    '[null null]',
    '[[1] [2]]',
    '[{"a": 1} {"b": 2}]',
    '{"a": [1] "b": [2]}',
    '{"a": {"k": 1} "b": {"k": 2}}',
    '{"a": 1, [1, 2]: 3}',
    '{"a": 1, {}: 3}',
    '{"a": 1, true: 3}',
    '{"a": 1, null: 3}',
    '{"a": 1, 123: 3}',
    '{"a": 1',
    '[1, 2',
    '{"a": 1,',
    '[1, 2,',
    '{"a": "\x01"}',
    '{"\x01": 1}',
    '["\x01"]',
    '{"a": "\\z"}',
    '{"\\z": 1}',
    '["\\z"]',
    '{"a": "\\u12"}',
    '{"\\u12": 1}',
    '["\\u12"]',
    '[' * 1025 + ']' * 1025,
    '[' * 1024 + '1,' + ']' * 1024,
    '{"a": ' * 1024 + '1,' + '}' * 1024,
    '{"a": ' * 1025 + '1' + '}' * 1025,
  ];

  for (final corrupt in corruptContainers) {
    final bytes = b(corrupt);

    // 1. JsonTokenReader.skipValue() throws FormatException
    final reader = JsonTokenReader.fromBytes(bytes);
    Expect.throwsFormatException(
      () => reader.skipValue(),
      'Expected FormatException on reader.skipValue() for: $corrupt',
    );
  }

  // Verify valid containers skip successfully
  final validContainers = [
    '[]',
    '{}',
    '[1, 2, 3]',
    '{"a": 1, "b": 2}',
    '{"a": [1, {"b": 2}], "c": true, "d": null, "e": "hello"}',
    '[[], [[]], [[[]]]]',
    '{"k": {"nested": {"arr": [1, 2, 3]}}}',
    '[' * 1024 + '1' + ']' * 1024,
    '{"a": ' * 1024 + '1' + '}' * 1024,
    '{"a": [' * 512 + '42' + ']}' * 512,
  ];

  for (final valid in validContainers) {
    final bytes = b(valid);
    final reader = JsonTokenReader.fromBytes(bytes);
    reader.skipValue();
    Expect.equals(JsonTokenType.endOfDocument, reader.peek());
  }
}

void testGetTokenSpanTrailingCommaAndEofRejection() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Trailing comma before '}' in object
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": 1,}'));
    reader.beginObject();
    Expect.equals('a', reader.nextName());
    Expect.equals(1, reader.readInt());
    Expect.throwsFormatException(
      () => reader.getTokenSpan(),
      'Expected FormatException on getTokenSpan() for {"a": 1,}',
    );
  }

  // 2. Trailing comma before ']' in array
  {
    final reader = JsonTokenReader.fromBytes(b('[1, 2,]'));
    reader.beginArray();
    Expect.equals(1, reader.readInt());
    Expect.equals(2, reader.readInt());
    Expect.throwsFormatException(
      () => reader.getTokenSpan(),
      'Expected FormatException on getTokenSpan() for [1, 2,]',
    );
  }

  // 3. Trailing comma at EOF in object
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": 1,'));
    reader.beginObject();
    Expect.equals('a', reader.nextName());
    Expect.equals(1, reader.readInt());
    Expect.throwsFormatException(
      () => reader.getTokenSpan(),
      'Expected FormatException on getTokenSpan() for {"a": 1, at EOF',
    );
  }

  // 4. Trailing comma at EOF in array
  {
    final reader = JsonTokenReader.fromBytes(b('[1, 2,  '));
    reader.beginArray();
    Expect.equals(1, reader.readInt());
    Expect.equals(2, reader.readInt());
    Expect.throwsFormatException(
      () => reader.getTokenSpan(),
      'Expected FormatException on getTokenSpan() for [1, 2, at EOF',
    );
  }

  // 5. Trailing comma in afterComma state (after hasNext() consumed comma)
  {
    final reader = JsonTokenReader.fromBytes(b('{"a": 1, }'));
    reader.beginObject();
    Expect.equals('a', reader.nextName());
    Expect.equals(1, reader.readInt());
    Expect.throwsFormatException(
      () => reader.hasNext(), // hasNext throws on trailing comma
    );
  }
}

void testTokenReaderUnifiedRollbackSemantics() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. readInt() rollback on floating point
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 3.14, "b": 10}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.throwsFormatException(() => r.readInt());
    // After rollback, peek() is still number, and readDouble succeeds
    Expect.equals(JsonTokenType.number, r.peek());
    Expect.equals(3.14, r.readDouble());
    Expect.equals('b', r.nextName());
    Expect.equals(10, r.readInt());
    r.endObject();
  }

  // 2. readDouble() rollback on invalid exponent
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1e, "b": 20}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.throwsFormatException(() => r.readDouble());
    // Reader cursor rolled back to start of token
    Expect.equals(JsonTokenType.number, r.peek());
  }

  // 3. readBool() rollback on invalid boolean
  {
    final r = JsonTokenReader.fromBytes(b('{"a": truthy, "b": true}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.throwsFormatException(() => r.readBool());
    Expect.equals(JsonTokenType.boolean, r.peek());
  }

  // 4. readNull() rollback on non-null
  {
    final r = JsonTokenReader.fromBytes(b('{"a": nil, "b": null}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.throwsFormatException(() => r.readNull());
    Expect.equals(JsonTokenType.nullValue, r.peek());
  }

  // 5. nextName() rollback on unclosed quote
  {
    final r = JsonTokenReader.fromBytes(b('{"unclosed: 10}'));
    r.beginObject();
    Expect.throwsFormatException(() => r.nextName());
    // After rollback, cursor is preserved at opening quote
    Expect.equals(JsonTokenType.propertyName, r.peek());
  }

  // 6. selectName() rollback on missing colon
  {
    final options = JsonKeyOptions.of(['key1', 'key2']);
    final r = JsonTokenReader.fromBytes(b('{"key1" 10}'));
    r.beginObject();
    Expect.throwsFormatException(() => r.selectName(options));
    Expect.equals(JsonTokenType.propertyName, r.peek());
  }

  // 7. selectString() rollback on invalid string
  {
    final options = JsonKeyOptions.of(['val1', 'val2']);
    final r = JsonTokenReader.fromBytes(b('{"key": 123}'));
    r.beginObject();
    Expect.equals('key', r.nextName());
    Expect.throwsFormatException(() => r.selectString(options));
    Expect.equals(JsonTokenType.number, r.peek());
    Expect.equals(123, r.readInt());
    r.endObject();
  }

  // 8. readString() rollback on invalid string
  {
    final r = JsonTokenReader.fromBytes(b('{"key": "unclosed}'));
    r.beginObject();
    Expect.equals('key', r.nextName());
    Expect.throwsFormatException(() => r.readString());
    Expect.equals(JsonTokenType.string, r.peek());
  }

  // 9. hasNext() rollback on unexpected end of document after comma
  {
    final r = JsonTokenReader.fromBytes(b('{"a": 1,'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.equals(1, r.readInt());
    Expect.throwsFormatException(() => r.hasNext());
    Expect.throwsFormatException(() => r.hasNext());
  }

  // 10. readNum() rollback on malformed scalar
  {
    final r = JsonTokenReader.fromBytes(b('{"a": invalid, "b": 123}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.throwsFormatException(() => r.readNum());
    Expect.equals(JsonTokenType.none, r.peek());
  }

  // 11. skipValue() rollback on malformed container
  {
    final r = JsonTokenReader.fromBytes(b('{"a": {"unclosed: 1}, "b": 2}'));
    r.beginObject();
    Expect.equals('a', r.nextName());
    Expect.throwsFormatException(() => r.skipValue());
    Expect.equals(JsonTokenType.beginObject, r.peek());
  }
}

void testReadStringSpanAndBytes() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. bytes property exposure
  {
    final rawBytes = b('["test", 123]');
    final reader = JsonTokenReader.fromBytes(rawBytes);
    Expect.identical(rawBytes, reader.bytes);
  }

  // 2. Standalone root string span
  {
    final json = '"hello world"';
    final bytes = b(json);
    final reader = JsonTokenReader.fromBytes(bytes);
    Expect.equals(JsonTokenType.string, reader.peek());
    final (start, end) = reader.readStringSpan();
    Expect.equals(1, start);
    Expect.equals(bytes.length - 1, end);
    Expect.equals('hello world', utf8.decode(reader.bytes.sublist(start, end)));
    Expect.equals(JsonTokenType.endOfDocument, reader.peek());
    Expect.isFalse(reader.hasNext());
  }

  // 3. Array of strings including empty, multi-byte UTF-8, and escape sequences
  {
    final json = '["", "Alice", "Dart 🎯", "escaped\\nline", "last"]';
    final bytes = b(json);
    final reader = JsonTokenReader.fromBytes(bytes);
    reader.beginArray();

    // ""
    Expect.isTrue(reader.hasNext());
    var (start, end) = reader.readStringSpan();
    Expect.equals(start, end);
    Expect.equals('', utf8.decode(reader.bytes.sublist(start, end)));

    // "Alice"
    Expect.isTrue(reader.hasNext());
    (start, end) = reader.readStringSpan();
    Expect.equals('Alice', utf8.decode(reader.bytes.sublist(start, end)));

    // "Dart 🎯" (multi-byte UTF-8)
    Expect.isTrue(reader.hasNext());
    (start, end) = reader.readStringSpan();
    Expect.equals('Dart 🎯', utf8.decode(reader.bytes.sublist(start, end)));

    // "escaped\\nline" (verbatim escape bytes preserved in span)
    Expect.isTrue(reader.hasNext());
    (start, end) = reader.readStringSpan();
    Expect.equals(
      r'escaped\nline',
      utf8.decode(reader.bytes.sublist(start, end)),
    );
    Expect.equals(
      'escaped\nline',
      jsonUtf8Decode(reader.bytes.sublist(start - 1, end + 1)),
    );

    // "last"
    Expect.isTrue(reader.hasNext());
    (start, end) = reader.readStringSpan();
    Expect.equals('last', utf8.decode(reader.bytes.sublist(start, end)));

    Expect.isFalse(reader.hasNext());
    reader.endArray();
    Expect.equals(JsonTokenType.endOfDocument, reader.peek());
  }

  // 4. Object fields with readStringSpan
  {
    final json =
        '{"id": "550e8400-e29b-41d4-a716-446655440000", "count": 42, "tag": "prod"}';
    final bytes = b(json);
    final reader = JsonTokenReader.fromBytes(bytes);
    reader.beginObject();

    Expect.isTrue(reader.hasNext());
    Expect.equals('id', reader.nextName());
    final (idStart, idEnd) = reader.readStringSpan();
    Expect.equals(
      '550e8400-e29b-41d4-a716-446655440000',
      utf8.decode(reader.bytes.sublist(idStart, idEnd)),
    );

    Expect.isTrue(reader.hasNext());
    Expect.equals('count', reader.nextName());
    Expect.equals(42, reader.readInt());

    Expect.isTrue(reader.hasNext());
    Expect.equals('tag', reader.nextName());
    final (tagStart, tagEnd) = reader.readStringSpan();
    Expect.equals('prod', utf8.decode(reader.bytes.sublist(tagStart, tagEnd)));

    Expect.isFalse(reader.hasNext());
    reader.endObject();
    Expect.equals(JsonTokenType.endOfDocument, reader.peek());
  }

  // 5. Rollback semantics on readStringSpan error
  {
    final reader = JsonTokenReader.fromBytes(b('[123, "valid"]'));
    reader.beginArray();

    // Calling readStringSpan on integer token must throw FormatException and roll back
    Expect.throwsFormatException(() => reader.readStringSpan());

    // Reader state preserved: readInt succeeds
    Expect.equals(123, reader.readInt());

    Expect.isTrue(reader.hasNext());
    final (start, end) = reader.readStringSpan();
    Expect.equals('valid', utf8.decode(reader.bytes.sublist(start, end)));
    Expect.isFalse(reader.hasNext());
    reader.endArray();
  }

  // 6. Rollback on unclosed string in readStringSpan
  {
    final reader = JsonTokenReader.fromBytes(b('["unclosed'));
    reader.beginArray();
    Expect.throwsFormatException(() => reader.readStringSpan());
    Expect.equals(JsonTokenType.string, reader.peek());
  }
}

void testStringCacheDirectMapped() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  // 1. Repeated property names and string values hit the cache and return identical instances
  {
    final json =
        '[{"id": "usr_100", "role": "admin", "status": "active"}, '
        '{"id": "usr_200", "role": "admin", "status": "active"}, '
        '{"id": "usr_300", "role": "admin", "status": "active"}]';
    final reader = JsonTokenReader.fromBytes(b(json));
    reader.beginArray();

    reader.beginObject();
    final k1Id = reader.nextName();
    final v1Id = reader.readString();
    final k1Role = reader.nextName();
    final v1Role = reader.readString();
    final k1Status = reader.nextName();
    final v1Status = reader.readString();
    reader.endObject();

    reader.beginObject();
    final k2Id = reader.nextName();
    final v2Id = reader.readString();
    final k2Role = reader.nextName();
    final v2Role = reader.readString();
    final k2Status = reader.nextName();
    final v2Status = reader.readString();
    reader.endObject();

    reader.beginObject();
    final k3Id = reader.nextName();
    final v3Id = reader.readString();
    final k3Role = reader.nextName();
    final v3Role = reader.readString();
    final k3Status = reader.nextName();
    final v3Status = reader.readString();
    reader.endObject();
    reader.endArray();

    Expect.equals('id', k1Id);
    Expect.equals('role', k1Role);
    Expect.equals('status', k1Status);
    Expect.equals('admin', v1Role);
    Expect.equals('active', v1Status);

    Expect.equals('id', k2Id);
    Expect.equals('role', k2Role);
    Expect.equals('status', k2Status);
    Expect.equals('admin', v2Role);
    Expect.equals('active', v2Status);

    Expect.equals('id', k3Id);
    Expect.equals('role', k3Role);
    Expect.equals('status', k3Status);
    Expect.equals('admin', v3Role);
    Expect.equals('active', v3Status);

    // Non-colliding slots (id: slot 13, status: slot 8, active: slot 12) return identical instances
    Expect.isTrue(identical(k1Id, k2Id));
    Expect.isTrue(identical(k1Id, k3Id));
    Expect.isTrue(identical(k1Status, k2Status));
    Expect.isTrue(identical(k1Status, k3Status));
    Expect.isTrue(identical(v1Status, v2Status));
    Expect.isTrue(identical(v1Status, v3Status));

    // Colliding slots (role and admin both map to slot 10) correctly evict and accurately decode
    Expect.equals(k1Role, k2Role);
    Expect.equals(v1Role, v2Role);
  }

  // 2. Direct-mapped slot collision and eviction with >16 keys
  {
    final keys = List.generate(
      32,
      (i) => 'property_key_${i.toString().padLeft(3, '0')}',
    );
    final sb = StringBuffer('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) sb.write(', ');
      sb.write('"${keys[i]}": $i');
    }
    sb.write('}');
    final bytes = b(sb.toString());

    // First pass populates and evicts cache slots
    final reader = JsonTokenReader.fromBytes(bytes);
    reader.beginObject();
    for (var i = 0; i < keys.length; i++) {
      Expect.isTrue(reader.hasNext());
      final name = reader.nextName();
      Expect.equals(keys[i], name);
      Expect.equals(i, reader.readInt());
    }
    reader.endObject();
    Expect.equals(JsonTokenType.endOfDocument, reader.peek());

    // Second reader pass verifies accuracy across all slots
    final reader2 = JsonTokenReader.fromBytes(bytes);
    reader2.beginObject();
    for (var i = 0; i < keys.length; i++) {
      Expect.isTrue(reader2.hasNext());
      final name = reader2.nextName();
      Expect.equals(keys[i], name);
      Expect.equals(i, reader2.readInt());
    }
    reader2.endObject();
  }

  // 3. Strings longer than 64 characters bypass cache accurately
  {
    final longKey = 'a' * 80;
    final longVal = 'b' * 120;
    final json = '{"$longKey": "$longVal", "$longKey": "$longVal"}';
    final reader = JsonTokenReader.fromBytes(b(json));
    reader.beginObject();
    final k1 = reader.nextName();
    final v1 = reader.readString();
    final k2 = reader.nextName();
    final v2 = reader.readString();
    reader.endObject();

    Expect.equals(longKey, k1);
    Expect.equals(longVal, v1);
    Expect.equals(longKey, k2);
    Expect.equals(longVal, v2);
  }

  // 4. Empty strings
  {
    final json = '{"": "", "": ""}';
    final reader = JsonTokenReader.fromBytes(b(json));
    reader.beginObject();
    final k1 = reader.nextName();
    final v1 = reader.readString();
    final k2 = reader.nextName();
    final v2 = reader.readString();
    reader.endObject();

    Expect.equals('', k1);
    Expect.equals('', v1);
    Expect.equals('', k2);
    Expect.equals('', v2);
  }

  // 5. Escaped characters and unicode values
  {
    final json = '{"escaped\\nkey": "val\\n1", "escaped\\nkey": "val\\n1"}';
    final reader = JsonTokenReader.fromBytes(b(json));
    reader.beginObject();
    final k1 = reader.nextName();
    final v1 = reader.readString();
    final k2 = reader.nextName();
    final v2 = reader.readString();
    reader.endObject();

    Expect.equals('escaped\nkey', k1);
    Expect.equals('val\n1', v1);
    Expect.equals('escaped\nkey', k2);
    Expect.equals('val\n1', v2);
  }

  // 6. Control character rejection
  {
    final bytesWithCtrl = Uint8List.fromList([
      34, // '"'
      107, 101, 121, // 'key'
      0x01, // unescaped control character
      34, // '"'
    ]);
    final reader = JsonTokenReader.fromBytes(bytesWithCtrl);
    Expect.throwsFormatException(() => reader.readString());
  }

  // 7. Malformed UTF-8 with allowMalformed
  {
    final malformedBytes = Uint8List.fromList([
      123, // '{'
      34, 107, 34, 58, // '"k":'
      34, 0xFF, 0xFE, 34, // '"\xFF\xFE"'
      125, // '}'
    ]);
    final reader = JsonTokenReader.fromBytes(
      malformedBytes,
      allowMalformed: true,
    );
    reader.beginObject();
    Expect.equals('k', reader.nextName());
    final val = reader.readString();
    Expect.equals('\uFFFD\uFFFD', val);
    reader.endObject();
  }
}
