import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/backend_config.dart';
import 'package:plana_app/features/onboarding/bot_auth_panel.dart';

class _Base extends BackendBaseNotifier {
  @override
  Future<String> build() async => 'https://example.invalid';
}

class _Backend extends BackendClient {
  _Backend() : super('https://example.invalid');

  int checks = 0;
  int failuresLeft = 0;
  Completer<({bool verified, String? sessionId})>? pending;

  @override
  Future<({String code, int expiresIn})> authGenerate() async =>
      (code: 'ABC123', expiresIn: 30);

  @override
  Future<({bool verified, String? sessionId})> authCheck(String code) async {
    checks++;
    if (failuresLeft > 0) {
      failuresLeft--;
      throw BackendException('无法连接后端');
    }
    if (pending != null) return pending!.future;
    return (verified: false, sessionId: null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mount(WidgetTester tester, _Backend backend) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendBaseProvider.overrideWith(_Base.new),
          backendClientProvider.overrideWithValue(backend),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 420, child: BotAuthPanel(compact: true)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('获取授权码'));
    await tester.pump();
    expect(find.text('ABC123'), findsOneWidget);
  }

  testWidgets(
    'repeated poll failures show retry and recovery resumes polling',
    (tester) async {
      final backend = _Backend()..failuresLeft = 2;
      await mount(tester, backend);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(backend.checks, 1);
      expect(find.textContaining('验证暂时失败'), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(backend.checks, 2);
      expect(find.textContaining('验证暂时失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(backend.checks, 3);
      expect(find.text('等待 Bot 验证…'), findsOneWidget);
      expect(find.text('ABC123'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(backend.checks, 4);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('slow checks do not overlap with later polling ticks', (
    tester,
  ) async {
    final backend = _Backend()
      ..pending = Completer<({bool verified, String? sessionId})>();
    await mount(tester, backend);
    await tester.pump(const Duration(seconds: 3));
    expect(backend.checks, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(backend.checks, 1);
    backend.pending!.complete((verified: false, sessionId: null));
    backend.pending = null;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(backend.checks, 2);
    await tester.pumpWidget(const SizedBox());
  });
}
