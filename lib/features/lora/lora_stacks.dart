import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/store/app_stores.dart';

import '../../core/net/backend_client.dart';
import '../../core/store/atomic_file.dart';
import '../generate/models.dart';

/// LoRA 堆:一组已挂 LoRA 连同各自的权重 / CLIP / 启停存成预设,整组挂回。
///
/// 按底模分开(anima / krea 的库互不通用,堆里的 LR 编号换了底模就查无此条),
/// 列表与同名覆盖都只在同一个 [LoraStack.base] 里算。
///
/// 只存编号和参数,不存触发词:应用时按编号去当前库现查触发词 / 预览 / hasTe。
/// 展示名也存一份,库里查不到时用来说明缺的是哪个。
///
/// 存档格式与网页端 `novelai_lora_stacks` 相同(JSON 数组、同名字段)。

/// 堆名长度上限。
const kLoraStackNameMax = 40;

class LoraStackEntry {
  const LoraStackEntry({
    required this.name,
    required this.displayName,
    required this.weight,
    this.clipWeight,
    this.enabled = true,
    this.previewUrl = '',
    this.type = 'concept',
  });

  /// LR 编号。
  final String name;
  final String displayName;
  final double weight;

  /// null = 跟随 [weight](同 [ActiveLora.clipWeight])。
  final double? clipWeight;
  final bool enabled;
  final String previewUrl;
  final String type;

  String get label => displayName.isNotEmpty ? displayName : name;

  Map<String, dynamic> toJson() => {
    'name': name,
    'display_name': displayName,
    'weight': weight,
    'clip_weight': ?clipWeight,
    'enabled': enabled,
    if (previewUrl.isNotEmpty) 'preview_url': previewUrl,
    'type': type,
  };

  /// [clipFollow] 为真时整堆跟随权重,条目里的 clip_weight 不生效。
  static LoraStackEntry? fromJson(Object? raw, {required bool clipFollow}) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString() ?? '';
    if (name.isEmpty) return null;
    final clip = raw['clip_weight'];
    return LoraStackEntry(
      name: name,
      displayName: raw['display_name']?.toString() ?? '',
      weight: (raw['weight'] as num?)?.toDouble() ?? 0.8,
      clipWeight: !clipFollow && clip is num ? clip.toDouble() : null,
      enabled: raw['enabled'] != false,
      previewUrl: raw['preview_url']?.toString() ?? '',
      type: raw['type']?.toString() ?? 'concept',
    );
  }
}

class LoraStack {
  const LoraStack({
    required this.id,
    required this.name,
    required this.base,
    required this.loras,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;

  /// `anima` / `krea`,见 [loraBaseOf]。
  final String base;
  final List<LoraStackEntry> loras;
  final int createdAt;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'base': base,
    'loras': [for (final e in loras) e.toJson()],
    // 网页端的整堆开关:关着时各条的 clip_weight 才生效
    'clipFollow': !loras.any((e) => e.clipWeight != null),
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  static LoraStack? fromJson(Object? raw) {
    if (raw is! Map || raw['loras'] is! List) return null;
    final id = raw['id']?.toString() ?? '';
    final name = raw['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    final clipFollow = raw['clipFollow'] != false;
    final now = DateTime.now().millisecondsSinceEpoch;
    return LoraStack(
      id: id,
      name: name,
      base: raw['base']?.toString() ?? 'anima',
      loras: [
        for (final e in raw['loras'] as List)
          ?LoraStackEntry.fromJson(e, clipFollow: clipFollow),
      ],
      createdAt: (raw['createdAt'] as num?)?.toInt() ?? now,
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? now,
    );
  }
}

/// 已挂列表 → 堆条目。下载中 / 下载失败的占位条没有真编号,不进堆。
List<LoraStackEntry> stackEntriesFromActive(List<ActiveLora> loras) => [
  for (final l in loras)
    if (l.pending == null)
      LoraStackEntry(
        name: l.name,
        displayName: l.displayName,
        weight: l.weight,
        clipWeight: l.clipWeight,
        enabled: l.enabled,
        previewUrl: l.previewUrl,
        type: l.type,
      ),
];

/// 保存弹窗的默认名:各条展示名用「 + 」连起来,超长截断。
String defaultLoraStackName(List<ActiveLora> loras) {
  final joined = [
    for (final l in loras)
      if (l.pending == null && l.displayName.isNotEmpty) l.displayName,
  ].join(' + ');
  return joined.length > kLoraStackNameMax
      ? '${joined.substring(0, kLoraStackNameMax - 1)}…'
      : joined;
}

/// 按当前库把堆还原成可挂载的 [ActiveLora]。
/// [missing] = 库里查不到(被移出 / 回收 / 别的账号的私有条目);
/// [notReady] = 还在推送或推送失败。两类都跳过,返回展示名给调用方提示。
({List<ActiveLora> loras, List<String> missing, List<String> notReady})
resolveLoraStack(LoraStack stack, List<LoraCardInfo> library) {
  final byId = {for (final l in library) l.name: l};
  final loras = <ActiveLora>[];
  final missing = <String>[];
  final notReady = <String>[];
  for (final e in stack.loras) {
    final item = byId[e.name];
    if (item == null) {
      missing.add(e.label);
      continue;
    }
    if (!item.ready) {
      notReady.add(item.displayName);
      continue;
    }
    loras.add(
      ActiveLora(
        name: item.name,
        displayName: item.displayName,
        weight: e.weight,
        clipWeight: e.clipWeight,
        enabled: e.enabled,
        hasTe: item.hasTe,
        triggerWords: item.triggerWords,
        previewUrl: item.previewUrl,
        type: item.type,
      ),
    );
  }
  return (loras: loras, missing: missing, notReady: notReady);
}

/// 全部 LoRA 堆(两个底模都在里面,用的时候按 base 筛),新存的在前。
final loraStacksProvider =
    AsyncNotifierProvider<LoraStacksNotifier, List<LoraStack>>(
      LoraStacksNotifier.new,
    );

/// Owned by AppStores so retries and application exit await the same queue.
class LoraStackStore {
  LoraStackStore(Directory root, {this.onSaveError})
    : _file = File('${root.path}/lora_stacks.json');
  final File _file;
  final void Function(Object)? onSaveError;
  Future<void> _chain = Future.value();
  List<LoraStack>? _items;
  List<LoraStack>? get loaded => _items;
  bool _dirty = false;
  Object? _error;
  int _seq = 0;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _chain.then((_) => action());
    _chain = task.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        if (_dirty) _error = e;
        onSaveError?.call(e);
      },
    );
    return task;
  }

  Future<List<LoraStack>> load() => _enqueue(_load);
  Future<List<LoraStack>> _load() async {
    if (_items != null) return _items!;
    if (!await _file.exists()) return _items = const [];
    final raw = jsonDecode(await _file.readAsString());
    if (raw is! List) throw const FormatException('LoRA 组合文件格式无效');
    final seen = <String>{};
    final out = <LoraStack>[];
    for (final e in raw) {
      final stack = LoraStack.fromJson(e);
      if (stack == null) throw const FormatException('LoRA 组合条目无效');
      if (seen.add(stack.id)) out.add(stack);
    }
    _error = null;
    return _items = List.unmodifiable(out);
  }

  Future<void> _commit(List<LoraStack> next) async {
    _items = List.unmodifiable(next);
    _dirty = true;
    await _persist();
  }

  Future<void> _persist() async {
    if (!_dirty) return;
    await writeStringAtomic(
      _file,
      jsonEncode([for (final s in _items!) s.toJson()]),
    );
    _dirty = false;
    _error = null;
  }

  void flush() {
    unawaited(_enqueue(_persist).catchError((Object _) {}));
  }

  Future<void> get idle async {
    await _chain;
    if (_error case final e?) throw e;
  }

  LoraStack? findByName(List<LoraStack> all, String base, String name) {
    final n = name.trim();
    return all.where((s) => s.base == base && s.name == n).firstOrNull;
  }

  /// 保存;同底模下同名的直接覆盖(保留原 id 与创建时间,位置不动)。
  Future<({LoraStack stack, bool replaced})> save({
    required String name,
    required String base,
    required List<LoraStackEntry> loras,
  }) => _enqueue(() async {
    await _load();
    final all = _items!;
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.length > kLoraStackNameMax ||
        !const {'anima', 'krea'}.contains(base) ||
        loras.isEmpty) {
      throw ArgumentError('无效的 LoRA 组合');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = findByName(all, base, trimmed);
    if (old != null) {
      final stack = LoraStack(
        id: old.id,
        name: old.name,
        base: base,
        loras: loras,
        createdAt: old.createdAt,
        updatedAt: now,
      );
      await _commit([for (final s in all) s.id == old.id ? stack : s]);
      return (stack: stack, replaced: true);
    }
    final stack = LoraStack(
      id: 'ls_${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      name: trimmed,
      base: base,
      loras: loras,
      createdAt: now,
      updatedAt: now,
    );
    await _commit([stack, ...all]);
    return (stack: stack, replaced: false);
  });

  /// 删除,返回原位置(撤销用);没找到返回 -1。
  Future<int> remove(String id) => _enqueue(() async {
    await _load();
    final all = _items!;
    final i = all.indexWhere((s) => s.id == id);
    if (i < 0) return -1;
    await _commit([...all]..removeAt(i));
    return i;
  });

  /// 撤销删除:放回原位置。同 id 已存在则不动。
  Future<void> restore(LoraStack stack, int index) => _enqueue(() async {
    await _load();
    final all = _items!;
    if (all.any(
      (s) => s.id == stack.id || (s.base == stack.base && s.name == stack.name),
    )) {
      return;
    }
    await _commit([...all]..insert(index.clamp(0, all.length), stack));
  });
}

class LoraStacksNotifier extends AsyncNotifier<List<LoraStack>> {
  LoraStackStore get _store => ref.read(appStoresProvider).loraStacks;
  @override
  Future<List<LoraStack>> build() => _store.load();

  LoraStack? findByName(List<LoraStack> all, String base, String name) =>
      _store.findByName(all, base, name);

  Future<T> _change<T>(Future<T> Function(LoraStackStore store) action) async {
    final store = _store;
    try {
      return await action(store);
    } finally {
      if (ref.mounted && store.loaded != null) state = AsyncData(store.loaded!);
    }
  }

  Future<({LoraStack stack, bool replaced})> save({
    required String name,
    required String base,
    required List<LoraStackEntry> loras,
  }) => _change((s) => s.save(name: name, base: base, loras: loras));
  Future<int> remove(String id) => _change((s) => s.remove(id));
  Future<void> restore(LoraStack stack, int index) =>
      _change((s) => s.restore(stack, index));
}
