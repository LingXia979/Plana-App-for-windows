import 'dart:async';
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
  late Directory root;
  late ProviderContainer container;
  final png = img.encodePng(img.Image(width: 2, height: 2));
  final data = 'data:image/png;base64,${base64Encode(png)}';
  File index() => File('${root.path}/tag_library.json');

  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_backup_previews_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => root.path,
    );
    container = ProviderContainer();
    syncCustomTagCategories(const []);
  });
  tearDown(() async {
    await container.read(tagLibraryProvider.notifier).settled;
    container.dispose();
    syncCustomTagCategories(const []);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });
  Future<TagLibrary> library() async {
    await container.read(tagLibraryProvider.future);
    return container.read(tagLibraryProvider.notifier);
  }

  Future<TagLibraryState> reopen() async {
    await container.read(tagLibraryProvider.notifier).settled;
    container.dispose();
    container = ProviderContainer();
    return container.read(tagLibraryProvider.future);
  }

  TagEntry entry(String id, List<String> previews) => TagEntry(
    id: id,
    category: TagCategory.artist,
    name: id,
    positive: 'artist:test',
    previews: previews,
  );

  test(
    'embedded previews restore in order, deduplicate, survive restart and protect shared files',
    () async {
      final lib = await library();
      final shared = File('${root.path}/shared.png')..writeAsBytesSync(png);
      final replaced = File('${root.path}/replaced.png')..writeAsBytesSync(png);
      await lib.upsert(entry('A12', [shared.path, replaced.path]));
      await lib.upsert(entry('keep', [shared.path]));
      final stat = await lib.mergeBackup(
        {
          'artist-style': [
            {
              'id': 'A12',
              'name': 'A12 restored',
              'prompt': 'artist:new',
              'preview': data,
              'previews': [data, 'https://example.invalid/preview.png'],
            },
          ],
        },
        custom: {
          'defs': [
            {'id': 'c_saved', 'label': '自定义', 'iconName': 'Tag'},
          ],
          'items': {
            'c_saved': [
              {
                'id': 'custom1',
                'name': '自定义图',
                'positive': 'test',
                'previews': [data],
              },
            ],
          },
        },
      );
      expect(stat[TagCategory.artist], (added: 0, updated: 1));
      final restored = await reopen();
      final a = restored.entries.firstWhere((e) => e.id == 'A12');
      expect(a.positive, 'artist:new');
      expect(a.previews, hasLength(2));
      expect(File(a.previews.first).readAsBytesSync(), png);
      expect(a.previews.last, 'https://example.invalid/preview.png');
      final custom = restored.entries.firstWhere((e) => e.id == 'custom1');
      expect(File(custom.previews.single).readAsBytesSync(), png);
      expect(custom.previews.single, isNot(a.previews.first));
      expect(shared.existsSync(), isTrue);
      expect(replaced.existsSync(), isFalse);
      expect(index().readAsStringSync().contains('data:image'), isFalse);
    },
  );

  test(
    'text-only backup retains local previews and reconciles remote previews',
    () async {
      final lib = await library();
      final local = File('${root.path}/local.png')..writeAsBytesSync(png);
      await lib.upsert(
        entry('A12', [
          local.path,
          'https://example.invalid/kept.png',
          'https://example.invalid/removed.png',
        ]),
      );
      await lib.mergeBackup({
        'artist-style': [
          {
            'id': 'A12',
            'prompt': 'new',
            'previews': [
              'https://example.invalid/kept.png',
              'https://example.invalid/added.png',
              'data:image/png;base64,%%%invalid',
              'C:/another-computer/private.png',
            ],
          },
        ],
      });
      final restored = (await reopen()).entries.single;
      expect(restored.previews, [
        local.path,
        'https://example.invalid/kept.png',
        'https://example.invalid/added.png',
      ]);
      expect(local.existsSync(), isTrue);
      await container.read(tagLibraryProvider.notifier).mergeBackup({
        'artist-style': [
          {'id': 'A12', 'prompt': 'text only'},
        ],
      });
      expect((await reopen()).entries.single.previews, [local.path]);
    },
  );

  test(
    'preview write failure keeps the old library and its files; retry works',
    () async {
      final lib = await library();
      final old = File('${root.path}/old.png')..writeAsBytesSync(png);
      await lib.upsert(entry('A12', [old.path]));
      final before = index().readAsBytesSync();
      final blocker = File('${root.path}/tag_previews')
        ..writeAsStringSync('block directory creation');
      final backup = {
        'artist-style': [
          {'id': 'A12', 'prompt': 'new', 'preview': data},
        ],
      };
      await expectLater(
        lib.mergeBackup(backup),
        throwsA(isA<FileSystemException>()),
      );
      expect(index().readAsBytesSync(), before);
      expect(
        container.read(tagLibraryProvider).value!.entries.single.previews,
        [old.path],
      );
      expect(old.existsSync(), isTrue);
      blocker.deleteSync();
      await lib.mergeBackup(backup);
      final restored = (await reopen()).entries.single;
      expect(restored.positive, 'new');
      expect(File(restored.previews.single).readAsBytesSync(), png);
    },
  );

  test(
    'index write failure is reported before old preview files can be deleted',
    () async {
      final lib = await library();
      final old = File('${root.path}/old.png')..writeAsBytesSync(png);
      await lib.upsert(entry('A12', [old.path]));
      final before = index().readAsBytesSync();
      final blocker = Directory('${index().path}.tmp')..createSync();
      final backup = {
        'artist-style': [
          {'id': 'A12', 'prompt': 'new', 'preview': data},
        ],
      };
      await expectLater(
        lib.mergeBackup(backup),
        throwsA(isA<FileSystemException>()),
      );
      expect(index().readAsBytesSync(), before);
      expect(old.existsSync(), isTrue);
      expect(
        File(
          container
              .read(tagLibraryProvider)
              .value!
              .entries
              .single
              .previews
              .single,
        ).existsSync(),
        isTrue,
      );
      blocker.deleteSync();
      await lib.mergeBackup(backup);
      final restored = (await reopen()).entries.single;
      expect(restored.positive, 'new');
      expect(File(restored.previews.single).readAsBytesSync(), png);
    },
  );

  test(
    'duplicate backup IDs do not overwrite image files or leave discarded staging images',
    () async {
      final lib = await library();
      await lib.mergeBackup({
        'artist-style': [
          {'id': 'A12', 'prompt': 'first', 'preview': data},
          {'id': 'A12', 'prompt': 'last', 'preview': data},
        ],
      });
      final restored = (await reopen()).entries.single;
      expect(restored.positive, 'last');
      expect(File(restored.previews.single).readAsBytesSync(), png);
      expect(Directory('${root.path}/tag_previews').listSync(), hasLength(1));
    },
  );

  test(
    'restoring images preserves unrelated edits made while writing them',
    () async {
      final lib = await library();
      final reached = Completer<void>();
      final release = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async {
        if (!reached.isCompleted) reached.complete();
        await release.future;
        return root.path;
      });
      final work = lib.mergeBackup({
        'artist-style': [
          {'id': 'A12', 'prompt': 'new', 'preview': data},
        ],
      });
      await reached.future;
      await lib.upsert(entry('concurrent', []));
      release.complete();
      await work;
      expect(
        (await reopen()).entries.map((e) => e.id),
        containsAll(['A12', 'concurrent']),
      );
    },
  );
}
