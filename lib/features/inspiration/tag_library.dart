import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/store/atomic_file.dart';
import 'inspiration_examples.dart';
import 'tag_models.dart';

/// 灵感页本地库状态:全部条目 + 每分类标签池 + 每分类最近使用。
/// 标签池/最近使用对齐 web 的 `tag_pool:<id>` / `usage_order:<id>`(存 50 显 8)。
class TagLibraryState {
  const TagLibraryState({
    this.entries = const [],
    this.pools = const {},
    this.usage = const {},
  });

  final List<TagEntry> entries;
  final Map<TagCategory, List<String>> pools;
  final Map<TagCategory, List<String>> usage;

  List<TagEntry> of(TagCategory c) => [
    for (final e in entries)
      if (e.category == c) e,
  ];

  List<String> poolOf(TagCategory c) => pools[c] ?? const [];

  /// 筛选行可用标签 = 标签池 ∪ 条目在用标签(对齐 web CompactPanel 并集)。
  List<String> knownTags(TagCategory c) {
    final s = <String>{...poolOf(c)};
    for (final e in entries) {
      if (e.category == c) s.addAll(e.tags);
    }
    final out = s.toList()..sort();
    return out;
  }

  TagLibraryState copyWith({
    List<TagEntry>? entries,
    Map<TagCategory, List<String>>? pools,
    Map<TagCategory, List<String>>? usage,
  }) => TagLibraryState(
    entries: entries ?? this.entries,
    pools: pools ?? this.pools,
    usage: usage ?? this.usage,
  );
}

final tagLibraryProvider = AsyncNotifierProvider<TagLibrary, TagLibraryState>(
  TagLibrary.new,
);

/// 本地库:单文件 `<support>/tag_library.json`(条目轻量纯文本,整文件
/// 读写;损坏时回空库)。所有变更先改状态再尽力落盘。
class TagLibrary extends AsyncNotifier<TagLibraryState> {
  late File _file;
  Future<void> _writes = Future.value();

  @override
  Future<TagLibraryState> build() async {
    final sup = await getApplicationSupportDirectory();
    _file = File('${sup.path}/tag_library.json');
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        if (j is Map<String, dynamic>) {
          final loaded = _decode(j);
          debugPrint(
            'Inspiration library: ${loaded.entries.length} entries at ${_file.path}',
          );
          return loaded;
        }
      }
    } catch (error) {
      debugPrint('Inspiration library could not be read: $error');
      // 损坏 → 空库(条目无二进制本体,无从重建)
    }
    debugPrint('Inspiration library: empty at ${_file.path}');
    return const TagLibraryState();
  }

  static TagLibraryState _decode(Map<String, dynamic> j) {
    final entries = <TagEntry>[];
    if (j['entries'] is List) {
      for (final e in j['entries'] as List) {
        if (e is Map<String, dynamic>) {
          if (TagEntry.fromJson(e) case final TagEntry t) entries.add(t);
        }
      }
    }
    Map<TagCategory, List<String>> byCat(Object? m) => {
      if (m is Map)
        for (final en in m.entries)
          if (tagCategoryByWebId(en.key.toString()) case final TagCategory c)
            c: [
              for (final t in (en.value is List ? en.value as List : const []))
                if (t is String) t,
            ],
    };
    return TagLibraryState(
      entries: entries,
      pools: byCat(j['pools']),
      usage: byCat(j['usage']),
    );
  }

  TagLibraryState get _s => state.value ?? const TagLibraryState();

  Future<void> _set(
    TagLibraryState next, {
    bool requirePersistence = false,
  }) async {
    state = AsyncData(next);
    final contents = jsonEncode({
      'version': 1,
      'entries': [for (final e in next.entries) e.toJson()],
      'pools': {
        for (final en in next.pools.entries)
          tagCategoryDef(en.key).webId: en.value,
      },
      'usage': {
        for (final en in next.usage.entries)
          tagCategoryDef(en.key).webId: en.value,
      },
    });
    // Serialize whole-file saves so a slower earlier write cannot erase a later
    // edit. Atomic replacement preserves the last complete library on failure.
    final write = _writes.then((_) => writeStringAtomic(_file, contents));
    _writes = write.catchError((Object error) {
      debugPrint('Inspiration library could not be saved: $error');
    });
    await (requirePersistence ? write : _writes);
  }

  Future<int> addPreviewExamples(TagCategory category) async {
    await future;
    final examples = await loadInspirationExamples(
      category: category,
      existingIds: {for (final e in _s.entries) e.id},
      support: _file.parent,
    );
    final byId = {for (final e in _s.entries) e.id: e};
    var added = 0;
    for (final example in examples) {
      if (byId.containsKey(example.id)) continue;
      byId[example.id] = example;
      added++;
    }
    // Persist even after a previous failed save. Existing edits are retained.
    await _set(
      _s.copyWith(entries: byId.values.toList()),
      requirePersistence: true,
    );
    return added;
  }

  static String newId(TagCategory c) {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = Random().nextInt(36 * 36 * 36).toRadixString(36).padLeft(3, '0');
    return '${tagCategoryDef(c).webId}_${ts}_$r';
  }

  /// 新增或按 id 覆盖(新建/编辑共用,对齐 web saveCustomTag 的 upsert);
  /// 被替换掉的本机预览文件顺带清理。
  Future<void> upsert(TagEntry e) async {
    final list = [..._s.entries];
    final i = list.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      _gcPreviewFiles(list[i].previews, keep: e.previews);
      list[i] = e;
    } else {
      list.add(e);
    }
    await _set(_s.copyWith(entries: list));
  }

  Future<void> remove(String id) async {
    for (final e in _s.entries) {
      if (e.id == id) _gcPreviewFiles(e.previews);
    }
    await _set(
      _s.copyWith(
        entries: [
          for (final e in _s.entries)
            if (e.id != id) e,
        ],
      ),
    );
  }

  /// 编辑器把内存里的预览字节落成文件,返回路径(存进 entry.previews)。
  static Future<String> savePreviewBytes(
    String entryId,
    int index,
    List<int> bytes,
  ) async {
    final sup = await getApplicationSupportDirectory();
    final dir = Directory('${sup.path}/tag_previews');
    await dir.create(recursive: true);
    final safe = entryId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final f = File(
      '${dir.path}/${safe}_${index}_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await f.writeAsBytes(bytes);
    return f.path;
  }

  /// 清空本机预览图(存储管理用):删文件的同时把路径从条目上摘掉 ——
  /// 只删文件会留下一堆指向不存在文件的 previews,卡片永远显示占位块。
  /// 收藏公共条目带来的远端 URL(http 开头)不动,那不是本机产物。
  Future<void> clearLocalPreviews() async {
    final next = <TagEntry>[];
    var touched = false;
    for (final e in _s.entries) {
      final remote = [
        for (final p in e.previews)
          if (p.startsWith('http')) p,
      ];
      if (remote.length == e.previews.length) {
        next.add(e);
        continue;
      }
      _gcPreviewFiles(e.previews);
      touched = true;
      next.add(e.copyWith(previews: remote));
    }
    if (touched) await _set(_s.copyWith(entries: next));
  }

  void _gcPreviewFiles(List<String> old, {List<String> keep = const []}) {
    for (final p in old) {
      if (p.startsWith('http') || keep.contains(p)) continue;
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
  }

  /// 分类内唯一名:重名依次试「x (副本)」「x (副本 2)」…(对齐 web fork)。
  String uniqueName(TagCategory c, String base) {
    final names = {
      for (final e in _s.entries)
        if (e.category == c) e.name,
    };
    if (!names.contains(base)) return base;
    for (var n = 1; ; n++) {
      final candidate = n == 1 ? '$base (副本)' : '$base (副本 $n)';
      if (!names.contains(candidate)) return candidate;
    }
  }

  /// 公共条目是否已收藏(同分类下 publicId 或同名任一命中)。
  bool isCollected(TagCategory c, {String? publicId, required String name}) {
    for (final e in _s.entries) {
      if (e.category != c) continue;
      if (publicId != null && e.publicId == publicId) return true;
      if (e.name == name) return true;
    }
    return false;
  }

  /// 收藏公共条目为本地副本;重复收藏返回 false。
  /// 老数据(同名但没记 publicId)顺手补上归属信息——「按机会迁移」,
  /// 对齐 web,否则去重与「收藏副本只读」判定会漏。
  Future<bool> collect(TagEntry publicEntry) async {
    for (final e in _s.entries) {
      if (e.category != publicEntry.category) continue;
      final hit =
          (publicEntry.publicId != null &&
              e.publicId == publicEntry.publicId) ||
          e.name == publicEntry.name;
      if (!hit) continue;
      if (e.publicId == null && publicEntry.publicId != null) {
        await upsert(
          e.copyWith(
            publicId: publicEntry.publicId,
            origin: TagOrigin.favorited,
          ),
        );
      }
      return false;
    }
    await upsert(
      TagEntry(
        id: 'fav_${DateTime.now().millisecondsSinceEpoch}',
        category: publicEntry.category,
        name: publicEntry.name,
        positive: publicEntry.positive,
        negative: publicEntry.negative,
        aliases: publicEntry.aliases,
        origin: TagOrigin.favorited,
        publicId: publicEntry.publicId,
        previews: publicEntry.previews,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        createdBy: publicEntry.createdBy,
      ),
    );
    return true;
  }

  // ---- 标签池 ----

  Future<bool> addPoolTag(TagCategory c, String tag) async {
    final t = tag.trim();
    if (t.isEmpty || _s.knownTags(c).contains(t)) return false;
    await _set(
      _s.copyWith(
        pools: {
          ..._s.pools,
          c: [..._s.poolOf(c), t]..sort(),
        },
      ),
    );
    return true;
  }

  /// 删池中标签,并从该分类所有条目上剥离(对齐 web handleSavePool)。
  Future<void> removePoolTag(TagCategory c, String tag) async {
    await _set(
      _s.copyWith(
        pools: {
          ..._s.pools,
          c: [
            for (final t in _s.poolOf(c))
              if (t != tag) t,
          ],
        },
        entries: [
          for (final e in _s.entries)
            e.category == c && e.tags.contains(tag)
                ? e.copyWith(
                    tags: [
                      for (final t in e.tags)
                        if (t != tag) t,
                    ],
                  )
                : e,
        ],
      ),
    );
  }

  int poolTagUsage(TagCategory c, String tag) {
    var n = 0;
    for (final e in _s.entries) {
      if (e.category == c && e.tags.contains(tag)) n++;
    }
    return n;
  }

  // ---- 最近使用(确认插入时记,前插去重截 50,对齐 web) ----

  Future<void> markUsed(TagCategory c, List<String> ids) async {
    final old = _s.usage[c] ?? const <String>[];
    final next = [
      ...ids,
      for (final id in old)
        if (!ids.contains(id)) id,
    ];
    await _set(_s.copyWith(usage: {..._s.usage, c: next.take(50).toList()}));
  }

  // ---- 云备份 ----

  /// 打包四类条目(web /api/user-tag-backup 的 categories 形状)。
  Map<String, List<Map<String, dynamic>>> encodeBackup() => {
    for (final d in kTagCategoryDefs) d.webId: encodeCategory(d.key),
  };

  /// 单分类条目打包(本地 JSON 导出用)。
  List<Map<String, dynamic>> encodeCategory(TagCategory c) => [
    for (final e in _s.entries)
      if (e.category == c) encodeBackupEntry(e),
  ];

  /// 恢复前预检:按 id 数出「覆盖 / 新增」(与 web 的冲突提示一致)。
  ({int overwrite, int add}) previewMerge(Map<String, dynamic> categories) {
    final localIds = {for (final e in _s.entries) e.id};
    var overwrite = 0, add = 0;
    for (final d in kTagCategoryDefs) {
      final raw = categories[d.webId];
      if (raw is! List) continue;
      for (final item in raw) {
        if (item is! Map || item['id'] is! String) continue;
        localIds.contains(item['id']) ? overwrite++ : add++;
      }
    }
    return (overwrite: overwrite, add: add);
  }

  /// 恢复:按 id 合并(同 id 覆盖、新 id 追加,本地独有保留)。
  /// 返回每类的 (新增, 覆盖) 明细,供结果文案与日志使用。
  Future<Map<TagCategory, ({int added, int updated})>> mergeBackup(
    Map<String, dynamic> categories,
  ) async {
    final byId = {for (final e in _s.entries) e.id: e};
    final localIds = {...byId.keys};
    final stat = <TagCategory, ({int added, int updated})>{};
    for (final d in kTagCategoryDefs) {
      final raw = categories[d.webId];
      if (raw is! List) continue;
      var added = 0, updated = 0;
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        final e = decodeBackupEntry(d.key, item);
        if (e == null) continue;
        localIds.contains(e.id) ? updated++ : added++;
        byId[e.id] = e;
      }
      if (added + updated > 0) {
        stat[d.key] = (added: added, updated: updated);
      }
    }
    await _set(_s.copyWith(entries: byId.values.toList()));
    return stat;
  }
}
