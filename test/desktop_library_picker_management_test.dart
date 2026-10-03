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
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/albums/album_store.dart';
import 'package:plana_app/features/gallery/albums/album_ui.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';

class _Search extends GallerySearchNotifier {
  @override
  GallerySearchState build() => const GallerySearchState(byId: {});
}

Uint8List _png(int red, int blue) => Uint8List.fromList(
  img.encodePng(
    img.fill(
      img.Image(width: 80, height: 120, numChannels: 4),
      color: img.ColorRgba8(red, 80, blue, 255),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late String dailyId;
  late Uint8List persistedCover;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_library_picker_');
    stores = await AppStores.open(rootOverride: root);
    dailyId = dailyAlbumId(DateTime.now());
    final images = [
      ResultImage(
        id: 'one',
        width: 80,
        height: 120,
        seed: 1,
        createdAt: 3000,
        bytes: _png(240, 20),
      ),
      ResultImage(
        id: 'two',
        width: 80,
        height: 120,
        seed: 2,
        createdAt: 2000,
        bytes: _png(20, 240),
      ),
      ResultImage(
        id: 'shared',
        width: 80,
        height: 120,
        seed: 3,
        createdAt: 1000,
        bytes: _png(160, 160),
      ),
    ];
    for (final image in images) {
      await stores.gallery.persistResult(image);
    }
    stores.gallery.scheduleIndex(results: images, selectedId: 'one', seq: 3);
    await stores.gallery.flushIndex();
    await stores.albums.update(
      (_) => AlbumsData(
        albums: [
          const GalleryAlbum(id: 'a', name: '正在创作', createdAt: 2000),
          const GalleryAlbum(id: 'b', name: '候选图库', createdAt: 1000),
          GalleryAlbum(id: dailyId, name: '当天图库', createdAt: 500),
        ],
        memberships: {
          'one': {'a'},
          'two': {'b'},
          'shared': {'a', 'b'},
        },
      ),
    );
    persistedCover = _png(45, 155);
    await stores.albums.setCover('b', persistedCover);
    await stores.albums.setCover(null, persistedCover);
    await stores.prefs.write(key: 'desktop_gallery_choice', value: 'a');
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        gallerySearchProvider.overrideWith(_Search.new),
      ],
    );
  });

  // Every queued write is drained while the widget FakeAsync zone is active.
  tearDown(() async => root.delete(recursive: true));

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 500 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue, reason: reason);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> withPicker(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: DesktopLibraryButton()),
          ),
        ),
      );
      await tester.tap(key('desktop-library-picker'));
      await tester.pumpAndSettle();
      expect(key('desktop-library-dialog'), findsOneWidget);
      await body();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      stores.flushNow();
      var idle = false;
      unawaited(
        Future.wait([
          stores.gallery.idle,
          stores.albums.idle,
          stores.workspace.idle,
          stores.assistant.idle,
          stores.prefs.write(key: 'test_fixture_drained', value: 'true'),
        ]).then((_) => idle = true),
      );
      await waitFor(tester, () => idle, 'all fixture writes finish');
      await tester.pump(const Duration(seconds: 5));
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> rightClick(WidgetTester tester, String id) async {
    final card = key('desktop-album-$id');
    await tester.ensureVisible(card);
    final pointer = await tester.startGesture(
      tester.getCenter(card),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await pointer.up();
    await tester.pumpAndSettle();
  }

  void expectUnchangedSelection() {
    expect(container.read(desktopLibraryProvider).albumId, 'a');
    expect(container.read(galleryProvider).selectedId, 'one');
    expect(key('desktop-library-dialog'), findsOneWidget);
  }

  testWidgets(
    'picker right click and rename do not select the managed album',
    (tester) async {
      await withPicker(tester, () async {
        await rightClick(tester, 'b');
        expect(key('desktop-library-cover'), findsOneWidget);
        expectUnchangedSelection();
        await tester.tap(key('desktop-library-rename'));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(field, '正在创作');
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await tester.pumpAndSettle();
        expect(find.text('这个图库名称已存在'), findsOneWidget);
        await tester.enterText(field, '重新命名');
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await waitFor(
          tester,
          () =>
              container.read(albumsProvider).name('b') == '重新命名' &&
              find.byType(AlertDialog).evaluate().isEmpty,
          'rename is persisted and the management dialog closes',
        );
        expect(find.text('重新命名'), findsOneWidget);
        expectUnchangedSelection();
        final restored = await tester.runAsync(() async {
          final store = AlbumStore(root);
          await store.load(liveImages: {'one', 'two', 'shared'});
          return store.data.name('b');
        });
        expect(restored, '重新命名');
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final source in ['current', 'history']) {
    testWidgets(
      'picker displays saved covers and uses the shared $source cover flow',
      (tester) async {
        await withPicker(tester, () async {
          for (final id in ['b', '']) {
            final cover = find.descendant(
              of: key('desktop-album-$id'),
              matching: find.byType(AlbumCoverImage),
            );
            expect(cover, findsOneWidget);
            await waitFor(
              tester,
              () => find
                  .descendant(of: cover, matching: find.byType(Image))
                  .evaluate()
                  .any((element) {
                    final image = (element.widget as Image).image;
                    return image is MemoryImage &&
                        orderedEquals(persistedCover).matches(image.bytes, {});
                  }),
              'persisted cover pixels appear in $id',
            );
          }
          await rightClick(tester, 'b');
          await tester.tap(key('desktop-library-cover'));
          await tester.pumpAndSettle();
          expect(key('album-cover-source-dialog'), findsOneWidget);
          expect(find.text('从这个图库里选择'), findsOneWidget);
          expect(find.text('从历史里选择'), findsOneWidget);
          expect(find.text('从本地上传图片'), findsOneWidget);
          expectUnchangedSelection();
          await tester.tap(key('album-cover-$source'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(key('history-image-picker'), findsOneWidget);
          expect(key('history-image-two'), findsOneWidget);
          expect(key('history-image-shared'), findsOneWidget);
          expect(
            key('history-image-one'),
            source == 'current' ? findsNothing : findsOneWidget,
          );
          final chosen = source == 'current' ? 'two' : 'one';
          await tester.tap(key('history-image-$chosen'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(key('album-cover-crop-dialog'), findsOneWidget);
          await tester.tap(key('album-cover-save'));
          await waitFor(
            tester,
            () =>
                container.read(albumsProvider).cover('b')?.sourceImageId ==
                    chosen &&
                find.text('封面已更新').evaluate().isNotEmpty,
            'cover update finishes without choosing its library',
          );
          expectUnchangedSelection();
          final savedCover = container.read(albumsProvider).cover('b')!;
          final restored = await tester.runAsync(() async {
            final store = AlbumStore(root);
            await store.load(liveImages: {'one', 'two', 'shared'});
            return store.data.cover('b');
          });
          expect(restored!.key, savedCover.key);
          expect(restored.sourceImageId, chosen);
        });
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets(
    'picker deletion confirms count, deletes exclusive images and keeps shared images',
    (tester) async {
      await withPicker(tester, () async {
        await rightClick(tester, 'b');
        await tester.tap(key('desktop-library-delete'));
        await tester.pumpAndSettle();
        expect(find.textContaining('是否删除这个图库（包含 2 张图片）'), findsOneWidget);
        expect(find.textContaining('1 张图片也属于其他图库，将保留这些图片。'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(container.read(albumsProvider).exists('b'), isTrue);
        expect(container.read(galleryProvider).results, hasLength(3));
        expectUnchangedSelection();
        await rightClick(tester, 'b');
        await tester.tap(key('desktop-library-delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '删除图库'));
        await waitFor(
          tester,
          () => find.text('已删除图库及 1 张图片；1 张其他图库共用的图片已保留').evaluate().isNotEmpty,
          'shared deletion flow is complete',
        );
        expect(container.read(albumsProvider).exists('b'), isFalse);
        expect(container.read(albumsProvider).ofImage('shared'), {'a'});
        expect(container.read(galleryProvider).results.map((r) => r.id), [
          'one',
          'shared',
        ]);
        expect(
          File('${root.path}/gallery/images/two.png').existsSync(),
          isFalse,
        );
        expect(
          File('${root.path}/gallery/images/shared.png').existsSync(),
          isTrue,
        );
        expect(key('desktop-album-b'), findsNothing);
        expectUnchangedSelection();
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'virtual automatic mode cannot manage its daily entity and all works is protected',
    (tester) async {
      await withPicker(tester, () async {
        await rightClick(tester, 'auto');
        expect(key('desktop-library-delete'), findsNothing);
        expect(container.read(albumsProvider).exists(dailyId), isTrue);
        expectUnchangedSelection();
        await rightClick(tester, dailyId);
        expect(key('desktop-library-delete'), findsOneWidget);
        expect(
          tester
              .widget<PopupMenuItem<dynamic>>(key('desktop-library-rename'))
              .enabled,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await rightClick(tester, '');
        expect(
          tester
              .widget<PopupMenuItem<dynamic>>(key('desktop-library-rename'))
              .enabled,
          isFalse,
        );
        expect(find.text('清空全部作品'), findsOneWidget);
        await tester.tap(key('desktop-library-delete'));
        await tester.pumpAndSettle();
        expect(find.textContaining('“全部作品”和其他图库容器会保留'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(container.read(galleryProvider).results, hasLength(3));
        expect(container.read(albumsProvider).albums, hasLength(3));
        expect(key('desktop-album-'), findsOneWidget);
        expectUnchangedSelection();
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'explicit card selection still changes library and closes the picker',
    (tester) async {
      await withPicker(tester, () async {
        await tester.tap(key('desktop-album-b'));
        await tester.pumpAndSettle();
        expect(container.read(desktopLibraryProvider).albumId, 'b');
        expect(container.read(desktopLibraryProvider).automatic, isFalse);
        expect(container.read(galleryProvider).selectedId, 'two');
        expect(key('desktop-library-dialog'), findsNothing);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'new library retains create and choose behavior',
    (tester) async {
      await withPicker(tester, () async {
        await tester.tap(key('desktop-new-album'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '新创作集',
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await waitFor(
          tester,
          () => key('desktop-library-dialog').evaluate().isEmpty,
          'new library creation chooses it and closes picker',
        );
        final selection = container.read(desktopLibraryProvider);
        expect(selection.automatic, isFalse);
        expect(container.read(albumsProvider).name(selection.albumId), '新创作集');
        expect(container.read(galleryProvider).selectedId, isNull);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
