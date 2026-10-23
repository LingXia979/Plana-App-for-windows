import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/app_info.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/auth/token_store.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/gen_settings.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/onboarding/welcome_page.dart';

import 'support/pump_until.dart';
import 'support/desktop_capture.dart';

class _GuideSettings extends GenSettingsNotifier {
  Future<void> settled = Future.value();

  @override
  Future<void> patch(GenSettings Function(GenSettings) change) =>
      settled = super.patch(change);
}

void main() {
  late AppStores stores;
  late ProviderContainer container;
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    FlutterSecureStorage.setMockInitialValues({});
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        genSettingsProvider.overrideWith(_GuideSettings.new),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    stores.flushNow();
    debugDefaultTargetPlatformOverride = null;
  });

  Finder key(String name) => find.byKey(ValueKey('desktop-welcome-$name'));
  Finder field(String hint) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == hint,
  );

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1000, 700),
    Size? paneSize,
    bool notify = true,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await stores.prefs.write(
        key: 'gen_settings',
        value: jsonEncode(GenSettings(genNotify: notify).toJson()),
      );
      await Future.wait([
        container.read(genSettingsProvider.future),
        container.read(authModeProvider.future),
        container.read(tokenProvider.future),
        container.read(botSessionProvider.future),
      ]);
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              final theme = ref.watch(themeSettingsProvider);
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.light(theme.seed.color).copyWith(
                  textTheme: AppTheme.light(
                    theme.seed.color,
                  ).textTheme.apply(fontFamily: 'Microsoft YaHei'),
                ),
                darkTheme: AppTheme.dark(theme.seed.color).copyWith(
                  textTheme: AppTheme.dark(
                    theme.seed.color,
                  ).textTheme.apply(fontFamily: 'Microsoft YaHei'),
                ),
                themeMode: theme.mode,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Align(
                    child: SizedBox(
                      width: paneSize?.width,
                      height: paneSize?.height,
                      child: Navigator(
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (context) => Scaffold(
                            body: Column(
                              children: [
                                const Text('原设置页'),
                                TextButton(
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const WelcomePage(replay: true),
                                    ),
                                  ),
                                  child: const Text('重新查看引导'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新查看引导'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> access(WidgetTester tester) async {
    await tap(tester, key('next'));
    await tap(tester, key('next'));
    expect(find.text('生成接入方式'), findsOneWidget);
  }

  Future<void> settleSettings(WidgetTester tester) async {
    var done = false;
    unawaited(
      (container.read(genSettingsProvider.notifier) as _GuideSettings).settled
          .then((_) => done = true),
    );
    await pumpUntil(tester, () => done);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      '${platform.name}: five steps, no notification prompt, completion returns',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final notify = platform == TargetPlatform.windows;
        await mount(tester, notify: notify);
        expect(find.text('欢迎使用 $kAppName'), findsOneWidget);
        expect(find.text(kAppTagline), findsOneWidget);
        expect(find.text('NovelAI 移动创作端'), findsNothing);
        expect(find.byType(PageView), findsNothing);
        await access(tester);
        await tap(tester, key('skip'));
        expect(find.text('跳过扩展'), findsOneWidget);
        await tap(tester, key('next'));
        expect(find.text('第 5 步，共 5 步 · 完成'), findsOneWidget);
        expect(find.text('设置完成'), findsOneWidget);
        expect(find.text('暂未配置'), findsOneWidget);
        expect(find.text('生成进度通知'), findsNothing);
        expect(find.text('开启通知'), findsNothing);
        expect(find.text('暂不开启'), findsNothing);
        await tap(tester, key('next'));
        expect(find.text('原设置页'), findsOneWidget);
        expect(find.byType(WelcomePage), findsNothing);
        expect(container.read(genSettingsProvider).value!.notifyPrimed, isTrue);
        expect(container.read(genSettingsProvider).value!.genNotify, notify);
        await settleSettings(tester);
        await tester.runAsync(() async {
          final saved = jsonDecode(
            (await stores.prefs.read(key: 'gen_settings'))!,
          );
          expect(saved['notifyPrimed'], isTrue);
          expect(saved['genNotify'], notify);
        });
        await finish(tester);
      },
    );
  }

  testWidgets('step navigation and dragging cannot bypass token or Bot setup', (
    tester,
  ) async {
    await mount(tester);
    expect(tester.widget<ListTile>(key('step-4')).enabled, isFalse);
    await tap(tester, key('step-4'));
    expect(find.text('第 1 步，共 5 步 · 欢迎'), findsOneWidget);
    await access(tester);
    expect(tester.widget<FilledButton>(key('next')).onPressed, isNull);
    expect(tester.widget<ListTile>(key('step-3')).enabled, isFalse);
    await tap(tester, key('step-3'));
    await tester.drag(key('content'), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 3 步，共 5 步 · 接入方式'), findsOneWidget);
    await tap(tester, find.text('用 Bot 账户生成'));
    await tap(tester, key('next'));
    expect(find.text('第 4 步，共 5 步 · 扩展功能'), findsOneWidget);
    expect(tester.widget<FilledButton>(key('next')).onPressed, isNull);
    expect(key('skip'), findsNothing);
    expect(tester.widget<ListTile>(key('step-4')).enabled, isFalse);
    await tap(tester, key('step-4'));
    expect(find.text('第 4 步，共 5 步 · 扩展功能'), findsOneWidget);
    await tap(tester, key('back'));
    expect(find.text('第 3 步，共 5 步 · 接入方式'), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
    'form drafts and theme survive back navigation and window resize',
    (tester) async {
      await mount(tester);
      await access(tester);
      await tap(tester, find.text('第三方'));
      await tester.enterText(
        field('https://example.com'),
        'https://relay.example',
      );
      await tester.enterText(field('接口 key'), 'draft-key');
      await tap(tester, key('step-1'));
      await tap(tester, find.text('深色'));
      await tap(tester, find.byTooltip('紫'));
      tester.view.physicalSize = const Size(480, 360);
      await tester.pumpAndSettle();
      expect(key('navigation'), findsNothing);
      await tap(tester, key('next'));
      expect(
        tester.widget<TextField>(field('接口 key')).controller!.text,
        'draft-key',
      );
      expect(
        tester.widget<TextField>(field('https://example.com')).controller!.text,
        'https://relay.example',
      );
      expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);
      expect(container.read(themeSettingsProvider).seedKey, 'violet');
      await tap(tester, key('back'));
      expect(find.text('外观配色'), findsOneWidget);
      expect(
        tester
            .widget<SegmentedButton<ThemeMode>>(
              find.byType(SegmentedButton<ThemeMode>),
            )
            .selected,
        {ThemeMode.dark},
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'small pane uses its own width; fields scroll while footer stays accessible',
    (tester) async {
      await mount(
        tester,
        size: const Size(1280, 800),
        paneSize: const Size(480, 360),
        textScale: 1.3,
      );
      expect(key('navigation'), findsNothing);
      await access(tester);
      await tap(tester, find.text('第三方'));
      final footer = tester.getRect(key('footer'));
      final input = field('接口 key');
      await tester.ensureVisible(input);
      await tester.enterText(input, 'relay-key');
      await tester.ensureVisible(field('https://example.com'));
      await tester.enterText(
        field('https://example.com'),
        'https://relay.example/',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull,
      );
      await tap(tester, find.widgetWithText(FilledButton, '保存'));
      expect(tester.getRect(key('footer')).bottom, footer.bottom);
      expect(
        tester.getRect(key('footer')).contains(tester.getCenter(key('next'))),
        isTrue,
      );
      for (
        var i = 0;
        i < 200 &&
            (container.read(naiKeysStoreProvider).value?.isEmpty ?? true);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      final saved = container.read(naiKeysStoreProvider).value;
      expect(saved!.single.token, 'relay-key');
      expect(saved.single.endpoint, 'https://relay.example');
      expect(key('skip'), findsNothing);
      await tap(tester, key('next'));
      await tap(tester, key('next'));
      expect(find.text('直连 Token · 已保存'), findsOneWidget);
      await tap(tester, key('next'));
      expect(find.text('原设置页'), findsOneWidget);
      await finish(tester);
    },
  );

  for (final scale in [1.0, 1.4]) {
    testWidgets('Windows welcome visual layout at scale $scale', (
      tester,
    ) async {
      await mount(tester, textScale: scale);
      await access(tester);
      await captureDesktop(
        tester,
        capture,
        'windows53-welcome-${(scale * 100).round()}',
      );
      await finish(tester);
    });
  }

  for (final escape in [false, true]) {
    testWidgets(
      'replay can exit early via ${escape ? 'Escape' : 'return button'}',
      (tester) async {
        await mount(tester, notify: false);
        await tap(tester, key('next'));
        await tap(tester, find.text('深色'));
        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        } else {
          await tap(tester, key('close'));
        }
        expect(find.text('原设置页'), findsOneWidget);
        expect(find.byType(WelcomePage), findsNothing);
        expect(
          container.read(genSettingsProvider).value!.notifyPrimed,
          isFalse,
        );
        expect(container.read(genSettingsProvider).value!.genNotify, isFalse);
        expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);
        await finish(tester);
      },
    );
  }
}
