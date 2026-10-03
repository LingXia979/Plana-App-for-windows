import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/desktop_output_store.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('跨日提交使用本地新日期，手动图库保持不变', () {
    const auto = DesktopLibrarySelection(day: '2026-09-30');
    const manual = DesktopLibrarySelection(
      choice: 'my_album',
      day: '2026-09-30',
    );
    expect(
      auto.capture(DateTime(2026, 9, 30, 23, 59)).albumId,
      'day_2026-09-30',
    );
    expect(auto.capture(DateTime(2026, 10, 1)).albumId, 'day_2026-10-01');
    expect(manual.capture(DateTime(2026, 10, 1)).albumId, 'my_album');
  });

  test('首次成功保存才建日期目录，同日复用，缺失目录重建', () async {
    final root = await Directory.systemTemp.createTemp('plana_desktop_output_');
    final output = DesktopOutputStore(Directory('${root.path}/作品'));
    ResultImage result(String id) => ResultImage(
      id: id,
      width: 1,
      height: 1,
      seed: 1,
      createdAt: DateTime(2026, 9, 30, 22).millisecondsSinceEpoch,
      bytes: Uint8List.fromList([137, 80, 78, 71]),
    );
    expect(await output.root.exists(), isFalse);
    final a = await output.save(result('gen0'), albumId: 'day_2026-09-30');
    final b = await output.save(result('gen1'), albumId: 'day_2026-09-30');
    expect(a.parent.path, b.parent.path);
    expect(a.parent.path, endsWith('2026-09-30'));
    expect(await a.readAsBytes(), [137, 80, 78, 71]);
    expect(await File(a.path.replaceAll('.png', '.json')).exists(), isTrue);
    await a.parent.delete(recursive: true);
    final c = await output.save(result('gen2'), albumId: 'day_2026-09-30');
    expect(await c.exists(), isTrue);
    final next = await output.save(result('gen3'), albumId: 'day_2026-10-01');
    expect(next.parent.path, endsWith('2026-10-01'));
    await root.delete(recursive: true);
  });

  test('多个写入者不会覆盖同名图片，失败后保存队列仍可使用', () async {
    final root = await Directory.systemTemp.createTemp('plana_desktop_race_');
    final a = DesktopOutputStore(root), b = DesktopOutputStore(root);
    final image = ResultImage(
      id: 'gen1',
      width: 1,
      height: 1,
      seed: 1,
      createdAt: DateTime(2026, 9, 30).millisecondsSinceEpoch,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    await expectLater(a.save(image, albumId: '../escape'), throwsArgumentError);
    final files = await Future.wait([
      for (var i = 0; i < 8; i++) (i.isEven ? a : b).save(image),
    ]);
    expect(files.map((f) => f.path).toSet(), hasLength(8));
    for (final file in files) {
      expect(await file.readAsBytes(), [1, 2, 3]);
    }
    expect(
      await root
          .list(recursive: true)
          .where((f) => f.path.endsWith('.part'))
          .isEmpty,
      isTrue,
    );
    await root.delete(recursive: true);
  });

  test('单一图库选择驱动浏览与保存，真实入库与重启恢复', () async {
    final root = await Directory.systemTemp.createTemp(
      'plana_desktop_gallery_',
    );
    final stores = await AppStores.open(rootOverride: root);
    final c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    final today = dailyAlbumId(DateTime.now());
    expect(c.read(galleryBrowseAlbumProvider), today);
    expect(c.read(albumsProvider).exists(today), isFalse);
    expect(await stores.desktopOutput.root.exists(), isFalse);
    final target = c.read(gallerySaveTargetProvider);
    final custom = await c.read(albumsProvider.notifier).create('猫猫');
    c.read(desktopLibraryProvider.notifier).choose(custom);
    expect(c.read(galleryBrowseAlbumProvider), custom);
    expect(c.read(gallerySaveTargetProvider).albumId, custom);
    final bytes = await File('assets/app_icon.png').readAsBytes();
    final image = await c
        .read(galleryProvider.notifier)
        .addResultToGallery(
          bytes: bytes,
          width: 256,
          height: 256,
          seed: 7,
          target: target,
        );
    expect(c.read(albumsProvider).contains(today, image.id), isTrue);
    expect(c.read(albumsProvider).contains(custom, image.id), isFalse);
    expect(c.read(galleryViewProvider).results, isEmpty);
    expect(
      await stores.desktopOutput.folderFor(today, DateTime.now()).exists(),
      isTrue,
    );
    c.read(desktopLibraryProvider.notifier).choose(null, automatic: true);
    expect(c.read(galleryViewProvider).results.single.id, image.id);
    await stores.prefs.write(key: 'desktop_gallery_choice', value: custom);
    stores.flushNow();
    await stores.gallery.idle;
    await stores.albums.idle;
    c.dispose();
    final reopened = await AppStores.open(rootOverride: root);
    final again = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(reopened),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    expect(again.read(galleryBrowseAlbumProvider), custom);
    expect(again.read(gallerySaveTargetProvider).albumId, custom);
    expect(again.read(albumsProvider).contains(today, image.id), isTrue);
    expect(await reopened.gallery.readImage(image.id), bytes);
    again.dispose();
    await root.delete(recursive: true);
  });
}
