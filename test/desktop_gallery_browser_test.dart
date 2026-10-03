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
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_groups.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
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
  GallerySearchState build() => const GallerySearchState(
    byId: {
      'sample0': (model: 'NAI 4.5 Full', text: 'cat, outdoors'),
      'sample1': (model: 'NAI 4 Curated', text: 'cat, indoors'),
      'sample2': (model: 'NAI 4.5 Full', text: 'landscape, outdoors'),
    },
  );
}

class _Picker extends FilePicker {
  String? path;
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => path;
}

class _Characters extends GalleryCharTags {
  @override
  Future<Map<String, List<GroupTag>>> build() async => {
    'sample0': [(key: 'cat', label: '猫猫')],
    'sample1': [(key: 'cat', label: '猫猫')],
  };
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Directory output;
  late _Picker picker;
  late List<ResultImage> images;
  var disposed = false;
  setUp(() {
    disposed = false;
    stores = AppStores.ephemeral();
    output = Directory.systemTemp.createTempSync('plana_library_browser_');
    picker = _Picker()..path = output.path;
    FilePicker.platform = picker;
    images = [
      for (var i = 0; i < 3; i++)
        ResultImage(
          id: 'sample$i',
          width: 80,
          height: 120,
          seed: 100 + i,
          createdAt: DateTime.now()
              .subtract(Duration(days: i))
              .millisecondsSinceEpoch,
          bytes: Uint8List.fromList(
            img.encodePng(img.Image(width: 80, height: 120)),
          ),
        ),
    ];
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => _Gallery(images)),
        gallerySearchProvider.overrideWith(_Search.new),
        galleryCharTagsProvider.overrideWith(_Characters.new),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      (_) async => throw StateError('Desktop must not export to phone gallery'),
    );
  });
  tearDown(() {
    stores.flushNow();
    if (!disposed) container.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      null,
    );
    output.deleteSync(recursive: true);
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> mount(
    WidgetTester tester, {
    Widget child = const DesktopGalleryBrowser(),
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
  }

  Future<void> waitForIo(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 600 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue, reason: reason);
    // Only settle route animations after the actual I/O-dependent state is
    // ready. A file appearing or a quiet frame does not mean export is done.
    await tester.pumpAndSettle();
  }

  bool exportFinished(WidgetTester tester) =>
      key('gallery-export-dialog').evaluate().isEmpty &&
      key('gallery-batch-export').evaluate().isNotEmpty &&
      tester.widget<FilledButton>(key('gallery-batch-export')).onPressed !=
          null;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    stores.flushNow();
    var done = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.albums.idle,
      ]).then((_) => done = true),
    );
    for (var i = 0; i < 100 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done, isTrue);
    await tester.pump();
    container.dispose();
    disposed = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  Future<void> openAll(WidgetTester tester) async {
    await tester.tap(key('desktop-library-card-all'));
    await tester.pumpAndSettle();
  }

  Future<void> holdImage(WidgetTester tester, String id) async {
    final tile = key('desktop-image-$id');
    await tester.ensureVisible(tile);
    final press = await tester.startGesture(
      tester.getCenter(tile),
      kind: PointerDeviceKind.mouse,
    );
    await press.moveBy(const Offset(5, 0));
    await tester.pump();
    await press.up();
    await tester.pumpAndSettle();
  }

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '${kind.name} selection starts with its pointer gesture and release never opens the image',
      (tester) async {
        await mount(tester);
        await openAll(tester);
        expect(find.text('多选'), findsNothing);
        final selected = container.read(galleryProvider).selectedId;
        final tile = key('desktop-image-sample0');
        final press = await tester.startGesture(
          tester.getCenter(tile),
          kind: kind,
        );
        expect(tester.widget<GalleryImageTile>(tile).selecting, isFalse);
        expect(key('desktop-image-viewer'), findsNothing);
        if (kind == PointerDeviceKind.touch) {
          await tester.pump(const Duration(milliseconds: 199));
          expect(tester.widget<GalleryImageTile>(tile).selecting, isFalse);
          await tester.pump(const Duration(milliseconds: 2));
        } else {
          await press.moveBy(const Offset(5, 0));
          await tester.pump();
        }
        expect(tester.widget<GalleryImageTile>(tile).selecting, isTrue);
        expect(tester.widget<GalleryImageTile>(tile).picked, isTrue);
        expect(find.text('已选 1 张'), findsOneWidget);
        await press.up();
        await tester.pumpAndSettle();
        expect(find.text('已选 1 张'), findsOneWidget);
        expect(key('desktop-image-viewer'), findsNothing);
        await tester.tap(key('desktop-image-sample1'));
        await tester.pumpAndSettle();
        expect(find.text('已选 2 张'), findsOneWidget);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.text('已选 1 张'), findsOneWidget);
        await tester.tap(find.text('全选').first);
        await tester.pumpAndSettle();
        expect(find.text('已选 3 张'), findsOneWidget);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(tester.widget<GalleryImageTile>(tile).selecting, isFalse);
        expect(find.text('多选'), findsNothing);
        expect(container.read(galleryProvider).selectedId, selected);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'Escape exits gallery selection with search focus and clears picks',
    (tester) async {
      await mount(tester);
      await openAll(tester);
      await holdImage(tester, 'sample0');
      await tester.tap(key('desktop-image-sample1'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 张'), findsOneWidget);
      await tester.tap(key('desktop-gallery-search'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(key('desktop-gallery-search'))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 '), findsNothing);
      expect(key('gallery-batch-export'), findsNothing);
      expect(key('desktop-gallery-grid'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('desktop-gallery-grid'), findsOneWidget);
      expect(container.read(desktopGalleryLocationProvider).overview, isFalse);
      await holdImage(tester, 'sample1');
      expect(find.text('已选 1 张'), findsOneWidget);
      expect(
        tester.widget<GalleryImageTile>(key('desktop-image-sample0')).picked,
        isFalse,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'Escape cancels the first gallery sweep before exiting selection',
    (tester) async {
      await mount(tester);
      await openAll(tester);
      final press = await tester.startGesture(
        tester.getCenter(key('desktop-image-sample0')),
        kind: PointerDeviceKind.mouse,
      );
      await press.moveBy(const Offset(5, 0));
      await tester.pump();
      expect(find.text('已选 1 张'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 '), findsNothing);
      await press.moveTo(tester.getCenter(key('desktop-image-sample1')));
      await tester.pump();
      await press.up();
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 '), findsNothing);
      expect(key('desktop-gallery-grid'), findsOneWidget);
      expect(key('desktop-image-viewer'), findsNothing);
      expect(container.read(galleryProvider).selectedId, 'sample0');
      await finish(tester);
    },
  );

  testWidgets(
    'Escape respects gallery export options without clearing selection',
    (tester) async {
      await mount(tester);
      await openAll(tester);
      await holdImage(tester, 'sample0');
      await tester.tap(key('gallery-batch-export'));
      await tester.pumpAndSettle();
      expect(key('gallery-export-dialog'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // Export options deliberately disable barrier/Escape dismissal.
      expect(key('gallery-export-dialog'), findsOneWidget);
      expect(find.text('已选 1 张'), findsOneWidget);
      expect(
        tester.widget<GalleryImageTile>(key('desktop-image-sample0')).picked,
        isTrue,
      );
      await tester.tap(
        find.descendant(
          of: key('gallery-export-dialog'),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(key('gallery-export-dialog'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 '), findsNothing);
      expect(key('desktop-gallery-grid'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'new library capsule reuses validation and reveals a created album after filtering',
    (tester) async {
      await tester.runAsync(
        () => container.read(albumsProvider.notifier).create('已有图库'),
      );
      await mount(tester);
      final folder = tester.getRect(key('desktop-gallery-folder'));
      final create = tester.getRect(key('desktop-gallery-create'));
      expect(create.left, greaterThan(folder.right));
      expect((create.center.dy - folder.center.dy).abs(), lessThan(3));
      expect(
        tester
            .widget<TextButton>(key('desktop-gallery-create'))
            .style!
            .shape!
            .resolve({}),
        isA<StadiumBorder>(),
      );
      await tester.enterText(key('desktop-gallery-search'), '已有');
      await tester.tap(key('desktop-gallery-date'));
      await tester.pumpAndSettle();
      await tester.tap(key('gallery-date-kind-today'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-gallery-create'));
      await tester.pumpAndSettle();
      final name = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(name, '   ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1–40 个字符的图库名称'), findsOneWidget);
      await tester.enterText(name, '已有图库');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('这个图库名称已存在'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(container.read(albumsProvider).albums, hasLength(1));
      expect(container.read(desktopGalleryLocationProvider).overview, isTrue);
      expect(
        tester
            .widget<TextField>(key('desktop-gallery-search'))
            .controller!
            .text,
        '已有',
      );
      await tester.tap(key('desktop-gallery-create'));
      await tester.pumpAndSettle();
      await tester.enterText(name, '  新图库  ');
      await tester.tap(find.text('保存'));
      await waitForIo(
        tester,
        () =>
            container.read(albumsProvider).albums.any((a) => a.name == '新图库') &&
            find.byType(AlertDialog).evaluate().isEmpty &&
            key('desktop-gallery-grid').evaluate().isNotEmpty,
        'creating a library must finish its album write and open the grid',
      );
      final albums = container.read(albumsProvider).albums;
      expect(albums, hasLength(2));
      final created = albums.singleWhere((a) => a.name == '新图库');
      expect(container.read(desktopGalleryLocationProvider), (
        overview: false,
        albumId: created.id,
      ));
      expect(container.read(desktopLibraryProvider).albumId, created.id);
      expect(key('desktop-gallery-grid'), findsOneWidget);
      expect(find.text('新图库'), findsOneWidget);
      await tester.tap(key('desktop-gallery-up'));
      await tester.pumpAndSettle();
      expect(key('desktop-library-card-${created.id}'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(key('desktop-gallery-search'))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('全部时间'), findsOneWidget);
      tester.view.physicalSize = const Size(600, 650);
      await tester.pumpAndSettle();
      expect(key('desktop-gallery-create').hitTestable(), findsOneWidget);
      expect(key('desktop-gallery-folder').hitTestable(), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'creation gallery picker creates one album and selects the ID returned by the name dialog',
    (tester) async {
      await mount(
        tester,
        child: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 260, child: DesktopLibraryButton()),
        ),
      );
      await tester.tap(key('desktop-library-picker'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-new-album'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '创作图库',
      );
      await tester.tap(find.text('保存'));
      await waitForIo(
        tester,
        () =>
            container
                .read(albumsProvider)
                .albums
                .any((a) => a.name == '创作图库') &&
            find.byType(AlertDialog).evaluate().isEmpty &&
            key('desktop-library-dialog').evaluate().isEmpty,
        'creating from the picker must finish saving and close both dialogs',
      );
      final created = container.read(albumsProvider).albums.single;
      expect(created.name, '创作图库');
      expect(container.read(desktopLibraryProvider).albumId, created.id);
      expect(key('desktop-library-dialog'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'library hierarchy, adjacent folder control and image details remain separate from creation selection',
    (tester) async {
      final album = (await tester.runAsync(
        () => container.read(albumsProvider.notifier).create('猫猫图库'),
      ))!;
      await tester.runAsync(
        () => container
            .read(albumsProvider.notifier)
            .organize({'sample0', 'sample1'}, {album}),
      );
      await mount(tester);
      expect(find.text('返回创作'), findsNothing);
      final date = tester.getRect(key('desktop-gallery-date'));
      final folder = tester.getRect(key('desktop-gallery-folder'));
      expect(folder.left, greaterThan(date.right));
      expect((folder.center.dy - date.center.dy).abs(), lessThan(3));
      await tester.tap(key('desktop-library-card-$album'));
      await tester.pumpAndSettle();
      expect(find.text('分组'), findsOneWidget);
      expect(find.text('模型'), findsOneWidget);
      expect(find.text('多选'), findsNothing);
      expect(key('desktop-image-sample2'), findsNothing);
      container.read(desktopLibraryProvider.notifier).choose(null);
      await tester.pumpAndSettle();
      expect(
        key('desktop-image-sample2'),
        findsNothing,
        reason:
            'Open library is independent from later creation library changes',
      );
      final selected = container.read(galleryProvider).selectedId;
      await tester.tap(key('desktop-image-sample1'));
      await settleIo(tester);
      expect(key('desktop-image-viewer'), findsOneWidget);
      expect(
        find.text('2 / 2'),
        findsOneWidget,
        reason: 'Viewer navigation spans the displayed dates',
      );
      expect(container.read(galleryProvider).selectedId, selected);
      await tester.tap(key('desktop-image-close'));
      await tester.pumpAndSettle();
      expect(key('desktop-gallery-grid'), findsOneWidget);
      await tester.tap(key('desktop-gallery-up'));
      await tester.pumpAndSettle();
      expect(key('desktop-gallery-libraries'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'model, date and text filters intersect and remove hidden batch selections',
    (tester) async {
      await mount(tester);
      await openAll(tester);
      await holdImage(tester, 'sample0');
      await tester.tap(find.text('全选').first);
      await tester.pumpAndSettle();
      expect(find.text('已选 3 张'), findsOneWidget);
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NAI 4.5 Full'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 张'), findsOneWidget);
      expect(key('desktop-image-sample1'), findsNothing);
      await tester.enterText(key('desktop-gallery-search'), '102');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 张'), findsOneWidget);
      expect(key('desktop-image-sample2'), findsOneWidget);
      await tester.enterText(key('desktop-gallery-search'), '');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-gallery-date'));
      await tester.pumpAndSettle();
      expect(key('gallery-date-panel'), findsOneWidget);
      await tester.tap(key('gallery-date-kind-today'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 张'), findsOneWidget);
      expect(key('desktop-image-sample0'), findsOneWidget);
      expect(key('desktop-image-sample2'), findsNothing);
      expect(
        tester.widget<FilledButton>(key('gallery-batch-export')).onPressed,
        isNull,
      );
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(600, 650);
      await tester.pumpAndSettle();
      expect(key('desktop-gallery-folder').hitTestable(), findsOneWidget);
      expect(key('desktop-gallery-date').hitTestable(), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'group drilldown returns to the group wall then the library overview',
    (tester) async {
      await mount(tester);
      await openAll(tester);
      await tester.tap(find.text('分组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按角色'));
      await tester.pumpAndSettle();
      expect(find.text('猫猫'), findsOneWidget);
      expect(find.text('未归类'), findsOneWidget);
      await tester.tap(find.text('猫猫'));
      await tester.pumpAndSettle();
      expect(key('desktop-image-sample0'), findsOneWidget);
      expect(key('desktop-image-sample1'), findsOneWidget);
      expect(key('desktop-image-sample2'), findsNothing);
      await holdImage(tester, 'sample0');
      await tester.tap(find.text('全选').first);
      await tester.pumpAndSettle();
      expect(find.text('已选 2 张'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-gallery-up'));
      await tester.pumpAndSettle();
      expect(find.text('未归类'), findsOneWidget);
      await tester.tap(key('desktop-gallery-up'));
      await tester.pumpAndSettle();
      expect(key('desktop-gallery-libraries'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'browser batches export only selected images, keeps cancellation safe and deletes through confirmation',
    (tester) async {
      await mount(tester);
      await openAll(tester);
      await holdImage(tester, 'sample1');
      await tester.tap(key('gallery-batch-export'));
      await tester.pumpAndSettle();
      await tester.tap(key('gallery-export-browse'));
      await tester.pumpAndSettle();
      await tester.tap(key('gallery-export-submit'));
      await waitForIo(
        tester,
        () => exportFinished(tester),
        'export must verify its output, close the modal, and enable the batch controls',
      );
      final files = output.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.path, contains('sample1'));
      expect(files.single.readAsBytesSync(), images[1].bytes);
      picker.path = null;
      await tester.tap(key('gallery-batch-export'));
      await tester.pumpAndSettle();
      await tester.tap(key('gallery-export-browse'));
      await tester.pumpAndSettle();
      await tester.tap(key('gallery-export-cancel'));
      await waitForIo(
        tester,
        () => exportFinished(tester),
        'canceling export must close its modal and release the batch controls',
      );
      expect(output.listSync().whereType<File>(), hasLength(1));
      await tester.tap(find.text('删除 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('删除 1 张作品?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(container.read(galleryProvider).results, hasLength(3));
      await tester.tap(find.text('删除 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await waitForIo(
        tester,
        () =>
            !container
                .read(galleryProvider)
                .results
                .any((r) => r.id == 'sample1') &&
            find.byType(AlertDialog).evaluate().isEmpty,
        'confirmed deletion must update gallery state and close its dialog',
      );
      expect(container.read(galleryProvider).results.map((r) => r.id), [
        'sample0',
        'sample2',
      ]);
      expect(key('desktop-gallery-grid'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'batch move uses the open library even after the creation library changes',
    (tester) async {
      final source = (await tester.runAsync(
        () => container.read(albumsProvider.notifier).create('来源图库'),
      ))!;
      final target = (await tester.runAsync(
        () => container.read(albumsProvider.notifier).create('目标图库'),
      ))!;
      await tester.runAsync(
        () => container
            .read(albumsProvider.notifier)
            .organize({'sample0'}, {source}),
      );
      await mount(tester);
      await tester.tap(key('desktop-library-card-$source'));
      await tester.pumpAndSettle();
      container.read(desktopLibraryProvider.notifier).choose(target);
      await tester.pumpAndSettle();
      await holdImage(tester, 'sample0');
      await tester.tap(find.text('移动 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('移动到图库'), findsOneWidget);
      await tester.tap(key('gallery-transfer-target-$target'));
      await tester.pumpAndSettle();
      final submit = key('gallery-transfer-submit');
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      await tester.pump();
      for (
        var i = 0;
        i < 200 && container.read(albumsProvider).contains(source, 'sample0');
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        container.read(albumsProvider).contains(source, 'sample0'),
        isFalse,
      );
      expect(
        container.read(albumsProvider).contains(target, 'sample0'),
        isTrue,
      );
      expect(key('desktop-image-sample0'), findsNothing);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-gallery-up'));
      await tester.pumpAndSettle();
      expect(key('desktop-gallery-libraries'), findsOneWidget);
      await finish(tester);
    },
  );
}
