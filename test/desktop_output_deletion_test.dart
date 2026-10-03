import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/desktop_output_store.dart';
import 'package:plana_app/features/gallery/models.dart';

void main() {
  late Directory temp;
  late DesktopOutputStore store;
  late ResultImage original;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plana_output_delete_');
    store = DesktopOutputStore(Directory('${temp.path}/作品'));
    original = ResultImage(
      id: 'gen1',
      width: 1,
      height: 1,
      seed: 1,
      createdAt: DateTime(2026, 10, 3).millisecondsSinceEpoch,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
  });
  tearDown(() async {
    await store.idle;
    await temp.delete(recursive: true);
  });

  test(
    'legacy metadata, collision suffixes and all managed folders are cleaned; manual exports survive',
    () async {
      final files = [
        await store.save(original),
        await store.save(original),
        await store.save(original, albumId: 'some-album'),
      ];
      final sidecar = File(files.first.path.replaceAll('.png', '.json'));
      final legacy =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      legacy.remove('managedBy');
      await sidecar.writeAsString(jsonEncode(legacy));
      final manual = await File(
        '${files.first.parent.path}/plana_gen1_1.png',
      ).writeAsBytes([9]);
      final foreignFolder = await Directory(
        '${store.root.path}/exports',
      ).create();
      final foreign = await files.first.copy(
        '${foreignFolder.path}/${files.first.uri.pathSegments.last}',
      );
      await sidecar.copy(foreign.path.replaceAll('.png', '.json'));
      final reopened = DesktopOutputStore(store.root);
      expect(await reopened.deleteResults([original]), {'gen1'});
      for (final file in files) {
        expect(await file.exists(), isFalse);
        expect(
          await File(file.path.replaceAll('.png', '.json')).exists(),
          isFalse,
        );
      }
      expect(await manual.exists(), isTrue);
      expect(await foreign.exists(), isTrue);
    },
  );

  test(
    'guarded deletion leaves files untouched, delayed save cannot resurrect a deleted output',
    () async {
      final saved = store.save(original);
      final rejected = store.deleteResults([original], canDelete: (_) => false);
      final file = await saved;
      expect(await rejected, isEmpty);
      expect(await file.exists(), isTrue);
      expect(await store.deleteResults([original]), {'gen1'});
      await expectLater(store.save(original), throwsStateError);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'matching name with another identity is retained and another image is unaffected',
    () async {
      final file = await store.save(original);
      final sidecar = File(file.path.replaceAll('.png', '.json'));
      final metadata =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      metadata['id'] = 'another-image';
      await sidecar.writeAsString(jsonEncode(metadata));
      final other = ResultImage(
        id: 'gen10',
        width: 1,
        height: 1,
        seed: 1,
        createdAt: original.createdAt,
        bytes: original.bytes,
      );
      final otherFile = await store.save(other);
      expect(await store.deleteResults([original]), {'gen1'});
      expect(await file.exists(), isTrue);
      expect(await sidecar.exists(), isTrue);
      expect(await otherFile.exists(), isTrue);
    },
  );

  test(
    'unreadable matching sidecar stops deletion and keeps the PNG for retry',
    () async {
      final file = await store.save(original);
      final sidecar = File(file.path.replaceAll('.png', '.json'));
      await sidecar.writeAsString('{broken');
      await expectLater(store.deleteResults([original]), throwsStateError);
      expect(await file.exists(), isTrue);
      expect(await sidecar.exists(), isTrue);
    },
  );
}
