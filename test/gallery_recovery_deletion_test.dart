import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';

class _Search extends GallerySearchNotifier {
  @override
  GallerySearchState build() => const GallerySearchState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_delete_recovery_');
    stores = await AppStores.open(rootOverride: root);
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        gallerySearchProvider.overrideWith(_Search.new),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await stores.flushForExit();
    await root.delete(recursive: true);
  });

  test(
    'deleted image and auxiliary recovery files stay deleted after restart',
    () async {
      final gallery = container.read(galleryProvider.notifier);
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final image = await gallery.addResultToGallery(
        bytes: bytes,
        width: 256,
        height: 256,
        seed: 42,
        target: const GallerySaveTarget.all(),
      );
      final paths = [
        '${root.path}/gallery/images/${image.id}.png',
        '${root.path}/gallery/thumbs/${image.id}.png',
        '${root.path}/gallery/thumbs/${image.id}.json',
        '${root.path}/gallery/inputs/${image.id}.json',
      ];
      for (final path in paths) {
        await File(
          '$path.tmp',
        ).writeAsBytes(path.endsWith('.png') ? bytes : [123, 125]);
        await File('$path.pending').writeAsString('{}');
        await File(
          '$path.bak',
        ).writeAsBytes(path.endsWith('.png') ? bytes : [123, 125]);
      }
      expect(await gallery.deleteResults([image.id]), {image.id});
      await stores.flushForExit();
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.gallery.initialResults, isEmpty);
      expect(await reopened.gallery.readImage(image.id), isNull);
      for (final path in paths) {
        for (final suffix in ['', '.tmp', '.pending', '.bak']) {
          expect(await File('$path$suffix').exists(), isFalse);
        }
      }
      await reopened.flushForExit();
    },
  );

  test(
    'failed recovery cleanup preserves the original and record for retry',
    () async {
      final gallery = container.read(galleryProvider.notifier);
      final image = await gallery.addResultToGallery(
        bytes: await File('assets/app_icon.png').readAsBytes(),
        width: 256,
        height: 256,
        seed: 42,
        target: const GallerySaveTarget.all(),
      );
      final original = File('${root.path}/gallery/images/${image.id}.png');
      final blocked = await Directory('${original.path}.tmp').create();
      expect(await gallery.deleteResults([image.id]), isEmpty);
      expect(await original.exists(), isTrue);
      expect(container.read(galleryProvider).results.single.id, image.id);
      await blocked.delete();
      expect(await gallery.deleteResults([image.id]), {image.id});
    },
  );
}
