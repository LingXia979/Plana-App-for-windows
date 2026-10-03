import '../../core/util/log.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/store/atomic_file.dart';
import '../../core/store/blob_store.dart';
import 'models.dart';
import 'state_codec.dart';

/// 创作工作台持久化(`<support>/workspace/state.json`):提示词、角色、
/// Vibe/角色参考(图片走 blob 仓)、图生图、参数、面板开合——重启原样回来。
/// 写入防抖 800ms 吸收滑条/输入抖动;前后台切换由 AppStores.flushNow 即刻落盘。
class WorkspaceStore {
  WorkspaceStore(this._blobs, Directory supportRoot)
    : _file = File('${supportRoot.path}/workspace/state.json');

  final BlobStore _blobs;
  final File _file;

  /// 启动读出的工作台状态;null = 首启/无存档。
  GenerateState? initial;
  GenerateState? _latest;

  /// GenerateNotifier 的 id 发号器续点(防重启后 id 撞车)。
  int idSeq = 100;

  static final _idNumRe = RegExp(r'^id(\d+)$');

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString());
      if (j is! Map<String, dynamic>) return;
      idSeq = (j['idSeq'] as num?)?.toInt() ?? 100;
      if (j['state'] is Map<String, dynamic>) {
        final s = await decodeGenerateState(
          j['state'] as Map<String, dynamic>,
          _blobs,
        );
        initial = s;
        // 防抖窗口内被杀时 idSeq 可能落后于状态里的实际 id,取两者最大
        for (final id in [
          for (final c in s.characters) c.id,
          for (final v in s.vibes) v.id,
          for (final r in s.charRefs) r.id,
        ]) {
          final m = _idNumRe.firstMatch(id);
          if (m != null) {
            final n = int.parse(m.group(1)!) + 1;
            if (n > idSeq) idSeq = n;
          }
        }
      }
    } catch (e) {
      logd('[workspace] 载入失败(按首启处理): $e');
      initial = null;
    }
  }

  GenerateState? _pending;
  int _pendingSeq = 100;
  Timer? _timer;
  Future<void> _chain = Future.value();
  Future<void> get idle => _chain;

  /// 状态一变就来这里排队;真正写盘在防抖窗口后。
  void schedule(GenerateState s, {required int idSeq}) {
    _blobs.referencesChanged();
    _latest = s;
    _pending = s;
    _pendingSeq = idSeq;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), flush);
  }

  /// 立即把挂起的状态落盘(串行链,不与上一次写重叠)。
  void flush() {
    final s = _pending;
    if (s == null) return;
    _pending = null;
    _timer?.cancel();
    final seq = _pendingSeq;
    _chain = _chain.then((_) async {
      try {
        final enc = await encodeGenerateState(s, _blobs);
        // 原子写:落盘时机就是退后台,不能留半截 JSON(见 atomic_file.dart)
        await writeStringAtomic(
          _file,
          jsonEncode({
            'v': 1,
            'idSeq': seq,
            'refs': enc.refs.toList(),
            'state': enc.json,
          }),
        );
      } catch (e) {
        logd('[workspace] 保存失败: $e');
      }
    });
  }

  /// 盘上存档引用的 blob 哈希(启动 GC 的引用清单)。
  Future<Set<String>> liveRefs({bool strict = false}) async {
    final live = <String>{};
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        if (j is! Map) throw const FormatException('工作台引用记录无法读取');
        live.addAll(BlobStore.referencedHashes(j));
      }
      final current = _latest ?? initial;
      if (current != null) {
        live.addAll(await generateStateBlobRefs(current, _blobs));
      }
    } catch (_) {
      if (strict) rethrow;
    }
    return live;
  }
}
