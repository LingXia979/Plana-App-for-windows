import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/desktop_canvas_gutters.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';
import 'package:plana_app/features/gallery/widgets/result_thumb.dart';
import 'package:plana_app/features/import/import_panel.dart';

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;
  @override
  GalleryState build() => GalleryState(
    results: images,
    selectedId: images.isEmpty ? null : images[1].id,
  );
}

void main() {
  late ProviderContainer container;
  late AppStores stores;
  late Uint8List bytes;
  var disposed = false;
  setUp(() {
    bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 120, height: 240)),
    );
    stores = AppStores.ephemeral();
    disposed = false;
  });
  tearDown(() {
    if (!disposed) container.dispose();
    stores.flushNow();
  });
  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> mount(WidgetTester tester, {bool empty = false}) async {
    final images = [
      if (!empty)
        for (var i = 0; i < 3; i++)
          ResultImage(
            id: 'image-$i',
            width: 120,
            height: 240,
            seed: i,
            bytes: bytes,
          ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => _Gallery(images)),
        galleryThumbProvider.overrideWith((ref, id) async => bytes),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  height: 44,
                  child: TextField(key: ValueKey('outside-prompt')),
                ),
                const Expanded(
                  child: GalleryPage(
                    desktop: true,
                    libraryControl: DesktopLibraryButton(),
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

  String? selected() => container.read(galleryProvider).selectedId;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    stores.flushNow();
    var done = false;
    unawaited(stores.gallery.idle.then((_) => done = true));
    for (var i = 0; i < 100 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done, isTrue);
    container.dispose();
    disposed = true;
  }

  testWidgets(
    'desktop history drop onto canvas opens import without mobile drop bands',
    (tester) async {
      await mount(tester);
      final before = selected();
      final thumb = key('history-thumb-image-0');
      final drag = await tester.startGesture(
        tester.getCenter(thumb),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, -100));
      await tester.pump();
      await drag.moveTo(tester.getCenter(find.byType(DesktopCanvasGutters)));
      await tester.pump();
      expect(find.text('拖到这里分享'), findsNothing);
      expect(find.text('拖到这里删除'), findsNothing);
      await drag.up();
      await tester.pump();
      // Metadata parsing runs in a real isolate; let it finish before waiting
      // for the loading indicator's animation to settle in fake time.
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(ImportImagePanel).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(ImportImagePanel), findsOneWidget);
      expect(
        tester.widget<ImportImagePanel>(find.byType(ImportImagePanel)).bytes,
        bytes,
      );
      expect(selected(), before);
      expect(container.read(galleryProvider).results.length, 3);
      await finish(tester);
    },
  );

  testWidgets(
    'short, downward and returned history drags leave the image untouched',
    (tester) async {
      await mount(tester);
      final before = selected();
      for (final movements in [
        [const Offset(0, -25)],
        [const Offset(0, 40)],
        [const Offset(0, -100), const Offset(0, 100)],
      ]) {
        final drag = await tester.startGesture(
          tester.getCenter(key('history-thumb-image-0')),
          kind: PointerDeviceKind.mouse,
        );
        for (final delta in movements) {
          await drag.moveBy(delta);
          await tester.pump();
        }
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.byType(ImportImagePanel), findsNothing);
        expect(selected(), before);
        expect(container.read(galleryProvider).results.length, 3);
      }
      await finish(tester);
    },
  );

  testWidgets(
    'history delete requires two clicks on the same red cross and resets on timeout or selection',
    (tester) async {
      await mount(tester);
      Color? cross(String id) => tester
          .widget<IconButton>(key('history-delete-$id'))
          .style!
          .foregroundColor!
          .resolve({});
      final normal = cross('image-0');
      await tester.tap(key('history-delete-image-0'));
      await tester.pump();
      expect(cross('image-0'), AppTheme.light().colorScheme.error);
      expect(container.read(galleryProvider).results.length, 3);
      await tester.pump(const Duration(seconds: 3));
      expect(cross('image-0'), normal);
      await tester.tap(key('history-delete-image-0'));
      await tester.pump();
      await tester.tap(key('history-thumb-image-2'));
      await tester.pumpAndSettle();
      expect(cross('image-0'), normal);
      await tester.tap(key('history-delete-image-0'));
      await tester.pump();
      await tester.tap(key('history-delete-image-0'));
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 && container.read(galleryProvider).results.length == 3;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(container.read(galleryProvider).results.map((r) => r.id), [
        'image-1',
        'image-2',
      ]);
      expect(cross('image-1'), normal);
      expect(find.byType(ImportImagePanel), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'blank gutters and history arrows change only the focused canvas and stop at boundaries',
    (tester) async {
      await mount(tester);
      expect(selected(), 'image-1');
      expect(find.text('查看当前图库'), findsNothing);
      expect(key('desktop-library-picker'), findsOneWidget);
      final headerRect = tester.getRect(key('desktop-library-picker'));
      final pickerRect = tester.getRect(key('desktop-history-browse'));
      final canvasRect = tester.getRect(find.byType(GalleryPage));
      expect(
        canvasRect.right - pickerRect.right,
        lessThan(20),
        reason: 'Library controls align with the right edge of the history bar',
      );
      final stripRect = tester.getRect(find.byType(FilmStrip));
      expect(headerRect.bottom, lessThanOrEqualTo(stripRect.top));
      expect(stripRect.top - headerRect.bottom, lessThan(20));
      Future<void> clickGutter(String name) async {
        final rect = tester.getRect(key(name));
        await tester.tapAt(Offset(rect.center.dx, rect.top + 20));
        await tester.pumpAndSettle();
      }

      await clickGutter('canvas-next-gutter');
      expect(selected(), 'image-2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected(), 'image-2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(selected(), 'image-1');
      await clickGutter('canvas-previous-gutter');
      expect(selected(), 'image-0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(selected(), 'image-0');
      await tester.tapAt(tester.getCenter(find.byType(DesktopCanvasGutters)));
      await tester.pumpAndSettle();
      expect(
        selected(),
        'image-0',
        reason: 'Clicking the image is not gutter navigation',
      );
      final thumb = find
          .descendant(
            of: find.byType(FilmStrip),
            matching: find.byType(ResultThumb),
          )
          .at(1);
      await tester.tap(thumb);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected(), 'image-2');
      await tester.enterText(key('outside-prompt'), 'prompt');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        selected(),
        'image-2',
        reason: 'Text cursor arrows must not navigate history',
      );
      await clickGutter('canvas-previous-gutter');
      expect(selected(), 'image-1');
      container.read(galleryZoomedProvider.notifier).set(true);
      await tester.pump();
      expect(find.byType(DesktopCanvasGutters), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(
        selected(),
        'image-1',
        reason: 'Zoomed canvas retains its pan controls',
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'empty desktop canvas still exposes the current library selector',
    (tester) async {
      await mount(tester, empty: true);
      expect(key('desktop-history-browse'), findsOneWidget);
      expect(key('desktop-library-picker'), findsOneWidget);
      await tester.tap(key('desktop-library-picker'));
      await tester.pumpAndSettle();
      expect(key('desktop-library-dialog'), findsOneWidget);
      expect(find.text('查看当前图库'), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
}
