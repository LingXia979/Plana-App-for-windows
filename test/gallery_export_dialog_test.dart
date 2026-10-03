import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/desktop_image_save.dart';
import 'package:plana_app/features/gallery/gallery_export.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_export_dialog.dart';
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

const _cleanupKeys = [
  'gallery-export-cleanup-selected',
  'gallery-export-cleanup-keepSamples',
  'gallery-export-cleanup-deleteAlbum',
];

Iterable<({String text, Color? color})> _textRuns(
  InlineSpan span, [
  Color? inherited,
]) sync* {
  if (span is! TextSpan) return;
  final color = span.style?.color ?? inherited;
  if (span.text case final String text) yield (text: text, color: color);
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _textRuns(child, color);
  }
}

bool _red(Color? color) {
  if (color == null) return false;
  final value = color.toARGB32();
  final red = (value >> 16) & 0xff;
  final green = (value >> 8) & 0xff;
  final blue = value & 0xff;
  return red > green && red > blue;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Directory output;
  late _DirectoryPicker picker;
  GalleryExportReport? report;
  var completed = false;
  var disposed = false;

  Finder key(String value) => find.byKey(ValueKey(value));
  Set<String> liveIds() => {
    for (final image in container.read(galleryProvider).results) image.id,
  };

  setUp(() {
    stores = AppStores.ephemeral();
    output = Directory.systemTemp.createTempSync('plana_export_dialog_');
    picker = _DirectoryPicker()..directory = output.path;
    FilePicker.platform = picker;
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    completed = false;
    disposed = false;
    report = null;
  });

  tearDown(() {
    stores.flushNow();
    if (!disposed) container.dispose();
    if (output.existsSync()) output.deleteSync(recursive: true);
  });

  // Every image is persisted through the real GalleryNotifier. Nothing in the
  // dialog, export service, gallery state, or album state is substituted.
  Future<ResultImage> addImage({
    required int seed,
    String? albumId,
    bool withParameters = false,
  }) async {
    var bytes = Uint8List.fromList(
      img.encodePng(
        img.fill(
          img.Image(width: 64, height: 96),
          color: img.ColorRgb8(seed % 255, 60, 160),
        ),
      ),
    );
    GenerateState? input;
    if (withParameters) {
      input = GenerateState.initial().copyWith(
        prompt: 'cat, outdoors',
        negativePrompt: 'lowres',
        params: GenParams(width: 64, height: 96, seed: '$seed'),
      );
      bytes = await writeImageMetadataPng(
        bytes,
        comment: {
          'prompt': 'cat, outdoors',
          'uc': 'lowres',
          'steps': 28,
          'scale': 5.0,
          'sampler': 'k_euler_ancestral',
          'seed': seed,
          'width': 64,
          'height': 96,
        },
      );
    }
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
    // Preparing remains busy behind the nested confirmation dialog, whose
    // translucent route does not necessarily stop the underlying progress
    // ticker. Advance its route animation without waiting for all tickers.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  Future<void> mount(
    WidgetTester tester, {
    required List<ResultImage> selected,
    required String? albumId,
    String albumName = '猫猫图库',
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                key: const ValueKey('open-export'),
                onPressed: () async {
                  report = await showGalleryExportDialog(
                    context,
                    selected: selected,
                    albumId: albumId,
                    albumName: albumName,
                  );
                  completed = true;
                },
                child: const Text('导出'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(key('open-export'));
    await tester.pumpAndSettle();
    expect(key('gallery-export-dialog'), findsOneWidget);
  }

  Future<void> browse(WidgetTester tester) async {
    await tester.tap(key('gallery-export-browse'));
    await tester.pumpAndSettle();
    if (picker.directory != null) {
      expect(
        tester
            .widget<TextField>(key('gallery-export-directory'))
            .controller!
            .text,
        picker.directory,
      );
    }
  }

  Future<void> requestCleanup(WidgetTester tester, String cleanupKey) async {
    await tester.ensureVisible(key(cleanupKey));
    await tester.tap(key(cleanupKey));
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('gallery-export-submit'));
    await tester.tap(key('gallery-export-submit'));
    await until(
      tester,
      () => key('gallery-export-confirm-dialog').evaluate().isNotEmpty,
      'cleanup must require a second confirmation',
    );
  }

  void expectRedConfirmation(WidgetTester tester) {
    final question = tester
        .widgetList<RichText>(
          find.descendant(
            of: key('gallery-export-confirm-dialog'),
            matching: find.byType(RichText),
          ),
        )
        .singleWhere(
          (widget) => widget.text.toPlainText().contains('你确认导出图片并执行'),
        );
    final match = RegExp(
      '你确认导出图片并执行“([^”]+)”操作？',
    ).firstMatch(question.text.toPlainText());
    expect(match, isNotNull);
    final redText = _textRuns(
      question.text,
    ).where((run) => _red(run.color)).map((run) => run.text).join();
    expect(redText, contains(match!.group(1)!));
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(key('gallery-export-confirm'));
    await until(tester, () => completed, 'export should return a report');
    expect(report, isNotNull);
    expect(key('gallery-export-dialog'), findsNothing);
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
    await until(tester, () => idle, 'test gallery writes should finish');
    container.dispose();
    disposed = true;
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('canceling the directory picker and dialog writes no exports', (
    tester,
  ) async {
    final image = (await tester.runAsync(() => addImage(seed: 11)))!;
    picker.directory = null;
    await mount(tester, selected: [image], albumId: null);
    expect(
      tester
          .widget<CheckboxListTile>(key('gallery-export-create-folder'))
          .value,
      isFalse,
    );
    for (final cleanup in _cleanupKeys) {
      expect(tester.widget<FilterChip>(key(cleanup)).selected, isFalse);
    }
    await browse(tester);
    expect(picker.calls, 1);
    expect(container.read(desktopSaveDirectoryProvider), isNull);
    expect(key('gallery-export-confirm-dialog'), findsNothing);
    expect(output.listSync(), isEmpty);
    expect(liveIds(), {image.id});
    await tester.tap(key('gallery-export-cancel'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(report, isNull);
    expect(output.listSync(), isEmpty);
    expect(
      await tester.runAsync(() => stores.gallery.readImage(image.id)),
      image.bytes,
    );
    await finish(tester);
  });

  testWidgets(
    'default export writes only selected originals without confirmation',
    (tester) async {
      late ResultImage selected;
      late ResultImage unselected;
      await tester.runAsync(() async {
        selected = await addImage(seed: 21);
        unselected = await addImage(seed: 22);
      });
      await mount(tester, selected: [selected], albumId: null);
      await browse(tester);
      await tester.tap(key('gallery-export-submit'));
      await tester.pump();
      expect(key('gallery-export-confirm-dialog'), findsNothing);
      await until(
        tester,
        () => completed,
        'default export should complete directly',
      );
      expect(report!.savedIds, {selected.id});
      expect(report!.failedIds, isEmpty);
      expect(report!.cleanupIds, isEmpty);
      expect(liveIds(), {selected.id, unselected.id});
      expect(output.listSync().whereType<Directory>(), isEmpty);
      final files = output.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(
        files.single.path,
        endsWith('plana_${selected.id}_${selected.seed}.png'),
      );
      expect(files.single.readAsBytesSync(), selected.bytes);
      await finish(tester);
    },
  );

  testWidgets(
    'cleanup choices are optional and mutually exclusive; canceling red confirmation is inert',
    (tester) async {
      late String albumId;
      late ResultImage image;
      await tester.runAsync(() async {
        albumId = await container.read(albumsProvider.notifier).create('猫猫图库');
        image = await addImage(seed: 31, albumId: albumId);
      });
      await mount(tester, selected: [image], albumId: albumId);
      await browse(tester);
      for (final cleanup in _cleanupKeys) {
        await tester.tap(key(cleanup));
        await tester.pumpAndSettle();
        for (final other in _cleanupKeys) {
          expect(
            tester.widget<FilterChip>(key(other)).selected,
            other == cleanup,
          );
        }
      }
      await tester.tap(key(_cleanupKeys.last));
      await tester.pumpAndSettle();
      for (final cleanup in _cleanupKeys) {
        expect(tester.widget<FilterChip>(key(cleanup)).selected, isFalse);
      }
      for (final cleanup in _cleanupKeys) {
        await requestCleanup(tester, cleanup);
        expectRedConfirmation(tester);
        expect(output.listSync(), isEmpty);
        expect(liveIds(), {image.id});
        await tester.tap(
          find.descendant(
            of: key('gallery-export-confirm-dialog'),
            matching: find.text('取消'),
          ),
        );
        await tester.pumpAndSettle();
        expect(key('gallery-export-confirm-dialog'), findsNothing);
        expect(key('gallery-export-dialog'), findsOneWidget);
        expect(completed, isFalse);
        expect(liveIds(), {image.id});
        expect(container.read(albumsProvider).exists(albumId), isTrue);
        expect(output.listSync(), isEmpty);
        // The prior choice remains selected until the next choice is pressed.
      }
      await tester.tap(key('gallery-export-cancel'));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets(
    'selected cleanup removes only successfully exported selections',
    (tester) async {
      late ResultImage selected;
      late ResultImage unselected;
      await tester.runAsync(() async {
        selected = await addImage(seed: 41);
        unselected = await addImage(seed: 42);
      });
      await mount(tester, selected: [selected], albumId: null);
      await browse(tester);
      await requestCleanup(tester, _cleanupKeys.first);
      expect(liveIds(), {selected.id, unselected.id});
      await confirm(tester);
      expect(report!.savedIds, {selected.id});
      expect(report!.failedIds, isEmpty);
      expect(report!.cleanupIds, {selected.id});
      expect(liveIds(), {unselected.id});
      expect(
        output.listSync().whereType<File>().single.readAsBytesSync(),
        selected.bytes,
      );
      await tester.runAsync(() async {
        await stores.gallery.idle;
        expect(await stores.gallery.readImage(selected.id), isNull);
        expect(await stores.gallery.readImage(unselected.id), unselected.bytes);
      });
      await finish(tester);
    },
  );

  testWidgets('an export write failure never deletes the selected originals', (
    tester,
  ) async {
    final image = (await tester.runAsync(() => addImage(seed: 51)))!;
    await mount(tester, selected: [image], albumId: null);
    await browse(tester);
    await requestCleanup(tester, _cleanupKeys.first);
    // Simulate the selected removable directory disappearing after confirmation
    // was prepared. Only this test's empty temporary directory is removed.
    await tester.runAsync(() => output.delete());
    await confirm(tester);
    expect(report!.savedIds, isEmpty);
    expect(report!.failedIds, {image.id});
    expect(report!.cleanupIds, isEmpty);
    expect(liveIds(), {image.id});
    expect(
      await tester.runAsync(() => stores.gallery.readImage(image.id)),
      image.bytes,
    );
    await finish(tester);
  });

  testWidgets(
    'deleting a library exports one selection then cleans its entire scope',
    (tester) async {
      late String albumId;
      late String otherAlbum;
      late ResultImage selected;
      late ResultImage unselected;
      late ResultImage other;
      await tester.runAsync(() async {
        final albums = container.read(albumsProvider.notifier);
        albumId = await albums.create('猫猫图库');
        otherAlbum = await albums.create('其它图库');
        selected = await addImage(seed: 61, albumId: albumId);
        unselected = await addImage(seed: 62, albumId: albumId);
        other = await addImage(seed: 63, albumId: otherAlbum);
      });
      await mount(tester, selected: [selected], albumId: albumId);
      await browse(tester);
      await requestCleanup(tester, _cleanupKeys.last);
      expectRedConfirmation(tester);
      await confirm(tester);
      expect(report!.savedIds, {selected.id});
      expect(report!.cleanupIds, {selected.id, unselected.id});
      expect(report!.failedIds, isEmpty);
      expect(liveIds(), {other.id});
      expect(container.read(albumsProvider).exists(albumId), isFalse);
      expect(container.read(albumsProvider).exists(otherAlbum), isTrue);
      expect(
        container.read(albumsProvider).contains(otherAlbum, other.id),
        isTrue,
      );
      final exports = output.listSync().whereType<File>().toList();
      expect(exports, hasLength(1));
      expect(exports.single.readAsBytesSync(), selected.bytes);
      await tester.runAsync(() async {
        await stores.gallery.idle;
        await stores.albums.idle;
        expect(await stores.gallery.readImage(selected.id), isNull);
        expect(await stores.gallery.readImage(unselected.id), isNull);
        expect(await stores.gallery.readImage(other.id), other.bytes);
      });
      await finish(tester);
    },
  );

  testWidgets(
    'a failed original deletion retains its snapshot, membership, and library',
    (tester) async {
      late String albumId;
      late ResultImage selected;
      late ResultImage unselected;
      late ResultImage blocked;
      late Directory blockedPath;
      late File sentinel;
      Map<String, dynamic>? snapshotBefore;
      Uint8List? thumbnailBefore;
      await tester.runAsync(() async {
        albumId = await container.read(albumsProvider.notifier).create('猫猫图库');
        selected = await addImage(seed: 101, albumId: albumId);
        unselected = await addImage(seed: 102, albumId: albumId);
        blocked = await addImage(
          seed: 103,
          albumId: albumId,
          withParameters: true,
        );
        snapshotBefore = await stores.gallery.readInputRaw(blocked.id);
        thumbnailBefore = await stores.gallery.readThumb(blocked.id);
        expect(snapshotBefore, isNotNull);
        expect(thumbnailBefore, isNotNull);
        // The gallery belongs to AppStores.ephemeral. Replace only this
        // fixture's PNG with a nonempty directory so deleting it as a file
        // fails consistently without touching any user library or permissions.
        final original = stores.gallery.imageFileForPreview(blocked.id);
        await original.delete();
        blockedPath = await Directory(original.path).create();
        sentinel = await File('${blockedPath.path}/keep.txt').writeAsString(
          'This fixture directory must not be recursively deleted.',
        );
      });
      await mount(tester, selected: [selected], albumId: albumId);
      await browse(tester);
      await requestCleanup(tester, _cleanupKeys.last);
      await confirm(tester);
      expect(report!.savedIds, {selected.id});
      expect(
        report!.failedIds,
        isEmpty,
        reason: 'the selected export succeeded',
      );
      expect(liveIds(), {blocked.id});
      final albums = container.read(albumsProvider);
      expect(albums.exists(albumId), isTrue);
      expect(albums.contains(albumId, blocked.id), isTrue);
      expect(albums.contains(albumId, selected.id), isFalse);
      expect(albums.contains(albumId, unselected.id), isFalse);
      expect(find.textContaining('未能删除'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'1\s*张.*未能删除|未能删除.*1\s*张')),
        findsOneWidget,
      );
      final exports = output.listSync().whereType<File>().toList();
      expect(exports, hasLength(1));
      expect(exports.single.readAsBytesSync(), selected.bytes);
      await tester.runAsync(() async {
        await stores.gallery.idle;
        await stores.albums.idle;
        expect(await stores.gallery.readImage(selected.id), isNull);
        expect(await stores.gallery.readImage(unselected.id), isNull);
        expect(await blockedPath.exists(), isTrue);
        expect(await sentinel.exists(), isTrue);
        expect(await stores.gallery.readInputRaw(blocked.id), snapshotBefore);
        // Original is deliberately a directory in this failure fixture. Check
        // retained cache bytes directly; an unverifiable preview is not shown.
        final thumbnail = File(
          '${blockedPath.parent.parent.path}/thumbs/${blocked.id}.png',
        );
        expect(await thumbnail.readAsBytes(), thumbnailBefore);
      });
      await finish(tester);
    },
  );

  testWidgets(
    'keep samples uses the whole library, ignores seed, and retains every unknown input',
    (tester) async {
      late String albumId;
      late String otherAlbum;
      late ResultImage old;
      late ResultImage unselectedOld;
      late ResultImage newest;
      late ResultImage unknownA;
      late ResultImage unknownB;
      late ResultImage other;
      await tester.runAsync(() async {
        final albums = container.read(albumsProvider.notifier);
        albumId = await albums.create('猫猫图库');
        otherAlbum = await albums.create('其它图库');
        old = await addImage(seed: 71, albumId: albumId, withParameters: true);
        unselectedOld = await addImage(
          seed: 72,
          albumId: albumId,
          withParameters: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));
        newest = await addImage(
          seed: 73,
          albumId: albumId,
          withParameters: true,
        );
        unknownA = await addImage(seed: 74, albumId: albumId);
        unknownB = await addImage(seed: 75, albumId: albumId);
        other = await addImage(
          seed: 76,
          albumId: otherAlbum,
          withParameters: true,
        );
      });
      expect(newest.createdAt, greaterThan(old.createdAt));
      await mount(tester, selected: [old], albumId: albumId);
      await browse(tester);
      await requestCleanup(tester, _cleanupKeys[1]);
      expectRedConfirmation(tester);
      await confirm(tester);
      expect(report!.savedIds, {old.id});
      expect(report!.cleanupIds, {old.id, unselectedOld.id});
      expect(liveIds(), {newest.id, unknownA.id, unknownB.id, other.id});
      expect(container.read(albumsProvider).exists(albumId), isTrue);
      expect(
        container.read(albumsProvider).contains(albumId, newest.id),
        isTrue,
      );
      expect(output.listSync().whereType<File>(), hasLength(1));
      await finish(tester);
    },
  );

  for (final (cleanupKey, remaining) in [
    (_cleanupKeys[0], 2),
    (_cleanupKeys[1], 1),
    (_cleanupKeys[2], 0),
  ]) {
    testWidgets(
      'all works $cleanupKey cleans images and preserves every library container',
      (tester) async {
        late String namedAlbum;
        late ResultImage selected;
        late ResultImage newest;
        await tester.runAsync(() async {
          namedAlbum = await container
              .read(albumsProvider.notifier)
              .create('保留图库');
          selected = await addImage(
            seed: 81,
            albumId: namedAlbum,
            withParameters: true,
          );
          await addImage(seed: 82, albumId: namedAlbum, withParameters: true);
          newest = await addImage(
            seed: 83,
            albumId: namedAlbum,
            withParameters: true,
          );
        });
        await mount(
          tester,
          selected: [selected],
          albumId: null,
          albumName: '全部作品',
        );
        expect(
          tester.widget<FilterChip>(key(_cleanupKeys.last)).onSelected,
          isNotNull,
        );
        expect(find.text('清空全部作品'), findsOneWidget);
        expect(find.textContaining('基础图库，始终保留'), findsOneWidget);
        await browse(tester);
        await requestCleanup(tester, cleanupKey);
        expectRedConfirmation(tester);
        if (cleanupKey == _cleanupKeys.last) {
          expect(find.text('其中 2 张未选择导出，也会被删除。'), findsOneWidget);
        }
        await confirm(tester);
        expect(report!.savedIds, {selected.id});
        expect(liveIds(), hasLength(remaining));
        if (remaining > 0) expect(liveIds(), contains(newest.id));
        final albums = container.read(albumsProvider);
        expect(albums.exists(null), isTrue);
        expect(albums.exists(namedAlbum), isTrue);
        expect(albums.albums, hasLength(1));
        expect(output.listSync().whereType<File>(), hasLength(1));
        await finish(tester);
      },
    );
  }

  testWidgets(
    'cleanup choices share a wide row and wrap without overflow on narrow windows',
    (tester) async {
      late String albumId;
      late ResultImage image;
      await tester.runAsync(() async {
        albumId = await container.read(albumsProvider.notifier).create('猫猫图库');
        image = await addImage(seed: 91, albumId: albumId);
      });
      await mount(tester, selected: [image], albumId: albumId);
      final wide = [
        for (final cleanup in _cleanupKeys) tester.getRect(key(cleanup)),
      ];
      expect(wide[0].top, closeTo(wide[1].top, 1));
      expect(wide[1].top, closeTo(wide[2].top, 1));
      expect(wide[0].right, lessThanOrEqualTo(wide[1].left));
      expect(wide[1].right, lessThanOrEqualTo(wide[2].left));
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(430, 900);
      await tester.pumpAndSettle();
      final narrow = [
        for (final cleanup in _cleanupKeys) tester.getRect(key(cleanup)),
      ];
      expect(narrow.last.top, greaterThan(narrow.first.top));
      for (final rect in narrow) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(430));
      }
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('gallery-export-create-folder'));
      await tester.tap(key('gallery-export-create-folder'));
      await tester.pumpAndSettle();
      expect(key('gallery-export-folder-date'), findsOneWidget);
      expect(key('gallery-export-folder-album'), findsOneWidget);
      await tester.tap(key('gallery-export-folder-album'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChoiceChip>(key('gallery-export-folder-album')).selected,
        isTrue,
      );
      expect(
        tester.widget<ChoiceChip>(key('gallery-export-folder-date')).selected,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('gallery-export-cancel'));
      await tester.tap(key('gallery-export-cancel'));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );
}
