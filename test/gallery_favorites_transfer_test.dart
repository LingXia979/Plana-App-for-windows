import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late String a, b, c, image;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('plana_favorite_transfer_');
    stores = await AppStores.open(rootOverride: root);
    container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    final albums = container.read(albumsProvider.notifier);
    a = await albums.create('来源');
    b = await albums.create('目标');
    c = await albums.create('其他');
    image = container
        .read(galleryProvider.notifier)
        .addResult(
          bytes: Uint8List.fromList(
            File('assets/app_icon.png').readAsBytesSync(),
          ),
          width: 512,
          height: 512,
          seed: 13,
        )
        .id;
    await stores.gallery.idle;
    await albums.organize({image}, {a});
  });

  tearDown(() async {
    stores.flushNow();
    await stores.gallery.flushIndex();
    await stores.gallery.idle;
    await stores.albums.idle;
    container.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'favorite survives reload, stripping and inpaint cleanup; old images default off',
    () async {
      final gallery = container.read(galleryProvider.notifier);
      expect(container.read(galleryProvider).results.single.favorite, isFalse);
      final selected = container.read(galleryProvider).selectedId;
      gallery.toggleFavorite(image);
      final result = container.read(galleryProvider).results.single;
      expect(result.favorite, isTrue);
      expect(result.stripped().favorite, isTrue);
      expect(result.withCreatedAt(100).favorite, isTrue);
      expect(result.withoutInpaintHistory().favorite, isTrue);
      expect(container.read(galleryProvider).selectedId, selected);
      await stores.gallery.flushIndex();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.gallery.initialResults.single.favorite, isTrue);
      gallery.toggleFavorite(image);
      gallery.toggleFavorite('missing');
      await stores.gallery.flushIndex();
      final again = await AppStores.open(rootOverride: root);
      expect(again.gallery.initialResults.single.favorite, isFalse);
    },
  );

  test(
    'copy creates independent IDs in each destination and undo deletes only those copies',
    () async {
      final albums = container.read(albumsProvider.notifier);
      final before = await stores.gallery.readImage(image);
      container.read(galleryProvider.notifier).toggleFavorite(image);
      final copied = await albums.transfer(
        {image},
        {b, c},
        copy: true,
        sourceAlbum: a,
      );
      expect(copied.count, 2);
      expect(container.read(albumsProvider).ofImage(image), {a});
      expect(container.read(galleryProvider).results, hasLength(3));
      expect(
        container.read(galleryProvider).results.every((r) => r.favorite),
        isTrue,
      );
      for (final id in copied.copiedIds) {
        expect(id, isNot(image));
        expect(await stores.gallery.readImage(id), before);
      }
      expect(await stores.gallery.readImage(image), before);
      final repeated = await albums.transfer(
        {image},
        {b},
        copy: true,
        sourceAlbum: a,
      );
      expect(repeated.count, 1);
      await albums.organize({image}, {c});
      await albums.undoTransfer(copied);
      expect(container.read(albumsProvider).ofImage(image), {a, c});
      expect(container.read(galleryProvider).results.map((r) => r.id).toSet(), {
        image,
        ...repeated.copiedIds,
      });
      await stores.gallery.flushIndex();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.albums.data.ofImage(image), {a, c});
      expect(reopened.gallery.initialResults.every((r) => r.favorite), isTrue);
    },
  );

  test(
    'move from one album preserves other copies; All Photos relocates all memberships',
    () async {
      final albums = container.read(albumsProvider.notifier);
      await albums.organize(
        {image},
        {b},
      ); // Existing shared membership remains compatible.
      await albums.transfer({image}, {c}, copy: false, sourceAlbum: a);
      expect(container.read(albumsProvider).ofImage(image), {b, c});
      expect(container.read(galleryProvider).results.single.id, image);
      await albums.transfer({image}, {a}, copy: false);
      expect(container.read(albumsProvider).ofImage(image), {a});
    },
  );

  test(
    'uncategorized image can be moved; stale source or target cannot lose memberships',
    () async {
      final albums = container.read(albumsProvider.notifier);
      await albums.organize({image}, {}, sources: {a});
      await albums.transfer({image}, {b}, copy: false);
      expect(container.read(albumsProvider).ofImage(image), {b});
      expect(
        (await albums.transfer(
          {image},
          {c},
          copy: false,
          sourceAlbum: a,
        )).count,
        0,
      );
      await expectLater(
        albums.transfer({image}, {'missing'}, copy: false),
        throwsStateError,
      );
      await expectLater(
        albums.transfer({image}, {b}, sourceAlbum: b, copy: true),
        throwsStateError,
      );
      expect(container.read(albumsProvider).ofImage(image), {b});
    },
  );
}
