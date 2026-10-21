/// 提示词整理(krea 专属功能模块,对齐 web KreaPromptModule):
/// 让 AI 把当前正向词整条改写成一段合格的 k2 提示词 —— Krea 2 用 Qwen3-VL 做
/// 文本编码器,吃的是连贯的自然语言描述;逗号分隔的 tag 串它读得懂但发挥不出来。
///
/// ⚠ 与 anima 的 [AnimaNlState] 交互**相反**,别照搬:
///   anima  tag 是骨架、句子是补充 → 结果**追加**到末尾(插入 / 移出,天然可逆)
///   krea   整条 prompt 就是一段自然语言 → 结果**替换**原文
/// 所以这里是「替换 + 还原」:替换时把原文存一份,只要用户没再动过提示词就能一键
/// 还原;一旦替换后又编辑过,还原入口就撤掉 —— 那时候还原等于毁掉他的修改。
///
/// 两个预设(后端只回一个 text,不分段、不产负面词):
///   改写为语句  tag 串 / 零散短语 → 完整自然语言
///   补充细节    已经像样了,只补光线/材质/镜头/氛围,不改主体
///
/// **只管正向**:排除内容不在本模块职责范围内(与服务端约定一致,请求里也没这字段)。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/store/app_stores.dart';
import 'canvas_state.dart';
import 'generate_state.dart';

/// 预设。`name` 即请求体 `mode` 的取值,不要改名。
enum KreaPromptMode { rewrite, enrich }

extension KreaPromptModeX on KreaPromptMode {
  String get label => switch (this) {
    KreaPromptMode.rewrite => '改写为语句',
    KreaPromptMode.enrich => '补充细节',
  };
}

/// 比较用归一化:去首尾空白 + 折叠连续空白(含换行)。
/// 判「当前正向词是否还是那段替换结果」用它 —— 编辑器可能改过换行/空格。
String kreaPromptKey(String text) =>
    text.trim().replaceAll(RegExp(r'\s+'), ' ');

/// 模块状态。[extra] / [mode] / [result] / [original] 落盘(重启回到原样,
/// 同 web 的 localStorage);[running] / [error] 是本次运行的临时态,不落盘。
class KreaPromptState {
  const KreaPromptState({
    this.extra = '',
    this.mode,
    this.result,
    this.original,
    this.running,
    this.error = '',
  });

  /// 用户补充的额外要求(随请求发给 AI)。
  final String extra;

  /// 上次跑的预设(「重新生成」用)。
  final KreaPromptMode? mode;
  final KreaPromptResult? result;

  /// 替换前的原文;null = 还没替换过(或已还原)。**空串是合法值**
  /// (从空提示词替换过来),所以用 null 而不是 isEmpty 表示「没替换过」。
  final String? original;

  /// 正在跑的预设;null = 空闲。
  final KreaPromptMode? running;
  final String error;

  /// 这次结果的整段文本(要整条替换进正向词的那一段)。
  String get fullText => kreaPromptKey(result?.text ?? '');

  /// 当前正向词是否**仍然**是这次替换的结果 —— 是才给「还原」。
  bool replacedIn(String prompt) =>
      original != null &&
      fullText.isNotEmpty &&
      kreaPromptKey(prompt) == fullText;

  KreaPromptState copyWith({
    String? extra,
    KreaPromptMode? mode,
    KreaPromptResult? result,
    String? original,
    KreaPromptMode? running,
    String? error,
    bool clearResult = false,
    bool clearOriginal = false,
    bool clearRunning = false,
  }) => KreaPromptState(
    extra: extra ?? this.extra,
    mode: clearResult ? null : (mode ?? this.mode),
    result: clearResult ? null : (result ?? this.result),
    original: clearOriginal ? null : (original ?? this.original),
    running: clearRunning ? null : (running ?? this.running),
    error: error ?? this.error,
  );

  Map<String, dynamic> toJson() => {
    'extra': extra,
    if (mode != null) 'mode': mode!.name,
    if (result != null) 'result': result!.toJson(),
    if (original != null) 'original': original,
  };

  factory KreaPromptState.fromJson(Map<String, dynamic> j) => KreaPromptState(
    extra: j['extra']?.toString() ?? '',
    mode: KreaPromptMode.values.where((m) => m.name == j['mode']).firstOrNull,
    result: j['result'] is Map<String, dynamic>
        ? KreaPromptResult.fromJson(j['result'] as Map<String, dynamic>)
        : null,
    original: j['original'] is String ? j['original'] as String : null,
  );
}

const _key = 'krea_prompt';

final kreaPromptProvider =
    AsyncNotifierProvider<KreaPromptNotifier, KreaPromptState>(
      KreaPromptNotifier.new,
    );

class KreaPromptNotifier extends AsyncNotifier<KreaPromptState> {
  /// 发号作废:每次运行自增,回来时对不上号(取消 / 又点了一次)整个丢弃。
  int _seq = 0;

  @override
  Future<KreaPromptState> build() async {
    // 结果和存着的原文都是照发起时那张画布的词来的:换了画布就作废(在途那趟
    // 也不要了),免得把 A 的整理结果替换 / 还原进 B。
    ref.listen(
      canvasWorkspaceProvider.select((w) => w.activeId),
      (prev, next) => _dropForCanvasSwitch(),
    );
    try {
      final raw = await ref.read(prefsStoreProvider).read(key: _key);
      if (raw == null || raw.isEmpty) return const KreaPromptState();
      return KreaPromptState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const KreaPromptState();
    }
  }

  KreaPromptState get _cur => state.value ?? const KreaPromptState();

  void _dropForCanvasSwitch() {
    _seq++;
    final cur = state.value;
    if (cur == null) return;
    _set(
      cur.copyWith(
        clearResult: true,
        clearOriginal: true,
        clearRunning: true,
        error: '',
      ),
    );
  }

  /// 先改状态(立即生效),再尽力持久化。[persist] = false 用于纯临时态
  /// (转圈/报错)的改动,不值得为它写盘。
  void _set(KreaPromptState next, {bool persist = true}) {
    state = AsyncData(next);
    if (persist) unawaited(_persist(next));
  }

  Future<void> _persist(KreaPromptState s) async {
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _key, value: jsonEncode(s.toJson()));
    } catch (_) {}
  }

  void setExtra(String v) => _set(_cur.copyWith(extra: v));

  /// 清空结果。**不动提示词框**,也不动存着的原文 —— 已经替换进去的那段是
  /// 用户的正文了,清结果只是收走这张卡上的预览。
  void clearResult() => _set(_cur.copyWith(clearResult: true, error: ''));

  /// 取消只是不再等这一趟的结果:服务端那次 LLM 已经在跑,掐不掉,
  /// 但用户不用再对着转圈干等(重新点会重新发一趟,注意后端每分钟 10 次限流)。
  void cancel() {
    _seq++;
    _set(_cur.copyWith(clearRunning: true), persist: false);
  }

  /// 整段替换正向词,并把原文存一份供还原。
  void applyReplace() {
    final text = _cur.fullText;
    if (text.isEmpty) return;
    final gen = ref.read(generateProvider.notifier);
    final before = ref.read(generateProvider).prompt;
    // 卡外写入一律只动定稿 prompt(编辑器草稿随之作废),同 LoRA 触发词/画师串
    gen.setPrompts(positive: text);
    _set(_cur.copyWith(original: before));
  }

  /// 还原成替换前的原文。
  void restore() {
    final before = _cur.original;
    if (before == null) return;
    ref.read(generateProvider.notifier).setPrompts(positive: before);
    _set(_cur.copyWith(clearOriginal: true));
  }

  /// 跑一次整理。正向词与在架 LoRA 都就地从生成状态取,调用方只给预设。
  Future<void> run(KreaPromptMode mode) async {
    final cur = _cur;
    if (cur.running != null) return;

    final gen = ref.read(generateProvider);
    final positive = gen.prompt.trim();
    if (positive.isEmpty) {
      _set(cur.copyWith(error: '正向提示词是空的,先写点东西再来'), persist: false);
      return;
    }
    final sid = (await ref.read(botSessionProvider.future))?.sessionId;
    if (sid == null || sid.isEmpty) {
      _set(cur.copyWith(error: '需要先登录后端账号'), persist: false);
      return;
    }

    final seq = ++_seq;
    _set(_cur.copyWith(running: mode, error: ''), persist: false);
    try {
      final res = await ref
          .read(backendClientProvider)
          .kreaPrompt(
            sessionId: sid,
            mode: mode.name,
            positive: positive,
            extra: cur.extra,
            loras: [
              // 只发已启用的:没启用的 LoRA 触发词写进提示词纯属噪声。
              // 还在下载的(pending)本就不进载荷,这里也一并跳过。
              for (final l in gen.loras)
                if (l.enabled && l.pending == null)
                  {
                    'name': l.displayName.isEmpty ? l.name : l.displayName,
                    'trigger_words': l.triggerWords,
                  },
            ],
          );
      if (seq != _seq) return;
      _set(
        _cur.copyWith(
          mode: mode,
          result: res,
          clearRunning: true,
          error: res.text.isEmpty ? 'AI 没给出可用的结果,换个说法再试试' : '',
        ),
      );
    } catch (e) {
      if (seq != _seq) return;
      _set(
        _cur.copyWith(
          clearRunning: true,
          error: e is BackendException ? e.message : '$e',
        ),
        persist: false,
      );
    }
  }
}
