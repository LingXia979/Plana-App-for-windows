import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_deletion.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_export.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/generate/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  late GalleryNotifier gallery;
  late AlbumsNotifier albums;
  late String source, target, other;
  late ResultImage original;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_copy_cleanup_');
    stores = await AppStores.open(rootOverride: root);
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    gallery = c.read(galleryProvider.notifier);
    albums = c.read(albumsProvider.notifier);
    source = await albums.create('来源');
    target = await albums.create('目标');
    other = await albums.create('另一个目标');
    final pixels = img.Image(width: 8, height: 12);
    img.fill(pixels, color: img.ColorRgb8(255, 0, 0));
    original = await gallery.addResultToGallery(
      bytes: Uint8List.fromList(img.encodePng(pixels)),
      width: 8,
      height: 12,
      seed: 324,
      badge: ResultBadge.upscaled,
      input: GenerateState.initial().copyWith(
        prompt: 'red flower',
        negativePrompt: 'blue',
      ),
      batchIndex: 2,
      target: GallerySaveTarget.album(source),
    );
    gallery.toggleFavorite(original.id);
    gallery.select(original.id);
  });

  tearDown(() async {
    stores.flushNow();
    await stores.gallery.flushIndex();
    await stores.gallery.idle;
    await stores.desktopOutput.idle;
    await stores.albums.idle;
    c.dispose();
    await root.delete(recursive: true);
  });

  Future<List<File>> outputs() async => stores.desktopOutput.root
      .list(recursive: true)
      .where((f) => f is File && f.path.endsWith('.png'))
      .cast<File>()
      .toList();

  test(
    'copy to two albums persists independent originals, metadata and favorites across reload',
    () async {
      // Exercise disk-backed copies, not just in-memory bytes.
      await stores.gallery.flushIndex();
      stores.gallery.initialResults = stores.gallery.initialResults
          .map((r) => r.stripped())
          .toList();
      c.invalidate(galleryProvider);
      gallery = c.read(galleryProvider.notifier);
      final copied = await albums.transfer(
        {original.id},
        {target, other},
        copy: true,
        sourceAlbum: source,
      );
      expect(copied.count, 2);
      expect(c.read(galleryProvider).results, hasLength(3));
      expect(c.read(galleryProvider).selectedId, original.id);
      expect(c.read(albumsProvider).ofImage(original.id), {source});
      for (final id in copied.copiedIds) {
        final result = c
            .read(galleryProvider)
            .results
            .singleWhere((r) => r.id == id);
        expect(result.createdAt, original.createdAt);
        expect(result.seed, original.seed);
        expect(result.batchIndex, 2);
        expect(result.badge, ResultBadge.upscaled);
        expect(result.favorite, isTrue);
        expect(await stores.gallery.readImage(id), original.bytes);
        expect((await stores.gallery.readInput(id))?.prompt, 'red flower');
        expect(c.read(albumsProvider).ofImage(id), hasLength(1));
      }
      expect(await outputs(), hasLength(3));
      gallery.toggleFavorite(copied.copiedIds.first);
      expect(
        c
            .read(galleryProvider)
            .results
            .singleWhere((r) => r.id == original.id)
            .favorite,
        isTrue,
      );
      await stores.gallery.flushIndex();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.gallery.initialResults, hasLength(3));
      expect(reopened.albums.data.ofImage(original.id), {source});
      expect(
        await reopened.gallery.readImage(copied.copiedIds.last),
        original.bytes,
      );
      reopened.flushNow();
      await reopened.gallery.idle;
    },
  );

  test(
    'export and delete source album preserves both physical copies and exported file',
    () async {
      final copies = await albums.transfer(
        {original.id},
        {target, other},
        copy: true,
        sourceAlbum: source,
      );
      await Directory('${root.path}/user-export').create();
      final plan = await prepareGalleryExport(
        selected: [original],
        albumImages: [original],
        albumId: source,
        albumName: '来源',
        store: stores.gallery,
        options: GalleryExportOptions(
          directory: '${root.path}/user-export',
          cleanup: GalleryExportCleanup.deleteAlbum,
        ),
      );
      final report = await exportGalleryImages(
        plan,
        store: stores.gallery,
        settings: const SaveSettings(),
      );
      expect(report.failedIds, isEmpty, reason: report.errors.toString());
      expect(await gallery.deleteResultsVerified(report.cleanupIds.toList()), {
        original.id,
      });
      await albums.delete(source);
      expect(
        c.read(galleryProvider).results.map((r) => r.id).toSet(),
        copies.copiedIds,
      );
      for (final id in copies.copiedIds) {
        expect(await stores.gallery.readImage(id), original.bytes);
        expect(await stores.gallery.readInput(id), isNotNull);
      }
      expect(await outputs(), hasLength(2));
      expect(await File(report.savedPaths[original.id]!).exists(), isTrue);
      // Deleting one copy must not remove the other copy either.
      await gallery.deleteResults([copies.copiedIds.first]);
      expect(c.read(galleryProvider).results.single.id, copies.copiedIds.last);
      expect(await outputs(), hasLength(1));
    },
  );

  test(
    'right-click album deletion removes only that album and its own output pair',
    () async {
      final copies = await albums.transfer(
        {original.id},
        {target},
        copy: true,
        sourceAlbum: source,
      );
      final plan = AlbumDeletionPlan.capture(
        albumId: source,
        albums: c.read(albumsProvider),
        images: c.read(galleryProvider).results,
      );
      final result = await deleteGalleryAlbum(c, plan);
      expect(result.albumDeleted, isTrue);
      expect(
        c.read(galleryProvider).results.single.id,
        copies.copiedIds.single,
      );
      expect(await outputs(), hasLength(1));
    },
  );

  test(
    'locked managed output keeps gallery record and metadata, retry cleans both files',
    () async {
      final png = (await outputs()).single;
      final bytes = await png.readAsBytes();
      await png.delete();
      await Directory(png.path).create(); // Portable locked-file surrogate.
      expect(await gallery.deleteResultsVerified([original.id]), isEmpty);
      expect(c.read(galleryProvider).results.single.id, original.id);
      expect(await stores.gallery.readImage(original.id), bytes);
      expect(await File(png.path.replaceAll('.png', '.json')).exists(), isTrue);
      await Directory(png.path).delete();
      await png.writeAsBytes(bytes);
      expect(await gallery.deleteResultsVerified([original.id]), {original.id});
      expect(await png.exists(), isFalse);
      expect(
        await File(png.path.replaceAll('.png', '.json')).exists(),
        isFalse,
      );
      expect(c.read(galleryProvider).results, isEmpty);
      await expectLater(
        stores.desktopOutput.save(original, albumId: source),
        throwsStateError,
      );
    },
  );

  test(
    'copy failure rolls back new files and records, keeps source and selected image',
    () async {
      final targetFolder = stores.desktopOutput.folderFor(
        target,
        DateTime.now(),
      );
      await targetFolder.parent.create(recursive: true);
      await File(targetFolder.path).writeAsString('block directory');
      await expectLater(
        albums.transfer(
          {original.id},
          {other, target},
          copy: true,
          sourceAlbum: source,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(c.read(galleryProvider).results.single.id, original.id);
      expect(c.read(galleryProvider).selectedId, original.id);
      expect(await stores.gallery.readImage(original.id), original.bytes);
      expect(await outputs(), hasLength(1));
      expect(c.read(albumsProvider).ofImage(original.id), {source});
    },
  );

  test(
    'legacy matching source signature does not trust a replaced thumbnail',
    () async {
      final diskOriginal = stores.gallery.imageFileForPreview(original.id);
      final sourceStat = await diskOriginal.stat();
      final thumbnail = File('${root.path}/gallery/thumbs/${original.id}.png');
      final signature = File('${root.path}/gallery/thumbs/${original.id}.json');
      final blue = img.Image(width: 256, height: 256);
      img.fill(blue, color: img.ColorRgb8(0, 0, 255));
      // Reproduce the persisted cache from the reported bug: the original's
      // signature still matches, but the thumbnail shows a different image.
      await signature.writeAsString(
        jsonEncode({
          'v': 1,
          'size': sourceStat.size,
          'modified': sourceStat.modified.microsecondsSinceEpoch,
        }),
      );
      await thumbnail.writeAsBytes(img.encodePng(blue));
      final repaired = img.decodePng(
        (await stores.gallery.readThumb(original.id))!,
      )!;
      expect(repaired.getPixel(100, 100).r, 255);
      expect(repaired.getPixel(100, 100).b, 0);
      expect(await diskOriginal.readAsBytes(), original.bytes);
      expect((await diskOriginal.stat()).modified, sourceStat.modified);
      expect(c.read(galleryProvider).selectedId, original.id);
    },
  );

  test(
    'cached thumbnail replacement is repaired with its signature and timestamps intact',
    () async {
      final thumbnail = File('${root.path}/gallery/thumbs/${original.id}.png');
      final signature = File('${root.path}/gallery/thumbs/${original.id}.json');
      final originalSignature = await signature.readAsBytes();
      final thumbnailStat = await thumbnail.stat();
      final blue = img.Image(width: 256, height: 256);
      img.fill(blue, color: img.ColorRgb8(0, 0, 255));
      await thumbnail.writeAsBytes(img.encodePng(blue));
      await thumbnail.setLastModified(thumbnailStat.modified);
      expect(await signature.readAsBytes(), originalSignature);
      final repaired = (await stores.gallery.readThumb(original.id))!;
      final pixels = img.decodePng(repaired)!;
      expect(pixels.getPixel(100, 100).r, 255);
      expect(pixels.getPixel(100, 100).b, 0);
      expect(await thumbnail.readAsBytes(), repaired);
      final repairedStat = await thumbnail.stat();
      expect(await stores.gallery.readThumb(original.id), repaired);
      // A subsequent read reuses the verified cache instead of rebuilding it.
      expect((await thumbnail.stat()).modified, repairedStat.modified);
      expect(await stores.gallery.readImage(original.id), original.bytes);
    },
  );

  test(
    'truncated cached thumbnail rebuilds without changing the original',
    () async {
      final thumbnail = File('${root.path}/gallery/thumbs/${original.id}.png');
      await thumbnail.writeAsBytes([137, 80, 78, 71]);
      final repaired = img.decodePng(
        (await stores.gallery.readThumb(original.id))!,
      )!;
      expect(repaired.getPixel(100, 100).r, 255);
      expect(await stores.gallery.readImage(original.id), original.bytes);
    },
  );

  test(
    'legacy wrong thumbnail rebuilds from original, and original replacement invalidates it',
    () async {
      final thumbnail = File('${root.path}/gallery/thumbs/${original.id}.png');
      final signature = File('${root.path}/gallery/thumbs/${original.id}.json');
      final blue = img.Image(width: 8, height: 12);
      img.fill(blue, color: img.ColorRgb8(0, 0, 255));
      final blueBytes = img.encodePng(blue);
      await thumbnail.writeAsBytes(blueBytes);
      await signature.delete();
      final repaired = img.decodePng(
        (await stores.gallery.readThumb(original.id))!,
      )!;
      expect(repaired.getPixel(100, 100).r, 255);
      expect(repaired.getPixel(100, 100).b, 0);
      expect(await signature.exists(), isTrue);
      final diskOriginal = stores.gallery.imageFileForPreview(original.id);
      await diskOriginal.writeAsBytes(blueBytes);
      await diskOriginal.setLastModified(DateTime(2030));
      final refreshed = img.decodePng(
        (await stores.gallery.readThumb(original.id))!,
      )!;
      expect(refreshed.getPixel(100, 100).b, 255);
      await diskOriginal.delete();
      expect(await stores.gallery.readThumb(original.id), isNull);
    },
  );
}
