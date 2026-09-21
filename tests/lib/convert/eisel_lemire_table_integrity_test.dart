import 'dart:convert';
import 'dart:typed_data';

import 'package:expect/expect.dart';

// Verifies Eisel-Lemire fast float parsing across:
// 1. Relocated power-of-10 tables in dart:_internal (exponents -350..320)
// 2. Single-pass 64-bit mantissa + Eisel-Lemire inside _ChunkedJsonParser.parseNumber
// 3. Byte-span fallback in _JsonUtf8Parser.parseDouble and _NumberBuffer (chunk straddling)
void main() {
  final utf8JsonDecoder = utf8.decoder.fuse(json.decoder);

  Object? decodeChunked(Uint8List bytes, int splitIndex) {
    Object? result;
    final sink = utf8JsonDecoder.startChunkedConversion(
      ChunkedConversionSink<Object?>.withCallback((r) => result = r.first),
    );
    if (splitIndex <= 0 || splitIndex >= bytes.length) {
      sink.add(bytes);
    } else {
      sink.add(Uint8List.sublistView(bytes, 0, splitIndex));
      sink.add(Uint8List.sublistView(bytes, splitIndex, bytes.length));
    }
    sink.close();
    return result;
  }

  void verifyLiteral(String rawNum, {bool testAllSplits = false}) {
    final str = '[$rawNum]';
    final bytes = Uint8List.fromList(utf8.encode(str));

    double? expectedValue;
    try {
      expectedValue = double.parse(rawNum);
    } catch (_) {
      expectedValue = null;
    }

    double? actualMono;
    try {
      actualMono = ((utf8JsonDecoder.convert(bytes) as List)[0] as num?)
          ?.toDouble();
    } catch (_) {
      actualMono = null;
    }

    if (expectedValue == null) {
      Expect.isNull(actualMono, 'Byte path should fail to parse $str');
      return;
    }
    Expect.isNotNull(actualMono, 'Byte path failed to parse $str');
    Expect.equals(expectedValue, actualMono, 'Mismatch on mono $str');
    if (expectedValue == 0.0) {
      Expect.equals(
        expectedValue.isNegative,
        actualMono!.isNegative,
        'Negative zero sign mismatch on mono $str',
      );
    }

    if (testAllSplits) {
      for (int split = 1; split < bytes.length; split++) {
        final actualSplit = ((decodeChunked(bytes, split) as List)[0] as num)
            .toDouble();
        Expect.equals(
          expectedValue,
          actualSplit,
          'Mismatch on chunk split $split for $str',
        );
        if (expectedValue == 0.0) {
          Expect.equals(
            expectedValue.isNegative,
            actualSplit.isNegative,
            'Negative zero sign mismatch on chunk split $split for $str',
          );
        }
      }
    }
  }

  for (int e = -350; e <= 320; e++) {
    for (var m in [
      '1',
      '5',
      '9',
      '123456789012345678',
      '9007199254740991',
      '9007199254740992',
    ]) {
      for (var sign in ['', '-']) {
        verifyLiteral('$sign${m}e$e');
      }
    }
  }

  // Fractional, boundary, negative-zero, subnormal, and 19+ digit literals
  // tested across both monolithic and every possible chunk split index.
  final edgeLiterals = <String>[
    '0.0',
    '-0.0',
    '-0.0000000000000000000000000000',
    '-0e10',
    '-0.0e-500',
    '-65.613616999999977',
    '49.871234567890123',
    '83.108200999999998',
    '0.00000000000000000000000012345678901234567',
    '12345678901234567.8',
    '123456789012345678.9',
    '1234567890123456789.0',
    '1234567890123456789.5',
    '-1234567890123456789.5',
    '9223372036854775807.5',
    '-9223372036854775808.5',
    '9999999999999999999',
    '-9999999999999999999',
    '9999999999999999999.0',
    '-9999999999999999999e-10',
    '0.9999999999999999999',
    '0.099999999999999999990',
    '123456789012345678901.23456789',
    '5e-324',
    '-5e-324',
    '2.2250738585072014e-308',
    '2.2250738585072009e-308',
    '1.7976931348623157e+308',
    '1e405',
    '-1e405',
    '1e-405',
    '-1e-405',
    '0.${'0' * 60}1e405',
    '0.${'0' * 100}1e405',
    '1${'0' * 100}e-405',
  ];

  for (final lit in edgeLiterals) {
    verifyLiteral(lit, testAllSplits: true);
  }
}
