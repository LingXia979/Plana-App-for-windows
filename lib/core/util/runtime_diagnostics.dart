import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';

/// Local diagnostics survive process exit. Never pass request bodies or images.
class RuntimeDiagnostics {
  RuntimeDiagnostics._(this.file, this.maxBytes);

  final File file;
  final int maxBytes;
  bool _writing = false;
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;
  FlutterExceptionHandler? _flutterHandler;
  bool Function(Object, StackTrace)? _platformHandler;
  static RuntimeDiagnostics? current;
  static int _session = 0;

  static Directory defaultDirectory() {
    if (Platform.isWindows) {
      return Directory(
        p.join(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
          kAppName,
          'diagnostics',
        ),
      );
    }
    if (Platform.isMacOS) {
      return Directory(
        p.join(
          Platform.environment['HOME'] ?? Directory.systemTemp.path,
          'Library',
          'Logs',
          kAppName,
        ),
      );
    }
    return Directory(
      p.join(
        Platform.environment['XDG_STATE_HOME'] ??
            p.join(
              Platform.environment['HOME'] ?? Directory.systemTemp.path,
              '.local',
              'state',
            ),
        'plana-app-for-windows',
        'diagnostics',
      ),
    );
  }

  static RuntimeDiagnostics? initialize({Directory? directory}) {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return null;
    }
    current?.dispose();
    final diagnostics = open(directory ?? defaultDirectory());
    current = diagnostics;
    diagnostics?.installHandlers();
    return diagnostics;
  }

  static RuntimeDiagnostics? open(
    Directory directory, {
    int maxBytes = 1024 * 1024,
  }) {
    if (maxBytes < 128) throw ArgumentError.value(maxBytes, 'maxBytes');
    try {
      directory.createSync(recursive: true);
      final old =
          directory
              .listSync(followLinks: false)
              .whereType<File>()
              .where((file) => p.basename(file.path).startsWith('dart-'))
              .where((file) => file.path.endsWith('.log'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in old.take((old.length - 9).clamp(0, old.length))) {
        try {
          file.deleteSync();
          final rotated = File('${file.path}.1');
          if (rotated.existsSync()) rotated.deleteSync();
        } catch (_) {}
      }
      final name =
          'dart-${DateTime.now().toUtc().microsecondsSinceEpoch}'
          '-$pid-${_session++}.log';
      final diagnostics = RuntimeDiagnostics._(
        File(p.join(directory.path, name))..createSync(),
        maxBytes,
      );
      diagnostics.event(
        'session-start',
        'version=$kAppVersion build=$kAppBuild '
            'os=${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      );
      return diagnostics;
    } catch (_) {
      return null;
    }
  }

  static String redact(String input) {
    var text = input.length > 24000 ? '${input.substring(0, 24000)}…' : input;
    text = text.replaceAllMapped(
      RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false),
      (match) {
        final url = Uri.tryParse(match[0]!);
        if (url == null) return '[URL]';
        return url
            .replace(
              userInfo: '',
              query: url.hasQuery ? 'REDACTED' : null,
              fragment: url.hasFragment ? 'REDACTED' : null,
            )
            .toString();
      },
    );
    text = text.replaceAll(
      RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    text = text.replaceAll(
      RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
      '[REDACTED]',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'''((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|authorization|session[_-]?id)["']?\s*[:=]\s*["']?)[^\s,"';&}\]]+''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}[REDACTED]',
    );
    return text.replaceAll(
      RegExp(r'\b(?:sk|nai)-[A-Za-z0-9._-]+'),
      '[REDACTED]',
    );
  }

  void event(String name, [String detail = '']) {
    if (_writing) return;
    _writing = true;
    try {
      final entry =
          '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'event': name, if (detail.isNotEmpty) 'detail': redact(detail)})}\n';
      if (file.lengthSync() + utf8.encode(entry).length > maxBytes) {
        final previous = File('${file.path}.1');
        if (previous.existsSync()) previous.deleteSync();
        file.renameSync(previous.path);
        file.createSync();
      }
      file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
    } catch (_) {
      // A full or read-only disk must not recursively report logging failures.
    } finally {
      _writing = false;
    }
  }

  void error(String source, Object error, StackTrace stack) =>
      event(source, '${error.runtimeType}: $error\n$stack');

  void installHandlers() {
    if (_flutterHandler != null) return;
    _previousFlutterError = FlutterError.onError;
    _previousPlatformError = PlatformDispatcher.instance.onError;
    _flutterHandler = (details) {
      error(
        'flutter-error',
        details.exception,
        details.stack ?? StackTrace.empty,
      );
      _previousFlutterError?.call(details);
    };
    _platformHandler = (exception, stack) {
      error('unhandled-error', exception, stack);
      return _previousPlatformError?.call(exception, stack) ?? false;
    };
    FlutterError.onError = _flutterHandler;
    PlatformDispatcher.instance.onError = _platformHandler;
  }

  void dispose() {
    if (FlutterError.onError == _flutterHandler) {
      FlutterError.onError = _previousFlutterError;
    }
    if (PlatformDispatcher.instance.onError == _platformHandler) {
      PlatformDispatcher.instance.onError = _previousPlatformError;
    }
    if (identical(current, this)) current = null;
  }
}
