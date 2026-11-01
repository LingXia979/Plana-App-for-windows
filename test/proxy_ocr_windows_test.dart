import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/proxy_import.dart';

void main() {
  final executable = Platform.environment['PLANA_PROXY_ASSIST_TEST_BIN'];
  final providedScreenshot = Platform.environment['PLANA_PROXY_OCR_FIXTURE'];
  final cases = [
    (
      name: 'English',
      path: 'test/fixtures/proxy_assist/settings.png',
      flags: <String>[],
    ),
    (
      name: 'Chinese',
      path: 'test/fixtures/proxy_assist/settings-zh.png',
      flags: ['--chinese'],
    ),
    (
      name: 'system proxy',
      path: 'test/fixtures/proxy_assist/system-proxy-settings.png',
      flags: ['--text-only'],
    ),
    if (providedScreenshot != null)
      (
        name: 'provided system proxy',
        path: providedScreenshot,
        flags: ['--text-only'],
      ),
  ];
  for (final fixture in cases) {
    test(
      'native ${fixture.name} screenshot yields only the HTTP/Mixed address',
      () async {
        final result = await Process.run(
          executable!,
          [fixture.path, ...fixture.flags],
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
