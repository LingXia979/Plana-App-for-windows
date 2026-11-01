import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/nai_proxy.dart';
import 'package:plana_app/core/net/network_proxy.dart';
import 'package:plana_app/core/net/proxy_import.dart';
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/features/profile/network_settings_page.dart';

import 'support/desktop_capture.dart';

void main() {
  late Directory root;
  late PrefsStore prefs;
  late ProviderContainer container;
  late Completer<String> probe;
  late ClipboardContent clipboard;
  late Uint8List screenshot;
  late Future<String> Function(Uint8List) recognize;
  var clipboardReads = 0;
  var fallbackDrops = 0;
  final tested = <NetworkProxySettings>[];
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_network_ui_');
    prefs = PrefsStore.emptyForTest(root);
    probe = Completer<String>();
    screenshot = await File(
      'test/fixtures/proxy_assist/settings.png',
    ).readAsBytes();
    clipboard = ClipboardContent.empty;
    clipboardReads = 0;
    fallbackDrops = 0;
    recognize = (_) async =>
        'Mixed Port: 7897\nSOCKS Port: 7898\nExternal Controller: 9090';
    tested.clear();
    container = ProviderContainer(
      overrides: [
        prefsStoreProvider.overrideWithValue(prefs),
        desktopModeProvider.overrideWithValue(true),
        proxyClipboardReaderProvider.overrideWithValue(() async {
          clipboardReads++;
          return clipboard;
        }),
        proxyImageRecognizerProvider.overrideWithValue(
          (bytes) => recognize(bytes),
        ),
        detectedProxySoftwareProvider.overrideWith(
          (ref, address) async => ProxySoftware.clash,
        ),
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
    bool expanded = true,
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
            home: DesktopImageDropHost(
              child: ImageDropRegion(
                label: 'synthetic artwork importer',
                pasteFallback: true,
                onDrop: (_, _) async {
                  fallbackDrops++;
                },
                child: const NetworkSettingsPage(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (expanded) {
      await tester.tap(find.byKey(const ValueKey('network-proxy-expand')));
      await tester.pumpAndSettle();
    }
  }

  Future<void> toggle(WidgetTester tester) async {
    final control = find.widgetWithText(SwitchListTile, '使用本机 HTTP 代理');
    await tester.ensureVisible(control);
    await tester.runAsync(() async {
      await tester.tap(control);
      await prefs.idle;
    });
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
    'switch applies immediately while saving edits leaves enable state and relay untouched',
    (tester) async {
      await mount(tester);
      await toggle(tester);
      expect(container.read(networkProxyProvider).enabled, isTrue);
      expect(
        container.read(networkProxyRuntimeProvider).settings.enabled,
        isTrue,
      );
      expect(
        container.read(networkProxyProvider).address,
        kDefaultNetworkProxyAddress,
      );
      await tester.enterText(
        find.byKey(const ValueKey('network-proxy-address')),
        'http://localhost:7897',
      );
      await tester.pump();
      expect(container.read(networkProxyProvider).enabled, isTrue);
      expect(find.text('有未应用的修改'), findsOneWidget);
      await save(tester);
      expect(container.read(networkProxyProvider).enabled, isTrue);
      expect(
        container.read(networkProxyProvider).address,
        'http://localhost:7897',
      );
      expect(container.read(naiProxyProvider), isFalse);
      expect(find.text('Plana → Clash → NovelAI'), findsOneWidget);
      final relay = find.widgetWithText(SwitchListTile, kNaiProxyTitle);
      await tester.ensureVisible(relay);
      await tester.runAsync(() async {
        await tester.tap(relay);
        await prefs.idle;
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Plana → Clash → Cloudflare 转发 → NovelAI'),
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
      await toggle(tester);
      expect(container.read(networkProxyProvider).enabled, isFalse);
      expect(
        container.read(networkProxyProvider).address,
        kDefaultNetworkProxyAddress,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('network-proxy-address')),
            )
            .controller!
            .text,
        'socks5://localhost:7891',
      );
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

  testWidgets(
    'clipboard screenshot fills only its HTTP draft, never enables or saves',
    (tester) async {
      clipboard = ClipboardContent(image: screenshot, format: 'png');
      await mount(tester);
      expect(clipboardReads, 0);
      await tester.tap(find.text('粘贴识别'));
      await tester.pumpAndSettle();
      expect(clipboardReads, 1);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('network-proxy-address')),
            )
            .controller!
            .text,
        'http://127.0.0.1:7897',
      );
      expect(container.read(networkProxyProvider).enabled, isFalse);
      expect(prefs.get(kNetworkProxyKey), isNull);
      expect(find.textContaining('已填入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'copied text with multiple valid addresses requires a choice and supports cancellation',
    (tester) async {
      clipboard = const ClipboardContent(
        text: 'Mixed Port: 7897\nHTTP Port: 8080',
      );
      await mount(tester);
      await tester.tap(find.text('粘贴识别'));
      await tester.pumpAndSettle();
      expect(find.text('选择识别到的代理地址'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('network-proxy-address')),
            )
            .controller!
            .text,
        kDefaultNetworkProxyAddress,
      );
      await tester.tap(find.text('粘贴识别'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('http://127.0.0.1:8080'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('network-proxy-address')),
            )
            .controller!
            .text,
        'http://127.0.0.1:8080',
      );
      expect(prefs.get(kNetworkProxyKey), isNull);
    },
  );

  testWidgets(
    'editing during OCR prevents an old result from replacing the new address',
    (tester) async {
      final pending = Completer<String>();
      recognize = (_) => pending.future;
      clipboard = ClipboardContent(image: screenshot, format: 'png');
      await mount(tester);
      await tester.tap(find.text('粘贴识别'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('network-proxy-address'));
      await tester.enterText(field, 'http://127.0.0.1:8888');
      pending.complete('Mixed Port: 7897');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'http://127.0.0.1:8888',
      );
      expect(find.textContaining('已填入'), findsNothing);
      expect(prefs.get(kNetworkProxyKey), isNull);
    },
  );

  testWidgets(
    'clipboard with no usable address preserves the form and explains failure',
    (tester) async {
      clipboard = const ClipboardContent(text: 'SOCKS port: 7891');
      await mount(tester);
      await tester.tap(find.text('粘贴识别'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未找到 HTTP'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('network-proxy-address')),
            )
            .controller!
            .text,
        kDefaultNetworkProxyAddress,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native Ctrl+V image reaches proxy OCR instead of artwork import',
    (tester) async {
      await mount(tester, expanded: false);
      await tester.runAsync(() async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'plana/image_drop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('paste', {
              'bytes': screenshot,
              'bitmap': false,
              'x': 120.0,
              'y': 150.0,
            }),
          ),
          (_) {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('network-proxy-address')),
            )
            .controller!
            .text,
        'http://127.0.0.1:7897',
      );
      expect(clipboardReads, 0);
      expect(find.text('保存并应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated Ctrl+V during recognition never falls through to artwork import',
    (tester) async {
      final pending = Completer<String>();
      var ocrCalls = 0;
      recognize = (_) {
        ocrCalls++;
        return pending.future;
      };
      await mount(tester);
      for (var i = 0; i < 2; i++) {
        await tester.runAsync(() async {
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'plana/image_drop',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('paste', {
                'bytes': screenshot,
                'bitmap': false,
                'x': 120.0,
                'y': 150.0,
              }),
            ),
            (_) {},
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
      }
      expect(ocrCalls, 1);
      expect(fallbackDrops, 0);
      await tester.runAsync(() async {
        pending.complete('Mixed Port: 7897');
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('已填入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual software label persists without changing transport address',
    (tester) async {
      await mount(tester);
      await toggle(tester);
      await tester.tap(find.byType(DropdownButtonFormField<ProxySoftware>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('代理软件').last);
      await tester.pumpAndSettle();
      await save(tester);
      expect(
        container.read(networkProxyProvider).software,
        ProxySoftware.other,
      );
      expect(
        container.read(networkProxyProvider).address,
        kDefaultNetworkProxyAddress,
      );
      expect(find.text('Plana → 代理软件 → NovelAI'), findsOneWidget);
      expect(
        NetworkProxySettings.decode(prefs.get(kNetworkProxyKey)).software,
        ProxySoftware.other,
      );
    },
  );

  testWidgets(
    'collapsed card keeps the switch and address, and edits reveal save controls',
    (tester) async {
      await mount(tester, expanded: false);
      final field = find.byKey(const ValueKey('network-proxy-address'));
      final expand = find.byKey(const ValueKey('network-proxy-expand'));
      expect(field, findsOneWidget);
      expect(find.text('粘贴识别'), findsNothing);
      expect(find.text('保存并应用'), findsNothing);
      expect(find.byType(DropdownButtonFormField<ProxySoftware>), findsNothing);
      await captureDesktop(tester, capture, 'network-proxy-collapsed');
      await toggle(tester);
      expect(container.read(networkProxyProvider).enabled, isTrue);
      expect(find.text('保存并应用'), findsNothing);
      await tester.enterText(field, 'http://127.0.0.1:7897');
      await tester.pumpAndSettle();
      expect(find.text('保存并应用'), findsOneWidget);
      await tester.tap(find.widgetWithText(CheckboxListTile, '本机与局域网直连'));
      await tester.tap(find.byType(DropdownButtonFormField<ProxySoftware>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('代理软件').last);
      await tester.pumpAndSettle();
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(find.text('保存并应用'), findsNothing);
      expect(find.text('有未应用的修改，展开后保存'), findsOneWidget);
      await toggle(tester);
      final applied = container.read(networkProxyProvider);
      expect(applied.enabled, isFalse);
      expect(applied.address, kDefaultNetworkProxyAddress);
      expect(applied.bypassLocal, isTrue);
      expect(applied.software, ProxySoftware.auto);
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'http://127.0.0.1:7897',
      );
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await save(tester);
      final saved = NetworkProxySettings.decode(prefs.get(kNetworkProxyKey));
      expect(saved.enabled, isFalse);
      expect(saved.address, 'http://127.0.0.1:7897');
      expect(saved.bypassLocal, isFalse);
      expect(saved.software, ProxySoftware.other);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed toggle persistence can retry without saving an address draft',
    (tester) async {
      final blocker = File('${root.path}/blocked');
      // Create disk-backed futures in the real async zone, as in setUp.
      await tester.runAsync(() async {
        await blocker.writeAsString('synthetic blocker');
        container.dispose();
        prefs = PrefsStore.emptyForTest(Directory(blocker.path));
        container = ProviderContainer(
          overrides: [
            prefsStoreProvider.overrideWithValue(prefs),
            desktopModeProvider.overrideWithValue(true),
            detectedProxySoftwareProvider.overrideWith(
              (ref, address) async => ProxySoftware.clash,
            ),
          ],
        );
      });
      await mount(tester, expanded: false);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(SwitchListTile, '使用本机 HTTP 代理'));
        try {
          await prefs.idle;
        } on FileSystemException {
          /* The page reports it. */
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('重试保存开关'), findsOneWidget);
      expect(
        container.read(networkProxyRuntimeProvider).settings.enabled,
        isTrue,
      );
      final field = find.byKey(const ValueKey('network-proxy-address'));
      await tester.enterText(field, 'http://127.0.0.1:7897');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await blocker.delete();
        await tester.tap(find.text('重试保存开关'));
        await prefs.idle;
      });
      await tester.pumpAndSettle();
      expect(find.text('重试保存开关'), findsNothing);
      final saved = NetworkProxySettings.decode(prefs.get(kNetworkProxyKey));
      expect(saved.enabled, isTrue);
      expect(saved.address, kDefaultNetworkProxyAddress);
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'http://127.0.0.1:7897',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'toggling during OCR keeps the imported draft separate from the applied address',
    (tester) async {
      final pending = Completer<String>();
      recognize = (_) => pending.future;
      clipboard = ClipboardContent(image: screenshot, format: 'png');
      await mount(tester);
      await tester.tap(find.text('粘贴识别'));
      await tester.pump();
      await toggle(tester);
      pending.complete('服 务 地 址 ： 127 ． 0 ． 0 ． 1 ： 7897');
      await tester.pumpAndSettle();
      expect(find.textContaining('已填入'), findsOneWidget);
      expect(container.read(networkProxyProvider).enabled, isTrue);
      expect(
        container.read(networkProxyProvider).address,
        kDefaultNetworkProxyAddress,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('network-proxy-address')),
            )
            .controller!
            .text,
        'http://127.0.0.1:7897',
      );
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
      final scrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text(kNaiProxyTitle),
        300,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('当前已应用的路线'),
        300,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'network-proxy-dark-route');
      expect(tester.takeException(), isNull);
    },
  );
}
