import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/import/image_metadata.dart';
import 'package:plana_app/features/tools/metadata_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('plana_export_test_'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'exports remove or replace metadata without altering originals or earlier copies',
    () async {
      final bytes = await writeCustomMetadataPng(
        await File('assets/app_icon.png').readAsBytes(),
        'original prompt',
      );
      final source = await File('${directory.path}/角色.png').writeAsBytes(bytes);
      final previous = await File(
        '${directory.path}/角色_clean.png',
      ).writeAsString('previous export');
      final cleaned = await exportMetadataCopy(
        directory: directory,
        sourceName: '角色.png',
        bytes: bytes,
      );
      expect(cleaned.path, endsWith('角色_clean (1).png'));
      expect(await extractImageMetadata(await cleaned.readAsBytes()), isNull);
      final outputs = await Future.wait([
        for (var i = 0; i < 2; i++)
          exportMetadataCopy(
            directory: directory,
            sourceName: '角色.png',
            bytes: bytes,
            customPrompt: 'new prompt',
          ),
      ]);
      expect(outputs.map((f) => f.path).toSet().length, 2);
      for (final file in outputs) {
        expect(
          (await extractImageMetadata(await file.readAsBytes()))!.prompt,
          'new prompt',
        );
      }
      expect(await source.readAsBytes(), bytes);
      expect(await previous.readAsString(), 'previous export');
    },
  );

  test(
    'unwritable destination fails explicitly and leaves the source unchanged',
    () async {
      final bytes = await File('assets/app_icon.png').readAsBytes();
      await expectLater(
        exportMetadataCopy(
          directory: Directory('${directory.path}/missing'),
          sourceName: 'image.png',
          bytes: bytes,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(directory.listSync(), isEmpty);
    },
  );
}
