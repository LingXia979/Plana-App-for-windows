import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import 'suggestions.dart' show metaKey;

/// 编辑器的标签收藏(底栏托盘里的快捷栏)。存标签名,新收的在前;
/// 大小写、下划线 / 空格写法不同的同一标签算一枚(见 [metaKey])。
/// 默认带 [TagFavoritesNotifier.defaults] 里的几枚。
final tagFavoritesProvider =
    NotifierProvider<TagFavoritesNotifier, List<String>>(
      TagFavoritesNotifier.new,
    );

/// 收藏的规范键集合:词条栏每换一枚标签都要问「收了没」。
final tagFavoriteKeysProvider = Provider<Set<String>>(
  (ref) => {for (final t in ref.watch(tagFavoritesProvider)) metaKey(t)},
);

class TagFavoritesNotifier extends Notifier<List<String>> {
  static const _key = 'editor_tag_favorites';

  /// 默认收藏只补一次:收藏表落过盘就记上这个标记,用户删掉的不再补回来。
  static const _seededKey = 'editor_tag_favorites_seeded';

  static const defaults = ['fur dataset', 'transparent background'];

  @override
  List<String> build() {
    final prefs = ref.read(prefsStoreProvider);
    final saved = _decode(prefs.get(_key));
    if (prefs.get(_seededKey) != null) return saved;
    final keys = {for (final t in saved) metaKey(t)};
    return [
      ...saved,
      for (final d in defaults)
        if (!keys.contains(metaKey(d))) d,
    ];
  }

  static List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return [
        for (final t in j)
          if (t is String && t.trim().isNotEmpty) t,
      ];
    } catch (_) {
      return const [];
    }
  }

  int _indexOf(String tag) {
    final k = metaKey(tag);
    return state.indexWhere((t) => metaKey(t) == k);
  }

  bool contains(String tag) => _indexOf(tag) >= 0;

  /// 收 / 取消收藏。
  void toggle(String tag) {
    final name = tag.trim();
    if (name.isEmpty) return;
    final i = _indexOf(name);
    _save(i >= 0 ? ([...state]..removeAt(i)) : [name, ...state]);
  }

  /// 移出收藏,返回原位置(撤销时放回去);不在收藏里返回 -1。
  int remove(String tag) {
    final i = _indexOf(tag);
    if (i >= 0) _save([...state]..removeAt(i));
    return i;
  }

  /// 撤销移除:放回原位置。
  void restore(String tag, int index) {
    if (contains(tag)) return;
    _save([...state]..insert(index.clamp(0, state.length), tag));
  }

  /// 先改状态(界面立刻响应),再落盘。
  void _save(List<String> next) {
    state = next;
    final prefs = ref.read(prefsStoreProvider);
    unawaited(prefs.write(key: _key, value: jsonEncode(next)));
    if (prefs.get(_seededKey) == null) {
      unawaited(prefs.write(key: _seededKey, value: '1'));
    }
  }
}
