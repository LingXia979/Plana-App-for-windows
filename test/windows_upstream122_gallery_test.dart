import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_grid_sheet.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';

class _Gallery extends GalleryNotifier {
  _Gallery(this.images);
  final List<ResultImage> images;
  @override
  GalleryState build() =>
      GalleryState(results: images, selectedId: images.first.id);
}

class _Search extends GallerySearchNotifier {
  @override
  GallerySearchState build() => const GallerySearchState();
}

void main() {
  for (final browser in [false, true]) {
    testWidgets(
      '${browser ? 'full gallery' : 'quick gallery'} keeps aspect, mouse sweep, menu and Escape after resize',
      (tester) async {
        tester.view.physicalSize = const Size(700, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final stores = AppStores.ephemeral();
        const sizes = [
          (64, 96),
          (128, 96),
          (96, 96),
          (64, 96),
          (144, 96),
          (48, 96),
        ];
        final images = [
          for (var i = 0; i < 18; i++)
            ResultImage(
              id: 'mixed$i',
              width: sizes[i % sizes.length].$1,
              height: sizes[i % sizes.length].$2,
              seed: i,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              bytes: Uint8List.fromList(
                img.encodePng(
                  img.Image(
                    width: sizes[i % sizes.length].$1,
                    height: sizes[i % sizes.length].$2,
                  ),
                ),
              ),
            ),
        ];
        final container = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            desktopModeProvider.overrideWithValue(true),
            galleryProvider.overrideWith(() => _Gallery(images)),
            gallerySearchProvider.overrideWith(_Search.new),
          ],
        );
        var disposed = false;
        addTearDown(() {
          if (!disposed) container.dispose();
          stores.flushNow();
        });
        container.read(desktopLibraryProvider.notifier).choose(null);
        var closed = false;
        String? opened;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Scaffold(
                body: GalleryGridContent(
                  desktop: true,
                  embedded: true,
                  onClose: () => closed = true,
                  browser: browser
                      ? GalleryGridBrowser(
                          albumId: null,
                          title: '全部图片',
                          onBack: () {},
                          onOpenImage: (items, i) => opened = items[i].id,
                        )
                      : null,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Finder tile(int i) => find.byKey(
          ValueKey(
            '${browser ? 'desktop-image' : 'quick-gallery-image'}-mixed$i',
          ),
        );
        void checkGeometry() {
          final visible = find.byType(GalleryImageTile).hitTestable();
          expect(visible.evaluate().length, greaterThanOrEqualTo(3));
          for (final element in visible.evaluate()) {
            final widget = element.widget as GalleryImageTile;
            final finder = find.byWidget(widget);
            final rect = tester.getRect(finder);
            expect(
              (rect.width - 10) / (rect.height - 10),
              closeTo(widget.result.aspect, .001),
            );
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(
              rect.right,
              lessThanOrEqualTo(tester.view.physicalSize.width + .01),
            );
            expect(widget.fit, BoxFit.contain);
          }
          expect(tester.takeException(), isNull);
        }

        checkGeometry();
        expect(
          tester.getSize(tile(1)).width,
          greaterThan(tester.getSize(tile(0)).width),
        );
        final press = await tester.startGesture(
          tester.getCenter(tile(0)),
          kind: PointerDeviceKind.mouse,
        );
        await press.moveBy(const Offset(5, 0));
        await tester.pump();
        await press.moveTo(tester.getCenter(tile(2)));
        await tester.pump();
        await press.up();
        await tester.pumpAndSettle();
        for (var i = 0; i < 3; i++) {
          expect(tester.widget<GalleryImageTile>(tile(i)).picked, isTrue);
        }
        expect(closed, isFalse);
        expect(opened, isNull);
        expect(container.read(galleryProvider).selectedId, 'mixed0');
        tester.view.physicalSize = const Size(420, 950);
        await tester.pumpAndSettle();
        checkGeometry();
        expect(tester.widget<GalleryImageTile>(tile(0)).picked, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(tester.widget<GalleryImageTile>(tile(0)).selecting, isFalse);

        final right = await tester.startGesture(
          tester.getCenter(tile(1)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await right.up();
        // The menu waits for original-image decode, with a 300 ms fallback.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.text('导入'), findsOneWidget);
        expect(tester.widget<GalleryImageTile>(tile(0)).selecting, isFalse);
        expect(closed, isFalse);
        expect(opened, isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('导入'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(tile(1));
        await tester.pumpAndSettle();
        if (browser) {
          expect(opened, 'mixed1');
          expect(closed, isFalse);
        } else {
          expect(closed, isTrue);
          expect(container.read(galleryProvider).selectedId, 'mixed1');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        container.dispose();
        disposed = true;
        stores.flushNow();
        await tester.pump();
      },
    );
  }
}
