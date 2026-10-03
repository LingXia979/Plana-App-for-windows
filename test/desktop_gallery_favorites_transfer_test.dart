import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/ui_prefs.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_gallery_browser.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/widgets/gallery_grid_sheet.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';

class _Search extends GallerySearchNotifier {
  @override
  GallerySearchState build() => const GallerySearchState();
}

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late String source, target;
  late List<String> ids;
  var quick = true;
  var disposed = false;
  Finder key(String value) => find.byKey(ValueKey(value));
  Finder tile(String id) =>
      key('${quick ? 'quick-gallery-image' : 'desktop-image'}-$id');
  Set<String> picked(WidgetTester tester) => {
    for (final tile in tester.widgetList<GalleryImageTile>(
      find.byType(GalleryImageTile),
    ))
      if (tile.picked) tile.result.id,
  };

  setUp(() {
    disposed = false;
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        gallerySearchProvider.overrideWith(_Search.new),
      ],
    );
  });
  tearDown(() {
    stores.flushNow();
    if (!disposed) container.dispose();
  });

  Future<void> mount(WidgetTester tester, bool isQuick) async {
    quick = isQuick;
    tester.view.physicalSize = const Size(1200, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final albums = container.read(albumsProvider.notifier);
      source = await albums.create('来源图库');
      target = await albums.create('目标图库');
      final bytes = Uint8List.fromList(
        File('assets/app_icon.png').readAsBytesSync(),
      );
      for (var i = 0; i < 6; i++) {
        container
            .read(galleryProvider.notifier)
            .addResult(bytes: bytes, width: 512, height: 512, seed: i);
      }
      ids = container.read(galleryProvider).results.map((r) => r.id).toList();
      await stores.gallery.idle;
      await albums.organize(ids.toSet(), {source});
      container
          .read(uiPrefsProvider.notifier)
          .patch((p) => p.copyWith(galleryColumns: 3));
      container.read(desktopLibraryProvider.notifier).choose(source);
      container.read(desktopGalleryLocationProvider.notifier).open(source);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: quick
                ? Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showGalleryGrid(context, desktop: true),
                      child: const Text('打开快速浏览'),
                    ),
                  )
                : const DesktopGalleryBrowser(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (quick) {
      await tester.tap(find.text('打开快速浏览'));
      await tester.pumpAndSettle();
    }
    final scroll = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .where((s) => s.axisDirection == AxisDirection.down)
        .first;
    scroll.controller?.jumpTo(0);
    await tester.pumpAndSettle();
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    var idle = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.gallery.flushIndex(),
        stores.albums.idle,
      ]).then((_) => idle = true),
    );
    await until(tester, () => idle);
    container.dispose();
    disposed = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  Future<void> hold(WidgetTester tester, String id) async {
    final press = await tester.startGesture(
      tester.getCenter(tile(id)),
      kind: PointerDeviceKind.mouse,
    );
    await press.moveBy(const Offset(5, 0));
    await tester.pump();
    await press.up();
    await tester.pumpAndSettle();
  }

  Future<void> submitTransfer(WidgetTester tester) async {
    await tester.tap(key('gallery-transfer-target-$target'));
    await tester.pumpAndSettle();
    await tester.tap(key('gallery-transfer-submit'));
    await until(
      tester,
      () => key('gallery-transfer-dialog').evaluate().isEmpty,
    );
  }

  for (final isQuick in [true, false]) {
    final surface = isQuick ? 'quick' : 'full';
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      testWidgets(
        '$surface first ${kind.name} selection immediately sweeps, retracts and releases',
        (tester) async {
          await mount(tester, isQuick);
          final press = await tester.startGesture(
            tester.getCenter(tile(ids[0])),
            kind: kind,
          );
          if (kind == PointerDeviceKind.touch) {
            await tester.pump(const Duration(milliseconds: 199));
            expect(picked(tester), isEmpty);
            await tester.pump(const Duration(milliseconds: 2));
          } else {
            await press.moveBy(const Offset(5, 0));
            await tester.pump();
          }
          expect(picked(tester), {ids[0]});
          await press.moveTo(tester.getCenter(tile(ids[2])));
          await tester.pump();
          expect(picked(tester), ids.take(3).toSet());
          await press.moveTo(tester.getCenter(tile(ids[1])));
          await tester.pump();
          expect(picked(tester), ids.take(2).toSet());
          await press.up();
          await tester.pumpAndSettle();
          expect(picked(tester), ids.take(2).toSet());
          expect(key('desktop-image-viewer'), findsNothing);
          // Starting on a selected image removes the swept range.
          final remove = await tester.startGesture(
            tester.getCenter(tile(ids[0])),
            kind: kind,
          );
          if (kind == PointerDeviceKind.touch) {
            await tester.pump(const Duration(milliseconds: 201));
          }
          await remove.moveTo(tester.getCenter(tile(ids[1])));
          await tester.pump();
          await remove.up();
          await tester.pumpAndSettle();
          expect(picked(tester), isEmpty);
          await finish(tester);
        },
      );
    }

    testWidgets('$surface mouse star drags never start image selection', (
      tester,
    ) async {
      await mount(tester, isQuick);
      final star = key('gallery-favorite-${ids[0]}');
      final origin = tester.getCenter(star);
      for (final offset in [const Offset(0, 15), const Offset(15, 0)]) {
        final mouse = await tester.startGesture(
          origin,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveTo(origin + offset);
        await mouse.moveTo(tester.getCenter(tile(ids[2])));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(picked(tester), isEmpty);
        expect(
          tester.widget<GalleryImageTile>(tile(ids[0])).selecting,
          isFalse,
        );
        expect(container.read(galleryProvider).results.first.favorite, isFalse);
      }
      await finish(tester);
    });

    testWidgets(
      '$surface stars do not open/select images and favorites filter stays scoped',
      (tester) async {
        await mount(tester, isQuick);
        final selected = container.read(galleryProvider).selectedId;
        await tester.tap(key('gallery-favorite-${ids[0]}'));
        await tester.pumpAndSettle();
        expect(container.read(galleryProvider).results.first.favorite, isTrue);
        expect(container.read(galleryProvider).selectedId, selected);
        expect(picked(tester), isEmpty);
        expect(key('desktop-image-viewer'), findsNothing);
        final star = key('gallery-favorite-${ids[1]}');
        final press = await tester.startGesture(tester.getCenter(star));
        await tester.pump(const Duration(milliseconds: 650));
        await press.up();
        await tester.pumpAndSettle();
        expect(
          tester.widget<GalleryImageTile>(tile(ids[1])).selecting,
          isFalse,
        );
        expect(container.read(galleryProvider).results[1].favorite, isFalse);
        await tester.runAsync(() async {
          final gallery = container.read(galleryProvider.notifier);
          final outside = gallery.addResult(
            bytes: Uint8List.fromList(
              File('assets/app_icon.png').readAsBytesSync(),
            ),
            width: 512,
            height: 512,
            seed: 100,
            select: false,
          );
          gallery.toggleFavorite(outside.id);
        });
        await tester.tap(key('gallery-favorites-filter'));
        await tester.pumpAndSettle();
        expect(tile(ids[0]), findsOneWidget);
        expect(tile(ids[1]), findsNothing);
        expect(find.byType(GalleryImageTile), findsOneWidget);
        await tester.tap(key('gallery-favorite-${ids[0]}'));
        await tester.pumpAndSettle();
        expect(find.byType(GalleryImageTile), findsNothing);
        await tester.tap(key('gallery-favorites-filter'));
        await tester.pumpAndSettle();
        expect(tile(ids[1]), findsOneWidget);
        await finish(tester);
      },
    );

    testWidgets(
      '$surface batch copy retains originals then move transfers only selected',
      (tester) async {
        await mount(tester, isQuick);
        await hold(tester, ids[0]);
        await tester.tap(key('gallery-batch-copy'));
        await tester.pumpAndSettle();
        expect(find.text('复制到图库'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(container.read(albumsProvider).ofImage(ids[0]), {source});
        expect(picked(tester), {ids[0]});
        await tester.tap(key('gallery-batch-copy'));
        await tester.pumpAndSettle();
        await submitTransfer(tester);
        expect(container.read(albumsProvider).ofImage(ids[0]), {source});
        expect(container.read(galleryProvider).results, hasLength(7));
        final copied = container.read(galleryProvider).results.first;
        expect(copied.id, isNot(ids[0]));
        expect(container.read(albumsProvider).ofImage(copied.id), {target});
        await hold(tester, ids[1]);
        await tester.tap(key('gallery-batch-move'));
        await tester.pumpAndSettle();
        expect(find.text('移动到图库'), findsOneWidget);
        await submitTransfer(tester);
        expect(container.read(albumsProvider).ofImage(ids[1]), {target});
        expect(container.read(albumsProvider).ofImage(ids[2]), {source});
        expect(tile(ids[1]), findsNothing);
        await finish(tester);
      },
    );

    testWidgets(
      '$surface copy dialog selects several destinations and creates a separate image in each',
      (tester) async {
        await mount(tester, isQuick);
        final second = (await tester.runAsync(
          () => container.read(albumsProvider.notifier).create('第二个目标'),
        ))!;
        await hold(tester, ids[0]);
        await tester.tap(key('gallery-batch-copy'));
        await tester.pumpAndSettle();
        await tester.tap(key('gallery-transfer-target-$target'));
        await tester.tap(key('gallery-transfer-target-$second'));
        await tester.pumpAndSettle();
        expect(find.text('复制 (1 × 2 个图库)'), findsOneWidget);
        await tester.tap(key('gallery-transfer-submit'));
        await until(
          tester,
          () => key('gallery-transfer-dialog').evaluate().isEmpty,
        );
        final results = container.read(galleryProvider).results;
        expect(results, hasLength(8));
        final albums = container.read(albumsProvider);
        final firstId = results
            .singleWhere((r) => albums.contains(target, r.id))
            .id;
        final secondId = results
            .singleWhere((r) => albums.contains(second, r.id))
            .id;
        expect({ids[0], firstId, secondId}, hasLength(3));
        expect(albums.ofImage(ids[0]), {source});
        await finish(tester);
      },
    );

    testWidgets(
      '$surface right click replaces desktop share with move and copy',
      (tester) async {
        await mount(tester, isQuick);
        final press = await tester.startGesture(
          tester.getCenter(tile(ids[0])),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await press.up();
        await until(tester, () => find.text('导入').evaluate().isNotEmpty);
        expect(find.text('分享'), findsNothing);
        expect(find.text('移动'), findsOneWidget);
        await tester.tap(find.text('复制'));
        await tester.pumpAndSettle();
        await submitTransfer(tester);
        expect(container.read(albumsProvider).ofImage(ids[0]), {source});
        expect(container.read(galleryProvider).results, hasLength(7));
        expect(picked(tester), isEmpty);
        await finish(tester);
      },
    );
  }

  testWidgets('full viewer copies then moves with the source album captured', (
    tester,
  ) async {
    await mount(tester, false);
    final selected = container.read(galleryProvider).selectedId;
    await tester.tap(tile(ids[0]));
    await until(
      tester,
      () => key('desktop-viewer-image').evaluate().isNotEmpty,
    );
    expect(key('desktop-image-viewer'), findsOneWidget);
    await tester.tap(key('desktop-image-copy'));
    await tester.pumpAndSettle();
    await submitTransfer(tester);
    expect(key('desktop-image-viewer'), findsOneWidget);
    expect(container.read(albumsProvider).ofImage(ids[0]), {source});
    expect(container.read(galleryProvider).results, hasLength(7));
    container.read(desktopLibraryProvider.notifier).choose(target);
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-image-move'));
    await tester.pumpAndSettle();
    await submitTransfer(tester);
    expect(key('desktop-image-viewer'), findsNothing);
    expect(container.read(albumsProvider).ofImage(ids[0]), {target});
    expect(container.read(galleryProvider).selectedId, selected);
    await finish(tester);
  });
}
