import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/import/image_metadata.dart';
import 'package:plana_app/features/tools/metadata_processing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('metadata_job_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'full metadata round trip handles Unicode, small images and V4 captions',
    () async {
      final base = await encodePngFromRgba(
        Uint8List(12 * 18 * 4)..fillRange(0, 12 * 18 * 4, 255),
        12,
        18,
      );
      final original = {
        'prompt': 'old',
        'uc': 'old negative',
        'width': 832,
        'height': 1216,
        'v4_prompt': {
          'caption': {
            'base_caption': 'old',
            'char_captions': [
              {
                'char_caption': 'cat ears',
                'centers': [
                  {'x': .5, 'y': .5},
                ],
              },
            ],
          },
        },
        'v4_negative_prompt': {
          'caption': {'base_caption': 'old negative', 'char_captions': []},
        },
        'custom_field': 'preserve me',
      };
      final edited = updateMetadataComment(original, {
        'prompt': '樱花, 猫娘',
        'uc': '低质量',
        'steps': 37,
        'scale': 6.5,
        'seed': 4294967295,
        'sampler': 'k_euler',
        'sm': true,
        'sm_dyn': true,
      });
      final written = await writeImageMetadataPng(
        base,
        comment: edited,
        source: 'NovelAI',
      );
      final meta = (await extractImageMetadata(written))!;
      expect(meta.prompt, '樱花, 猫娘');
      expect(meta.negativePrompt, '低质量');
      expect(meta.steps, '37');
      expect(meta.scale, '6.5');
      expect(meta.seed, '4294967295');
      expect((meta.width, meta.height), (12, 18));
      expect(meta.characters.single.prompt, 'cat ears');
      expect(metadataComment(meta)['custom_field'], 'preserve me');
      expect(metadataComment(meta)['sm_dyn'], true);
      expect(original['prompt'], 'old');
      expect(await extractImageMetadata(await cleanImagePng(written)), isNull);
    },
  );

  test('replacing metadata also removes stale hidden metadata', () async {
    final hidden = await writeCustomMetadataPng(
      await File('assets/app_icon.png').readAsBytes(),
      'hidden secret',
    );
    final output = await writeImageMetadataPng(
      hidden,
      comment: {'prompt': 'visible edit', 'uc': 'new negative'},
    );
    final meta = (await extractImageMetadata(output))!;
    expect(meta.prompt, 'visible edit');
    expect(meta.negativePrompt, 'new negative');
    expect(await extractImageMetadata(await cleanImagePng(output)), isNull);
  });

  test(
    'folder scan is sorted, nonrecursive and filters supported image extensions',
    () async {
      for (final name in ['b.WEBP', 'a.png', 'c.JPEG', 'notes.txt']) {
        File('${temp.path}/$name').writeAsStringSync('fixture');
      }
      Directory('${temp.path}/nested').createSync();
      File('${temp.path}/nested/hidden.png').writeAsStringSync('fixture');
      final files = await listMetadataImages(temp);
      expect(files.map((f) => f.uri.pathSegments.last), [
        'a.png',
        'b.WEBP',
        'c.JPEG',
      ]);
    },
  );

  test(
    'batch snapshots parameters, continues after corrupt files and protects originals',
    () async {
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final a = await File('${temp.path}/a.png').writeAsBytes(bytes);
      final broken = await File(
        '${temp.path}/broken.png',
      ).writeAsString('broken');
      final c = await File('${temp.path}/c.png').writeAsBytes(bytes);
      final previous = await File(
        '${temp.path}/a_custom.png',
      ).writeAsString('previous');
      final comment = <String, dynamic>{
        'prompt': 'snapshot',
        'uc': 'negative',
        'seed': 123,
      };
      final files = [a, broken, c];
      final job = MetadataBatchJob(
        files: files,
        directory: temp,
        comment: comment,
      );
      files.clear();
      comment['prompt'] = 'changed after start';
      final progress = <int>[];
      final result = await job.run(
        onProgress: (done, _, _) => progress.add(done),
      );
      expect(progress, [1, 2, 3]);
      expect(result.outputs, hasLength(2));
      expect(result.errors.single, contains('broken.png'));
      expect(result.cancelled, false);
      expect(result.outputs.first, endsWith('a_custom (1).png'));
      for (final path in result.outputs) {
        final meta = (await extractImageMetadata(
          await File(path).readAsBytes(),
        ))!;
        expect(meta.prompt, 'snapshot');
        expect(meta.negativePrompt, 'negative');
      }
      expect(await a.readAsBytes(), bytes);
      expect(await previous.readAsString(), 'previous');
    },
  );

  test(
    'cancelling finishes current image and keeps completed copies',
    () async {
      final bytes = await File('assets/app_icon.png').readAsBytes();
      final files = [
        for (var i = 0; i < 3; i++)
          await File('${temp.path}/$i.png').writeAsBytes(bytes),
      ];
      final job = MetadataBatchJob(
        files: files,
        directory: Directory('${temp.path}/out'),
      );
      final result = await job.run(onProgress: (_, _, _) => job.cancel());
      expect(result.cancelled, true);
      expect(result.outputs, hasLength(1));
      expect(File(result.outputs.single).existsSync(), true);
      expect(files.every((f) => f.existsSync()), true);
    },
  );
}
