import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_dates.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 6)));
  GalleryNotifier gallery() => container.read(galleryProvider.notifier);
  List<String> live() =>
      container.read(galleryProvider).results.map((r) => r.id).toList();
  List<String> trash() =>
      container.read(galleryProvider).trash.map((t) => t.image.id).toList();
  String add(int seed) =>
      gallery().addResult(bytes: png, width: 4, height: 6, seed: seed).id;
  ProviderContainer open(AppStores value) => ProviderContainer(
    overrides: [
      appStoresProvider.overrideWithValue(value),
      desktopModeProvider.overrideWithValue(false),
    ],
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_trash_');
    stores = await AppStores.open(rootOverride: root);
    container = open(stores);
  });
  tearDown(() async {
    await stores.flushForExit();
    container.dispose();
    await root.delete(recursive: true);
  });

  test(
    'trash survives restart without becoming unindexed live images; restore keeps favorites and albums',
    () async {
      final ids = [for (var i = 0; i < 4; i++) add(i)];
      final albums = container.read(albumsProvider.notifier);
      final album = await albums.create('旅行');
      await albums.organize({ids[1]}, {album});
      gallery().setFavorite(ids[1], true);
      await stores.gallery.idle;
      final before = await stores.gallery.readImage(ids[1]);
      expect(await gallery().deleteResults([ids[1]]), {ids[1]});
      expect(await gallery().deleteResults([ids[2]]), {ids[2]});
      expect(live(), [ids[3], ids[0]]);
      expect(trash(), [ids[2], ids[1]]);
      expect(container.read(albumsProvider).ofImage(ids[1]), {album});
      expect(await stores.gallery.readImage(ids[1]), before);
      await stores.flushForExit();
      container.dispose();
      stores = await AppStores.open(rootOverride: root);
      container = open(stores);
      expect(live(), [ids[3], ids[0]]);
      expect(trash(), [ids[2], ids[1]]);
      expect(await gallery().restoreTrash([ids[1], ids[2]]), 2);
      expect(live(), ids.reversed.toList());
      expect(trash(), isEmpty);
      expect(
        container
            .read(galleryProvider)
            .results
            .singleWhere((r) => r.id == ids[1])
            .favorite,
        isTrue,
      );
      expect(container.read(albumsProvider).ofImage(ids[1]), {album});
      expect(await stores.gallery.readImage(ids[1]), before);
    },
  );

  test(
    'restoring a copy with an older creation date returns it ahead of surviving originals',
    () async {
      final original = add(1);
      final later = add(2);
      final albums = container.read(albumsProvider.notifier);
      final target = await albums.create('独立副本');
      final copy = (await gallery().copyResults({original}, {target})).single;
      expect(live(), [copy, later, original]);
      await gallery().deleteResults([copy, later]);
      final newest = add(3);
      await gallery().restoreTrash([later]);
      await gallery().restoreTrash([copy]);
      expect(live(), [newest, copy, later, original]);
      await gallery().deleteResults([copy]);
      expect(await gallery().purgeTrash([copy, original]), {copy});
      expect(live(), [newest, later, original]);
      expect(await stores.gallery.readImage(original), png);
      expect(await stores.gallery.readImage(copy), isNull);
      expect(container.read(albumsProvider).ofImage(copy), isEmpty);
    },
  );

  test(
    'expiry uses 30 local calendar days and never purges a newly restored entry',
    () async {
      final a = add(1), b = add(2);
      final now = DateTime(2050, 3, 31, 0, 1);
      await gallery().deleteResults([a], now: DateTime(2050, 3, 1, 23, 59));
      await gallery().deleteResults([b], now: DateTime(2050, 3, 2));
      await gallery().purgeExpiredTrash(now: now);
      expect(trash(), [b]);
      expect(await stores.gallery.readImage(a), isNull);
      expect(await stores.gallery.readImage(b), png);
      await gallery().restoreTrash([b]);
      await gallery().purgeExpiredTrash(now: now.add(const Duration(days: 40)));
      expect(live(), [b]);
      expect(
        galleryDaysSince(
          DateTime(2024, 2, 29, 23, 59).millisecondsSinceEpoch,
          DateTime(2024, 3, 1),
        ),
        1,
      );
      expect(galleryDaysSince(DateTime(2051).millisecondsSinceEpoch, now), 0);
    },
  );

  test(
    'sequence includes trash and duplicate old items cannot resurrect it',
    () async {
      final id = add(1);
      await gallery().deleteResults([id]);
      await stores.flushForExit();
      final file = File('${root.path}/gallery/index.json');
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      data['seq'] = 0;
      data['items'] = [
        Map<String, dynamic>.from((data['trash'] as List).single),
      ];
      await file.writeAsString(jsonEncode(data));
      container.dispose();
      stores = await AppStores.open(rootOverride: root);
      container = open(stores);
      expect(live(), isEmpty);
      expect(trash(), [id]);
      expect(add(2), isNot(id));
      expect(await stores.gallery.readImage(id), png);
    },
  );

  test('restore and purge serialize; clear also removes trash', () async {
    final a = add(1), b = add(2);
    await gallery().deleteResults([a, b]);
    final restore = gallery().restoreTrash([a]);
    final purge = gallery().purgeTrash([a, b]);
    expect(await restore, 1);
    expect(await purge, {b});
    expect(live(), [a]);
    await gallery().deleteResults([a]);
    await gallery().clearAll();
    expect(live(), isEmpty);
    expect(trash(), isEmpty);
    expect(await stores.gallery.readImage(a), isNull);
  });
}
