import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../generate/generate_state.dart';
import 'editor_models.dart';

final editorProvider = NotifierProvider<EditorNotifier, EditorState>(
  EditorNotifier.new,
);

/// 光标驱动定稿:字符串就是真相,正/负各一条(含原样权重语法)。
/// 折叠体不在正文里(正文只有 `<#名字>` 占位符),存 [foldBodies];
/// 只增不删且跨会话留存于撤销档(解散/删除只动正文,表项留着给撤销兜底),
/// 定稿与草稿都经 [expandFolds] 拼回完整语法后再算。
/// 撤销栈按编辑目标跨会话长效(见 [_UndoArchive]),退出编辑器不重置。
class EditorState {
  const EditorState({
    this.positiveText = '',
    this.negativeText = '',
    this.activePositive = true,
    this.canUndo = false,
    this.foldBodies = const {},
    this.foldLinks = const [],
  });

  final String positiveText;
  final String negativeText;
  final bool activePositive;
  final bool canUndo;

  /// 折叠表:占位符名字 → 折叠体(正/负两侧共用,载入时已跨侧去重)。
  final Map<String, String> foldBodies;
  final List<PromptFoldLink> foldLinks;

  String get activeText => activePositive ? positiveText : negativeText;

  /// 当前段定稿(占位符展开 + 剔除编辑期语法)。token 读数用。
  String get activeOutput => outputOf(expandFolds(activeText, foldBodies));

  EditorState copyWith({
    String? positiveText,
    String? negativeText,
    bool? activePositive,
    bool? canUndo,
    Map<String, String>? foldBodies,
    List<PromptFoldLink>? foldLinks,
  }) => EditorState(
    positiveText: positiveText ?? this.positiveText,
    negativeText: negativeText ?? this.negativeText,
    activePositive: activePositive ?? this.activePositive,
    canUndo: canUndo ?? this.canUndo,
    foldBodies: foldBodies ?? this.foldBodies,
    foldLinks: foldLinks ?? this.foldLinks,
  );
}

typedef _Snap = (String pos, String neg, List<PromptFoldLink> links);

/// 单个编辑目标(主提示词/某角色)的撤销档。**进程级长效**:退出编辑器
/// 不清空,重进接着撤,只在进程结束或角色被删时消亡。折叠表一并留存且
/// 只增不删 —— 历史快照里的占位符要靠它才解析得回(会话内「表只增不删」
/// 原则的跨会话延伸;表悬空会让占位符漏成 `#名字` 字面量进提示词)。
class _UndoArchive {
  final List<_Snap> snaps = [];
  Map<String, String> folds = const {};
}

class EditorNotifier extends Notifier<EditorState> {
  EditorNotifier({this.immediateWriteBack = false});

  /// Inline editors stay open while Generate and other editors are used.
  final bool immediateWriteBack;
  bool isWritingBack = false;

  /// key = 角色 id,主提示词用 ''。
  final Map<String, _UndoArchive> _archives = {};
  static const _maxHistory = 60;
  int _lastPushMs = 0;

  _UndoArchive get _arc =>
      _archives.putIfAbsent(_charId ?? '', _UndoArchive.new);

  /// 本次会话的编辑目标:null = 创作页主提示词,否则 = 该 id 的角色提示词。
  /// 进页面时由 [load] 钉死,中途不变。用 id 不用名字——角色自动编号
  /// (「角色 N」)在删掉中间一个再新增时会重名,名字不是稳定句柄。
  String? _charId;

  /// 编辑中实时回写创作页的防抖(编辑器内容不再只活在内存:
  /// 回写进 generateProvider 后由工作台持久化链自动落盘,
  /// 中途被杀最多丢一个防抖窗口的字)。
  Timer? _writeBack;

  @override
  EditorState build() {
    ref.onDispose(() => _writeBack?.cancel());
    return const EditorState();
  }

  void load({
    required String positive,
    required String negative,
    required bool startPositive,
    String? charId,
  }) {
    _writeBack?.cancel(); // 新会话,作废上一会话可能挂着的回写
    _lastPushMs = 0;
    _charId = charId;
    // 角色已删,其撤销档随之作废(主档 '' 恒保留)
    final live = <String>{
      '',
      for (final c in ref.read(generateProvider).characters) c.id,
    };
    _archives.removeWhere((k, _) => !live.contains(k));
    final arc = _arc;
    final input = ref.read(generateProvider);
    final links = validPromptFoldLinks(
      positive,
      negative,
      charId == null
          ? input.promptFoldLinks
          : [
              for (final character in input.characters)
                if (character.id == charId) ...character.foldLinks,
            ],
    );
    final posNames = <String, String>{}, negNames = <String, String>{};
    // 草稿(完整折叠语法)→ 正文占位符 + 折叠表。负面侧避开正面已占的
    // 名字,两侧共同避开撤销档已占的名字(同名同体复用,不同体加序号 ——
    // 免得本次载入的折叠顶掉历史快照还指望着的同名旧折叠体)。
    final (posText, posBodies) = collapseFolds(
      positive,
      seed: arc.folds,
      onCollapsed: (fold, name) => posNames[fold.name] = name,
    );
    final (negText, negBodies) = collapseFolds(
      negative,
      seed: {...arc.folds, ...posBodies},
      onCollapsed: (fold, name) => negNames[fold.name] = name,
    );
    arc.folds = {...arc.folds, ...posBodies, ...negBodies};
    state = EditorState(
      positiveText: posText,
      negativeText: negText,
      activePositive: startPositive,
      canUndo: arc.snaps.isNotEmpty,
      foldBodies: arc.folds,
      foldLinks: [
        for (final link in links)
          link.renamed(
            posNames[link.positiveName]!,
            negNames[link.negativeName]!,
          ),
      ],
    );
  }

  /// 注册一个折叠体(补全插入画师串 / OC 标签组时),返回占位符该用的名字
  /// (重名且内容不同时自动加序号)。表只增不删——撤销回带占位符的旧文本时
  /// 仍能解析。
  String registerFold(String name, String body) {
    final linkedNames = {
      for (final link in state.foldLinks) ...[
        link.positiveName,
        link.negativeName,
      ],
    };
    // A newly registered manual fold must not reuse the anchor of an imported
    // pair, even if its display name and body happen to be identical.
    final lookup = {
      ...state.foldBodies,
      for (final name in linkedNames) name: '${state.foldBodies[name]}\u0000',
    };
    final n = uniqueFoldName(name, body, lookup);
    final next = {...state.foldBodies, n: body};
    _arc.folds = next; // 撤销档同步留存:快照回带占位符时仍解析得回
    state = state.copyWith(foldBodies: next);
    return n;
  }

  void _scheduleWriteBack() {
    _writeBack?.cancel();
    if (immediateWriteBack) {
      flushWriteBack();
      return;
    }
    _writeBack = Timer(const Duration(milliseconds: 400), flushWriteBack);
  }

  /// 立即把当前定稿回写(防抖到点/离开编辑器/退后台共用)。
  /// 目标由 [load] 钉死的 [_charId] 决定:角色会话绝不写主提示词
  /// ——从前这里写死了 setPrompts,点角色卡进来编辑会静默覆盖主提示词。
  void flushWriteBack() {
    _writeBack?.cancel();
    isWritingBack = true;
    try {
      _writeToGenerate();
    } finally {
      isWritingBack = false;
    }
  }

  void _writeToGenerate() {
    final gen = ref.read(generateProvider.notifier);
    final id = _charId;
    // 草稿 = 占位符展开回完整折叠语法(下次载入原样收回);定稿再剔编辑期语法
    final posDraft = expandFolds(state.positiveText, state.foldBodies);
    final negDraft = expandFolds(state.negativeText, state.foldBodies);
    final pos = outputOf(posDraft);
    final neg = outputOf(negDraft);
    final posRaw = draftOf(posDraft, pos);
    final negRaw = draftOf(negDraft, neg);
    final links = validPromptFoldLinks(posDraft, negDraft, state.foldLinks);
    if (id == null) {
      gen.setPrompts(
        positive: pos,
        negative: neg,
        positiveRaw: posRaw,
        negativeRaw: negRaw,
        promptFoldLinks: links,
      );
      return;
    }
    // updateCharacter 没有 setPrompts 那样的同值短路,这里自己挡一道:
    // 防抖回写高频触发,内容没变不该惊动创作页重建与落盘。
    for (final c in ref.read(generateProvider).characters) {
      if (c.id != id) continue;
      if (c.positive == pos &&
          c.negative == neg &&
          c.positiveRaw == posRaw &&
          c.negativeRaw == negRaw &&
          listEquals(c.foldLinks, links)) {
        return;
      }
      break;
    }
    gen.updateCharacter(
      id,
      positive: pos,
      negative: neg,
      positiveRaw: posRaw,
      negativeRaw: negRaw,
      foldLinks: links,
    );
  }

  /// 写入当前段。structural=true(删/插/改权重等)必入撤销栈,打字按 700ms 合并。
  void editActive(
    String text, {
    bool structural = false,
    bool detachRemovedFolds = false,
  }) {
    if (text == state.activeText) return;
    final bodies = state.foldBodies;
    final existingLinks = validPromptFoldLinks(
      expandFolds(state.positiveText, bodies),
      expandFolds(state.negativeText, bodies),
      state.foldLinks,
    );
    var opposite = state.activePositive
        ? state.negativeText
        : state.positiveText;
    final oldRefs = parseFoldRefs(state.activeText, bodies);
    final newRefs = parseFoldRefs(text, bodies);
    final replacesFold = newRefs.any(
      (next) =>
          newRefs.where((ref) => ref.name == next.name).length >
          oldRefs.where((ref) => ref.name == next.name).length,
    );
    var removedLinkedFold = false;
    for (final link in existingLinks) {
      final name = state.activePositive ? link.positiveName : link.negativeName;
      if (newRefs.any((ref) => ref.name == name)) continue;
      final old = oldRefs.where((ref) => ref.name == name).toList();
      if (old.length != 1) continue;
      removedLinkedFold = true;
      // The editor's explicit unfold action replaces a reference with its body
      // in place (also within weight/disabled wrappers). It detaches the pair;
      // it never means deleting its counterpart.
      if (detachRemovedFolds ||
          replacesFold ||
          unfoldRef(state.activeText, old.single, bodies) == text) {
        continue;
      }
      final otherName = state.activePositive
          ? link.negativeName
          : link.positiveName;
      final other = parseFoldRefs(
        opposite,
        bodies,
      ).where((ref) => ref.name == otherName).toList();
      if (other.length == 1) {
        opposite = deleteFoldRef(opposite, other.single).$1;
      }
    }
    final positive = state.activePositive ? text : opposite;
    final negative = state.activePositive ? opposite : text;
    final nextLinks = validPromptFoldLinks(
      expandFolds(positive, bodies),
      expandFolds(negative, bodies),
      existingLinks,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (structural || removedLinkedFold || now - _lastPushMs > 700) {
      final snaps = _arc.snaps;
      snaps.add((state.positiveText, state.negativeText, state.foldLinks));
      if (snaps.length > _maxHistory) snaps.removeAt(0);
      _lastPushMs = now;
    }
    state = state.copyWith(
      positiveText: positive,
      negativeText: negative,
      foldLinks: nextLinks,
      canUndo: true,
    );
    _scheduleWriteBack();
  }

  void setActivePositive(bool v) {
    if (v == state.activePositive) return;
    state = state.copyWith(activePositive: v);
  }

  void undo() {
    final snaps = _arc.snaps;
    if (snaps.isEmpty) return;
    final s = snaps.removeLast();
    _lastPushMs = 0;
    state = state.copyWith(
      positiveText: s.$1,
      negativeText: s.$2,
      foldLinks: s.$3,
      canUndo: snaps.isNotEmpty,
    );
    _scheduleWriteBack();
  }

  String outputPositive() =>
      outputOf(expandFolds(state.positiveText, state.foldBodies));
  String outputNegative() =>
      outputOf(expandFolds(state.negativeText, state.foldBodies));
}
