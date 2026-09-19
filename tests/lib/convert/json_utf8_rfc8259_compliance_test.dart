import 'dart:convert';
import 'dart:typed_data';

void main() {
  testTrailingGarbage();
  testUnclosedContainers();
  testInt64Overflow();
  testBufferSizingAndScale();
  print("All tests passed!");
}

void testTrailingGarbage() {
  final badInputs = [
    '123 456',
    '{"a": 1} garbage',
    '[1, 2] ]',
    '12.34 56.78',
    '"hello" "world"',
    'true false',
    'null 123',
    '{"a": 1} {"b": 2}',
  ];
  for (var input in badInputs) {
    try {
      jsonDecode(input);
      throw StateError("Should have thrown on: " + input);
    } on FormatException catch (e) {
      if (!e.message.contains('Unexpected character') &&
          !e.message.contains('Trailing garbage')) {
        print("Exception message: " + e.message);
      }
    }
  }
}

void testUnclosedContainers() {
  final unclosed = ['{', '{"a": 1', '[', '[1, 2', '{"a": 1,', '[1,'];
  for (var input in unclosed) {
    try {
      jsonDecode(input);
      throw StateError("Should have thrown on: " + input);
    } on FormatException catch (e) {}
  }
}

void testInt64Overflow() {
  final validInt64 = '9223372036854775807';
  if (jsonDecode(validInt64) != 9223372036854775807) throw StateError('fail');

  final validInt64Neg = '-9223372036854775808';
  if (jsonDecode(validInt64Neg) != -9223372036854775808)
    throw StateError('fail');

  final overflowInt64 = '9223372036854775808';
  if (jsonDecode(overflowInt64) is! double) throw StateError('fail');

  final overflowInt64Neg = '-9223372036854775809';
  if (jsonDecode(overflowInt64Neg) is! double) throw StateError('fail');

  final deepOverflow = '-92233720368547758080';
  if (jsonDecode(deepOverflow) is! double) throw StateError('fail');
}

void testBufferSizingAndScale() {
  final smallMap = {'a': 1, 'b': 2.0};
  final smallBytes = jsonUtf8Encode(smallMap);
  if (utf8.decode(smallBytes) != '{"a":1,"b":2.0}')
    throw StateError("Small failed");

  final largeList = List.generate(10000, (i) => "item" + i.toString());
  final largeBytes = jsonUtf8Encode(largeList);
  var jsonString = utf8.decode(largeBytes);
  final largeDecoded = jsonDecode(jsonString) as List;
  if (largeDecoded.length != 10000 || largeDecoded[9999] != "item9999") {
    throw StateError("Large encode failed");
  }

  final doubleList = [0.0, -80.0, 55.0, 1.23, 1e20];
  final doubleBytes = jsonUtf8Encode(doubleList);
  final doubleStr = utf8.decode(doubleBytes);
  if (!doubleStr.contains('0.0') ||
      !doubleStr.contains('-80.0') ||
      !doubleStr.contains('55.0')) {
    if (doubleStr != '[0.0,-80.0,55.0,1.23,100000000000000000000.0]' &&
        doubleStr != '[0,-80,55,1.23,100000000000000000000]') {
      throw StateError("Double formatting: " + doubleStr);
    }
  }
}
