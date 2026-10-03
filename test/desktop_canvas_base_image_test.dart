import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/desktop/desktop_canvas_state.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/section_card.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!Platform.isWindows) return;
    for (final (family, path) in [
      ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ('monospace', r'C:\Windows\Fonts\consola.ttf'),
      ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
      (
        'MaterialIcons',
        r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      ),
    ]) {
      final file = File(path);
      if (await file.exists()) {
        await (FontLoader(
          family,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  late AppStores stores;
  late ProviderContainer container;
  var disposed = false;
  setUp(() async {
    disposed = false;
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: '{"enableCompletion":false}',
    );
    for (final key in [
      'hint_grid_longpress',
      'hint_save_longpress',
      'hint_strip_swipe',
    ]) {
      await stores.prefs.write(key: key, value: '1');
    }
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
  });
  tearDown(() {
    if (!disposed) container.dispose();
    stores.flushNow();
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Uint8List png(int width, int height) => Uint8List.fromList(
    img.encodePng(img.Image(width: width, height: height)),
  );

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const PlanaApp()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> useBase(WidgetTester tester) async {
    await tester.tap(key('canvas-use-base'));
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (container.read(generateProvider).img2img != null &&
          container.read(desktopImg2ImgRevealProvider) == null &&
          tester.widget<TextButton>(key('canvas-use-base')).onPressed != null) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'current result becomes the base, opens a hidden module and reveals it on repeated use without generating',
    (tester) async {
      final source = png(64, 64);
      final current = png(192, 320);
      final job = InpaintJob(image: source, mask: source, strength: .7);
      final generate = container.read(generateProvider.notifier);
      generate
        ..setPrompts(positive: 'keep this prompt', negative: 'keep negative')
        ..setInpaint(job, width: 64, height: 64)
        ..togglePanel(Panel.i2i)
        ..addCharacter()
        ..addCharacter()
        ..addCharacter();
      final before = container.read(generateProvider);
      await tester.runAsync(() async {
        await container.read(genModulesProvider.future);
        await container
            .read(genModulesProvider.notifier)
            .patch(
              (settings) => settings.copyWith(
                enabled: {...settings.enabled, GenModule.img2img: false},
              ),
            );
      });
      final result = (await tester.runAsync(
        () => container
            .read(galleryProvider.notifier)
            .addResultToGallery(
              bytes: current,
              width: 192,
              height: 320,
              seed: 321,
              badge: ResultBadge.inpaint,
              input: GenerateState.initial().copyWith(
                prompt: 'do not import this prompt',
                inpaint: job,
              ),
              target: const GallerySaveTarget.all(),
            ),
      ))!;
      await mount(tester);
      expect(key('desktop-module-img2img'), findsNothing);

      final old = tester.getRect(key('canvas-compare-old'));
      expect(
        old.bottom,
        lessThan(tester.getRect(key('canvas-regenerate')).top),
      );
      expect(
        old.top,
        greaterThan(tester.getRect(key('canvas-top-actions')).bottom),
      );

      await useBase(tester);
      final after = container.read(generateProvider);
      expect(after.img2img?.image, same(current));
      expect(after.inpaint, isNull);
      expect(after.openPanels, contains(Panel.i2i));
      expect(after.params.model, before.params.model);
      expect(after.params.activeSteps, before.params.activeSteps);
      expect(after.params.seed, before.params.seed);
      expect(after.prompt, before.prompt);
      expect(after.negativePrompt, before.negativePrompt);
      expect(after.characters, before.characters);
      expect((after.params.width, after.params.height), (192, 320));
      expect(
        container
            .read(genModulesProvider)
            .requireValue
            .isEnabled(GenModule.img2img),
        isTrue,
      );
      expect(container.read(shellIndexProvider), kTabCreate);
      expect(container.read(galleryProvider).selectedId, result.id);
      expect(container.read(generationProvider).jobs, isEmpty);
      expect(container.read(generationProvider).error, isNull);

      final module = key('desktop-module-img2img');
      final card = find.descendant(
        of: module,
        matching: find.byType(SectionCard),
      );
      expect(tester.widget<SectionCard>(card).expanded, isTrue);
      final scrollbar = tester.widget<Scrollbar>(
        key('desktop-controls-scrollbar'),
      );
      final scroll = scrollbar.controller!;
      expect(scroll.offset, greaterThan(0));
      final viewport = tester.getRect(key('desktop-controls-scrollbar'));
      expect(tester.getTopLeft(module).dy, closeTo(viewport.top + 3, 5));
      expect(container.read(desktopImg2ImgRevealProvider), isNull);

      // The byte identity is unchanged, but the action should still reopen and
      // reveal the card after the user scrolls away and collapses it.
      generate.togglePanel(Panel.i2i);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await useBase(tester);
      expect(container.read(generateProvider).img2img?.image, same(current));
      expect(tester.widget<SectionCard>(card).expanded, isTrue);
      expect(scroll.offset, greaterThan(0));
      expect(tester.getTopLeft(module).dy, closeTo(viewport.top + 3, 5));
      expect(container.read(generationProvider).jobs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      disposed = true;
      stores.flushNow();
    },
  );
}
