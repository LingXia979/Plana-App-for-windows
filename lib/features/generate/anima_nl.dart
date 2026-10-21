/// 自然语言补强(anima 专属功能模块,对齐 web AnimaNlModule):
/// 让 AI 按当前正向词写出英文句子 —— anima 是 tag + 英文 caption 混训的模型,
/// tag 给画面元素骨架,句子把这些元素之间的关系讲清楚。
///
/// 两个预设各产**一段话**(后端只回一个 text,不分段、不产负面词):
///   多人场景  讲清画面里谁是谁、他们之间在做什么(方位只在 tag 有依据时才写)
///   整体补强  按现有 tag 补 2-4 句
/// 整段写进正向词或整段移出,不拆条。在场判定以提示词字符串为准(不另存 applied 位),
/// 用户在编辑器里删掉这段,卡片上的 ✓ 自动变回 +。
///
/// 写进去的是裸句子(与 web 同):app 的折叠是仅编辑期语法(存在 promptRaw 里,
/// 见 editor_models),卡外写入一律只动定稿 `prompt` —— 与画师串/OC 库、LoRA
/// 触发词同一条路子。
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
enum AnimaNlMode { characters, enhance }

extension AnimaNlModeX on AnimaNlMode {
  String get label => switch (this) {
    AnimaNlMode.characters => '多人场景',
    AnimaNlMode.enhance => '整体补强',
  };
}

// ---- 句子 ↔ 正向提示词的读写 ----
// 句内有逗号,不能走 lora_triggers 那套按逗号切 tag 的口径,整段当一个整体处理。

/// 比较用归一化:去首尾空白 + 折叠连续空白(含换行)。
String nlKey(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

/// 匹配这一段:段内每处空白放宽成 `\s+`,用户在编辑器里换过行/多敲了空格也认。
RegExp? _nlPattern(String text) {
  final key = nlKey(text);
  if (key.isEmpty) return null;
  return RegExp(key.split(' ').map(RegExp.escape).join(r'\s+'));
}

/// 该段是否已在提示词里。
bool promptHasNl(String prompt, String text) =>
    _nlPattern(text)?.hasMatch(prompt) ?? false;

/// 追加一段到正向词末尾(已在场则原样返回)。
///
/// anima 要求自然语言排在所有 tag 之后,故一律追到末尾;末尾已经是句子时用空格
/// 接、否则用逗号接 —— 拼出来正是「tag, tag, Sentence one. Sentence two.」
/// (句子之间不夹逗号,与 anima 的写法约定一致)。
String appendNlToPrompt(String prompt, String text) {
  final seg = nlKey(text);
  if (seg.isEmpty || promptHasNl(prompt, seg)) return prompt;
  final base = prompt
      .trimRight()
      .replaceFirst(RegExp(r'[,，]$'), '')
      .trimRight();
  if (base.isEmpty) return seg;
  final tailIsSentence = RegExp(r'[.!?。！？]$').hasMatch(base);
  return '$base${tailIsSentence ? ' ' : ', '}$seg';
}

/// 从正向词里移除该段(顺带收掉接缝上的空逗号)。
/// 只改接缝两侧的分隔符,句子之外的换行/间距原样保留。
String removeNlFromPrompt(String prompt, String text) {
  final m = _nlPattern(text)?.firstMatch(prompt);
  if (m == null) return prompt;
  final left = prompt
      .substring(0, m.start)
      .replaceFirst(RegExp(r'[\s,，]+$'), '');
  final right = prompt.substring(m.end).replaceFirst(RegExp(r'^[\s,，]+'), '');
  if (left.isEmpty) return right;
  if (right.isEmpty) return left;
  return '$left, $right';
}

/// 模块状态。[extra] / [mode] / [result] 落盘(重启回到原样,同 web 的
/// localStorage);[running] / [error] 是本次运行的临时态,不落盘。
class AnimaNlState {
  const AnimaNlState({
    this.extra = '',
    this.mode,
    this.result,
    this.running,
    this.error = '',
  });

  /// 用户补充的额外要求(随请求发给 AI)。
  final String extra;

  /// 上次跑的预设(「重新生成」用)。
  final AnimaNlMode? mode;
  final AnimaNlResult? result;

  /// 正在跑的预设;null = 空闲。
  final AnimaNlMode? running;
  final String error;

  /// 这次结果落进正向词的那一整段(唯一的插入点)。
  String get fullText => nlKey(result?.text ?? '');

  AnimaNlState copyWith({
    String? extra,
    AnimaNlMode? mode,
    AnimaNlResult? result,
    AnimaNlMode? running,
    String? error,
    bool clearResult = false,
    bool clearRunning = false,
  }) => AnimaNlState(
    extra: extra ?? this.extra,
    mode: clearResult ? null : (mode ?? this.mode),
    result: clearResult ? null : (result ?? this.result),
    running: clearRunning ? null : (running ?? this.running),
    error: error ?? this.error,
  );

  Map<String, dynamic> toJson() => {
    'extra': extra,
    if (mode != null) 'mode': mode!.name,
    if (result != null) 'result': result!.toJson(),
  };

  factory AnimaNlState.fromJson(Map<String, dynamic> j) => AnimaNlState(
    extra: j['extra']?.toString() ?? '',
    mode: AnimaNlMode.values.where((m) => m.name == j['mode']).firstOrNull,
    result: j['result'] is Map<String, dynamic>
        ? AnimaNlResult.fromJson(j['result'] as Map<String, dynamic>)
        : null,
  );
}

const _key = 'anima_nl';

final animaNlProvider = AsyncNotifierProvider<AnimaNlNotifier, AnimaNlState>(
  AnimaNlNotifier.new,
);

class AnimaNlNotifier extends AsyncNotifier<AnimaNlState> {
  /// 发号作废:每次运行自增,回来时对不上号(取消 / 又点了一次)整个丢弃。
  int _seq = 0;

  @override
  Future<AnimaNlState> build() async {
    // 补强结果是照发起时那张画布的词来的:换了画布就作废(在途那趟也不要了),
    // 免得把 A 的句子插进 B。
    ref.listen(
      canvasWorkspaceProvider.select((w) => w.activeId),
      (prev, next) => _dropForCanvasSwitch(),
    );
    try {
      final raw = await ref.read(prefsStoreProvider).read(key: _key);
      if (raw == null || raw.isEmpty) return const AnimaNlState();
      return AnimaNlState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AnimaNlState();
    }
  }

  AnimaNlState get _cur => state.value ?? const AnimaNlState();

  void _dropForCanvasSwitch() {
    _seq++;
    final cur = state.value;
    if (cur == null) return;
    _set(cur.copyWith(clearResult: true, clearRunning: true, error: ''));
  }

  /// 先改状态(立即生效),再尽力持久化。[persist] = false 用于纯临时态
  /// (转圈/报错)的改动,不值得为它写盘。
  void _set(AnimaNlState next, {bool persist = true}) {
    state = AsyncData(next);
    if (persist) unawaited(_persist(next));
  }

  Future<void> _persist(AnimaNlState s) async {
    try {
      await ref
          .read(prefsStoreProvider)
          .write(key: _key, value: jsonEncode(s.toJson()));
    } catch (_) {}
  }

  void setExtra(String v) => _set(_cur.copyWith(extra: v));

  void clearResult() => _set(_cur.copyWith(clearResult: true, error: ''));

  /// 取消只是不再等这一趟的结果:服务端那次 LLM 已经在跑,掐不掉,
  /// 但用户不用再对着转圈干等(重新点会重新发一趟,注意后端每分钟 10 次限流)。
  void cancel() {
    _seq++;
    _set(_cur.copyWith(clearRunning: true), persist: false);
  }

  /// 跑一次补强。正向词与在架 LoRA 都就地从生成状态取,调用方只给预设。
  /// (负向词不参与:后端不再产负面补充,发过去也没人看。)
  Future<void> run(AnimaNlMode mode) async {
    final cur = _cur;
    if (cur.running != null) return;

    final gen = ref.read(generateProvider);
    final positive = gen.prompt.trim();
    if (positive.isEmpty) {
      _set(cur.copyWith(error: '正向提示词是空的,先写点 tag 再来'), persist: false);
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
          .animaNl(
            sessionId: sid,
            mode: mode.name,
            positive: positive,
            extra: cur.extra,
            // 已写进正向词的那段回带,让模型换角度写、别复读
            existingNl: promptHasNl(gen.prompt, cur.fullText)
                ? cur.fullText
                : '',
            loras: [
              for (final l in gen.loras)
                if (l.enabled)
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
          error: res.text.isEmpty ? 'AI 没给出可用的句子,换个说法再试试' : '',
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
