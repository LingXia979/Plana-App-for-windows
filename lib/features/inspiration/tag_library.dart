import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/store/atomic_file.dart';
import '../migrate/web_backup.dart' show decodeDataUrl;
import 'inspiration_examples.dart';
import 'tag_models.dart';

/// 页签顺序 / 隐藏里法典的键(其余是各分类的 webId)。
const kCodexTabKey = 'codex';

/// 能删的内置类别(删了只是不出页签、条目一并清掉;同名新建即恢复)。
const kRemovableBuiltins = {'scene', 'other'};

/// 灵感页本地库状态:全部条目 + 每分类标签池 + 每分类最近使用 + 自定义类别
/// 与页签的排列。标签池/最近使用对齐 web 的 `tag_pool:<id>` / `usage_order:<id>`
/// (存 50 显 8)。
class TagLibraryState {
  const TagLibraryState({
    this.entries = const [],
    this.pools = const {},
    this.usage = const {},
    this.customDefs = const [],
    this.order = const [],
    this.hidden = const {},
    this.labels = const {},
  });

  final List<TagEntry> entries;
  final Map<TagCategory, List<String>> pools;
  final Map<TagCategory, List<String>> usage;

  /// 自定义类别,按创建先后。
  final List<TagCategoryDef> customDefs;

  /// 页签顺序(webId / [kCodexTabKey]);没列到的按默认顺序排在后面。
  final List<String> order;

  /// 删掉的内置类别(只认 [kRemovableBuiltins] 里的)。
  final Set<String> hidden;

  /// 内置类别(含法典)改过的名字:webId / [kCodexTabKey] → 新名字。
  final Map<String, String> labels;

  bool isRemoved(String key) =>
      kRemovableBuiltins.contains(key) && hidden.contains(key);

  /// 全部页签,含藏起来的:内置四类 → 自定义 → 法典 的默认顺序,再按 [order] 重排。
  List<String> get tabKeys {
    final all = [
      for (final d in kTagCategoryDefs) d.webId,
      for (final d in customDefs) d.webId,
      kCodexTabKey,
    ];
    return [
      for (final k in order.toSet())
        if (all.contains(k)) k,
      for (final k in all)
        if (!order.contains(k)) k,
    ];
  }

  /// 顶栏上要显示的页签(删掉的内置类别不出)。
  List<String> get visibleTabKeys => [
    for (final k in tabKeys)
      if (!isRemoved(k)) k,
  ];

  List<TagEntry> of(TagCategory c) => [
    for (final e in entries)
      if (e.category == c) e,
  ];

  List<String> poolOf(TagCategory c) => pools[c] ?? const [];

  /// 筛选行可用标签 = 标签池 ∪ 条目在用标签(对齐 web CompactPanel 并集)。
  /// 池里的按池的顺序,只挂在条目上、不在池里的按字母序排在后面。
  List<String> knownTags(TagCategory c) {
    final pool = <String>{...poolOf(c)};
    final extra = <String>{};
    for (final e in entries) {
      if (e.category != c) continue;
      for (final t in e.tags) {
        if (!pool.contains(t)) extra.add(t);
      }
    }
    return [...pool, ...(extra.toList()..sort())];
  }

  TagLibraryState copyWith({
    List<TagEntry>? entries,
    Map<TagCategory, List<String>>? pools,
    Map<TagCategory, List<String>>? usage,
    List<TagCategoryDef>? customDefs,
    List<String>? order,
    Set<String>? hidden,
    Map<String, String>? labels,
  }) => TagLibraryState(
    entries: entries ?? this.entries,
    pools: pools ?? this.pools,
    usage: usage ?? this.usage,
    customDefs: customDefs ?? this.customDefs,
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    labels: labels ?? this.labels,
  );

  /// 云备份 / 落盘里的 `custom` 块(条目另算)。
  Map<String, dynamic> layoutJson() => {
    'defs': [
      for (final d in customDefs) d.toJson(),
      // 内置类别的改名也放这儿(id 是内置的 webId),后端原样存
      for (final e in labels.entries) {'id': e.key, 'label': e.value},
    ],
    'order': order,
    'hidden': hidden.toList(),
  };
}

final tagLibraryProvider = AsyncNotifierProvider<TagLibrary, TagLibraryState>(
  TagLibrary.new,
);

/// 本地库:单文件 `<support>/tag_library.json`(条目轻量纯文本,整文件
/// 读写;损坏时回空库)。所有变更先改状态再尽力落盘。
class TagLibrary extends AsyncNotifier<TagLibraryState> {
  late File _file;
  Future<void> _writes = Future.value();

  /// 最近一次落盘写完(成功与否都算写完)。
  ///
  /// 变更先改状态、再排队落盘,所以「状态里有了」不等于「盘上有了」。测试等
  /// 这一步:等固定时长在慢盘上必翻车(见 desktop_profile_inspiration_test)。
  Future<void> get settled => _writes;

  @override
  Future<TagLibraryState> build() async {
    final sup = await getApplicationSupportDirectory();
    _file = File('${sup.path}/tag_library.json');
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        if (j is Map<String, dynamic>) {
          final loaded = _recoverCategories(_decode(j));
          syncCustomTagCategories(loaded.customDefs, labels: loaded.labels);
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
    syncCustomTagCategories(const []);
    debugPrint('Inspiration library: empty at ${_file.path}');
    return const TagLibraryState();
  }

  static List<String> _strs(Object? v) => [
    if (v is List)
      for (final x in v)
        if (x is String) x,
  ];

  /// 内置类别(含法典)的改名:defs 里 id 不是 `c_` 开头的那些。
  static Map<String, String> _labelsOf(Object? v) => {
    if (v is List)
      for (final x in v)
        if (x is Map &&
            x['id'] is String &&
            x['label'] is String &&
            (x['id'] == kCodexTabKey ||
                kTagCategoryDefs.any((d) => d.webId == x['id'])))
          x['id'] as String: x['label'] as String,
  };

  static List<TagCategoryDef> _defs(Object? v) => {
    if (v is List)
      for (final x in v)
        if (TagCategoryDef.fromJson(x) case final TagCategoryDef d) d.webId: d,
  }.values.toList();

  static TagLibraryState _recoverCategories(TagLibraryState s) {
    final defs = {for (final d in s.customDefs) d.webId: d};
    for (final e in s.entries) {
      if (!e.category.isCustom) continue;
      defs.putIfAbsent(
        e.category.name,
        () => TagCategoryDef.custom(
          id: e.category.name,
          label: e.category.name,
          iconName: 'Tag',
          layout: TagCardLayout.square,
        ),
      );
    }
    return s.copyWith(
      customDefs: defs.values.toList(),
      hidden: s.hidden
          .where(
            (key) =>
                kRemovableBuiltins.contains(key) &&
                !s.entries.any((e) => tagCategoryByWebId(key) == e.category),
          )
          .toSet(),
    );
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
    final layout = j['categories'] is Map ? j['categories'] as Map : const {};
    return TagLibraryState(
      entries: entries,
      pools: byCat(j['pools']),
      usage: byCat(j['usage']),
      customDefs: _defs(layout['defs']),
      order: _strs(layout['order']),
      hidden: _strs(layout['hidden']).toSet(),
      labels: _labelsOf(layout['defs']),
    );
  }

  TagLibraryState get _s => state.value ?? const TagLibraryState();

  Future<void> _set(
    TagLibraryState next, {
    bool requirePersistence = false,
  }) async {
    syncCustomTagCategories(next.customDefs, labels: next.labels);
    state = AsyncData(next);
    final contents = jsonEncode({
      'version': 1,
      'categories': next.layoutJson(),
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
    final nonce = Random().nextInt(0x100000000).toRadixString(16);
    final f = File(
      '${dir.path}/${safe}_${index}_${DateTime.now().microsecondsSinceEpoch}_$nonce.jpg',
    );
    try {
      await f.writeAsBytes(bytes, flush: true);
    } catch (_) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      rethrow;
    }
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
        models: publicEntry.models,
        recipe: publicEntry.recipe,
        origin: TagOrigin.favorited,
        publicId: publicEntry.publicId,
        previews: publicEntry.previews,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        createdBy: publicEntry.createdBy,
      ),
    );
    return true;
  }

  // ---- 自定义类别 / 页签排列 ----

  /// 新建类别,返回它。
  Future<TagCategoryDef> addCategory({
    required String label,
    required String iconName,
    required TagCardLayout layout,
  }) async {
    await future;
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = Random().nextInt(36 * 36 * 36).toRadixString(36).padLeft(3, '0');
    final def = TagCategoryDef.custom(
      id: '${TagCategory.customPrefix}${ts}_$r',
      label: label,
      iconName: iconName,
      layout: layout,
    );
    await _set(_s.copyWith(customDefs: [..._s.customDefs, def]));
    return def;
  }

  Future<void> updateCategory(TagCategoryDef def) async {
    await future;
    await _set(
      _s.copyWith(
        customDefs: [
          for (final d in _s.customDefs) d.webId == def.webId ? def : d,
        ],
      ),
    );
  }

  /// 删类别,连同它的条目、标签池与最近使用。
  Future<void> removeCategory(TagCategory c) async {
    if (!c.isCustom) return;
    await future;
    for (final e in _s.entries) {
      if (e.category == c) _gcPreviewFiles(e.previews);
    }
    await _set(
      _s.copyWith(
        customDefs: [
          for (final d in _s.customDefs)
            if (d.key != c) d,
        ],
        entries: [
          for (final e in _s.entries)
            if (e.category != c) e,
        ],
        pools: {..._s.pools}..remove(c),
        usage: {..._s.usage}..remove(c),
        order: [
          for (final k in _s.order)
            if (k != c.name) k,
        ],
        hidden: {..._s.hidden}..remove(c.name),
      ),
    );
  }

  /// 内置类别(含法典)改名;[label] 为空或等于原名 = 改回原名。
  Future<void> renameBuiltin(String key, String label) async {
    await future;
    final orig = key == kCodexTabKey
        ? '法典'
        : kTagCategoryDefs.firstWhere((d) => d.webId == key).label;
    final next = {..._s.labels};
    if (label.trim().isEmpty || label.trim() == orig) {
      next.remove(key);
    } else {
      next[key] = label.trim();
    }
    await _set(_s.copyWith(labels: next));
  }

  /// 删掉场景 / 其他:不出页签,条目、标签池、最近使用与改名一并清掉。
  Future<void> removeBuiltin(TagCategory c) async {
    final key = tagCategoryDef(c).webId;
    if (!kRemovableBuiltins.contains(key)) return;
    await future;
    for (final e in _s.entries) {
      if (e.category == c) _gcPreviewFiles(e.previews);
    }
    await _set(
      _s.copyWith(
        entries: [
          for (final e in _s.entries)
            if (e.category != c) e,
        ],
        pools: {..._s.pools}..remove(c),
        usage: {..._s.usage}..remove(c),
        hidden: {..._s.hidden, key},
        labels: {..._s.labels}..remove(key),
      ),
    );
  }

  /// 把删掉的场景 / 其他加回来(空的)。
  Future<void> restoreBuiltin(String key) async {
    await future;
    await _set(_s.copyWith(hidden: {..._s.hidden}..remove(key)));
  }

  /// 调整页签顺序([from] / [to] 是 [TagLibraryState.visibleTabKeys] 里的下标,
  /// [to] 已按移走 [from] 后的列表算)。
  Future<void> moveTab(int from, int to) async {
    await future;
    final list = _s.visibleTabKeys;
    list.insert(to, list.removeAt(from));
    await _set(
      _s.copyWith(
        order: [
          ...list,
          for (final k in _s.tabKeys)
            if (_s.isRemoved(k)) k,
        ],
      ),
    );
  }

  // ---- 标签池 ----

  Future<bool> addPoolTag(TagCategory c, String tag) async {
    final t = tag.trim();
    if (t.isEmpty || _s.knownTags(c).contains(t)) return false;
    await _set(
      _s.copyWith(
        pools: {
          ..._s.pools,
          c: [..._s.poolOf(c), t],
        },
      ),
    );
    return true;
  }

  /// 调整标签顺序([from] / [to] 是 [TagLibraryState.knownTags] 里的下标,
  /// [to] 已按移走 [from] 后的列表算)。不在池里的标签一并按新顺序写进池。
  Future<void> movePoolTag(TagCategory c, int from, int to) async {
    final list = _s.knownTags(c);
    list.insert(to, list.removeAt(from));
    await _set(_s.copyWith(pools: {..._s.pools, c: list}));
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

  /// 自定义类别那一块(云备份的 `custom`):定义、页签排列 + 各类条目。
  Map<String, dynamic> encodeCustom() => {
    ..._s.layoutJson(),
    'items': {for (final d in _s.customDefs) d.webId: encodeCategory(d.key)},
  };

  /// 单分类条目打包(本地 JSON 导出用)。
  List<Map<String, dynamic>> encodeCategory(TagCategory c) => [
    for (final e in _s.entries)
      if (e.category == c) encodeBackupEntry(e),
  ];

  /// 四类 + 自定义类别的条目摊成一张 webId → 原始条目表。[categories] 里也可以
  /// 直接放自定义类别的键(单类 JSON 导入)。
  static Map<String, dynamic> _flat(
    Map<String, dynamic> categories,
    Map<String, dynamic>? custom,
  ) => {
    for (final d in kTagCategoryDefs)
      if (categories[d.webId] case final List l) d.webId: l,
    for (final e in categories.entries)
      if (e.key.startsWith(TagCategory.customPrefix) && e.value is List)
        e.key: e.value,
    if (custom?['items'] case final Map items)
      for (final e in items.entries)
        if (e.key is String &&
            (e.key as String).startsWith(TagCategory.customPrefix) &&
            e.value is List)
          e.key as String: e.value,
  };

  /// 恢复前预检:按 id 数出「覆盖 / 新增」(与 web 的冲突提示一致)。
  ({int overwrite, int add}) previewMerge(
    Map<String, dynamic> categories, {
    Map<String, dynamic>? custom,
  }) {
    final localIds = {for (final e in _s.entries) e.id};
    var overwrite = 0, add = 0;
    for (final raw in _flat(categories, custom).values) {
      for (final item in raw as List) {
        if (item is! Map || item['id'] is! String) continue;
        localIds.contains(item['id']) ? overwrite++ : add++;
      }
    }
    return (overwrite: overwrite, add: add);
  }

  /// 恢复:按 id 合并(同 id 覆盖、新 id 追加,本地独有保留)。自定义类别的
  /// 定义同 id 以云端为准、本地独有的保留;页签排列用云端的。
  /// 内嵌预览先写入本机；未附带图片的备份保留该条目现有的本机预览。
  /// 返回每类的 (新增, 覆盖) 明细,供结果文案与日志使用。
  Future<Map<TagCategory, ({int added, int updated})>> mergeBackup(
    Map<String, dynamic> categories, {
    Map<String, dynamic>? custom,
  }) async {
    await future;
    final localIds = {for (final e in _s.entries) e.id};
    final restored = <String, TagEntry>{};
    final created = <String>[];
    final stat = <TagCategory, ({int added, int updated})>{};
    try {
      for (final en in _flat(categories, custom).entries) {
        final cat = tagCategoryByWebId(en.key);
        if (cat == null) continue;
        var added = 0, updated = 0;
        for (final item in en.value as List) {
          if (item is! Map<String, dynamic>) continue;
          final e = decodeBackupEntry(cat, item);
          if (e == null) continue;
          localIds.contains(e.id) ? updated++ : added++;
          final old =
              restored[e.id] ??
              _s.entries.where((entry) => entry.id == e.id).firstOrNull;
          restored[e.id] = e.copyWith(
            previews: await _restorePreviews(item, e.id, old, created),
          );
        }
        if (added + updated > 0) {
          stat[cat] = (added: added, updated: updated);
        }
      }
    } catch (_) {
      _gcPreviewFiles(
        created,
        keep: [for (final e in _s.entries) ...e.previews],
      );
      rethrow;
    }
    // 图片写入期间允许其他条目发生编辑；合并到最新状态，不用旧快照覆盖它们。
    final replaced = [
      ...created,
      for (final e in _s.entries)
        if (restored.containsKey(e.id)) ...e.previews,
    ];
    final byId = {for (final e in _s.entries) e.id: e, ...restored};
    var next = _s.copyWith(entries: byId.values.toList());
    if (custom != null) {
      final cloud = _defs(custom['defs']);
      final cloudIds = {for (final d in cloud) d.webId};
      next = next.copyWith(
        customDefs: [
          ...cloud,
          for (final d in _s.customDefs)
            if (!cloudIds.contains(d.webId)) d,
        ],
        order: custom.containsKey('order') ? _strs(custom['order']) : _s.order,
        hidden: custom.containsKey('hidden')
            ? _strs(custom['hidden']).toSet()
            : _s.hidden,
        labels: {..._s.labels, ..._labelsOf(custom['defs'])},
      );
    }
    // 索引写入失败时保留新旧图片，明确报错，避免磁盘上的旧索引引用失效。
    await _set(_recoverCategories(next), requirePersistence: true);
    _gcPreviewFiles(
      replaced,
      keep: [for (final e in _s.entries) ...e.previews],
    );
    return stat;
  }

  static Future<List<String>> _restorePreviews(
    Map<String, dynamic> item,
    String id,
    TagEntry? local,
    List<String> created,
  ) async {
    final out = <String>[];
    final seen = <String>{};
    var embedded = false;
    for (final p in [
      item['preview'],
      if (item['previews'] case final List list) ...list,
    ]) {
      if (p is! String || p.isEmpty || !seen.add(p)) continue;
      if (p.startsWith('data:')) {
        final bytes = decodeDataUrl(p);
        if (bytes == null || bytes.isEmpty) continue;
        final path = await savePreviewBytes(id, out.length, bytes);
        created.add(path);
        out.add(path);
        embedded = true;
      } else {
        final uri = Uri.tryParse(p);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty) {
          out.add(p);
        }
      }
    }
    if (embedded || local == null) return out;
    // 备份不会携带另一台电脑的本地路径；本机已有预览按原顺序保留。
    return <String>{
      for (final p in local.previews)
        if (!p.startsWith('http') || out.contains(p)) p,
      ...out,
    }.toList();
  }
}
