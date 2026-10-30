import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  late GalleryNotifier gallery;
  late String album;
  final png = Uint8List.fromList(
    img.encodePng(img.Image(width: 8, height: 12)),
  );
  Future<ResultImage> add(int seed) => gallery.addResultToGallery(
    bytes: png,
    width: 8,
    height: 12,
    seed: seed,
    input: GenerateState.initial().copyWith(prompt: 'cat $seed'),
    target: GallerySaveTarget.album(album),
  );
  Future<List<File>> outputs() => stores.desktopOutput.root
      .list(recursive: true)
      .where((f) => f is File && f.path.endsWith('.png'))
      .cast<File>()
      .toList();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_windows_trash_');
    stores = await AppStores.open(rootOverride: root);
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    gallery = c.read(galleryProvider.notifier);
    album = await c.read(albumsProvider.notifier).create('测试');
  });
  tearDown(() async {
    await stores.flushForExit();
    c.dispose();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      root.path.split(Platform.pathSeparator).last,
      startsWith('plana_windows_trash_'),
    );
    await root.delete(recursive: true);
  });

  test(
    'index failure retains images and a retry saves the newest active and trash state',
    () async {
      final a = await add(1), b = await add(2);
      await stores.flushForExit();
      final blocker = await Directory(
        '${root.path}/gallery/index.json.tmp',
      ).create();
      expect(await gallery.deleteResults([a.id]), isEmpty);
      expect(c.read(galleryProvider).trash.single.image.id, a.id);
      expect(await stores.gallery.readImage(a.id), png);
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      gallery.setFavorite(b.id, true);
      await blocker.delete();
      await stores.flushForExit();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.gallery.initialTrash.single.image.id, a.id);
      expect(reopened.gallery.initialResults.single.id, b.id);
      expect(reopened.gallery.initialResults.single.favorite, isTrue);
      expect(reopened.albums.data.ofImage(a.id), {album});
      await reopened.flushForExit();
    },
  );

  test(
    'trash keeps managed output and metadata; a locked output blocks only permanent purge',
    () async {
      final image = await add(1);
      final output = (await outputs()).single;
      final metadata = File(output.path.replaceAll('.png', '.json'));
      final outputBytes = await output.readAsBytes();
      await gallery.deleteResults([image.id]);
      expect(await output.exists(), isTrue);
      expect(await metadata.exists(), isTrue);
      expect((await stores.gallery.readInput(image.id))!.prompt, 'cat 1');
      await output.delete();
      await Directory(output.path).create();
      expect(await gallery.purgeTrash([image.id]), isEmpty);
      expect(c.read(galleryProvider).trash.single.image.id, image.id);
      expect(await stores.gallery.readImage(image.id), png);
      expect(await metadata.exists(), isTrue);
      await Directory(output.path).delete();
      await output.writeAsBytes(outputBytes);
      expect(await gallery.purgeTrash([image.id]), {image.id});
      expect(await output.exists(), isFalse);
      expect(await metadata.exists(), isFalse);
      expect(await stores.gallery.readInput(image.id), isNull);
      expect(c.read(albumsProvider).ofImage(image.id), isEmpty);
    },
  );

  test(
    'recovery sidecars cannot revive purged trash; blocked cleanup preserves original',
    () async {
      final image = await add(1);
      await gallery.deleteResults([image.id]);
      final original = File('${root.path}/gallery/images/${image.id}.png');
      await File('${original.path}.bak').writeAsBytes(png);
      final blocker = await Directory('${original.path}.tmp').create();
      expect(await gallery.purgeTrash([image.id]), isEmpty);
      expect(await original.exists(), isTrue);
      expect(c.read(galleryProvider).trash, hasLength(1));
      await blocker.delete();
      expect(await gallery.purgeTrash([image.id]), {image.id});
      await stores.flushForExit();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.gallery.initialResults, isEmpty);
      expect(reopened.gallery.initialTrash, isEmpty);
      expect(await reopened.gallery.readImage(image.id), isNull);
      expect(await File('${original.path}.bak').exists(), isFalse);
      await reopened.flushForExit();
    },
  );

  test(
    'album cover is hidden in trash and restored; read-only memberships stop purge',
    () async {
      final image = await add(1);
      final albums = c.read(albumsProvider.notifier);
      await albums.setCover(album, png, sourceImageId: image.id);
      final cover = c.read(albumSummariesProvider)[album]!.cover;
      expect(cover, isNotNull);
      await gallery.deleteResults([image.id]);
      expect(c.read(albumSummariesProvider)[album]!.cover, isNull);
      expect(c.read(albumsProvider).album(album)!.cover!.key, cover!.key);
      stores.albums.readOnly = true;
      await expectLater(gallery.purgeTrash([image.id]), throwsStateError);
      expect(await stores.gallery.readImage(image.id), png);
      stores.albums.readOnly = false;
      await gallery.restoreTrash([image.id]);
      expect(c.read(albumSummariesProvider)[album]!.cover!.key, cover.key);
    },
  );

  test('album write failure leaves a purge record for retry', () async {
    final image = await add(1);
    await gallery.deleteResults([image.id]);
    final blocker = await Directory(
      '${root.path}/gallery/albums.json.tmp',
    ).create();
    await expectLater(
      gallery.purgeTrash([image.id]),
      throwsA(isA<FileSystemException>()),
    );
    expect(c.read(galleryProvider).trash.single.image.id, image.id);
    expect(c.read(albumsProvider).ofImage(image.id), {album});
    await expectLater(gallery.restoreTrash([image.id]), throwsStateError);
    expect(c.read(galleryProvider).results, isEmpty);
    await blocker.delete();
    expect(await gallery.purgeTrash([image.id]), {image.id});
    expect(c.read(galleryProvider).trash, isEmpty);
    expect(c.read(albumsProvider).ofImage(image.id), isEmpty);
  });

  test(
    'exit waits for queued delete then restore and records the final state',
    () async {
      final image = await add(1);
      final deletion = gallery.deleteResults([image.id]);
      final restoration = gallery.restoreTrash([image.id]);
      await stores.flushForExit();
      expect(await deletion, {image.id});
      expect(await restoration, 1);
      final index =
          jsonDecode(
                await File('${root.path}/gallery/index.json').readAsString(),
              )
              as Map;
      expect((index['items'] as List).single['id'], image.id);
      expect(index['trash'], isEmpty);
    },
  );
}
