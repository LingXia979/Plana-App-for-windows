import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/auth/secure_storage.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/features/onboarding/bot_auth_panel.dart';

typedef _Check = ({bool verified, String? sessionId});
typedef _Validation = ({bool valid, String? botUserId, int? expiresAtMs});
const _valid = (
  valid: true,
  botUserId: 'fixture-user',
  expiresAtMs: 2000000000000,
);

class _Base extends BackendBaseNotifier {
  @override
  Future<String> build() async => 'https://example.invalid';
}

class _Storage extends FlutterSecureStorage {
  final values = <String, String>{'auth_mode': 'token'};
  String? failKey;
  Completer<void>? holdSession;
  int sessionWrites = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == 'bot_session') {
      sessionWrites++;
      if (holdSession != null) await holdSession!.future;
    }
    if (key == failKey) throw StateError('Synthetic storage failure');
    if (value != null) values[key] = value;
  }
}

class _Backend extends BackendClient {
  _Backend() : super('https://example.invalid');
  int checks = 0;
  int validations = 0;
  int expiresIn = 30;
  int failuresLeft = 0;
  bool verified = false;
  Completer<_Check>? pendingCheck;
  Completer<_Validation>? pendingValidation;

  @override
  Future<({String code, int expiresIn})> authGenerate() async =>
      (code: 'ABC123', expiresIn: expiresIn);

  @override
  Future<_Check> authCheck(String code) async {
    checks++;
    if (failuresLeft > 0) {
      failuresLeft--;
      throw StateError('Synthetic connection error');
    }
    if (pendingCheck != null) return pendingCheck!.future;
    return (verified: verified, sessionId: verified ? 'fixture-session' : null);
  }

  @override
  Future<_Validation> validate(String sessionId) async {
    validations++;
    return pendingValidation?.future ?? Future.value(_valid);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  late _Backend backend;
  late ProviderContainer container;
  int completed = 0;

  setUp(() {
    completed = 0;
    storage = _Storage();
    backend = _Backend();
    container = ProviderContainer(
      overrides: [
        backendBaseProvider.overrideWith(_Base.new),
        backendClientProvider.overrideWithValue(backend),
        secureStorageProvider.overrideWithValue(storage),
      ],
    );
  });

  Future<void> mount(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
    await container.read(authModeProvider.future);
    await container.read(botSessionProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                child: BotAuthPanel(
                  compact: true,
                  onAuthorized: () => completed++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('获取授权码'));
    await tester.pump();
  }

  Future<void> tick(WidgetTester tester, [int seconds = 3]) async {
    await tester.pump(Duration(seconds: seconds));
    await tester.pump();
  }

  testWidgets(
    'unexpected polling errors recover automatically without replacing the code',
    (tester) async {
      backend.failuresLeft = 2;
      await mount(tester);
      await tick(tester);
      await tick(tester);
      expect(find.textContaining('验证暂时失败'), findsOneWidget);
      await tick(tester);
      expect(find.text('等待 Bot 验证…'), findsOneWidget);
      expect(find.text('ABC123'), findsOneWidget);
      expect(backend.checks, 3);
    },
  );

  for (final key in ['bot_session', 'auth_mode']) {
    testWidgets(
      '$key write failure cannot report authorization success and can retry',
      (tester) async {
        backend.verified = true;
        storage.failKey = key;
        await mount(tester);
        await tick(tester);
        expect(completed, 0);
        await tick(tester);
        expect(completed, 0);
        expect(find.textContaining('安全存储'), findsOneWidget);
        expect(find.text('ABC123'), findsOneWidget);
        storage.failKey = null;
        await tester.tap(find.text('重试'));
        await tester.pump();
        expect(completed, 1);
        expect(container.read(authModeProvider).value, AuthMode.bot);
        expect(
          container.read(botSessionProvider).value?.sessionId,
          'fixture-session',
        );
        expect(storage.values['auth_mode'], 'bot');
        final checks = backend.checks;
        await tick(tester, 6);
        expect(backend.checks, checks);
      },
    );
  }

  for (final action in ['cancel', 'expire', 'unmount']) {
    testWidgets(
      '$action while validation waits ignores its late authorized response',
      (tester) async {
        backend.verified = true;
        backend.expiresIn = action == 'expire' ? 4 : 30;
        backend.pendingValidation = Completer<_Validation>();
        await mount(tester);
        await tick(tester);
        expect(backend.validations, 1);
        if (action == 'cancel') {
          await tester.tap(find.text('取消'));
          await tester.pump();
        } else if (action == 'expire') {
          await tick(tester, 1);
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        backend.pendingValidation!.complete(_valid);
        await tester.pump();
        expect(completed, 0);
        expect(storage.sessionWrites, 0);
        expect(container.read(authModeProvider).value, AuthMode.token);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a new attempt polls even if the old request is pending and the code repeats',
    (tester) async {
      final old = Completer<_Check>();
      final current = Completer<_Check>();
      backend.pendingCheck = old;
      await mount(tester);
      await tick(tester);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.tap(find.text('获取授权码'));
      await tester.pump();
      backend.pendingCheck = current;
      await tick(tester);
      expect(backend.checks, 2);
      old.complete((verified: true, sessionId: 'stale-session'));
      await tester.pump();
      expect(completed, 0);
      expect(storage.sessionWrites, 0);
      await tick(tester);
      expect(
        backend.checks,
        2,
        reason:
            'The stale completion must not unlock the new in-flight request',
      );
      current.complete((verified: false, sessionId: null));
      backend.pendingCheck = null;
      await tester.pump();
      await tick(tester);
      expect(backend.checks, 3);
    },
  );

  testWidgets(
    'authorization persistence finishes once without overlapping polls or cancellation',
    (tester) async {
      backend.verified = true;
      storage.holdSession = Completer<void>();
      await mount(tester);
      await tick(tester);
      expect(storage.sessionWrites, 1);
      await tick(tester, 6);
      expect(backend.checks, 1);
      final cancel = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '取消'),
      );
      expect(cancel.onPressed, isNull);
      storage.holdSession!.complete();
      await tester.pump();
      expect(completed, 1);
      expect(storage.sessionWrites, 1);
    },
  );
}
