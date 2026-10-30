import '../../core/store/blob_store.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/store/atomic_file.dart';
import '../../core/util/log.dart';
import 'canvas_models.dart';
import 'workspace_store.dart';

/// 一次出图记下的画布内容,和这次出的图。
class CanvasHistoryEntry {
  CanvasHistoryEntry({
    required this.id,
    required this.at,
    required this.json,
    required this.preview,
    required this.resultIds,
    required this.refs,
  }) : fingerprint = jsonEncode(json);

  final String id;

  /// 最近一次用这组内容出图的时间(毫秒)。
  final int at;

  /// 画布内容,格式同存档里的 `canvases[].prompts`;图片只记哈希。
  final Map<String, dynamic> json;

  /// 不带图片的那份内容,列表里看词和参数用。
  final CanvasPrompts preview;

  /// 这组内容出的图(图库 id),新的在前,最多 [CanvasHistoryStore.maxResults] 张。
  final List<String> resultIds;

  /// [json] 引用的 blob 哈希。
  final List<String> refs;

  final String fingerprint;

  /// [json] 里某个列表键的条数(Vibe、角色参考等,[preview] 里没有图片那几项)。
  int countOf(String key) => json[key] is List ? (json[key] as List).length : 0;

  bool has(String key) => json[key] is Map;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at,
    'content': json,
    'results': resultIds,
    'refs': refs,
  };
}

/// 画布历史(`<support>/workspace/history/<画布 id>.json`):每张画布记最近
/// [cap] 次出图时的内容,内容和上一条一样就只把新图追加到那一条。
///
/// 删掉的画布文件先留着(删除可撤销),启动时由 [removeOrphans] 清掉。
class CanvasHistoryStore {
  CanvasHistoryStore(
    this._workspace,
    Directory supportRoot, {
    this.onSaveError,
    this.onReferencesChanged,
  }) : _dir = Directory('${supportRoot.path}/workspace/history');

  static const cap = 50;
  static const maxResults = 4;

  final WorkspaceStore _workspace;
  final Directory _dir;
  final _cache = <String, List<CanvasHistoryEntry>>{};
  Future<void> _chain = Future.value();
  var _seq = 0;
  final void Function(Object)? onSaveError;
  final void Function()? onReferencesChanged;
  final _pending =
      <({String id, CanvasPrompts content, List<String> results, int at})>[];
  final _dirty = <String>{};
  Object? _error;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final task = _chain.then((_) => action());
    _chain = task.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        _error = e;
        onSaveError?.call(e);
        logd('[history] 保存/读取失败: $e');
      },
    );
    return task;
  }

  void flush() {
    unawaited(_enqueue(_drain).catchError((Object _) {}));
  }

  File _fileOf(String canvasId) =>
      File('${_dir.path}/${Uri.encodeComponent(canvasId)}.json');

  /// 新的在前。
  Future<List<CanvasHistoryEntry>> load(String canvasId) =>
      _enqueue(() => _load(canvasId));

  Future<List<CanvasHistoryEntry>> _load(String canvasId) async {
    final cached = _cache[canvasId];
    if (cached != null) return cached;
    final out = <CanvasHistoryEntry>[];
    try {
      final f = _fileOf(canvasId);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is! Map || j['entries'] is! List) {
          throw const FormatException('画布历史格式无效');
        }
        {
          for (final e in j['entries'] as List) {
            if (e is! Map ||
                e['id'] is! String ||
                e['content'] is! Map<String, dynamic> ||
                e['refs'] is! List) {
              throw const FormatException('画布历史条目无效');
            }
            final content = e['content'] as Map<String, dynamic>;
            out.add(
              CanvasHistoryEntry(
                id: e['id'] as String,
                at: (e['at'] as num?)?.toInt() ?? 0,
                json: content,
                preview: await _workspace.decodeCanvas(
                  content,
                  withImages: false,
                ),
                resultIds: _strings(e['results']),
                refs: {
                  ..._strings(e['refs']),
                  ...BlobStore.referencedHashes(content),
                }.toList(),
              ),
            );
          }
        }
      }
    } catch (e) {
      logd('[history] 读取失败: $e');
      rethrow;
    }
    return _cache[canvasId] ??= out;
  }

  static List<String> _strings(Object? raw) => [
    if (raw is List)
      for (final s in raw)
        if (s is String) s,
  ];

  /// 记一次出图:[content] 是发起时那张画布的内容,[resultIds] 是这次入库的图。
  Future<void> record(
    String canvasId,
    CanvasPrompts content,
    List<String> resultIds,
  ) {
    if (resultIds.isEmpty) return Future.value();
    _pending.add((
      id: canvasId,
      content: content,
      results: List.of(resultIds),
      at: DateTime.now().millisecondsSinceEpoch,
    ));
    onReferencesChanged?.call();
    return _enqueue(_drain);
  }

  Future<void> _drain() async {
    Object? failure;
    final blocked = <String>{};
    for (final pending in _pending.toList()) {
      if (blocked.contains(pending.id)) continue;
      try {
        final list = [...await _load(pending.id)];
        final enc = await _workspace.encodeCanvas(pending.content);
        final json = jsonDecode(jsonEncode(enc.json)) as Map<String, dynamic>;
        final head = list.firstOrNull;
        final same = head?.fingerprint == jsonEncode(json);
        final entry = CanvasHistoryEntry(
          id: same ? head!.id : 'h${pending.at}-${_seq++}',
          at: pending.at,
          json: json,
          preview: await _workspace.decodeCanvas(json, withImages: false),
          resultIds: {
            ...pending.results,
            if (same) ...head!.resultIds,
          }.take(maxResults).toList(),
          refs: enc.refs.toList(),
        );
        if (same) list.removeAt(0);
        list.insert(0, entry);
        _cache[pending.id] = List.unmodifiable(list.take(cap));
        _dirty.add(pending.id);
        _pending.remove(pending);
        onReferencesChanged?.call();
      } catch (e) {
        failure = e;
        blocked.add(pending.id);
      }
    }
    for (final id in _dirty.toList()) {
      try {
        await writeStringAtomic(
          _fileOf(id),
          jsonEncode({
            'v': 1,
            'entries': [for (final e in _cache[id]!) e.toJson()],
          }),
        );
        _dirty.remove(id);
      } catch (e) {
        failure = e;
      }
    }
    _error = failure;
    if (failure != null) throw failure;
  }

  Future<void> get idle async {
    await _chain;
    if (_error case final e?) throw e;
  }

  /// 所有历史引用的 blob 哈希(blob GC 的引用清单)。
  Future<Set<String>> liveRefs() => _enqueue(() async {
    // Pending snapshots may still contain bytes that could not be encoded.
    // Stop cleanup rather than guessing which blobs they need.
    if (_pending.isNotEmpty) await _drain();
    final out = <String>{
      for (final list in _cache.values)
        for (final e in list) ...e.refs,
    };
    if (!await _dir.exists()) return out;
    await for (final f in _dir.list(followLinks: false)) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['entries'] is! List) {
        throw const FormatException('无法核对画布历史的图片引用');
      }
      for (final e in j['entries'] as List) {
        if (e is! Map || e['refs'] is! List || e['content'] is! Map) {
          throw const FormatException('无法核对画布历史条目的图片引用');
        }
        out.addAll(BlobStore.referencedHashes(e));
      }
    }
    return out;
  });

  /// 删掉不在 [keep] 里的画布的历史;[since] 之后才写的不动(本次启动新建的画布)。
  Future<void> removeOrphans(Set<String> keep, DateTime since) =>
      _enqueue(() async {
        try {
          if (!await _dir.exists()) return;
          await for (final f in _dir.list()) {
            if (f is! File || !f.path.endsWith('.json')) continue;
            final name = f.uri.pathSegments.last;
            final id = Uri.decodeComponent(
              name.substring(0, name.length - '.json'.length),
            );
            if (keep.contains(id) ||
                _cache.containsKey(id) ||
                _pending.any((p) => p.id == id)) {
              continue;
            }
            if ((await f.stat()).modified.isAfter(since)) continue;
            _cache.remove(id);
            await f.delete();
            onReferencesChanged?.call();
          }
        } catch (_) {}
      });
}

/// 一张画布的历史,新的在前。记了新的一条就由记录方 invalidate。
final canvasHistoryProvider = FutureProvider.autoDispose
    .family<List<CanvasHistoryEntry>, String>(
      (ref, canvasId) => ref.watch(appStoresProvider).history.load(canvasId),
    );
