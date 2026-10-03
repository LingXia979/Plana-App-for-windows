import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/util/preview_cache.dart';
import 'package:plana_app/features/vibe_library/local_vibe_folder.dart';
import 'package:plana_app/features/vibe_library/naiv4vibe_codec.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plana-folder-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Map<String, dynamic> fixture(String id, {bool image = true}) {
    final picture = img.Image(width: 80, height: 160);
    img.fill(picture, color: img.ColorRgb8(id.codeUnitAt(0), 90, 140));
    final base64 = base64Encode(img.encodePng(picture));
    return {
      'identifier': 'novelai-vibe-transfer',
      'id': image ? naiVibeIdOfBase64(base64) : id,
      if (image) 'image': base64,
      'name': '素材 $id',
      'encodings': <String, dynamic>{},
      'importInfo': {'strength': .42, 'information_extracted': .8},
    };
  }

  test(
    'folder scan reuses cache, refreshes changed files, ignores corrupt files and remembers directory',
    () async {
      final originals = Directory('${temp.path}/originals')..createSync();
      final cache = Directory('${temp.path}/cache');
      final single = File('${originals.path}/one.naiv4vibe');
      await single.writeAsString(jsonEncode(fixture('a')));
      await File('${originals.path}/bundle.naiv4vibebundle').writeAsString(
        buildBundleText([fixture('b'), fixture('c'), fixture('a')]),
      );
      await File('${originals.path}/bad.json').writeAsString('broken');
      await File('${originals.path}/unrelated.txt').writeAsString('keep me');
      final container = ProviderContainer(
        overrides: [vibeFolderRootProvider.overrideWith((ref) async => cache)],
      );
      await container.read(vibeFolderProvider.future);
      final lib = container.read(vibeFolderProvider.notifier);
      await lib.choose(originals.path);
      final first = container.read(vibeFolderProvider).requireValue;
      expect(first.entries, hasLength(3));
      expect(first.skipped, 1);
      expect(first.cached, 0);
      final entry = first.entries.firstWhere((e) => e.name == '素材 a');
      final preview = img.decodePng(await File(entry.preview!).readAsBytes())!;
      expect(preview.width / preview.height, .5);
      expect(
        (await PreviewWorkQueue.run(
          () => loadFolderVibe(entry, 'v4-5full'),
        )).infoExtracted,
        .8,
      );
      final before = await File(entry.preview!).lastModified();
      await lib.refresh();
      expect(container.read(vibeFolderProvider).requireValue.cached, 3);
      expect(await File(entry.preview!).lastModified(), before);
      await single.writeAsString(
        jsonEncode({...fixture('d'), 'name': 'changed'}),
      );
      await lib.refresh();
      final changed = container.read(vibeFolderProvider).requireValue;
      expect(changed.cached, 2);
      expect(changed.entries.any((e) => e.name == 'changed'), isTrue);
      container.dispose();
      final reopened = ProviderContainer(
        overrides: [vibeFolderRootProvider.overrideWith((ref) async => cache)],
      );
      final restored = await reopened.read(vibeFolderProvider.future);
      expect(restored.directory, originals.path);
      expect(restored.entries, hasLength(4));
      await reopened.read(vibeFolderProvider.notifier).disconnect();
      expect(await single.exists(), isTrue);
      expect(
        await File('${originals.path}/unrelated.txt').readAsString(),
        'keep me',
      );
      reopened.dispose();
    },
  );

  test(
    'same image keeps distinct model encodings in the folder browser',
    () async {
      final originals = Directory('${temp.path}/variants')..createSync();
      for (final model in ['v4-5full', 'v4-5curated']) {
        final raw = fixture('same-image');
        mergeEncodingIntoRaw(
          raw,
          modelKey: model,
          infoExtracted: .7,
          encoding: 'encoded-$model',
        );
        await File(
          '${originals.path}/$model.naiv4vibe',
        ).writeAsString(buildVibeText(raw));
      }
      final container = ProviderContainer(
        overrides: [
          vibeFolderRootProvider.overrideWith(
            (ref) async => Directory('${temp.path}/cache'),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(vibeFolderProvider.future);
      await container.read(vibeFolderProvider.notifier).choose(originals.path);
      final entries = container.read(vibeFolderProvider).requireValue.entries;
      expect(entries, hasLength(2));
      expect(entries.map((e) => e.id).toSet(), hasLength(1));
      expect(
        entries.map((e) => e.models.single),
        containsAll(['v4-5full', 'v4-5curated']),
      );
    },
  );

  test(
    'thumbnail-only files display; changed files cannot load stale selections',
    () async {
      final file = File('${temp.path}/thumb.json');
      final raw = fixture('thumb', image: false);
      raw['thumbnail'] =
          'data:image/png;base64,${base64Encode(img.encodePng(img.Image(width: 180, height: 60)))}';
      mergeEncodingIntoRaw(
        raw,
        modelKey: 'v4-5full',
        infoExtracted: .8,
        encoding: 'full08',
      );
      await file.writeAsString(jsonEncode(raw));
      final result = await readFolderVibes(file.path, '${temp.path}/cache');
      expect(result.entries.single.hasImage, isFalse);
      final preview = img.decodePng(
        await File(result.entries.single.preview!).readAsBytes(),
      )!;
      expect(preview.width / preview.height, 3);
      final data = await loadFolderVibe(result.entries.single, 'v4-5full');
      expect(data.encodedByModel, {'v4-5full': 'full08'});
      await file.writeAsString('changed');
      await expectLater(
        loadFolderVibe(result.entries.single, 'v4-5full'),
        throwsFormatException,
      );
    },
  );

  test(
    'encoding-only models never mix information-extraction values or Full/Curated',
    () {
      final raw = fixture('enc', image: false);
      mergeEncodingIntoRaw(
        raw,
        modelKey: 'v4-5full',
        infoExtracted: .7,
        encoding: 'full07',
      );
      mergeEncodingIntoRaw(
        raw,
        modelKey: 'v4-5curated',
        infoExtracted: .4,
        encoding: 'curated04',
      );
      mergeEncodingIntoRaw(
        raw,
        modelKey: 'v4-5curated',
        infoExtracted: .7,
        encoding: 'curated07',
      );
      final p = ParsedVibe(raw);
      final data = dataForParsedVibe(p, 'v4-5curated', .4);
      expect(data.infoExtracted, .4);
      expect(data.encodedByModel, {'v4-5curated': 'curated04'});
      expect(dataForParsedVibe(p, 'v4-5full', .4).encodedByModel, {
        'v4-5full': 'full07',
        'v4-5curated': 'curated07',
      });
      expect(() => dataForParsedVibe(p, 'v4full', .7), throwsFormatException);
    },
  );

  test(
    'fit preview cache preserves landscape and portrait proportions off the UI isolate',
    () async {
      final cache = PreviewCache(Directory('${temp.path}/previews'));
      for (final dims in [(90, 240), (300, 80)]) {
        final source = File('${temp.path}/${dims.$1}.png');
        await source.writeAsBytes(
          img.encodePng(img.Image(width: dims.$1, height: dims.$2)),
        );
        final output = (await cache.fileFor(source.path))!;
        final decoded = img.decodePng(await File(output).readAsBytes())!;
        expect(decoded.width / decoded.height, dims.$1 / dims.$2);
        expect(await cache.fileFor(source.path), output);
      }
    },
  );
}
