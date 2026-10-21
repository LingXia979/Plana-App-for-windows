import '../../core/util/log.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/store/atomic_file.dart';
import '../../core/store/blob_store.dart';
import 'models.dart';
import 'canvas_models.dart';
import 'state_codec.dart';

/// 创作工作台持久化(`<support>/workspace/state.json`):提示词、角色、
/// Vibe/角色参考(图片走 blob 仓)、图生图、参数、面板开合——重启原样回来。
/// 写入防抖 800ms 吸收滑条/输入抖动;前后台切换由 AppStores.flushNow 即刻落盘。
///
/// 格式(v3):`state` 仍是整份创作状态(全局设置 + 当前画布的词),旧版本只认它,
/// 装回旧包至少保住当前那套;各画布的提示词组另挂在 `canvases` 里,不带图片。
/// 读得懂两种老格式:v1 只有 `state`(迁成「默认画布」);v2 是每张画布各存一整份
/// 状态、没有顶层 `state`(全局设置取当时那张当前画布的)。
class WorkspaceStore {
  WorkspaceStore(this._blobs, Directory supportRoot)
    : _file = File('${supportRoot.path}/workspace/state.json'),
      _presetsFile = File('${supportRoot.path}/prompt_presets.json');

  final BlobStore _blobs;
  final File _file;
  File get _migrationBackup => File('${_file.path}.pre-v3.bak');

  /// 预设库文件,只为读 1.1.1 用的那一档(见 [_legacyPresetId])。
  final File _presetsFile;

  /// 启动读出的整份创作状态;null = 首启/无存档。
  GenerateState? initial;
  GenerateState? _latest;

  /// 启动读出的画布集合;null = 首启/无存档(由调用方按 [initial] 建一张)。
  CanvasWorkspace? initialCanvases;

  /// GenerateNotifier 的 id 发号器续点(防重启后 id 撞车)。
  int idSeq = 100;

  static final _idNumRe = RegExp(r'^id(\d+)$');
  static final _canvasNumRe = RegExp(r'^canvas(\d+)$');

  /// 1.1.1 的提示词预设是全局一份,记在预设库文件的 `activeId` 里;那时的存档
  /// 没记用哪一档。升级上来按它补进画布,补完存一次,之后只认画布自己记的。
  Future<String?> _legacyPresetId() async {
    try {
      if (!await _presetsFile.exists()) return null;
      final j = jsonDecode(await _presetsFile.readAsString());
      return j is Map && j['activeId'] is String
          ? j['activeId'] as String
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> load() => _loadFrom(_file);

  Future<void> _loadFrom(File source) async {
    try {
      if (!await source.exists()) return;
      final j = jsonDecode(await source.readAsString());
      if (j is! Map<String, dynamic>) {
        throw const FormatException('Invalid workspace');
      }
      // Preserve the legacy file before migration can schedule its first write.
      if (j['v'] != 3 && !await _migrationBackup.exists()) {
        await _file.copy(_migrationBackup.path);
      }
      idSeq = (j['idSeq'] as num?)?.toInt() ?? 100;
      final legacyPreset = await _legacyPresetId();
      // 有没有哪份没记预设、按 1.1.1 那一档补上的:补了就得存回去
      var presetFilled = false;
      bool lacksPreset(Object? m) => m is Map && m['promptPresetId'] is! String;
      if (lacksPreset(j['state'])) presetFilled = true;
      var full = j['state'] is Map<String, dynamic>
          ? await decodeGenerateState(
              j['state'] as Map<String, dynamic>,
              _blobs,
              presetFallback: legacyPreset,
            )
          : null;
      final savedActive = j['activeCanvasId'] is String
          ? j['activeCanvasId'] as String
          : null;

      final canvases = <CanvasDraft>[];
      var nextId = (j['nextCanvasId'] as num?)?.toInt() ?? 2;
      // v2 没有顶层 state:全局设置取当前画布那一整份(找不到就取第一张)
      GenerateState? v2Active;
      GenerateState? v2First;
      if (j['canvases'] is List) {
        for (final raw in j['canvases'] as List) {
          if (raw is! Map<String, dynamic> ||
              raw['id'] is! String ||
              (raw['id'] as String).isEmpty ||
              canvases.any((c) => c.id == raw['id'])) {
            continue;
          }
          final id = raw['id'] as String;
          try {
            final CanvasPrompts prompts;
            if (raw['prompts'] is Map<String, dynamic>) {
              if (lacksPreset(raw['prompts'])) presetFilled = true;
              prompts = await _decodePrompts(
                raw['prompts'] as Map<String, dynamic>,
                globals: full?.params,
                presetFallback: legacyPreset,
              );
            } else if (raw['state'] is Map<String, dynamic>) {
              if (lacksPreset(raw['state'])) presetFilled = true;
              final s = await decodeGenerateState(
                raw['state'] as Map<String, dynamic>,
                _blobs,
                presetFallback: legacyPreset,
              );
              v2First ??= s;
              if (id == savedActive) v2Active = s;
              prompts = CanvasPrompts.of(s);
            } else {
              continue;
            }
            final name = raw['name'] is String
                ? (raw['name'] as String).trim()
                : '';
            canvases.add(
              CanvasDraft(
                id: id,
                name: name.isEmpty ? '画布 ${canvases.length + 1}' : name,
                prompts: prompts,
              ),
            );
            final m = _canvasNumRe.firstMatch(id);
            if (m != null) {
              final n = int.parse(m.group(1)!) + 1;
              if (nextId < n) nextId = n;
            }
          } catch (e) {
            logd('[workspace] 跳过损坏画布: $e');
          }
        }
      }
      full ??= v2Active ?? v2First;

      if (canvases.isEmpty) {
        if (full == null) {
          throw const FormatException('Missing workspace state');
        }
        initial = full;
        initialCanvases = CanvasWorkspace.single(CanvasPrompts.of(full));
      } else {
        // 最上面那张是默认画布,名字固定(老存档里排第一的那张就此改叫默认画布)
        if (canvases.first.name != kDefaultCanvasName) {
          canvases[0] = canvases[0].copyWith(name: kDefaultCanvasName);
        }
        final activeId = canvases.any((c) => c.id == savedActive)
            ? savedActive!
            : canvases.first.id;
        final active = canvases.firstWhere((c) => c.id == activeId);
        if (full != null && activeId == savedActive) {
          // 当前画布以整份状态里的词为准(同一次写盘,正常两边一致)
          canvases[canvases.indexOf(active)] = active.copyWith(
            prompts: CanvasPrompts.of(full),
          );
        } else {
          // 记着的当前画布坏了 / 没有整份状态:全局设置照用,词换成落到的那张
          full = active.prompts.applyTo(full ?? GenerateState.initial());
        }
        // 出图参数是后来才跟画布走的:老存档里的画布一律接着用当时那份全局的
        final legacy = CanvasSampling.of(full.params);
        for (var i = 0; i < canvases.length; i++) {
          if (canvases[i].prompts.sampling == null) {
            canvases[i] = canvases[i].copyWith(
              prompts: canvases[i].prompts.withSampling(legacy),
            );
          }
        }
        initial = full;
        initialCanvases = CanvasWorkspace(
          canvases: canvases,
          activeId: activeId,
          nextId: nextId < 2 ? 2 : nextId,
        );
      }

      // 防抖窗口内被杀时 idSeq 可能落后于状态里的实际 id,取两者最大;
      // 角色 id 要把所有画布都算上,不能只看当前那张。
      for (final id in [
        for (final v in full.vibes) v.id,
        for (final r in full.charRefs) r.id,
        for (final r in full.kreaStyleRefs) r.id,
        for (final canvas in initialCanvases!.canvases) ...[
          for (final c in canvas.prompts.characters) c.id,
        ],
      ]) {
        final m = _idNumRe.firstMatch(id);
        if (m != null) {
          final n = int.parse(m.group(1)!) + 1;
          if (n > idSeq) idSeq = n;
        }
      }
      // 补过预设就存一次:预设库文件往后不再记那一档,不存下次就读不到了
      if (presetFilled && legacyPreset != null) {
        schedule(full, canvases: initialCanvases!, idSeq: idSeq);
      }
    } catch (e) {
      logd('[workspace] 载入失败: $e');
      initial = null;
      initialCanvases = null;
      if (source.path == _file.path && await _migrationBackup.exists()) {
        final corrupt = File('${_file.path}.corrupt.bak');
        try {
          if (!await corrupt.exists()) await _file.copy(corrupt.path);
        } on FileSystemException catch (backupError) {
          logd('[workspace] 损坏存档备份失败: $backupError');
        }
        await _loadFrom(_migrationBackup);
      }
    }
  }

  GenerateState? _pending;
  CanvasWorkspace? _pendingCanvases;
  int _pendingSeq = 100;
  Timer? _timer;
  Future<void> _chain = Future.value();

  /// 状态一变就来这里排队;真正写盘在防抖窗口后。
  void schedule(
    GenerateState s, {
    CanvasWorkspace? canvases,
    required int idSeq,
  }) {
    _blobs.referencesChanged();
    _latest = s;
    _pending = s;
    _pendingCanvases = canvases ?? CanvasWorkspace.single(CanvasPrompts.of(s));
    _pendingSeq = idSeq;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), flush);
  }

  /// 立即把挂起的状态落盘(串行链,不与上一次写重叠)。
  void flush() {
    final s = _pending;
    final w = _pendingCanvases;
    if (s == null || w == null) return;
    _pending = null;
    _pendingCanvases = null;
    _timer?.cancel();
    final seq = _pendingSeq;
    _chain = _chain.then((_) async {
      try {
        final enc = await encodeGenerateState(s, _blobs);
        final canvases = <Map<String, dynamic>>[
          for (final c in w.canvases)
            {
              'id': c.id,
              'name': c.name,
              'prompts': await _encodePrompts(c.prompts),
            },
        ];
        // 原子写:落盘时机就是退后台,不能留半截 JSON(见 atomic_file.dart)
        await writeStringAtomic(
          _file,
          jsonEncode({
            'v': 3,
            'idSeq': seq,
            'refs': enc.refs.toList(),
            'state': enc.json,
            'activeCanvasId': w.activeId,
            'nextCanvasId': w.nextId,
            'canvases': canvases,
          }),
        );
      } catch (e) {
        logd('[workspace] 保存失败: $e');
      }
    });
  }

  Future<void> get idle => _chain;

  /// 一张画布的提示词组只存跟画布走的那几项。角色编解码借整份状态那一套
  /// (含老存档的站位迁移),免得两种角色格式各走各的;提示词组不带图片,
  /// 所以也不产生 blob 引用。
  static const _promptKeys = [
    'prompt',
    'negativePrompt',
    'promptRaw',
    'negativePromptRaw',
    'promptFoldLinks',
    'characters',
    'promptPresetId',
  ];

  /// 模型、尺寸、种子和采样参数借整份状态 params 里的同名键(含分档记忆)。
  static const _samplingKeys = [
    'model',
    'naiEffort',
    'width',
    'height',
    'seed',
    'steps',
    'cfg',
    'varietyPlus',
    'sampler',
    'noiseSchedule',
    'cfgRescale',
    'animaSteps',
    'animaCfg',
    'animaSampler',
    'animaScheduler',
    'kreaSteps',
    'kreaCfg',
    'kreaSampler',
    'kreaScheduler',
    'modalMem',
  ];

  Future<Map<String, dynamic>> _encodePrompts(CanvasPrompts p) async {
    final base = GenerateState.initial();
    // 出图参数原样写进去,存的就是这张画布自己那份
    final s = p
        .applyTo(base)
        .copyWith(
          params: p.sampling?.writeInto(
            base.params.copyWith(useCoords: p.useCoords),
          ),
        );
    final enc = await encodeGenerateState(s, _blobs);
    final params = enc.json['params'] as Map<String, dynamic>;
    return {
      for (final k in _promptKeys)
        if (enc.json.containsKey(k)) k: enc.json[k],
      'useCoords': p.useCoords,
      if (p.sampling != null)
        'sampling': {
          for (final k in _samplingKeys)
            if (params.containsKey(k)) k: params[k],
        },
    };
  }

  /// [globals] 是同一份存档顶层的整份参数:尺寸和种子比模型、采样晚收进画布,
  /// 那之前存下的画布没这几个键,接着用当时全局那份。
  Future<CanvasPrompts> _decodePrompts(
    Map<String, dynamic> j, {
    GenParams? globals,
    String? presetFallback,
  }) async {
    final sampling = j['sampling'];
    final s = await decodeGenerateState(
      {
        for (final k in _promptKeys)
          if (j.containsKey(k)) k: j[k],
        'params': {
          if (globals != null) ...{
            'width': globals.width,
            'height': globals.height,
            'seed': globals.seed,
          },
          if (sampling is Map<String, dynamic>) ...sampling,
          // 带上这个键,解码就不会把它当老存档去迁移站位
          'useCoords': j['useCoords'] == true,
        },
      },
      _blobs,
      presetFallback: presetFallback,
    );
    final prompts = CanvasPrompts.of(s);
    // 没这块的是老存档:先空着,载入收尾时补成当时的全局参数
    return sampling is Map<String, dynamic>
        ? prompts
        : prompts.withSampling(null);
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
      if (await _migrationBackup.exists()) {
        final backup = jsonDecode(await _migrationBackup.readAsString());
        if (backup is! Map) throw const FormatException('工作台迁移备份无法读取');
        live.addAll(BlobStore.referencedHashes(backup));
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
