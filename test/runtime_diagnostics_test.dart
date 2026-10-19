import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/runtime_diagnostics.dart';

void main() {
  late Directory directory;

  setUp(() => directory = Directory.systemTemp.createTempSync('plana-logs-'));
  tearDown(() => directory.deleteSync(recursive: true));

  test('logs survive closing and reopening a session', () {
    final first = RuntimeDiagnostics.open(directory)!;
    first.event('before-exit', 'ready');
    first.dispose();
    final second = RuntimeDiagnostics.open(directory)!;
    expect(second.file.path, isNot(first.file.path));
    final records = first.file.readAsLinesSync().map(
      (line) => jsonDecode(line),
    );
    expect(records.first['event'], 'session-start');
    expect(records.last['event'], 'before-exit');
    second.dispose();
  });

  test('keeps ten sessions and deletes their matching rotated logs', () {
    final unrelated = File('${directory.path}/user-file.txt')
      ..writeAsStringSync('keep');
    for (var i = 0; i < 14; i++) {
      final name = 'dart-${1000000000000000 + i}-1.log';
      File('${directory.path}/$name').writeAsStringSync('old');
      File('${directory.path}/$name.1').writeAsStringSync('rotated');
    }
    final log = RuntimeDiagnostics.open(directory)!;
    final files = directory.listSync().whereType<File>().toList();
    expect(files.where((file) => file.path.endsWith('.log')), hasLength(10));
    expect(files.where((file) => file.path.endsWith('.log.1')), hasLength(9));
    expect(unrelated.readAsStringSync(), 'keep');
    expect(
      File('${directory.path}/dart-1000000000000000-1.log').existsSync(),
      isFalse,
    );
    log.dispose();
  });

  test('rotates bounded files and retains the latest events', () {
    final log = RuntimeDiagnostics.open(directory, maxBytes: 512)!;
    for (var i = 0; i < 50; i++) {
      log.event('step', 'operation-$i');
    }
    expect(log.file.lengthSync(), lessThanOrEqualTo(512));
    final previous = File('${log.file.path}.1');
    expect(previous.lengthSync(), lessThanOrEqualTo(512));
    expect(log.file.readAsStringSync(), contains('operation-49'));
    expect(directory.listSync(), hasLength(2));
    log.dispose();
  });

  test('unwritable destinations and later IO failure do not throw', () {
    final blocked = File('${directory.path}/blocked')
      ..writeAsStringSync('file');
    expect(RuntimeDiagnostics.open(Directory(blocked.path)), isNull);
    final log = RuntimeDiagnostics.open(directory)!;
    log.file.deleteSync();
    expect(() => log.event('no-file'), returnsNormally);
    expect(
      () => log.error('no-file', StateError('failed'), StackTrace.current),
      returnsNormally,
    );
    log.dispose();
  });

  test('redacts common credentials from errors and URL queries', () {
    const message =
        'https://user:pass@example.test/image?key=secret#token '
        'Bearer abc.def.ghi api_key="private-key" token=private-token '
        'sk-private nai-private eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature';
    expect(() => RuntimeDiagnostics.redact(message), returnsNormally);
    final log = RuntimeDiagnostics.open(directory)!;
    log.error('test-error', StateError(message), StackTrace.current);
    final written = log.file.readAsStringSync();
    for (final secret in [
      'user:pass',
      'key=secret',
      '#token',
      'abc.def.ghi',
      'private-key',
      'private-token',
      'sk-private',
      'nai-private',
      'eyJhbGci',
    ]) {
      expect(written, isNot(contains(secret)), reason: secret);
    }
    expect(written, contains('example.test/image'));
    expect(written, contains('test-error'));
    log.dispose();
  });

  test(
    'records framework and async errors while preserving previous handlers',
    () {
      final originalFlutter = FlutterError.onError;
      final originalPlatform = PlatformDispatcher.instance.onError;
      var frameworkCalls = 0;
      var asyncCalls = 0;
      void flutterHandler(FlutterErrorDetails _) => frameworkCalls++;
      bool platformHandler(Object _, StackTrace _) {
        asyncCalls++;
        return true;
      }

      final log = RuntimeDiagnostics.open(directory)!;
      try {
        FlutterError.onError = flutterHandler;
        PlatformDispatcher.instance.onError = platformHandler;
        log.installHandlers();
        log.installHandlers();
        FlutterError.onError!(
          FlutterErrorDetails(exception: StateError('framework')),
        );
        expect(
          PlatformDispatcher.instance.onError!(
            StateError('async'),
            StackTrace.current,
          ),
          isTrue,
        );
        expect(frameworkCalls, 1);
        expect(asyncCalls, 1);
        final written = log.file.readAsStringSync();
        expect(written, contains('flutter-error'));
        expect(written, contains('unhandled-error'));
        log.dispose();
        expect(FlutterError.onError, flutterHandler);
        expect(PlatformDispatcher.instance.onError, platformHandler);
      } finally {
        log.dispose();
        FlutterError.onError = originalFlutter;
        PlatformDispatcher.instance.onError = originalPlatform;
      }
    },
  );

  test('an unhandled async error retains its default unhandled result', () {
    final original = PlatformDispatcher.instance.onError;
    final log = RuntimeDiagnostics.open(directory)!;
    try {
      PlatformDispatcher.instance.onError = null;
      log.installHandlers();
      expect(
        PlatformDispatcher.instance.onError!(
          StateError('unhandled'),
          StackTrace.current,
        ),
        isFalse,
      );
    } finally {
      log.dispose();
      PlatformDispatcher.instance.onError = original;
    }
  });
}
