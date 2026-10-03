import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/import/desktop_image_drop.dart';
import 'package:plana_app/features/import/import_panel.dart';

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;

  @override
  GalleryState build() =>
      GalleryState(results: images, selectedId: images.first.id);
}

void main() {
  late ProviderContainer c;
  late AppStores stores;
  late List<ResultImage> images;
  final received = <String?>[];

  setUp(() {
    received.clear();
    stores = AppStores.ephemeral();
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 120, height: 240)),
    );
    images = [
      for (var i = 0; i < 2; i++)
        ResultImage(
          id: 'canvas-$i',
          width: 120,
          height: 240,
          seed: i,
          bytes: bytes,
        ),
    ];
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => _Gallery(images)),
        galleryThumbProvider.overrideWith((ref, _) async => bytes),
      ],
    );
    c.read(desktopLibraryProvider.notifier).choose(null);
  });

  tearDown(() {
    c.dispose();
    stores.flushNow();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Row(
              children: [
                const Expanded(child: GalleryPage(desktop: true)),
                ImageDropRegion(
                  label: '接收测试图片',
                  onDrop: (_, payload) async => received.add(payload.imageId),
                  child: const SizedBox(
                    key: ValueKey('receiver'),
                    width: 180,
                    height: 600,
                    child: ColoredBox(color: Colors.blueGrey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder canvas() => find.byWidgetPredicate(
    (w) => w is GalleryImageDrag && w.canvas && w.result.id == 'canvas-0',
  );
  Finder transform() => find.descendant(
    of: canvas(),
    matching: find.byKey(const ValueKey('desktop-canvas-transform')),
  );

  Future<void> waitDrop(WidgetTester tester) async {
    for (var i = 0; i < 100 && received.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> mouseDoubleClick(WidgetTester tester, Offset at) async {
    var gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 80));
    gesture = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await gesture.up();
    await tester.pumpAndSettle();
  }

  for (final firstMove in [
    const Offset(40, 0),
    const Offset(0, -40),
    const Offset(-30, 30),
    const Offset(3, 0),
  ]) {
    testWidgets('fitted real canvas drags after first motion $firstMove', (
      tester,
    ) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(canvas()),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(firstMove);
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('receiver'))),
      );
      await tester.pump();
      await gesture.up();
      await waitDrop(tester);
      expect(received, ['canvas-0']);
      expect(c.read(galleryProvider).selectedId, 'canvas-0');
      expect(find.byType(ImportImagePanel), findsNothing);
      expect(c.read(galleryZoomedProvider), isFalse);
      await finish(tester);
    });
  }

  testWidgets('double click zooms and zoomed mouse pan does not start a drop', (
    tester,
  ) async {
    await mount(tester);
    final at = tester.getCenter(canvas());
    await mouseDoubleClick(tester, at);
    expect(c.read(galleryZoomedProvider), isTrue);
    final before = tester.widget<Transform>(transform()).transform.clone();
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(45, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(45, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<Transform>(transform()).transform, isNot(before));
    expect(received, isEmpty);
    expect(c.read(galleryProvider).selectedId, 'canvas-0');
    await finish(tester);
  });

  testWidgets('wheel zoom restores to fit and the image can be carried again', (
    tester,
  ) async {
    await mount(tester);
    final at = tester.getCenter(canvas());
    await tester.sendEventToBinding(
      PointerScrollEvent(position: at, scrollDelta: const Offset(0, -160)),
    );
    await tester.pumpAndSettle();
    expect(c.read(galleryZoomedProvider), isTrue);
    expect(
      tester.widget<Transform>(transform()).transform.getMaxScaleOnAxis(),
      greaterThan(2),
    );
    await mouseDoubleClick(tester, at);
    expect(c.read(galleryZoomedProvider), isFalse);
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-12, -12));
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('receiver'))),
    );
    await tester.pump();
    await gesture.up();
    await waitDrop(tester);
    expect(received, ['canvas-0']);
    await finish(tester);
  });

  testWidgets('touch pinch continues smoothly across fit-to-zoom transition', (
    tester,
  ) async {
    await mount(tester);
    final at = tester.getCenter(canvas());
    final left = await tester.startGesture(
      at - const Offset(0, 45),
      pointer: 10,
    );
    final right = await tester.startGesture(
      at + const Offset(0, 45),
      pointer: 11,
    );
    await left.moveBy(const Offset(0, -30));
    await right.moveBy(const Offset(0, 30));
    await tester.pump();
    await left.moveBy(const Offset(0, -30));
    await right.moveBy(const Offset(0, 30));
    await tester.pump();
    final midway = tester
        .widget<Transform>(transform())
        .transform
        .getMaxScaleOnAxis();
    expect(midway, greaterThan(1));
    await left.moveBy(const Offset(0, -30));
    await right.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(
      tester.widget<Transform>(transform()).transform.getMaxScaleOnAxis(),
      greaterThan(midway),
    );
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(c.read(galleryZoomedProvider), isTrue);
    expect(received, isEmpty);
    await finish(tester);
  });

  testWidgets(
    'tiny mouse movement preserves click and touch does not carry canvas',
    (tester) async {
      await mount(tester);
      final at = tester.getCenter(canvas());
      var gesture = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(.5, .5));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(received, isEmpty);
      expect(c.read(galleryZoomedProvider), isFalse);
      gesture = await tester.startGesture(at);
      await gesture.moveBy(const Offset(0, -45));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('receiver'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(received, isEmpty);
      await finish(tester);
    },
  );
}
