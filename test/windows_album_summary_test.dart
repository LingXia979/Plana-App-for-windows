import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late String source, target, other, first, newest;
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

  ProviderContainer openContainer(AppStores storage) => ProviderContainer(
    overrides: [
      appStoresProvider.overrideWithValue(storage),
      desktopModeProvider.overrideWithValue(true),
    ],
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('plana_album_cache_');
    stores = await AppStores.open(rootOverride: root);
    container = openContainer(stores);
    final albums = container.read(albumsProvider.notifier);
    source = await albums.create('来源');
    target = await albums.create('目标');
    other = await albums.create('其他');
    final gallery = container.read(galleryProvider.notifier);
    first = gallery.addResult(bytes: png, width: 8, height: 8, seed: 1).id;
    newest = gallery.addResult(bytes: png, width: 8, height: 8, seed: 2).id;
    await stores.gallery.idle;
    await albums.organize({first, newest}, {source});
  });

  tearDown(() async {
    await stores.flushForExit();
    container.dispose();
    final resolved = root.absolute.path;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      root.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('plana_album_cache_'),
    );
    if (await root.exists()) await Directory(resolved).delete(recursive: true);
  });

  test(
    'selection reuses summaries; new and deleted albums refresh the cache',
    () async {
      final initial = container.read(albumSummariesProvider);
      expect(initial[null]!.count, 2);
      expect(initial[source]!.first!.id, newest);
      expect(initial[target]!.count, 0);
      container.read(galleryProvider.notifier).select(first);
      expect(container.read(albumSummariesProvider), same(initial));
      final albums = container.read(albumsProvider.notifier);
      final empty = await albums.create('新空图库');
      expect(container.read(albumSummariesProvider)[empty], (
        count: 0,
        first: null,
        cover: null,
      ));
      await albums.delete(empty);
      expect(
        container.read(albumSummariesProvider).containsKey(empty),
        isFalse,
      );
      // A removed library never removes the actual images from All Photos.
      await albums.delete(source);
      final after = container.read(albumSummariesProvider);
      expect(after.containsKey(source), isFalse);
      expect(after[null]!.count, 2);
      expect(
        initial[source]!.count,
        2,
        reason: 'Published summaries are snapshots',
      );
    },
  );

  test(
    'independent copies, move and both kinds of undo refresh each library',
    () async {
      final albums = container.read(albumsProvider.notifier);
      container.read(albumSummariesProvider);
      final copied = await albums.transfer(
        {newest},
        {target, other},
        copy: true,
        sourceAlbum: source,
      );
      final withCopies = container.read(albumSummariesProvider);
      expect(withCopies[null]!.count, 4);
      expect(withCopies[source]!.count, 2);
      expect(withCopies[target]!.count, 1);
      expect(withCopies[other]!.count, 1);
      expect(withCopies[target]!.first!.id, isNot(newest));
      expect(
        withCopies[target]!.first!.id,
        isNot(withCopies[other]!.first!.id),
      );
      final moved = await albums.transfer(
        {first},
        {target},
        copy: false,
        sourceAlbum: source,
      );
      expect(container.read(albumSummariesProvider)[source]!.count, 1);
      expect(container.read(albumSummariesProvider)[target]!.count, 2);
      await albums.undoTransfer(moved);
      expect(container.read(albumSummariesProvider)[source]!.count, 2);
      expect(container.read(albumSummariesProvider)[target]!.count, 1);
      await albums.undoTransfer(copied);
      final restored = container.read(albumSummariesProvider);
      expect(restored[null]!.count, 2);
      expect(restored[target], (count: 0, first: null, cover: null));
      expect(restored[other], (count: 0, first: null, cover: null));
      expect(restored[source]!.first!.id, newest);
    },
  );

  test(
    'deleting a cover source falls back; uploaded covers and copies survive',
    () async {
      final albums = container.read(albumsProvider.notifier);
      await albums.setCover(source, png, sourceImageId: newest);
      await albums.setCover(null, png, sourceImageId: newest);
      await albums.setCover(other, png);
      final uploaded = container.read(albumSummariesProvider)[other]!.cover!;
      final copied = await albums.transfer(
        {newest},
        {target},
        copy: true,
        sourceAlbum: source,
      );
      final copy = copied.copiedIds.single;
      await albums.setCover(target, png, sourceImageId: copy);
      expect(container.read(albumSummariesProvider)[source]!.cover, isNotNull);
      await container.read(galleryProvider.notifier).deleteResults([newest]);
      final after = container.read(albumSummariesProvider);
      expect(after[null]!.count, 2);
      expect(after[null]!.cover, isNull);
      expect(after[source]!.count, 1);
      expect(after[source]!.first!.id, first);
      expect(after[source]!.cover, isNull);
      expect(after[target]!.first!.id, copy);
      expect(after[target]!.cover!.sourceImageId, copy);
      expect(after[other]!.cover!.key, uploaded.key);
      expect(await stores.gallery.readImage(copy), png);
    },
  );

  test(
    'restart rebuilds summaries from disk and clear removes old cache entries',
    () async {
      final albums = container.read(albumsProvider.notifier);
      await albums.setCover(source, png, sourceImageId: newest);
      await albums.transfer(
        {newest},
        {target},
        copy: true,
        sourceAlbum: source,
      );
      final before = container.read(albumSummariesProvider);
      await stores.gallery.idle;
      await stores.gallery.flushIndex();
      await stores.albums.idle;
      final reopened = await AppStores.open(rootOverride: root);
      final reloaded = openContainer(reopened);
      try {
        final after = reloaded.read(albumSummariesProvider);
        for (final id in before.keys) {
          expect(after[id]!.count, before[id]!.count);
          expect(after[id]!.first?.id, before[id]!.first?.id);
          expect(after[id]!.cover?.key, before[id]!.cover?.key);
        }
      } finally {
        await reopened.flushForExit();
        reloaded.dispose();
      }
      await albums.clearAll();
      final cleared = container.read(albumSummariesProvider);
      expect(cleared.keys, [null]);
      expect(cleared[null]!.count, 3);
      expect(cleared[null]!.cover, isNull);
    },
  );
}
