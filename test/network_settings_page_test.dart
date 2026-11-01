import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/nai_proxy.dart';
import 'package:plana_app/core/net/network_proxy.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/profile/network_settings_page.dart';

import 'support/desktop_capture.dart';

void main() {
  late Directory root;
  late PrefsStore prefs;
  late ProviderContainer container;
  late Completer<String> probe;
  final tested = <NetworkProxySettings>[];
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_network_ui_');
    prefs = PrefsStore.emptyForTest(root);
    probe = Completer<String>();
    tested.clear();
    container = ProviderContainer(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        desktopModeProvider.overrideWithValue(true),
        networkProxyProbeProvider.overrideWithValue((settings) {
          tested.add(settings);
          return probe.future;
        }),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await prefs.idle;
    await root.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool dark = false,
    double width = 950,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const NetworkSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    final button = find.text('保存并应用');
    await tester.ensureVisible(button);
    await tester.runAsync(() async {
      await tester.tap(button);
      await prefs.idle;
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'save applies only the local proxy; relay remains a separate immediate setting',
    (tester) async {
      await mount(tester);
      await tester.tap(find.widgetWithText(SwitchListTile, '使用本机 HTTP 代理'));
      await tester.enterText(
        find.byKey(const ValueKey('network-proxy-address')),
        'http://localhost:7897',
      );
      await tester.pump();
      expect(container.read(networkProxyProvider).enabled, isFalse);
      expect(find.text('有未应用的修改'), findsOneWidget);
      await save(tester);
      expect(container.read(networkProxyProvider).enabled, isTrue);
      expect(
        container.read(networkProxyProvider).address,
        'http://localhost:7897',
      );
      expect(container.read(naiProxyProvider), isFalse);
      expect(find.text('Plana → Clash / 本机代理 → NovelAI'), findsOneWidget);
      final relay = find.widgetWithText(SwitchListTile, kNaiProxyTitle);
      await tester.ensureVisible(relay);
      await tester.runAsync(() async {
        await tester.tap(relay);
        await prefs.idle;
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Plana → Clash / 本机代理 → Cloudflare 云端转发 → NovelAI'),
        findsOneWidget,
      );
      expect(
        container.read(networkProxyProvider).address,
        'http://localhost:7897',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wrong protocol is blocked, but disabling always works with an invalid draft',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(networkProxyProvider.notifier)
            .save(const NetworkProxySettings(enabled: true)),
      );
      await mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('network-proxy-address')),
        'socks5://localhost:7891',
      );
      await save(tester);
      expect(find.textContaining('请填写 http://'), findsOneWidget);
      expect(
        container.read(networkProxyProvider).address,
        kDefaultNetworkProxyAddress,
      );
      await tester.tap(find.widgetWithText(SwitchListTile, '使用本机 HTTP 代理'));
      await save(tester);
      expect(container.read(networkProxyProvider).enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'probe neither enables nor saves; editing hides an obsolete probe response',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('测试代理'));
      await tester.pump();
      expect(tested, hasLength(1));
      expect(container.read(networkProxyProvider).enabled, isFalse);
      expect(prefs.get(kNetworkProxyKey), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('network-proxy-address')),
        'http://localhost:7897',
      );
      await tester.runAsync(() async {
        probe.complete('obsolete success');
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('obsolete success'), findsNothing);
      expect(prefs.get(kNetworkProxyKey), isNull);
      probe = Completer<String>();
      await tester.tap(find.text('测试代理'));
      await tester.pump();
      expect(tested.last.address, 'http://localhost:7897');
      await tester.runAsync(() async {
        probe.complete('synthetic reachable');
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('synthetic reachable'), findsOneWidget);
      expect(container.read(networkProxyProvider).enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'another settings entry refreshes a clean form but preserves a local draft',
    (tester) async {
      await mount(tester);
      await tester.runAsync(
        () => container
            .read(networkProxyProvider.notifier)
            .save(
              const NetworkProxySettings(
                enabled: true,
                address: 'http://localhost:7897',
              ),
            ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('network-proxy-address'));
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'http://localhost:7897',
      );
      expect(find.text('有未应用的修改'), findsNothing);
      await tester.enterText(field, 'http://localhost:7898');
      await tester.runAsync(
        () => container
            .read(networkProxyProvider.notifier)
            .save(const NetworkProxySettings(address: 'http://localhost:7900')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'http://localhost:7898',
      );
      expect(find.text('有未应用的修改'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('light desktop settings explain both routes without overflow', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text(kNaiProxyTitle), findsOneWidget);
    expect(find.text(kNaiProxyHint), findsOneWidget);
    expect(find.text('代理访问 NovelAI'), findsNothing);
    await captureDesktop(tester, capture, 'network-proxy-light');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dark narrow layout and enlarged text remain scrollable and actionable',
    (tester) async {
      await mount(tester, dark: true, width: 420, scale: 1.4);
      await captureDesktop(tester, capture, 'network-proxy-dark-narrow');
      await tester.ensureVisible(find.text(kNaiProxyTitle));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('当前已应用的路线'));
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'network-proxy-dark-route');
      expect(tester.takeException(), isNull);
    },
  );
}
