import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late ProviderContainer container;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('plana_examples_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    container = ProviderContainer();
  });
  tearDown(() {
    container.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    temp.deleteSync(recursive: true);
  });

  test(
    'examples survive restart, preserve edits and own separate full size previews',
    () async {
      await container.read(tagLibraryProvider.future);
      final library = container.read(tagLibraryProvider.notifier);
      const own = TagEntry(
        id: 'my-scene',
        category: TagCategory.scene,
        name: '自己的场景',
      );
      await library.upsert(own);
      expect(await library.addPreviewExamples(TagCategory.scene), 3);
      expect(await library.addPreviewExamples(TagCategory.other), 3);
      final entries = container.read(tagLibraryProvider).requireValue.entries;
      expect(entries.length, 7);
      final previews = entries.where((e) => e.previews.isNotEmpty).toList();
      expect(previews.map((e) => e.previews.single).toSet().length, 6);
      for (final entry in previews) {
        final image = img.decodePng(
          await File(entry.previews.single).readAsBytes(),
        )!;
        expect(
          (image.width, image.height),
          (entry.extra['width'], entry.extra['height']),
        );
      }
      final edited = previews.first.copyWith(
        name: '编辑过的示例',
        positive: 'my prompt',
      );
      await library.upsert(edited);
      expect(await library.addPreviewExamples(TagCategory.scene), 0);
      await library.remove(previews.last.id);
      expect(await File(previews.last.previews.single).exists(), isFalse);
      expect(
        await File(previews[previews.length - 2].previews.single).exists(),
        isTrue,
      );
      container.dispose();
      container = ProviderContainer();
      final reopened = await container.read(tagLibraryProvider.future);
      expect(reopened.entries.length, 6);
      expect(
        reopened.entries.firstWhere((e) => e.id == edited.id).positive,
        'my prompt',
      );
      expect(reopened.entries.any((e) => e.id == previews.last.id), isFalse);
      expect(reopened.entries.any((e) => e.id == own.id), isTrue);
    },
  );

  test('overlapping edits persist the newest complete library', () async {
    await container.read(tagLibraryProvider.future);
    final library = container.read(tagLibraryProvider.notifier);
    await Future.wait([
      for (var i = 0; i < 12; i++)
        library.upsert(
          TagEntry(id: 'scene-$i', category: TagCategory.scene, name: '场景 $i'),
        ),
    ]);
    final json =
        jsonDecode(await File('${temp.path}/tag_library.json').readAsString())
            as Map;
    expect((json['entries'] as List).length, 12);
    container.dispose();
    container = ProviderContainer();
    expect(
      (await container.read(tagLibraryProvider.future)).entries.length,
      12,
    );
  });
}
