import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/proxy_import.dart';

void main() {
  final executable = Platform.environment['PLANA_PROXY_ASSIST_TEST_BIN'];
  for (final chinese in [false, true]) {
    test(
      'native ${chinese ? 'Chinese' : 'English'} screenshot yields only the HTTP/Mixed address',
      () async {
        final result = await Process.run(
          executable!,
          [
            'test/fixtures/proxy_assist/settings${chinese ? '-zh' : ''}.png',
            if (chinese) '--chinese',
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          parseProxyAddresses(
            result.stdout as String,
          ).map((candidate) => candidate.address).toList(),
          ['http://127.0.0.1:7897'],
        );
      },
      skip: executable == null || !Platform.isWindows
          ? 'Set PLANA_PROXY_ASSIST_TEST_BIN to the native OCR test executable on Windows.'
          : false,
    );
  }
}
