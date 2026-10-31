import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/ui_prefs.dart';
import 'package:plana_app/features/inspiration/codex/codex_block.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/widgets/char_pick_sheet.dart';

class _DelayedLibrary extends TagLibrary {
  _DelayedLibrary(this.ready, this.loaded);

  final Future<void> ready;
  final Completer<void> loaded;

  @override
  Future<TagLibraryState> build() async {
    await ready;
    final result = await super.build();
    loaded.complete();
    return result;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late ProviderContainer container;
  File getFile() => File('${root.path}/tag_library.json');

  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_custom_categories_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => root.path,
    );
    container = ProviderContainer();
    syncCustomTagCategories(const []);
  });
  tearDown(() {
    container.dispose();
    syncCustomTagCategories(const []);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    root.deleteSync(recursive: true);
  });
  Future<TagLibraryState> reopen() async {
    await container.read(tagLibraryProvider.notifier).settled;
    container.dispose();
    container = ProviderContainer();
    return container.read(tagLibraryProvider.future);
  }

  test(
    'legacy library survives categories, concurrent saves and restart',
    () async {
      final preview = File('${root.path}/kept.png')
        ..writeAsBytesSync([1, 2, 3]);
      final legacy = TagEntry(
        id: 'old',
        category: TagCategory.character,
        name: '旧角色',
        positive: 'solo',
        previews: [preview.path],
        tags: const ['常用'],
      );
      getFile().writeAsStringSync(
        jsonEncode({
          'version': 1,
          'entries': [legacy.toJson()],
          'pools': {
            'character': ['常用'],
          },
          'usage': {
            'character': ['old'],
          },
        }),
      );
      final loaded = await container.read(tagLibraryProvider.future);
      expect(loaded.visibleTabKeys, [
        'character',
        'artist-style',
        'scene',
        'other',
        'codex',
      ]);
      final lib = container.read(tagLibraryProvider.notifier);
      final def = await lib.addCategory(
        label: '服装',
        iconName: 'Shirt',
        layout: TagCardLayout.portrait,
      );
      await Future.wait([
        lib.upsert(
          TagEntry(
            id: 'dress',
            category: def.key,
            name: '裙子',
            positive: 'dress',
          ),
        ),
        lib.renameBuiltin('character', '人物'),
        lib.addPoolTag(def.key, '常用服装'),
      ]);
      await lib.markUsed(def.key, ['dress']);
      await lib.moveTab(4, 0);
      final saved = await reopen();
      expect(saved.entries.map((e) => e.id), ['old', 'dress']);
      expect(saved.of(TagCategory.character).single.previews, [preview.path]);
      expect(saved.poolOf(def.key), ['常用服装']);
      expect(saved.usage[def.key], ['dress']);
      expect(saved.visibleTabKeys.first, def.webId);
      expect(tagCategoryDef(def.key).label, '服装');
      expect(tagCategoryDef(TagCategory.character).label, '人物');
      expect(preview.existsSync(), isTrue);
    },
  );

  test('creating a category waits for the existing library to load', () async {
    getFile().writeAsStringSync(
      jsonEncode({
        'version': 1,
        'entries': [
          const TagEntry(
            id: 'kept',
            category: TagCategory.character,
            name: '旧角色',
            positive: 'solo',
          ).toJson(),
        ],
      }),
    );
    final ready = Completer<void>(), loaded = Completer<void>();
    container.dispose();
    container = ProviderContainer(
      overrides: [
        tagLibraryProvider.overrideWith(
          () => _DelayedLibrary(ready.future, loaded),
        ),
      ],
    );
    final creating = container
        .read(tagLibraryProvider.notifier)
        .addCategory(
          label: '衣服',
          iconName: 'Shirt',
          layout: TagCardLayout.none,
        );
    final stayedLoading = container.read(tagLibraryProvider).isLoading;
    ready.complete();
    await loaded.future;
    final def = await creating;
    final restored = await reopen();
    expect(stayedLoading, isTrue);
    expect(restored.entries.single.id, 'kept');
    expect(restored.customDefs.single.key, def.key);
  });

  test(
    'category deletion protects builtins and cleans only the chosen category',
    () async {
      await container.read(tagLibraryProvider.future);
      final lib = container.read(tagLibraryProvider.notifier);
      final c = await lib.addCategory(
        label: '衣服',
        iconName: 'Shirt',
        layout: TagCardLayout.none,
      );
      await lib.upsert(
        const TagEntry(id: 'char', category: TagCategory.character, name: '角色'),
      );
      await lib.upsert(TagEntry(id: 'outfit', category: c.key, name: '衣服'));
      await lib.upsert(
        const TagEntry(id: 'scene', category: TagCategory.scene, name: '场景'),
      );
      await lib.addPoolTag(c.key, '标签');
      await lib.markUsed(c.key, ['outfit']);
      await lib.removeCategory(TagCategory.character);
      await lib.removeBuiltin(TagCategory.character);
      await lib.removeCategory(c.key);
      await lib.removeBuiltin(TagCategory.scene);
      var state = await reopen();
      expect(state.entries.map((e) => e.id), ['char']);
      expect(state.pools.containsKey(c.key), isFalse);
      expect(state.usage.containsKey(c.key), isFalse);
      expect(panelTagCats(state), isNot(contains(TagCategory.scene)));
      await container.read(tagLibraryProvider.notifier).restoreBuiltin('scene');
      state = await reopen();
      expect(panelTagCats(state), contains(TagCategory.scene));
    },
  );

  test(
    'cloud and single-category backups restore definitions, labels and hidden data',
    () async {
      await container.read(tagLibraryProvider.future);
      final lib = container.read(tagLibraryProvider.notifier);
      final def = await lib.addCategory(
        label: '动作',
        iconName: 'Hand',
        layout: TagCardLayout.none,
      );
      await lib.upsert(
        TagEntry(
          id: 'wave',
          category: def.key,
          name: '招手',
          positive: 'waving',
          negative: 'bad hands',
        ),
      );
      await lib.renameBuiltin('codex', '词典');
      await lib.moveTab(5, 0);
      final cloud =
          jsonDecode(jsonEncode(lib.encodeCustom())) as Map<String, dynamic>;
      final file = buildBackupFile(
        def.key,
        lib.encodeCategory(def.key),
        exportedAt: '2026-10-31',
      );
      expect((file['categoryDefinition'] as Map)['label'], '动作');
      expect(parseBackupFile(file).cat, def.key);
      await lib.removeCategory(def.key);
      await lib.mergeBackup({}, custom: cloud);
      var state = await reopen();
      expect(state.of(def.key).single.negative, 'bad hands');
      expect(state.customDefs.single.layout, TagCardLayout.none);
      expect(codexTabLabel(), '词典');
      final order = state.visibleTabKeys;
      await container
          .read(tagLibraryProvider.notifier)
          .mergeBackup(
            {def.webId: parseBackupFile(file).items},
            custom: {
              'defs': [file['categoryDefinition']],
            },
          );
      state = await reopen();
      expect(
        state.visibleTabKeys,
        order,
      ); // partial import does not reset tab order
      await container
          .read(tagLibraryProvider.notifier)
          .removeBuiltin(TagCategory.scene);
      await container.read(tagLibraryProvider.notifier).mergeBackup({
        'scene': [
          {'id': 'restored', 'name': '旧场景', 'positive': 'forest'},
        ],
      });
      state = await reopen();
      expect(state.visibleTabKeys, contains('scene'));
      expect(state.of(TagCategory.scene).single.name, '旧场景');
    },
  );

  test(
    'malformed category metadata cannot hide valid legacy/custom entries',
    () async {
      final entry = TagEntry(
        id: 'orphan',
        category: TagCategory.custom('c_missing'),
        name: '仍可读取',
        positive: 'safe',
      );
      getFile().writeAsStringSync(
        jsonEncode({
          'entries': [entry.toJson()],
          'categories': {
            'defs': [
              null,
              {'id': 'c_', 'label': ''},
            ],
            'order': ['c_missing', 'c_missing', 'unknown'],
            'hidden': ['character', 'c_missing', 'codex'],
          },
        }),
      );
      final loaded = await container.read(tagLibraryProvider.future);
      expect(loaded.entries.single.id, 'orphan');
      expect(
        loaded.visibleTabKeys.where((k) => k == 'c_missing'),
        hasLength(1),
      );
      expect(loaded.visibleTabKeys, containsAll(['character', 'codex']));
      expect(loaded.customDefs.single.webId, 'c_missing');
    },
  );

  test(
    'picker memories and codex blocks persist without resetting other preferences',
    () async {
      final stores = await AppStores.open(
        rootOverride: Directory('${root.path}/prefs'),
      );
      container.dispose();
      container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      container
          .read(uiPrefsProvider.notifier)
          .patch((p) => p.copyWith(galleryBrowseAlbum: 'kept'));
      container
          .read(uiPrefsProvider.notifier)
          .setLastPage('charPick', 'c_outfit');
      container
          .read(uiPrefsProvider.notifier)
          .setLastPage('libraryPick', 'codex');
      container.read(codexBlocksProvider.notifier).toggle('book1', ['parent']);
      container.read(codexBlocksProvider.notifier).toggle('book2', ['other']);
      await stores.flushForExit();
      container.dispose();
      final restored = await AppStores.open(
        rootOverride: Directory('${root.path}/prefs'),
      );
      container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(restored)],
      );
      expect(container.read(uiPrefsProvider).galleryBrowseAlbum, 'kept');
      expect(container.read(uiPrefsProvider).lastPages, {
        'charPick': 'c_outfit',
        'libraryPick': 'codex',
      });
      expect(
        container.read(codexBlockProvider('book1')).hides(['parent', 'child']),
        isTrue,
      );
      container.read(codexBlocksProvider.notifier).clear('book1');
      expect(container.read(codexBlockProvider('book2')).active, isTrue);
      await restored.flushForExit();
    },
  );
}
