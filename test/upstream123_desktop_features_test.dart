import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/nai_endpoint.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/core/ui/theme_swatches.dart';
import 'package:plana_app/features/desktop/desktop_workspace.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/profile/appearance_page.dart';
import 'package:plana_app/features/profile/widgets/token_add_sheet.dart';
import 'package:plana_app/l10n/l10n.dart';
import 'package:plana_app/main.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

// Use the production themes, locale delegates, font scaling and drop host.
class _App extends ConsumerWidget {
  const _App(this.home);
  final Widget home;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = const PlanaApp().build(context, ref) as MaterialApp;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: app.theme,
      darkTheme: app.darkTheme,
      themeMode: app.themeMode,
      locale: app.locale,
      supportedLocales: app.supportedLocales,
      localizationsDelegates: app.localizationsDelegates,
      builder: app.builder,
      home: home,
    );
  }
}

void main() {
  setUpAll(loadDesktopCaptureFonts);
  late AppStores stores;
  late ProviderContainer c;
  var disposed = false;
  final capture = GlobalKey();
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    disposed = false;
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: '{"enableCompletion":false}',
    );
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() {
    if (!disposed) c.dispose();
    stores.flushNow();
  });

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    disposed = true;
    await pumpUntilComplete(tester, stores.flushForExit());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> mount(WidgetTester tester, Widget home, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(key: capture, child: _App(home)),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'new themes and locales round-trip without changing existing desktop preferences',
    () {
      const old = ThemeSettings(
        mode: ThemeMode.dark,
        textScale: 1.4,
        pageAlignment: PageAlignment.left,
        showTools: false,
        collapsiblePromptCards: false,
      );
      for (final accent in floatAccents) {
        for (final language in ['', 'zh', 'en', 'ja']) {
          final current = old.copyWith(
            seedKey: floatThemeKey(accent),
            language: language,
          );
          final restored = ThemeSettings.fromJson(current.toJson());
          expect(restored, current);
          expect(restored.floatAccent, same(accent));
          expect(restored.textScale, 1.4);
          expect(restored.pageAlignment, PageAlignment.left);
          expect(restored.showTools, isFalse);
          expect(restored.collapsiblePromptCards, isFalse);
        }
      }
      for (final seed in themeSeeds) {
        final restored = ThemeSettings.fromJson({'seed': seed.key});
        expect(restored.seed.key, seed.key);
        expect(restored.float, isFalse);
        expect(restored.language, 'zh');
      }
      expect(ThemeSettings.fromJson({'language': 'nope'}).language, 'zh');
    },
  );

  for (final language in ['en', 'ja']) {
    testWidgets(
      '$language desktop parameters fit at 140% and language/theme changes preserve the request',
      (tester) async {
        final settings = c.read(themeSettingsProvider.notifier);
        settings.patch(
          (s) => s.copyWith(
            language: language,
            seedKey: floatThemeKey(floatAccents[2]),
            mode: language == 'ja' ? ThemeMode.dark : ThemeMode.light,
            textScale: 1.4,
          ),
        );
        final editor = c.read(generateProvider.notifier);
        editor.setPrompts(positive: 'synthetic prompt');
        editor.applyParams(
          c
              .read(generateProvider)
              .params
              .copyWith(model: 'NAI 4.5 Full', seed: '12345', steps: 23),
        );
        final before = buildNaiPayload(
          c.read(generateProvider),
          presetId: 'none',
        ).body;
        await mount(
          tester,
          const Scaffold(body: DesktopWorkspace()),
          const Size(1440, 1000),
        );
        final l = lookupAppLocalizations(Locale(language));
        expect(find.text(l.generationSettings), findsOneWidget);
        expect(find.text(l.desktopPromptGuidance), findsOneWidget);
        expect(find.byTooltip(l.randomSeed), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const ValueKey('desktop-seed')));
        await tester.pumpAndSettle();
        await captureDesktop(
          tester,
          capture,
          'upstream123-$language-desktop-140',
        );
        settings.patch((s) => s.copyWith(language: 'zh', seedKey: 'teal'));
        await tester.pumpAndSettle();
        expect(find.text('生成设置'), findsOneWidget);
        expect(
          buildNaiPayload(c.read(generateProvider), presetId: 'none').body,
          before,
        );
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'appearance language and palette selectors work in a narrow desktop pane',
    (tester) async {
      await mount(tester, const AppearancePage(), const Size(420, 1000));
      await tester.tap(find.byKey(const ValueKey('appearance-language')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('English').last,
          matching: find.byType(CheckedPopupMenuItem<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(c.read(themeSettingsProvider).language, 'en');
      await tester.tap(find.byTooltip('浮卡 蓝'));
      await tester.pumpAndSettle();
      expect(c.read(themeSettingsProvider).floatAccent, kFloatBlue);
      expect(tester.takeException(), isNull);
      await captureDesktop(tester, capture, 'upstream123-appearance-light');
      c
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(mode: ThemeMode.dark));
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'upstream123-appearance-dark');
      await tester.tap(find.byTooltip('青'));
      await tester.pumpAndSettle();
      expect(c.read(themeSettingsProvider).float, isFalse);
      expect(c.read(themeSettingsProvider).seedKey, 'teal');
      final selected = tester
          .widgetList<ThemeSwatch>(find.byType(ThemeSwatch))
          .where((s) => s.selected);
      expect(selected.single.label, '青');
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'adding an OpenAI relay preserves its full endpoint across secure-storage reload',
    (tester) async {
      await c.read(naiKeysStoreProvider.future);
      await mount(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showTokenAddSheet(context),
                child: const Text('Add fixture'),
              ),
            ),
          ),
        ),
        const Size(420, 850),
      );
      await tester.tap(find.text('Add fixture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第三方'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenAI 格式'));
      await tester.pumpAndSettle();
      Finder field(String hint) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == hint,
      );
      await tester.enterText(
        field('https://example.com/v1'),
        'https://synthetic-relay.invalid/v1/',
      );
      await tester.enterText(field('接口 key'), 'synthetic-key');
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'upstream123-openai-add');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      final key = c.read(naiKeysStoreProvider).requireValue.single;
      expect(
        key.endpoint,
        'https://synthetic-relay.invalid/v1/chat/completions',
      );
      c.invalidate(naiKeysStoreProvider);
      final restored = await c.read(naiKeysStoreProvider.future);
      expect(restored.single.endpoint, key.endpoint);
      expect(naiEndpointIsChat(restored.single.endpoint), isTrue);
      expect(restored.single.token, 'synthetic-key');
      await finish(tester);
    },
  );
}
