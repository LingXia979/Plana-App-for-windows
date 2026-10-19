import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/blob_store.dart';

void main() {
  late Directory root;
  late BlobStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_blob_concurrent_');
    store = BlobStore(root);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'simultaneous snapshots save the same reference image completely',
    () async {
      final bytes = Uint8List.fromList(List.generate(4096, (i) => i % 256));
      final hash = sha256.convert(bytes).toString();
      final hashes = await Future.wait([
        for (var i = 0; i < 32; i++) store.put(Uint8List.fromList(bytes)),
      ]);
      expect(hashes, everyElement(hash));
      expect(await store.get(hash), bytes);
      expect(
        await Directory(
          '${root.path}/blobs',
        ).list().map((file) => file.uri.pathSegments.last).toList(),
        ['$hash.bin'],
      );
    },
  );

  test(
    'failed shared writes reach all callers and allow a later retry',
    () async {
      final blocker = File('${root.path}/blobs');
      await blocker.writeAsString('blocked');
      final bytes = Uint8List.fromList([1, 2, 3]);
      await Future.wait([
        for (var i = 0; i < 8; i++)
          expectLater(store.put(bytes), throwsA(isA<FileSystemException>())),
      ]);
      await blocker.delete();
      final hash = await store.put(bytes);
      expect(await store.get(hash), bytes);
    },
  );
}
