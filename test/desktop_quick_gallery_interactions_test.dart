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
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/desktop/desktop_gallery_page.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';
import 'package:plana_app/features/generate/models.dart';

class _DirectoryPicker extends FilePicker {
  String? directory;
  int calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls++;
    return directory;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Directory output;
  late _DirectoryPicker picker;
  var disposed = false;

  Finder key(String value) => find.byKey(ValueKey(value));
  Finder tile(ResultImage image) => key('quick-gallery-image-${image.id}');
  Finder getQuick() => key('desktop-quick-gallery');
  Set<String> liveIds() => {
    for (final image in container.read(galleryProvider).results) image.id,
  };

  setUp(() {
    disposed = false;
    stores = AppStores.ephemeral();
    output = Directory.systemTemp.createTempSync('plana_quick_interactions_');
    picker = _DirectoryPicker()..directory = output.path;
    FilePicker.platform = picker;
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    container.read(desktopLibraryProvider.notifier).choose(null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      (_) async => throw StateError('Quick export must use the desktop dialog'),
    );
  });

  tearDown(() {
    stores.flushNow();
    if (!disposed) container.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      null,
    );
    if (output.existsSync()) output.deleteSync(recursive: true);
  });

  // Keep the real gallery, membership, search and export pipeline. The fixture
  // writes only to AppStores.ephemeral and the per-test output directory.
  Future<ResultImage> addImage({
    required int seed,
    String? albumId,
    String prompt = 'cat, outdoors',
  }) async {
    final input = GenerateState.initial().copyWith(
      prompt: prompt,
      negativePrompt: 'lowres',
      params: GenParams(width: 64, height: 96, seed: '$seed'),
    );
    final bytes = await writeImageMetadataPng(
      Uint8List.fromList(
        img.encodePng(
          img.fill(
            img.Image(width: 64, height: 96),
            color: img.ColorRgb8(seed % 255, 60, 160),
          ),
        ),
      ),
      comment: {
        'prompt': prompt,
        'uc': 'lowres',
        'steps': 28,
        'scale': 5.0,
        'sampler': 'k_euler_ancestral',
        'seed': seed,
        'width': 64,
        'height': 96,
      },
    );
    final image = container
        .read(galleryProvider.notifier)
        .addResult(
          bytes: bytes,
          width: 64,
          height: 96,
          seed: seed,
          input: input,
        );
    await stores.gallery.idle;
    await stores.gallery.flushIndex();
    if (albumId != null) {
      await container
          .read(albumsProvider.notifier)
          .organize({image.id}, {albumId});
    }
    return image;
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 300 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue, reason: reason);
    // A confirmation route can leave the parent's progress ticker active.
    // Wait for the actual condition, then only finish the route transition.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  ScrollPosition gridPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find
                  .descendant(
                    of: getQuick(),
                    matching: find.byType(CustomScrollView),
                  )
                  .first,
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(width: 320, child: DesktopLibraryButton()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-history-browse'));
    await tester.pumpAndSettle();
    expect(getQuick(), findsOneWidget);
    // Session scroll memory is intentionally shared by quick browsing. Each
    // independent test starts from a known position without changing that code.
    gridPosition(tester).jumpTo(0);
    await tester.pumpAndSettle();
  }

  Future<void> hold(WidgetTester tester, ResultImage image) async {
    final press = await tester.startGesture(
      tester.getCenter(tile(image)),
      kind: PointerDeviceKind.mouse,
    );
    await press.moveBy(const Offset(5, 0));
    await tester.pump();
    await press.up();
    await tester.pumpAndSettle();
    expect(tester.widget<GalleryImageTile>(tile(image)).picked, isTrue);
  }

  Future<void> openExport(WidgetTester tester) async {
    await tester.tap(key('gallery-batch-export'));
    await tester.pumpAndSettle();
    expect(key('gallery-export-dialog'), findsOneWidget);
    for (final mode in ['selected', 'keepSamples', 'deleteAlbum']) {
      expect(key('gallery-export-cleanup-$mode'), findsOneWidget);
    }
    expect(
      picker.calls,
      0,
      reason: 'Opening export must first show its options',
    );
    await tester.tap(key('gallery-export-browse'));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    expect(
      tester
          .widget<TextField>(key('gallery-export-directory'))
          .controller!
          .text,
      output.path,
    );
  }

  Future<void> requestCleanup(WidgetTester tester, String mode) async {
    await tester.ensureVisible(key('gallery-export-cleanup-$mode'));
    await tester.tap(key('gallery-export-cleanup-$mode'));
    await tester.pumpAndSettle();
    await tester.tap(key('gallery-export-submit'));
    await until(
      tester,
      () => key('gallery-export-confirm-dialog').evaluate().isNotEmpty,
      'Cleanup must prepare its whole-library scope and ask for confirmation',
    );
  }

  Future<void> confirmExport(WidgetTester tester) async {
    await tester.tap(key('gallery-export-confirm'));
    await until(
      tester,
      () => key('gallery-export-dialog').evaluate().isEmpty,
      'Confirmed export and cleanup must finish before closing the dialog',
    );
    await tester.pumpAndSettle();
  }

  void expectOneExport(ResultImage selected) {
    final files = output.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, contains('_${selected.id}_'));
    expect(files.single.readAsBytesSync(), selected.bytes);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    var idle = false;
    unawaited(
      Future.wait([
        stores.gallery.flushIndex(),
        stores.gallery.idle,
        stores.albums.idle,
      ]).then((_) => idle = true),
    );
    await until(tester, () => idle, 'The isolated gallery writes must finish');
    container.dispose();
    disposed = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      'quick ${kind.name} selection starts with its pointer gesture and consumes release',
      (tester) async {
        late ResultImage first;
        late ResultImage second;
        await tester.runAsync(() async {
          first = await addImage(seed: 1001);
          second = await addImage(seed: 1002);
        });
        await mount(tester);
        final selected = container.read(galleryProvider).selectedId;
        expect(find.text('多选'), findsNothing);
        final press = await tester.startGesture(
          tester.getCenter(tile(first)),
          kind: kind,
        );
        expect(tester.widget<GalleryImageTile>(tile(first)).selecting, isFalse);
        if (kind == PointerDeviceKind.touch) {
          await tester.pump(const Duration(milliseconds: 199));
          expect(
            tester.widget<GalleryImageTile>(tile(first)).selecting,
            isFalse,
          );
          await tester.pump(const Duration(milliseconds: 2));
        } else {
          await press.moveBy(const Offset(5, 0));
          await tester.pump();
        }
        expect(tester.widget<GalleryImageTile>(tile(first)).selecting, isTrue);
        expect(tester.widget<GalleryImageTile>(tile(first)).picked, isTrue);
        await press.up();
        await tester.pumpAndSettle();
        expect(getQuick(), findsOneWidget);
        expect(find.text('已选 1 张'), findsOneWidget);
        expect(container.read(galleryProvider).selectedId, selected);
        await tester.tap(tile(second));
        await tester.pumpAndSettle();
        expect(find.text('已选 2 张'), findsOneWidget);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(tester.widget<GalleryImageTile>(tile(first)).selecting, isFalse);
        expect(find.text('多选'), findsNothing);
        expect(key('quick-gallery-search').hitTestable(), findsOneWidget);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'Escape exits quick selection with search focus and keeps browsing',
    (tester) async {
      late ResultImage first;
      late ResultImage second;
      await tester.runAsync(() async {
        first = await addImage(seed: 1101);
        second = await addImage(seed: 1102);
      });
      await mount(tester);
      await hold(tester, first);
      await tester.tap(tile(second));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 张'), findsOneWidget);
      await tester.tap(key('quick-gallery-search'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(key('quick-gallery-search'))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 '), findsNothing);
      expect(key('gallery-batch-export'), findsNothing);
      expect(getQuick(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(getQuick(), findsOneWidget);
      await hold(tester, second);
      expect(find.text('已选 1 张'), findsOneWidget);
      expect(tester.widget<GalleryImageTile>(tile(first)).picked, isFalse);
      // The header close button lies outside the grid content's focus subtree.
      Focus.of(tester.element(find.byTooltip('关闭快速浏览'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 '), findsNothing);
      expect(getQuick(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(getQuick(), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('Escape cancels the first quick sweep before exiting selection', (
    tester,
  ) async {
    late ResultImage first;
    late ResultImage second;
    await tester.runAsync(() async {
      first = await addImage(seed: 1201);
      second = await addImage(seed: 1202);
    });
    await mount(tester);
    final selected = container.read(galleryProvider).selectedId;
    final press = await tester.startGesture(
      tester.getCenter(tile(first)),
      kind: PointerDeviceKind.mouse,
    );
    await press.moveBy(const Offset(5, 0));
    await tester.pump();
    expect(find.text('已选 1 张'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 '), findsNothing);
    await press.moveTo(tester.getCenter(tile(second)));
    await tester.pump();
    await press.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 '), findsNothing);
    expect(getQuick(), findsOneWidget);
    expect(container.read(galleryProvider).selectedId, selected);
    await finish(tester);
  });

  testWidgets('Escape stays within quick export confirmation and options', (
    tester,
  ) async {
    final image = (await tester.runAsync(() => addImage(seed: 1301)))!;
    await mount(tester);
    await hold(tester, image);
    await openExport(tester);
    await requestCleanup(tester, 'selected');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(key('gallery-export-confirm-dialog'), findsNothing);
    expect(key('gallery-export-dialog'), findsOneWidget);
    expect(find.text('已选 1 张'), findsOneWidget);
    expect(tester.widget<GalleryImageTile>(tile(image)).picked, isTrue);
    expect(liveIds(), {image.id});
    expect(output.listSync(), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // The options route is intentionally not dismissible with Escape.
    expect(key('gallery-export-dialog'), findsOneWidget);
    expect(find.text('已选 1 张'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: key('gallery-export-dialog'),
        matching: find.text('取消'),
      ),
    );
    await tester.pumpAndSettle();
    expect(key('gallery-export-dialog'), findsNothing);
    expect(find.text('已选 1 张'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 '), findsNothing);
    expect(getQuick(), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
    'quick hold cancels for pointer cancellation, dragging and wheel',
    (tester) async {
      late ResultImage latest;
      await tester.runAsync(() async {
        for (var i = 0; i < 24; i++) {
          latest = await addImage(seed: 2000 + i);
        }
      });
      await mount(tester);
      final selected = container.read(galleryProvider).selectedId;
      final canceled = await tester.startGesture(
        tester.getCenter(tile(latest)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await canceled.cancel();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<GalleryImageTile>(tile(latest)).selecting, isFalse);

      final drag = await tester.startGesture(tester.getCenter(tile(latest)));
      await tester.pump(const Duration(milliseconds: 50));
      await drag.moveBy(const Offset(0, -70));
      await tester.pump();
      await drag.moveBy(const Offset(0, -70));
      await tester.pump(const Duration(milliseconds: 250));
      await drag.up();
      await tester.pumpAndSettle();
      expect(gridPosition(tester).pixels, greaterThan(0));
      expect(find.textContaining('已选 '), findsNothing);
      gridPosition(tester).jumpTo(0);
      await tester.pumpAndSettle();

      final point = tester.getCenter(tile(latest));
      final wheelHold = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: point,
          scrollDelta: const Offset(0, 160),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await wheelHold.up();
      await tester.pumpAndSettle();
      expect(gridPosition(tester).pixels, greaterThan(0));
      expect(find.textContaining('已选 '), findsNothing);
      expect(getQuick(), findsOneWidget);
      expect(container.read(galleryProvider).selectedId, selected);
      await finish(tester);
    },
  );

  testWidgets(
    'quick secondary click keeps the per-image menu without selecting',
    (tester) async {
      final image = (await tester.runAsync(() => addImage(seed: 2101)))!;
      await mount(tester);
      final right = await tester.startGesture(
        tester.getCenter(tile(image)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await until(
        tester,
        () => find.text('导入').evaluate().isNotEmpty,
        'The per-image menu must open after its full image is predecoded',
      );
      expect(find.text('导入'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('分享'), findsNothing);
      expect(find.text('移动'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.textContaining('已选 '), findsNothing);
      expect(getQuick(), findsOneWidget);
      expect(liveIds(), {image.id});
      // Dismiss through the route barrier; no per-image mutation is invoked.
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.text('导入'), findsNothing);
      expect(getQuick(), findsOneWidget);
      await hold(tester, image);
      await finish(tester);
    },
  );

  testWidgets('quick library switch follows the output folder and wraps', (
    tester,
  ) async {
    late ResultImage cat;
    late ResultImage forest;
    await tester.runAsync(() async {
      cat = await addImage(seed: 2201, prompt: 'cat, outdoors');
      forest = await addImage(seed: 2202, prompt: 'forest, landscape');
    });
    await mount(tester);
    final search = tester.getRect(key('quick-gallery-search'));
    final folder = tester.getRect(key('desktop-gallery-folder'));
    final library = tester.getRect(key('quick-gallery-library'));
    final group = tester.getRect(find.text('分组'));
    expect(search.right, lessThan(folder.left));
    expect(folder.right, lessThan(library.left));
    expect(library.right, lessThan(group.left));
    expect((search.center.dy - library.center.dy).abs(), lessThan(3));
    expect(find.byTooltip('搜索提示词标签'), findsNothing);
    await tester.enterText(key('quick-gallery-search'), 'forest');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tile(forest), findsOneWidget);
    expect(tile(cat), findsNothing);
    await tester.enterText(key('quick-gallery-search'), '${cat.seed}');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tile(cat), findsOneWidget);
    expect(tile(forest), findsNothing);
    await tester.enterText(key('quick-gallery-search'), forest.id);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tile(forest), findsOneWidget);
    expect(tile(cat), findsNothing);
    await tester.enterText(key('quick-gallery-search'), '');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tile(cat), findsOneWidget);
    expect(tile(forest), findsOneWidget);
    for (final size in [const Size(720, 650), const Size(600, 760)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(key('quick-gallery-search').hitTestable(), findsOneWidget);
      expect(key('quick-gallery-library').hitTestable(), findsOneWidget);
      final panel = tester.getRect(getQuick());
      for (final control in ['quick-gallery-search', 'quick-gallery-library']) {
        final bounds = tester.getRect(key(control));
        expect(bounds.left, greaterThanOrEqualTo(panel.left));
        expect(bounds.right, lessThanOrEqualTo(panel.right));
      }
      expect(tester.takeException(), isNull);
    }
    await finish(tester);
  });

  testWidgets(
    'quick sample cleanup includes hidden unselected images in its album',
    (tester) async {
      late String album;
      late String otherAlbum;
      late ResultImage selected;
      late ResultImage hidden;
      late ResultImage newest;
      late ResultImage outside;
      await tester.runAsync(() async {
        album = await container.read(albumsProvider.notifier).create('样图图库');
        otherAlbum = await container
            .read(albumsProvider.notifier)
            .create('其他图库');
        selected = await addImage(seed: 3101, albumId: album);
        hidden = await addImage(seed: 3102, albumId: album);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        newest = await addImage(seed: 3103, albumId: album);
        // Same settings in a different album must never steal this album's sample.
        outside = await addImage(seed: 3104, albumId: otherAlbum);
      });
      expect(newest.createdAt, greaterThan(hidden.createdAt));
      container.read(desktopLibraryProvider.notifier).choose(album);
      await mount(tester);
      await tester.enterText(key('quick-gallery-search'), '${selected.seed}');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tile(hidden), findsNothing);
      expect(tile(newest), findsNothing);
      await hold(tester, selected);
      await openExport(tester);
      expect(find.text('「样图图库」· 已选 1 张'), findsOneWidget);
      await requestCleanup(tester, 'keepSamples');
      expect(find.text('导出所选 1 张；从「样图图库」删除 2 张。'), findsOneWidget);
      expect(find.text('其中 1 张未选择导出，也会被删除。'), findsOneWidget);
      await confirmExport(tester);
      expectOneExport(selected);
      expect(liveIds(), {newest.id, outside.id});
      expect(container.read(albumsProvider).contains(album, newest.id), isTrue);
      expect(
        container.read(albumsProvider).contains(otherAlbum, outside.id),
        isTrue,
      );
      expect(
        await tester.runAsync(() => stores.gallery.readImage(hidden.id)),
        isNull,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'quick automatic date export uses the date album for full cleanup',
    (tester) async {
      final dayAlbum = dailyAlbumId(DateTime.now());
      final dayName = dayAlbum.substring(4);
      late String otherAlbum;
      late ResultImage selected;
      late ResultImage unselected;
      late ResultImage outside;
      await tester.runAsync(() async {
        await container
            .read(albumsProvider.notifier)
            .ensureDailyAlbum(dayAlbum);
        otherAlbum = await container
            .read(albumsProvider.notifier)
            .create('保留图库');
        selected = await addImage(seed: 3201, albumId: dayAlbum);
        unselected = await addImage(seed: 3202, albumId: dayAlbum);
        outside = await addImage(seed: 3203, albumId: otherAlbum);
      });
      container
          .read(desktopLibraryProvider.notifier)
          .choose(null, automatic: true);
      await mount(tester);
      expect(tile(outside), findsNothing);
      await hold(tester, selected);
      await openExport(tester);
      expect(find.text('「$dayName」· 已选 1 张'), findsOneWidget);
      await requestCleanup(tester, 'deleteAlbum');
      expect(find.text('导出所选 1 张；从「$dayName」删除 2 张。'), findsOneWidget);
      expect(find.text('其中 1 张未选择导出，也会被删除。'), findsOneWidget);
      await confirmExport(tester);
      expectOneExport(selected);
      expect(liveIds(), {outside.id});
      expect(container.read(albumsProvider).exists(dayAlbum), isFalse);
      expect(
        container.read(albumsProvider).contains(otherAlbum, outside.id),
        isTrue,
      );
      expect(
        await tester.runAsync(() => stores.gallery.readImage(unselected.id)),
        isNull,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'quick All export clears unselected originals but retains containers',
    (tester) async {
      late String album;
      late ResultImage selected;
      late ResultImage unselected;
      await tester.runAsync(() async {
        album = await container.read(albumsProvider.notifier).create('空图库也保留');
        selected = await addImage(seed: 3301, albumId: album);
        unselected = await addImage(seed: 3302);
      });
      await mount(tester);
      await hold(tester, selected);
      await openExport(tester);
      expect(find.text('「全部作品」· 已选 1 张'), findsOneWidget);
      expect(find.text('清空全部作品'), findsOneWidget);
      await requestCleanup(tester, 'deleteAlbum');
      expect(find.text('导出所选 1 张；从「全部作品」删除 2 张。'), findsOneWidget);
      await confirmExport(tester);
      expectOneExport(selected);
      expect(liveIds(), isEmpty);
      expect(container.read(albumsProvider).exists(null), isTrue);
      expect(container.read(albumsProvider).exists(album), isTrue);
      expect(container.read(albumsProvider).memberships, isEmpty);
      expect(
        await tester.runAsync(() => stores.gallery.readImage(unselected.id)),
        isNull,
      );
      await finish(tester);
    },
  );
}
