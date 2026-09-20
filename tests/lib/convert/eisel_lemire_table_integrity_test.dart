import 'dart:convert';

import 'package:expect/expect.dart';

// This test verifies that the Eisel-Lemire tables (_power10_Exp, _power10_Sig)
// were not corrupted during relocation to dart:_internal.
// We test this by parsing strings in the byte-path (which uses E-L)
// and validating against the String path (which uses the stock VM double.parse).
void main() {
  final utf8JsonDecoder = utf8.decoder.fuse(json.decoder);

  for (int e = -350; e <= 320; e++) {
    // Generate mantissas that exercise boundary rounding conditions
    for (var m in [
      '1',
      '5',
      '9',
      '123456789012345678',
      '9007199254740991',
      '9007199254740992',
    ]) {
      for (var sign in ['', '-']) {
        final str = '[$sign${m}e$e]';
        double? expectedStrPath;
        try {
          expectedStrPath = (json.decode(str) as List)[0] as double?;
        } catch (_) {
          expectedStrPath = null;
        }

        double? actualBytePath;
        try {
          actualBytePath =
              (utf8JsonDecoder.convert(utf8.encode(str)) as List)[0] as double?;
        } catch (_) {
          actualBytePath = null;
        }

        if (expectedStrPath == null) {
          Expect.isNull(actualBytePath, 'Byte path should fail to parse $str');
        } else {
          Expect.isNotNull(actualBytePath, 'Byte path failed to parse $str');
          Expect.equals(
            expectedStrPath,
            actualBytePath,
            'Mismatch on parsing $str',
          );
        }
      }
    }
  }
}
