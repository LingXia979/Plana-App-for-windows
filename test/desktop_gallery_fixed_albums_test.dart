import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_gallery_browser.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/albums/album_ui.dart';
import 'package:plana_app/features/gallery/gallery_export.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';
import 'package:plana_app/features/gallery/widgets/gallery_export_dialog.dart';
import 'package:plana_app/features/gallery/widgets/gallery_trash_actions.dart';
import 'package:plana_app/features/gallery/widgets/gallery_trash_content.dart';

import 'support/pump_until.dart';
import 'support/desktop_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  late GalleryNotifier gallery;
  late String album, first, second;
  var disposed = false;
  final captureKey = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  Finder key(String value) => find.byKey(ValueKey(value));

  setUp(() async {
    disposed = false;
    root = await Directory.systemTemp.createTemp('plana_fixed_gallery_');
    await Directory('${root.path}/export').create();
    stores = await AppStores.open(rootOverride: root);
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    gallery = c.read(galleryProvider.notifier);
    album = await c.read(albumsProvider.notifier).create('保存目标');
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 40, height: 60)),
    );
    first = (await gallery.addResultToGallery(
      bytes: bytes,
      width: 40,
      height: 60,
      seed: 1,
      target: GallerySaveTarget.album(album),
    )).id;
    second = (await gallery.addResultToGallery(
      bytes: bytes,
      width: 40,
      height: 60,
      seed: 2,
      target: GallerySaveTarget.album(album),
    )).id;
    gallery.setFavorite(first, true);
    c.read(desktopLibraryProvider.notifier).choose(album);
    await stores.flushForExit();
  });
  tearDown(() async {
    // finish() drains both clocks before disposing the widget environment.
    // A second flush here can wait on futures bound to its stopped fake clock.
    if (!disposed) c.dispose();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      root.path.split(Platform.pathSeparator).last,
      startsWith('plana_fixed_gallery_'),
    );
    await root.delete(recursive: true);
  });
  Future<void> mount(
    WidgetTester tester, [
    Widget child = const DesktopGalleryBrowser(),
  ]) async {
    tester.view.physicalSize = const Size(1200, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            theme: AppTheme.light().copyWith(
              platform: TargetPlatform.windows,
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await pumpUntilComplete(tester, stores.flushForExit());
    c.dispose();
    disposed = true;
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'fixed favorites and trash remain visible and browsing leaves save target and filmstrip unchanged',
    (tester) async {
      await mount(tester);
      final allCard = key('desktop-library-card-all');
      final favoriteCard = key('desktop-library-card-$favoritesId');
      final trashCard = key('desktop-library-card-$trashId');
      expect(allCard, findsOneWidget);
      expect(favoriteCard, findsOneWidget);
      expect(trashCard, findsOneWidget);
      await captureDesktop(tester, captureKey, 'batch5-fixed-entries');
      expect(
        tester.getTopLeft(favoriteCard).dx,
        greaterThan(tester.getTopLeft(allCard).dx),
      );
      final view = c
          .read(galleryViewProvider)
          .results
          .map((r) => r.id)
          .toList();
      final selected = c.read(galleryProvider).selectedId;
      await tester.tap(favoriteCard);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<GalleryImageTile>(find.byType(GalleryImageTile))
            .map((t) => t.result.id),
        [first],
      );
      expect(c.read(desktopLibraryProvider).albumId, album);
      expect(c.read(gallerySaveTargetProvider).albumId, album);
      expect(c.read(galleryViewProvider).results.map((r) => r.id), view);
      expect(c.read(galleryProvider).selectedId, selected);
      await tester.tap(key('desktop-gallery-up'));
      await tester.pumpAndSettle();
      await tester.enterText(key('desktop-gallery-search'), '不匹配任何图库');
      await tester.pumpAndSettle();
      expect(favoriteCard, findsOneWidget);
      expect(trashCard, findsOneWidget);
      await tester.tap(trashCard);
      await tester.pumpAndSettle();
      expect(find.text('回收站为空'), findsOneWidget);
      expect(c.read(gallerySaveTargetProvider).albumId, album);
      await finish(tester);
    },
  );

  testWidgets(
    'virtual entries cannot become albums or save targets and are absent from save picker',
    (tester) async {
      for (final id in [favoritesId, trashId]) {
        expect(c.read(albumsProvider).exists(id), isFalse);
        expect(
          () => c.read(desktopLibraryProvider.notifier).choose(id),
          throwsStateError,
        );
        await expectLater(
          c.read(albumsProvider.notifier).rename(id, '改名'),
          throwsStateError,
        );
        await expectLater(
          c.read(albumsProvider.notifier).delete(id),
          throwsStateError,
        );
      }
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAlbumLibrary(context, saveOnly: true),
            child: const Text('选择目标'),
          ),
        ),
      );
      await tester.tap(find.text('选择目标'));
      await tester.pumpAndSettle();
      expect(find.text(favoritesName), findsNothing);
      expect(find.text(trashName), findsNothing);
      expect(find.text('保存目标'), findsWidgets);
      await finish(tester);
    },
  );

  testWidgets(
    'delete shows undo; trash supports mouse preview, cancel purge and restore selected with keyboard',
    (tester) async {
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => moveGalleryImagesToTrash(context, [first, second]),
            child: const Text('删除测试'),
          ),
        ),
      );
      await tester.tap(find.text('删除测试'));
      await pumpUntil(tester, () => find.text('撤销').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(c.read(galleryProvider).results, isEmpty);
      await tester.tap(find.text('撤销'));
      await pumpUntil(
        tester,
        () => c.read(galleryProvider).results.length == 2,
      );
      await pumpUntilComplete(tester, gallery.deleteResults([first, second]));
      await mount(tester, GalleryTrashContent(onBack: () {}));
      expect(find.textContaining('剩余 30 天'), findsOneWidget);
      await pumpUntil(
        tester,
        () => [
          first,
          second,
        ].every((id) => c.read(galleryThumbProvider(id)).value != null),
      );
      await tester.pump(const Duration(seconds: 4));
      await captureDesktop(tester, captureKey, 'batch5-trash');
      await tester.tap(
        key('trash-image-$first'),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('回收站预览'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(key('trash-purge'));
      await tester.pumpAndSettle();
      expect(find.text('彻底删除 2 张作品？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.read(galleryProvider).trash, hasLength(2));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('恢复 (2)'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('全部恢复'), findsOneWidget);
      await tester.tap(key('trash-select'));
      await tester.pump();
      await tester.tap(key('trash-image-$first'));
      await tester.pump();
      expect(find.text('恢复 (1)'), findsOneWidget);
      await tester.tap(key('trash-restore'));
      await pumpUntil(
        tester,
        () => c.read(galleryProvider).results.length == 1,
      );
      expect(c.read(galleryProvider).results.single.id, first);
      expect(c.read(galleryProvider).results.single.favorite, isTrue);
      expect(c.read(galleryProvider).trash.single.image.id, second);
      await pumpUntil(
        tester,
        () =>
            tester.widget<OutlinedButton>(key('trash-purge')).onPressed != null,
      );
      await tester.tap(key('trash-purge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('彻底删除'));
      await pumpUntil(tester, () => c.read(galleryProvider).trash.isEmpty);
      expect(
        await tester.runAsync(() => stores.gallery.readImage(second)),
        isNull,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'favorites export only allows selected cleanup and leaves nonfavorites and save target intact',
    (tester) async {
      GalleryExportReport? report;
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              report = await showGalleryExportDialog(
                context,
                selected: c
                    .read(galleryProvider)
                    .results
                    .where((r) => r.favorite)
                    .toList(),
                albumId: favoritesId,
                albumName: favoritesName,
              );
            },
            child: const Text('导出收藏'),
          ),
        ),
      );
      await tester.tap(find.text('导出收藏'));
      await tester.pumpAndSettle();
      await tester.enterText(
        key('gallery-export-directory'),
        '${root.path}/export',
      );
      expect(key('gallery-export-cleanup-keepSamples'), findsNothing);
      expect(key('gallery-export-cleanup-deleteAlbum'), findsNothing);
      await tester.tap(key('gallery-export-cleanup-selected'));
      await tester.tap(key('gallery-export-submit'));
      await pumpUntil(
        tester,
        () => key('gallery-export-confirm').evaluate().isNotEmpty,
      );
      expect(find.text('导出所选 1 张；从「收藏」删除 1 张。'), findsOneWidget);
      await tester.tap(key('gallery-export-confirm'));
      await pumpUntil(tester, () => report != null);
      expect(report!.savedIds, {first});
      expect(c.read(galleryProvider).results.single.id, second);
      expect(c.read(gallerySaveTargetProvider).albumId, album);
      expect(c.read(albumsProvider).exists(album), isTrue);
      await finish(tester);
    },
  );
}
