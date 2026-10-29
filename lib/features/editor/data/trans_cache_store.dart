import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/store/atomic_file.dart';
import 'suggestions.dart';

/// 后端翻回来的译名(注音层里词库没有的短语、句子)在本机存一份。
///
/// 开机灌回反查缓存([cacheTagMeta]),写过的短语不用再问后端,断网也照样显示。
/// 只存翻出来的;按翻出来的先后留最近 [cap] 条。
class TransCacheStore {
  TransCacheStore(Directory root, {this.onSaveError})
    : _file = File('${root.path}${Platform.pathSeparator}tag_trans_cache.json');

  final File _file;
  final void Function(Object error)? onSaveError;

  /// [metaKey] 形态的键 → 译名。插入序即新旧序,末尾最新。
  final _entries = <String, String>{};

  Timer? _debounce;
  bool _dirty = false;
  int _revision = 0;
  Future<void> _chain = Future.value();
  Future<void> _lastWrite = Future.value();

  static const cap = 5000;

  /// 等待实际落盘;写失败向退出流程报告,保留修改供下次 flush 重试。
  Future<void> get idle => _lastWrite;

  int get length => _entries.length;

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString());
      if (j is! Map) return;
      for (final e in j.entries) {
        final k = e.key, v = e.value;
        if (k is String && v is String) {
          _remember(k, v);
        }
      }
      // 仅将上限内的有效缓存灌回内存,损坏或旧版超大缓存不会无限增长。
      _entries.forEach((k, v) => cacheTagMeta(k, trans: v));
    } catch (_) {}
  }

  /// 记下一条译名,稍后落盘。
  void put(String key, String zh) {
    if (!_remember(key, zh)) return;
    _revision++;
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), flush);
  }

  bool _remember(String key, String zh) {
    key = metaKey(key);
    zh = zh.trim();
    final displayed = firstTransSegment(zh, tag: key);
    if (key.isEmpty ||
        displayed == null ||
        displayed == key ||
        _entries[key] == zh) {
      return false;
    }
    _entries.remove(key);
    _entries[key] = zh;
    while (_entries.length > cap) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }

  /// 有改动就立即落盘(退后台时调)。
  void flush() {
    _debounce?.cancel();
    _debounce = null;
    if (!_dirty) return;
    _dirty = false;
    final revision = _revision;
    final payload = jsonEncode(_entries);
    final write = _chain.then((_) async {
      try {
        await writeStringAtomic(_file, payload);
      } catch (e) {
        // 新快照已经包含旧条目;旧失败不能把后来排队的快照覆盖回去。
        if (_revision == revision) _dirty = true;
        onSaveError?.call(e);
        rethrow;
      }
    });
    _lastWrite = write;
    _chain = write.catchError((Object _) {});
  }
}
