import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/import/import_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Uint8List plain, metadata;
  setUp(() async {
    stores = AppStores.ephemeral();
    plain = Uint8List.fromList(
      img.encodePng(img.Image(width: 320, height: 480)),
    );
    metadata = await writeImageMetadataPng(
      plain,
      source: 'NovelAI Diffusion V4.5 4BDE2A90',
      comment: {
        'prompt': 'cat girl, cherry blossoms',
        'uc': 'new negative',
        'seed': 4321,
        'steps': 28,
        'scale': 6.5,
        'sampler': 'k_euler',
        'noise_schedule': 'native',
      },
    );
  });
  tearDown(() async {
    container.dispose();
    stores.flushNow();
    await stores.gallery.idle;
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> drain(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester, {
    bool desktop = true,
    bool hasMetadata = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = desktop
        ? const Size(1440, 900)
        : const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(desktop),
      ],
    );
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: 'original', negative: 'keep negative');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ImportImagePanel(
                      bytes: hasMetadata ? metadata : plain,
                      fileName: 'preview.png',
                      displayName: 'preview',
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await drain(
      tester,
      () =>
          find.byType(ImportImagePanel).evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'desktop preview and options sit side by side; resize preserves selection and import semantics',
    (tester) async {
      await mount(tester);
      expect(
        tester.getRect(key('desktop-import-preview')).right,
        lessThan(tester.getRect(key('desktop-import-details')).left),
      );
      expect(
        tester.getSize(key('desktop-import-window')).width,
        lessThanOrEqualTo(1240),
      );
      expect(
        tester.getSize(key('desktop-import-confirm')).width,
        lessThan(220),
      );
      expect(
        tester.widget<Image>(key('desktop-import-preview')).fit,
        BoxFit.contain,
      );
      final footer = tester.getRect(key('desktop-import-footer'));
      await tester.tap(key('import-select-负向提示词'));
      await tester.tap(find.text('正向提示词'));
      await tester.pumpAndSettle();
      expect(tester.getRect(key('desktop-import-footer')), footer);
      tester.view.physicalSize = const Size(700, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(key('desktop-import-confirm').hitTestable(), findsOneWidget);
      await tester.tap(key('desktop-import-confirm'));
      await drain(
        tester,
        () => find.byType(ImportImagePanel).evaluate().isEmpty,
      );
      expect(
        container.read(generateProvider).prompt,
        'cat girl, cherry blossoms',
      );
      expect(container.read(generateProvider).negativePrompt, 'keep negative');
      await finish(tester);
    },
  );

  testWidgets(
    'no metadata keeps reference actions and Escape cancels without changing creation',
    (tester) async {
      await mount(tester, hasMetadata: false);
      expect(key('desktop-import-confirm'), findsNothing);
      expect(find.text('图生图'), findsOneWidget);
      expect(find.text('反推提示词'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ImportImagePanel), findsNothing);
      expect(container.read(generateProvider).prompt, 'original');
      await finish(tester);
    },
  );

  testWidgets('phone import retains its original layout', (tester) async {
    await mount(tester, desktop: false);
    expect(key('desktop-import-window'), findsNothing);
    expect(find.text('导入所选内容'), findsOneWidget);
    expect(find.text('图生图'), findsOneWidget);
    await finish(tester);
  });
}
