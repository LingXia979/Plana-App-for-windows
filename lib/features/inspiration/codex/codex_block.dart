import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import 'codex_models.dart';

/// 法典分类屏蔽:被屏蔽分类下的词条不进瀑布流、随机、搜索与详情翻页。
/// 存本机设置(键 `codex_blocks`),每部法典各记一份。

/// 一部法典的屏蔽状态。
class CodexBlock {
  const CodexBlock({this.paths = const []});

  /// 已屏蔽的分类路径;屏蔽父级即含全部子级。
  final List<List<String>> paths;

  bool get active => paths.isNotEmpty;

  /// 这条路径本身是否在屏蔽表里。
  bool contains(List<String> path) => paths.any((b) => _samePath(b, path));

  /// [path](词条或分类)是否落在某个已屏蔽分类下。
  bool hides(List<String> path) => paths.any((b) => codexPathUnder(path, b));

  Map<String, dynamic> toJson() => {'paths': paths};

  static CodexBlock fromJson(Object? j) {
    if (j is! Map) return const CodexBlock();
    return CodexBlock(
      paths: [
        if (j['paths'] case final List ps)
          for (final p in ps)
            if (p is List && p.isNotEmpty && p.every((s) => s is String))
              List<String>.from(p),
      ],
    );
  }
}

bool _samePath(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _key = 'codex_blocks';

final codexBlocksProvider =
    NotifierProvider<CodexBlocksNotifier, Map<String, CodexBlock>>(
      CodexBlocksNotifier.new,
    );

/// 一部法典的屏蔽状态。
final codexBlockProvider = Provider.family<CodexBlock, String>(
  (ref, id) => ref.watch(codexBlocksProvider)[id] ?? const CodexBlock(),
);

class CodexBlocksNotifier extends Notifier<Map<String, CodexBlock>> {
  @override
  Map<String, CodexBlock> build() {
    try {
      final raw = ref.read(prefsStoreProvider).get(_key);
      if (raw == null || raw.isEmpty) return const {};
      final j = jsonDecode(raw);
      if (j is! Map) return const {};
      return {
        for (final e in j.entries)
          if (e.key is String) e.key as String: CodexBlock.fromJson(e.value),
      };
    } catch (_) {
      return const {};
    }
  }

  CodexBlock _of(String id) => state[id] ?? const CodexBlock();

  void _put(String id, CodexBlock b) {
    state = {...state, id: b};
    try {
      ref
          .read(prefsStoreProvider)
          .write(
            key: _key,
            value: jsonEncode({
              for (final e in state.entries) e.key: e.value.toJson(),
            }),
          );
    } catch (_) {}
  }

  /// 屏蔽 / 解除一个分类。
  void toggle(String id, List<String> path) {
    if (path.isEmpty) return;
    final cur = _of(id);
    _put(
      id,
      CodexBlock(
        paths: cur.contains(path)
            ? [
                for (final p in cur.paths)
                  if (!_samePath(p, path)) p,
              ]
            : [...cur.paths, List<String>.unmodifiable(path)],
      ),
    );
  }

  /// 解除这部法典的全部屏蔽。
  void clear(String id) => _put(id, const CodexBlock());
}
