import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
import 'package:plana_app/features/gallery/albums/album_store.dart';
import 'package:plana_app/features/gallery/albums/album_ui.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_grid_sheet.dart';

class _Search extends GallerySearchNotifier {
  @override
  GallerySearchState build() => const GallerySearchState(byId: {});
}

class _ImagePicker extends FilePicker {
  Uint8List? bytes;
  FileType? requestedType;
  bool? requestedData;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    requestedType = type;
    requestedData = withData;
    final selected = bytes;
    return selected == null
        ? null
        : FilePickerResult([
            PlatformFile(
              name: 'cover.png',
              size: selected.length,
              bytes: selected,
            ),
          ]);
  }
}

Uint8List _png(int red, int blue) => Uint8List.fromList(
  img.encodePng(
    img.fill(
      img.Image(width: 80, height: 120, numChannels: 4),
      color: img.ColorRgba8(red, 80, blue, 128),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late _ImagePicker picker;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_album_actions_');
    stores = await AppStores.open(rootOverride: root);
    final images = [
      ResultImage(
        id: 'one',
        width: 80,
        height: 120,
        seed: 1,
        createdAt: 2000,
        bytes: _png(240, 20),
      ),
      ResultImage(
        id: 'two',
        width: 80,
        height: 120,
        seed: 2,
        createdAt: 1000,
        bytes: _png(20, 240),
      ),
    ];
    for (final image in images) {
      await stores.gallery.persistResult(image);
    }
    stores.gallery.scheduleIndex(results: images, selectedId: 'one', seq: 2);
    await stores.gallery.flushIndex();
    await stores.albums.update(
      (_) => AlbumsData(
        albums: const [
          GalleryAlbum(id: 'a', name: '喵喵', createdAt: 2000),
          GalleryAlbum(id: 'b', name: '其他', createdAt: 1000),
          GalleryAlbum(id: 'empty', name: '空图库', createdAt: 500),
        ],
        memberships: {
          'one': {'a', 'b'},
          'two': {'b'},
        },
      ),
    );
    await stores.prefs.write(key: 'desktop_gallery_choice', value: 'a');
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        gallerySearchProvider.overrideWith(_Search.new),
      ],
    );
    picker = _ImagePicker();
    FilePicker.platform = picker;
  });

  // Widget-created store chains are drained before leaving FakeAsync below.
  tearDown(() async {
    await root.delete(recursive: true);
  });

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

  Future<void> withBrowser(
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
            home: const Scaffold(body: DesktopGalleryBrowser()),
          ),
        ),
      );
      await tester.pumpAndSettle();
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

  Future<void> rightClick(WidgetTester tester, String album) async {
    final pointer = await tester.startGesture(
      tester.getCenter(key('desktop-library-card-$album')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await pointer.up();
    await tester.pumpAndSettle();
    expect(key('desktop-library-cover'), findsOneWidget);
  }

  Future<void> sources(WidgetTester tester, String album) async {
    await rightClick(tester, album);
    await tester.tap(key('desktop-library-cover'));
    await tester.pumpAndSettle();
    expect(key('album-cover-source-dialog'), findsOneWidget);
  }

  testWidgets(
    'right click keeps selection and reuses album name validation',
    (tester) async {
      await withBrowser(tester, () async {
        await rightClick(tester, 'a');
        expect(container.read(desktopGalleryLocationProvider).overview, isTrue);
        expect(container.read(desktopLibraryProvider).albumId, 'a');
        expect(container.read(galleryProvider).selectedId, 'one');
        await tester.tap(key('desktop-library-rename'));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(field, '其他');
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await tester.pumpAndSettle();
        expect(find.text('这个图库名称已存在'), findsOneWidget);
        await tester.enterText(field, '新的名字');
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await waitFor(
          tester,
          () =>
              container.read(albumsProvider).name('a') == '新的名字' &&
              find.byType(AlertDialog).evaluate().isEmpty,
          'rename finishes and closes dialog',
        );
        final restored = await tester.runAsync(() async {
          final store = AlbumStore(root);
          await store.load(liveImages: {'one', 'two'});
          return store;
        });
        expect(restored!.data.name('a'), '新的名字');
        expect(container.read(galleryProvider).selectedId, 'one');
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'deleting a shared-only album confirms count and retains shared images elsewhere',
    (tester) async {
      await withBrowser(tester, () async {
        await rightClick(tester, 'a');
        await tester.tap(key('desktop-library-delete'));
        await tester.pumpAndSettle();
        expect(find.textContaining('是否删除这个图库（包含 1 张图片）'), findsOneWidget);
        expect(find.textContaining('1 张图片也属于其他图库，将保留这些图片。'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(container.read(albumsProvider).exists('a'), isTrue);
        await rightClick(tester, 'a');
        await tester.tap(key('desktop-library-delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '删除图库'));
        await waitFor(
          tester,
          () => find.text('已删除图库及 0 张图片；1 张其他图库共用的图片已保留').evaluate().isNotEmpty,
          'album deletion finishes',
        );
        expect(container.read(albumsProvider).exists('a'), isFalse);
        expect(container.read(albumsProvider).ofImage('one'), {'b'});
        expect(container.read(galleryProvider).results, hasLength(2));
        expect(
          File('${root.path}/gallery/images/one.png').existsSync(),
          isTrue,
        );
        expect(
          File('${root.path}/gallery/images/two.png').existsSync(),
          isTrue,
        );
        expect(container.read(desktopLibraryProvider).albumId, isNull);
        expect(key('desktop-library-card-all'), findsOneWidget);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'renamed daily albums use their saved title in every desktop view',
    (tester) async {
      await withBrowser(tester, () async {
        const id = 'day_2026-10-02';
        unawaited(container.read(albumsProvider.notifier).ensureDailyAlbum(id));
        await waitFor(
          tester,
          () => key('desktop-library-card-$id').evaluate().isNotEmpty,
          'daily album is available',
        );
        await rightClick(tester, id);
        await tester.tap(key('desktop-library-rename'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '秋日猫猫',
        );
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await waitFor(
          tester,
          () =>
              container.read(albumsProvider).name(id) == '秋日猫猫' &&
              find.byType(AlertDialog).evaluate().isEmpty,
          'daily album rename is committed',
        );
        final albums = container.read(albumsProvider);
        expect(
          desktopLibraryLabel(
            const DesktopLibrarySelection(day: '2026-10-02'),
            albums,
          ),
          '秋日猫猫',
        );
        expect(
          desktopLibraryLabel(
            const DesktopLibrarySelection(choice: id, day: '2026-10-03'),
            albums,
          ),
          '秋日猫猫',
        );
        expect(
          desktopLibraryLabel(
            const DesktopLibrarySelection(day: '2026-10-03'),
            albums,
          ),
          '2026-10-03',
        );
        await tester.tap(key('desktop-library-card-$id'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widget<GalleryGridContent>(find.byType(GalleryGridContent))
              .browser!
              .title,
          '秋日猫猫',
        );
        expect(find.text('秋日猫猫'), findsWidgets);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'all works cannot be renamed and clearing keeps every album container',
    (tester) async {
      await withBrowser(tester, () async {
        await rightClick(tester, 'all');
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
        expect(container.read(galleryProvider).results, hasLength(2));
        await rightClick(tester, 'all');
        await tester.tap(key('desktop-library-delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '清空全部作品'));
        await waitFor(
          tester,
          () => find.text('已删除 2 张作品，图库已保留').evaluate().isNotEmpty,
          'verified deletion and persistence finish',
        );
        expect(container.read(galleryProvider).results, isEmpty);
        expect(container.read(albumsProvider).albums.map((album) => album.id), [
          'a',
          'b',
          'empty',
        ]);
        expect(container.read(albumsProvider).memberships, isEmpty);
        expect(key('desktop-library-card-all'), findsOneWidget);
        expect(
          File('${root.path}/gallery/images/one.png').existsSync(),
          isFalse,
        );
        expect(
          File('${root.path}/gallery/images/two.png').existsSync(),
          isFalse,
        );
        final reloaded = await tester.runAsync(
          () => AppStores.open(rootOverride: root),
        );
        expect(reloaded!.gallery.initialResults, isEmpty);
        expect(reloaded.albums.data.albums, hasLength(3));
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'clear all retains an image whose original path cannot be deleted',
    (tester) async {
      await withBrowser(tester, () async {
        await tester.runAsync(() async {
          final path = '${root.path}/gallery/images/two.png';
          await File(path).delete();
          await Directory(path).create();
        });
        await rightClick(tester, 'all');
        await tester.tap(key('desktop-library-delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '清空全部作品'));
        await waitFor(
          tester,
          () => find.text('已删除 1 张作品；1 张未能删除，仍保留在图库中').evaluate().isNotEmpty,
          'partial deletion is reported accurately',
        );
        expect(container.read(galleryProvider).results.single.id, 'two');
        expect(container.read(albumsProvider).ofImage('two'), {'b'});
        expect(container.read(albumsProvider).albums, hasLength(3));
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final source in ['current', 'history']) {
    testWidgets(
      '$source cover selection is scoped and survives restart',
      (tester) async {
        await withBrowser(tester, () async {
          await sources(tester, 'a');
          await tester.tap(key('album-cover-$source'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(key('history-image-picker'), findsOneWidget);
          expect(key('history-image-one'), findsOneWidget);
          expect(
            key('history-image-two'),
            source == 'current' ? findsNothing : findsOneWidget,
          );
          final selectedId = source == 'current' ? 'one' : 'two';
          await tester.tap(key('history-image-$selectedId'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(key('album-cover-crop-dialog'), findsOneWidget);
          await tester.tap(key('album-cover-save'));
          await waitFor(
            tester,
            () =>
                container.read(albumsProvider).cover('a') != null &&
                find.text('封面已更新').evaluate().isNotEmpty,
            'cover is cropped and persisted',
          );
          final cover = container.read(albumsProvider).cover('a')!;
          expect(cover.sourceImageId, selectedId);
          final restored = await tester.runAsync(() async {
            final store = AlbumStore(root);
            await store.load(liveImages: {'one', 'two'});
            return (store.data.cover('a'), await store.readCover(cover.key));
          });
          expect(restored!.$1!.key, cover.key);
          final decoded = img.decodePng(restored.$2!)!;
          expect((decoded.width, decoded.height), (512, 512));
          expect(decoded.getPixel(200, 200).a, inInclusiveRange(126, 130));
          expect(container.read(desktopLibraryProvider).albumId, 'a');
          expect(container.read(galleryProvider).selectedId, 'one');
          expect(
            find.descendant(
              of: key('desktop-library-card-a'),
              matching: find.byType(AlbumCoverImage),
            ),
            findsOneWidget,
          );
        });
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets(
    'local upload can cancel, customize all works and restore automatic cover',
    (tester) async {
      await withBrowser(tester, () async {
        await sources(tester, 'all');
        await tester.tap(key('album-cover-upload'));
        await tester.pumpAndSettle();
        expect(key('album-cover-crop-dialog'), findsNothing);
        expect(container.read(albumsProvider).allPhotosCover, isNull);
        picker.bytes = _png(80, 200);
        await sources(tester, 'all');
        await tester.tap(key('album-cover-upload'));
        await tester.pumpAndSettle();
        expect(key('album-cover-crop-dialog'), findsOneWidget);
        expect(picker.requestedType, FileType.image);
        expect(picker.requestedData, isTrue);
        await tester.tap(key('album-cover-save'));
        await waitFor(
          tester,
          () =>
              container.read(albumsProvider).allPhotosCover != null &&
              find.text('封面已更新').evaluate().isNotEmpty,
          'uploaded cover is saved',
        );
        expect(
          container.read(albumsProvider).allPhotosCover!.sourceImageId,
          isNull,
        );
        expect(container.read(galleryProvider).results, hasLength(2));
        await sources(tester, 'all');
        await tester.tap(key('album-cover-auto'));
        await waitFor(
          tester,
          () =>
              container.read(albumsProvider).allPhotosCover == null &&
              find.text('已恢复自动封面').evaluate().isNotEmpty,
          'automatic cover is restored',
        );
        expect(container.read(galleryProvider).results, hasLength(2));
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'empty album keeps history and upload available without an overflowing source menu',
    (tester) async {
      await withBrowser(tester, () async {
        await sources(tester, 'empty');
        tester.view.physicalSize = const Size(360, 640);
        await tester.pumpAndSettle();
        expect(
          tester.widget<ListTile>(key('album-cover-current')).enabled,
          isFalse,
        );
        expect(
          tester.widget<ListTile>(key('album-cover-history')).enabled,
          isTrue,
        );
        expect(
          tester.widget<ListTile>(key('album-cover-upload')).enabled,
          isTrue,
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(container.read(albumsProvider).cover('empty'), isNull);
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
