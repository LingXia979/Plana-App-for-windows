import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;

  @override
  GalleryState build() =>
      GalleryState(results: images, selectedId: images.first.id);

  @override
  void select(String? id) =>
      state = state.copyWith(selectedId: id, clearSelection: id == null);
}

class _Library extends DesktopLibraryNotifier {
  @override
  DesktopLibrarySelection build() =>
      const DesktopLibrarySelection(choice: '', day: '2026-10-03');
}

class _Generation extends GenerationNotifier {
  @override
  GenPool build() => const GenPool();

  void begin(Uint8List preview) => state = GenPool(
    selectedId: 'fake-running-job',
    jobs: [
      GenJob(
        id: 'fake-running-job',
        kind: GenJobKind.normal,
        stage: GenJobStage.running,
        width: 128,
        height: 192,
        seq: 1,
        step: 1,
        total: 2,
        preview: preview,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late List<ResultImage> images;
  String? copied;
  var disposed = false;
  Uint8List png(int w, int h, img.Color color) => Uint8List.fromList(
    img.encodePng(img.Image(width: w, height: h)..clear(color)),
  );
  final current = png(1664, 2432, img.ColorRgb8(255, 0, 0));
  final before = png(1664, 2432, img.ColorRgb8(0, 0, 255));
  final mask = png(1664, 2432, img.ColorRgb8(255, 255, 255));
  final smaller = png(128, 192, img.ColorRgb8(0, 255, 0));

  setUp(() {
    disposed = false;
    copied = null;
    stores = AppStores.ephemeral();
    images = [
      ResultImage(
        id: 'gen0',
        width: 1664,
        height: 2432,
        seed: 4294967295,
        bytes: current,
        badge: ResultBadge.inpaint,
        input: GenerateState.initial().copyWith(
          inpaint: InpaintJob(image: before, mask: mask, strength: .7),
        ),
      ),
      ResultImage(
        id: 'gen1',
        width: 128,
        height: 192,
        seed: 7654321,
        bytes: smaller,
      ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        desktopLibraryProvider.overrideWith(_Library.new),
        galleryProvider.overrideWith(() => _Gallery(images)),
        generationProvider.overrideWith(_Generation.new),
        galleryThumbProvider.overrideWith(
          (ref, id) async =>
              images.singleWhere((image) => image.id == id).bytes,
        ),
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    if (!disposed) container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    final root = stores.desktopOutput.root.parent;
    expect(
      root.path.startsWith(
        '${Directory.systemTemp.path}${Platform.pathSeparator}plana_stores',
      ),
      isTrue,
    );
    root.deleteSync(recursive: true);
  });

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> spinUntil(WidgetTester tester, bool Function() done) async {
    await tester.pump();
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  Future<void> mount(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const Scaffold(body: GalleryPage(desktop: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    disposed = true;
    stores.flushNow();
    var done = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.workspace.idle,
        stores.assistant.idle,
        stores.ledger.idle,
        stores.albums.idle,
        stores.desktopOutput.idle,
      ]).then((_) => done = true),
    );
    await spinUntil(tester, () => done);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final width in [360.0, 1100.0]) {
    testWidgets(
      'canvas metadata stays on opposite bottom corners at width $width',
      (tester) async {
        await mount(tester, width);
        final canvas = tester.getRect(find.byType(ResultChrome));
        final resolution = tester.getRect(key('canvas-resolution'));
        final seed = tester.getRect(key('canvas-seed'));
        final metadata = tester.getRect(key('canvas-metadata'));
        final comparison = tester.getRect(key('canvas-compare-old'));
        expect(find.text('1664 × 2432'), findsOneWidget);
        expect(find.text('4294967295'), findsOneWidget);
        expect(resolution.left, closeTo(canvas.left + 12, .01));
        expect(seed.right, closeTo(canvas.right - 12, .01));
        expect(resolution.bottom, closeTo(seed.bottom, .01));
        expect(seed.bottom, closeTo(canvas.bottom - 16, .01));
        expect(resolution.right, lessThan(seed.left));
        expect(comparison.right, closeTo(seed.right, .01));
        expect(comparison.bottom, lessThan(metadata.top));
        expect(comparison.overlaps(seed), isFalse);
        expect(comparison.overlaps(resolution), isFalse);
        expect(key('canvas-seed').hitTestable(), findsOneWidget);
        expect(key('canvas-compare-old').hitTestable(), findsOneWidget);

        await tester.tap(key('canvas-seed'));
        await tester.pump();
        expect(copied, '4294967295');
        expect(container.read(generateProvider).params.seed, '4294967295');
        expect(container.read(galleryProvider).selectedId, 'gen0');
        final held = await tester.startGesture(
          tester.getCenter(key('canvas-compare-old')),
          kind: PointerDeviceKind.mouse,
        );
        await spinUntil(
          tester,
          () => container.read(comparePreviewProvider) != null,
        );
        expect(container.read(comparePreviewProvider)?.resultId, 'gen0');
        expect(container.read(galleryProvider).selectedId, 'gen0');
        await held.up();
        await tester.pump();
        expect(container.read(comparePreviewProvider), isNull);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'starting generation exits active comparison and blocks keyboard reactivation',
    (tester) async {
      await mount(tester, 360);
      final held = await tester.startGesture(
        tester.getCenter(key('canvas-compare-old')),
        kind: PointerDeviceKind.mouse,
      );
      await spinUntil(
        tester,
        () => container.read(comparePreviewProvider) != null,
      );
      expect(container.read(comparePreviewProvider)?.resultId, 'gen0');

      (container.read(generationProvider.notifier) as _Generation).begin(
        smaller,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(container.read(comparePreviewProvider), isNull);
      expect(
        tester.widget<ResultChrome>(find.byType(ResultChrome)).enabled,
        isFalse,
      );
      expect(key('canvas-compare-old').hitTestable(), findsNothing);
      await held.up();

      for (final keyboardKey in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.enter,
      ]) {
        await tester.sendKeyDownEvent(keyboardKey);
        await tester.pump();
        expect(container.read(comparePreviewProvider), isNull);
        await tester.sendKeyUpEvent(keyboardKey);
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(container.read(comparePreviewProvider), isNull);
      expect(container.read(galleryProvider).selectedId, 'gen0');
      await finish(tester);
    },
  );

  testWidgets(
    'changing the selected image refreshes dimensions and copied seed',
    (tester) async {
      await mount(tester, 360);
      container.read(galleryProvider.notifier).select('gen1');
      await tester.pumpAndSettle();
      expect(find.text('1664 × 2432'), findsNothing);
      expect(find.text('4294967295'), findsNothing);
      expect(find.text('128 × 192'), findsOneWidget);
      expect(find.text('7654321'), findsOneWidget);
      expect(key('canvas-compare-old'), findsNothing);
      await tester.tap(key('canvas-seed'));
      await tester.pump();
      expect(copied, '7654321');
      expect(container.read(generateProvider).params.seed, '7654321');
      expect(container.read(galleryProvider).selectedId, 'gen1');
      await finish(tester);
    },
  );
}
