import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/desktop/desktop_workspace.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';

class _Canvas extends GenerateNotifier {
  @override
  GenerateState build() => GenerateState.initial().copyWith(
    prompt: 'keep this positive',
    negativePrompt: 'keep this negative',
    params: const GenParams(
      width: 512,
      height: 768,
      steps: 27,
      cfg: 6.5,
      seed: '123',
    ),
  );
}

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;
  @override
  GalleryState build() =>
      GalleryState(results: images, selectedId: images.first.id);
  @override
  void select(String? id) => state = state.copyWith(selectedId: id);
  void clear() => state = const GalleryState(results: [], selectedId: null);
}

class _Library extends DesktopLibraryNotifier {
  @override
  DesktopLibrarySelection build() =>
      const DesktopLibrarySelection(choice: '', day: '2026-10-03');
}

class _Tags extends TagLibrary {
  @override
  Future<TagLibraryState> build() async => const TagLibraryState();
}

class _Generation extends GenerationNotifier {
  int calls = 0;
  @override
  GenPool build() => const GenPool();
  @override
  Future<GenOutcome> generate({
    GallerySaveTarget? galleryTarget,
    GenerateState? using,
    bool stay = false,
    void Function(String jobId)? onJob,
  }) async {
    calls++;
    return GenOutcome.ok;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late List<ResultImage> images;
  String? copied;
  bool clipboardFails = false;
  Completer<void>? pendingClipboard;
  final image = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 16, height: 16)..clear(img.ColorRgb8(20, 90, 180)),
    ),
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    copied = null;
    clipboardFails = false;
    pendingClipboard = null;
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: '{"enableCompletion":false,"showTranslation":false}',
    );
    images = [
      for (final seed in [4294967295, 0, 9223372036854775807])
        ResultImage(
          id: 'seed-$seed',
          width: 16,
          height: 16,
          seed: seed,
          bytes: image,
          input: GenerateState.initial().copyWith(
            prompt: 'do not import me',
            negativePrompt: 'do not import exclusions',
            params: const GenParams(seed: '999', width: 1024, height: 1024),
          ),
        ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        generateProvider.overrideWith(_Canvas.new),
        generationProvider.overrideWith(_Generation.new),
        desktopLibraryProvider.overrideWith(_Library.new),
        galleryProvider.overrideWith(() => _Gallery(images)),
        galleryThumbProvider.overrideWith((ref, id) async => image),
        tagLibraryProvider.overrideWith(_Tags.new),
        publicTagsProvider.overrideWith((ref, category) async => []),
        tagAuthorNamesProvider.overrideWith((ref) async => {}),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (clipboardFails) {
            throw PlatformException(code: 'test_clipboard_unavailable');
          }
          copied = (call.arguments as Map)['text'] as String?;
          if (pendingClipboard != null) await pendingClipboard!.future;
        }
        return null;
      },
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> mount(
    WidgetTester tester, {
    bool workspace = false,
    bool desktop = true,
    bool enabled = true,
    Size size = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: workspace
                ? const DesktopWorkspace()
                : Consumer(
                    builder: (context, ref, _) {
                      final displayed = ref.watch(galleryProvider).selected;
                      return displayed == null
                          ? const SizedBox()
                          : ResultChrome(
                              result: displayed,
                              showActions: false,
                              desktop: desktop,
                              enabled: enabled,
                            );
                    },
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  }

  Future<Map<String, dynamic>> snapshot(WidgetTester tester) async =>
      (await tester.runAsync(
        () =>
            encodeGenerateState(container.read(generateProvider), stores.blobs),
      ))!.json;

  for (final expanded in [false, true]) {
    testWidgets(
      'desktop seed summary clears without scrolling or expanding settings (expanded: $expanded)',
      (tester) async {
        await tester.runAsync(
          () => stores.prefs.write(
            key: 'desktop_generation_settings_expanded',
            value: expanded ? '1' : '0',
          ),
        );
        container
            .read(generateProvider.notifier)
            .applyParams(
              container
                  .read(generateProvider)
                  .params
                  .copyWith(seed: '4039256465'),
            );
        await mount(tester, workspace: true, size: const Size(1440, 700));
        final before = await snapshot(tester);
        final viewport = find.byKey(
          const PageStorageKey('desktop-controls-scroll'),
        );
        final scroll = tester
            .widget<SingleChildScrollView>(viewport)
            .controller!;
        final previousOffset = scroll.offset;
        expect(previousOffset, 0);
        expect(key('desktop-seed'), expanded ? findsOneWidget : findsNothing);
        if (expanded) {
          expect(
            tester.getRect(key('desktop-seed')).top,
            greaterThan(tester.getRect(viewport).bottom),
          );
        }
        expect(find.byTooltip('清空种子，改为每次随机'), findsOneWidget);
        for (var tap = 0; tap < 2; tap++) {
          final gesture = await tester.startGesture(
            tester.getCenter(key('desktop-summary-seed')),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 40));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(container.read(generateProvider).params.seed, isEmpty);
          expect(scroll.offset, previousOffset);
          expect(
            stores.prefs.get('desktop_generation_settings_expanded'),
            expanded ? '1' : '0',
          );
          expect(
            find.descendant(
              of: key('desktop-summary-seed'),
              matching: find.text('随机'),
            ),
            findsOneWidget,
          );
          final after = await snapshot(tester);
          (after['params'] as Map)['seed'] = '4039256465';
          expect(after, before);
        }
        if (expanded) {
          expect(
            tester.widget<TextField>(key('desktop-seed')).controller!.text,
            isEmpty,
          );
        } else {
          expect(key('desktop-seed'), findsNothing);
        }
        expect(copied, isNull);
        expect(container.read(galleryProvider).selectedId, images.first.id);
        expect(
          (container.read(generationProvider.notifier) as _Generation).calls,
          0,
        );
        await finish(tester);
      },
    );
  }

  testWidgets(
    'desktop canvas seed updates the actual left field for current image, zero and large values only',
    (tester) async {
      await mount(tester, workspace: true);
      final before = await snapshot(tester);
      expect(
        tester.widget<TextField>(key('desktop-seed')).controller!.text,
        '123',
      );
      for (final result in images) {
        container.read(galleryProvider.notifier).select(result.id);
        await tester.pumpAndSettle();
        await tester.tap(key('canvas-seed'));
        await tester.pump();
        final expected = '${result.seed}';
        expect(container.read(generateProvider).params.seed, expected);
        expect(
          tester.widget<TextField>(key('desktop-seed')).controller!.text,
          expected,
        );
        expect(copied, expected);
        expect(container.read(galleryProvider).selectedId, result.id);
        final after = await snapshot(tester);
        (after['params'] as Map)['seed'] = '123';
        expect(
          after,
          before,
          reason:
              'Clicking a seed must not import any other parameters or prompts',
        );
      }
      expect(
        (container.read(generationProvider.notifier) as _Generation).calls,
        0,
      );
      expect(find.byType(Dialog), findsNothing);
      (container.read(galleryProvider.notifier) as _Gallery).clear();
      await tester.pumpAndSettle();
      expect(key('canvas-seed'), findsNothing);
      expect(
        container.read(generateProvider).params.seed,
        '9223372036854775807',
      );
      await finish(tester);
    },
  );

  for (final seed in [0, 4294967295, 9223372036854775807]) {
    testWidgets(
      'shared mobile seed action applies and copies $seed without generation',
      (tester) async {
        container.read(galleryProvider.notifier).select('seed-$seed');
        await mount(tester, desktop: false);
        await tester.tap(key('canvas-seed'));
        await tester.pump();
        expect(container.read(generateProvider).params.seed, '$seed');
        expect(copied, '$seed');
        expect(find.text('已应用并复制种子 $seed'), findsOneWidget);
        expect(
          (container.read(generationProvider.notifier) as _Generation).calls,
          0,
        );
        await finish(tester);
      },
    );
  }

  testWidgets('unavailable clipboard does not prevent applying the seed', (
    tester,
  ) async {
    clipboardFails = true;
    await mount(tester);
    await tester.tap(key('canvas-seed'));
    await tester.pump();
    expect(container.read(generateProvider).params.seed, '4294967295');
    expect(copied, isNull);
    expect(find.text('已应用种子 4294967295'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets(
    'disabled result chrome cannot apply a seed through taps or keyboard',
    (tester) async {
      await mount(tester, enabled: false);
      await tester.tap(key('canvas-seed'));
      for (final key in [
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(container.read(generateProvider).params.seed, '123');
      expect(copied, isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'seed applies before clipboard completes and a later image switch cannot import its other parameters',
    (tester) async {
      pendingClipboard = Completer<void>();
      await mount(tester);
      await tester.tap(key('canvas-seed'));
      await tester.pump();
      expect(container.read(generateProvider).params.seed, '4294967295');
      container.read(galleryProvider.notifier).select('seed-0');
      final gen = container.read(generateProvider.notifier);
      gen.applyParams(
        container.read(generateProvider).params.copyWith(cfg: 7.5),
      );
      await tester.pump();
      pendingClipboard!.complete();
      await tester.pumpAndSettle();
      expect(container.read(generateProvider).params.seed, '4294967295');
      expect(container.read(generateProvider).params.cfg, 7.5);
      await tester.tap(key('canvas-seed'));
      await tester.pump();
      expect(container.read(generateProvider).params.seed, '0');
      expect(container.read(generateProvider).params.cfg, 7.5);
      await finish(tester);
    },
  );
}
