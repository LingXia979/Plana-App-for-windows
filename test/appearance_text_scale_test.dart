import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/profile/appearance_page.dart';
import 'package:plana_app/main.dart';

/// Use the production app's theme and builder with a small settings route.
class _App extends ConsumerWidget {
  const _App({this.systemScaler});

  final TextScaler? systemScaler;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = const PlanaApp().build(context, ref) as MaterialApp;
    return MaterialApp(
      theme: app.theme,
      darkTheme: app.darkTheme,
      themeMode: app.themeMode,
      builder: systemScaler == null
          ? app.builder
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: systemScaler),
              child: Builder(
                builder: (context) => app.builder!(context, child),
              ),
            ),
      home: const _Page(),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text(
          'Text outside settings',
          key: ValueKey('outside-text'),
          style: TextStyle(fontSize: 14, height: 1),
        ),
        const TextField(key: ValueKey('draft')),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(
              content: Text('Dialog text', key: ValueKey('dialog-text')),
            ),
          ),
          child: const Text('Open dialog'),
        ),
        const Expanded(child: AppearancePage()),
      ],
    ),
  );
}

class _SystemScaler extends TextScaler {
  const _SystemScaler();

  @override
  double scale(double fontSize) =>
      fontSize < 20 ? fontSize * 1.2 : fontSize * 1.1;

  @override
  double get textScaleFactor => 1.2;
}

void main() {
  late AppStores stores;
  late ProviderContainer container;

  setUp(() {
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() {
    container.dispose();
  });

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> settlePrefs(WidgetTester tester) async {
    var done = false;
    unawaited(stores.prefs.idle.then((_) => done = true));
    for (var i = 0; i < 200 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done, isTrue, reason: 'Font preference must finish writing to disk');
  }

  Future<ThemeSettings> reloadTheme(WidgetTester tester) async {
    await settlePrefs(tester);
    return (await tester.runAsync(() async {
      final prefs = await PrefsStore.open(
        stores.desktopOutput.root.parent,
        legacyRead: (_) async => null,
      );
      return loadThemeSettings(prefs);
    }))!;
  }

  Future<void> mount(WidgetTester tester, {TextScaler? systemScaler}) async {
    tester.view.physicalSize = const Size(700, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _App(systemScaler: systemScaler),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'font setting updates the app, keeps drafts and survives reload',
    (tester) async {
      await mount(tester);
      final before = tester.getSize(key('outside-text')).height;
      await tester.enterText(key('draft'), 'cat, outdoors');
      final slider = key('appearance-text-scale');
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final position = tester.getRect(slider);
      await tester.tapAt(Offset(position.right - 24, position.center.dy));
      await tester.pumpAndSettle();
      expect(container.read(themeSettingsProvider).textScale, 1.4);
      expect(tester.getSize(key('outside-text')).height, greaterThan(before));
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'cat, outdoors',
      );
      final restored = await reloadTheme(tester);
      expect(restored.textScale, 1.4);
      final restart = ProviderContainer(
        overrides: [themeInitProvider.overrideWithValue(restored)],
      );
      expect(restart.read(themeSettingsProvider).textScale, 1.4);
      restart.dispose();

      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      var scaler = MediaQuery.textScalerOf(tester.element(key('dialog-text')));
      expect(scaler.scale(14), closeTo(19.6, .001));
      container
          .read(themeSettingsProvider.notifier)
          .patch((settings) => settings.copyWith(textScale: .8));
      await tester.pumpAndSettle();
      expect(key('dialog-text'), findsOneWidget);
      scaler = MediaQuery.textScalerOf(tester.element(key('dialog-text')));
      expect(scaler.scale(14), closeTo(11.2, .001));
      Navigator.of(tester.element(key('dialog-text'))).pop();
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      await tester.tap(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      expect(container.read(themeSettingsProvider).textScale, 1);
      expect(tester.getSize(key('outside-text')).height, before);
      expect((await reloadTheme(tester)).textScale, 1);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('app font size preserves the system scaling curve', (
    tester,
  ) async {
    container
        .read(themeSettingsProvider.notifier)
        .patch((settings) => settings.copyWith(textScale: 1.25));
    await mount(tester, systemScaler: const _SystemScaler());
    final scaler = MediaQuery.textScalerOf(tester.element(key('outside-text')));
    expect(scaler.scale(14), closeTo(14 * 1.2 * 1.25, .001));
    expect(scaler.scale(28), closeTo(28 * 1.1 * 1.25, .001));
    await settlePrefs(tester);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'maximum app font size leaves settings usable in a narrow window',
    (tester) async {
      container
          .read(themeSettingsProvider.notifier)
          .patch((settings) => settings.copyWith(textScale: 1.4));
      await mount(tester);
      tester.view.physicalSize = const Size(360, 650);
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('appearance-text-scale'));
      await tester.pumpAndSettle();
      expect(key('appearance-text-scale').hitTestable(), findsOneWidget);
      await tester.ensureVisible(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      await tester.tap(key('appearance-text-scale-reset'));
      await tester.pumpAndSettle();
      expect(container.read(themeSettingsProvider).textScale, 1);
      await settlePrefs(tester);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
