import 'dart:convert';

import 'package:expect/expect.dart';

void main() {
  final values = <double>[
    0.0,
    -0.0,
    1.0,
    -1.0,
    1.5,
    -1.5,
    // 13-17 significant digits decimal fraction
    1.234567890123,
    1.2345678901234,
    1.23456789012345,
    1.234567890123456,
    1.2345678901234567,
    // Negative cases
    -1.234567890123,
    -1.2345678901234,
    -1.23456789012345,
    -1.234567890123456,
    -1.2345678901234567,
    // Boundary .5 straddlers
    1e15 - 0.5,
    1e15 + 0.5,
    -1e15 - 0.5,
    -1e15 + 0.5,
    1e16 - 0.5,
    1e16 + 0.5,
    // Typical values
    1e-15,
    1e-16,
    1e15,
    1e16,
    1e17,
  ];

  for (final value in values) {
    final asString = value.toString();
    final asUtf8 = JsonUtf8Encoder().convert(value);
    final utf8String = utf8.decode(asUtf8);
    if (!asString.toLowerCase().contains("e")) {
      Expect.equals(asString, utf8String, "Utf8 encoder mismatch for $value");
    }

    // Round trip
    final decoded = json.decode(utf8String);
    Expect.equals(value, decoded, "Decode mismatch for $value");
  }
}
