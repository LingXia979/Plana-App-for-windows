import '../../core/util/prompt_tokens.dart' show cleanPromptToken;
import '../editor/editor_models.dart'
    show
        PromptFoldLink,
        draftOf,
        outputOf,
        pickEditorText,
        parseFolds,
        parseToks,
        deleteTok,
        setUnitsDisabled,
        stripFolds,
        topLevelUnits,
        validPromptFoldLinks;
import '../inspiration/tag_models.dart' show TagCategory, TagEntry;
import 'models.dart';

/// 主提示词分区的纯函数:拼接、计数口径、列表整理。状态写入在 GenerateNotifier
/// 与 CanvasWorkspaceNotifier.updatePrompts。

/// 分区头尾的空白与逗号:拼接时去掉,免得出现 `a,, b`。
String _clean(String s) =>
    s.trim().replaceAll(RegExp(r'^[,，\s]+|[,，\s]+$'), '');

/// 这一格的这一侧进不进载荷。主体的负面一直进:卡上负面那行是整张卡的,
/// 停用 / 删掉主体那一行只管它的正向。
bool _on(PromptSection s, {required bool positive}) =>
    (s.isMain && !positive) || s.enabled;

/// 主体那一行删掉了,主体的词还在(负面一直在;正向是之后又被写进来的),
/// 按排在最上面算 —— 卡上也是补在最上面(见 [withMainRow])。
List<PromptSection> _withMain(List<PromptSection> list) =>
    list.any((x) => x.isMain) ? list : [const PromptSection.main(), ...list];

/// 卡上和改分区时用的那份行:主体那一行删掉之后主体又被写进了正向(读图导入、
/// AI 助手…),主体回到最上面。
List<PromptSection> withMainRow(List<PromptSection> list, String mainPrompt) =>
    list.isEmpty || list.any((x) => x.isMain) || mainPrompt.trim().isEmpty
    ? list
    : [const PromptSection.main(), ...list];

/// 主体的正向进不进载荷。没分区、主体那一行删掉了都算进:那时它要么就是
/// 全部的词,要么是空的。
bool mainEnabled(List<PromptSection> list) => list
    .firstWhere((x) => x.isMain, orElse: () => const PromptSection.main())
    .enabled;

/// 按行序把主体和启用的分区拼成一整串。[main] 是主体那一侧的词(正或负)。
///
/// 正向按分区完整拼接,不同画师串／角色中的相同词也保留。
/// 负面仍合并重复的普通词,不改动任何分区保存的原文。
String joinSections(
  List<PromptSection> sections,
  String main, {
  required bool positive,
}) {
  if (sections.isEmpty) return main;
  final seen = <String>{};
  return [
    for (final s in _withMain(sections))
      if (_on(s, positive: positive))
        if (positive)
          _clean(s.isMain ? main : s.positive)
        else
          _dropSeen(_clean(s.isMain ? main : s.negative), seen),
  ].where((p) => p.isNotEmpty).join(', ');
}

/// 带记号(权重、折叠、禁用、换行)的词不参与去重:拆开比对会拆坏它们。
final _syntax = RegExp(r'[{}\[\]:~<>#|\n]');

/// 去掉 [text] 里 [seen] 已有的普通词,再把这一格的普通词记进 [seen]。
/// 同一格里自己重复的照原样留着。
String _dropSeen(String text, Set<String> seen) {
  if (text.isEmpty) return text;
  final own = <String>{};
  final kept = <String>[];
  for (final piece in text.split(RegExp(r'[,，]'))) {
    final key = _syntax.hasMatch(piece) ? '' : cleanPromptToken(piece);
    if (key.isNotEmpty) {
      if (seen.contains(key)) continue;
      own.add(key);
    }
    kept.add(piece);
  }
  seen.addAll(own);
  return _clean(kept.join(','));
}

/// 去重比对用的键:普通词按 [cleanPromptToken],带记号的按原样(空白归一)。
String _wordKey(String piece) {
  final t = piece.trim();
  if (!_syntax.hasMatch(t)) return 'p:${cleanPromptToken(t)}';
  return 's:${t.replaceAll(RegExp(r'\s+'), ' ').toLowerCase()}';
}

/// 逗号切开,标出哪几段是能整段拿掉的顶层词:不在 `{}` `[]` `::` 组里,
/// 自身记号也收了口。
List<(String, bool)> _topPieces(String text) {
  final out = <(String, bool)>[];
  var depth = 0;
  var inWeight = false;
  var inDisabled = false;
  var foldDepth = 0;
  for (final piece in text.split(RegExp(r'[,，]'))) {
    final top = depth == 0 && !inWeight && !inDisabled && foldDepth == 0;
    var d = 0;
    var tildes = 0;
    for (final c in piece.split('')) {
      if (c == '{' || c == '[') d++;
      if (c == '}' || c == ']') d--;
      if (c == '~') tildes++;
    }
    final weights = '::'.allMatches(piece).length;
    depth += d;
    foldDepth += '<#'.allMatches(piece).length - '#>'.allMatches(piece).length;
    if (weights.isOdd) inWeight = !inWeight;
    if (tildes.isOdd) inDisabled = !inDisabled;
    out.add((
      piece,
      top &&
          d == 0 &&
          foldDepth == 0 &&
          !inDisabled &&
          weights.isEven &&
          tildes.isEven &&
          piece.trim().isNotEmpty,
    ));
  }
  return out;
}

/// 从 [text] 里拿掉启用的格子里已有的顶层词。[main] 是主体那一侧的词,
/// [withMain] 为 false 时主体不算。
String dropSectionWords(
  String text,
  List<PromptSection> sections,
  String main, {
  required bool positive,
  bool withMain = false,
}) {
  if (text.trim().isEmpty) return text;
  final have = <String>{
    for (final s in _withMain(sections))
      if ((withMain || !s.isMain) && _on(s, positive: positive))
        for (final (p, top) in _topPieces(
          s.isMain ? main : (positive ? s.positive : s.negative),
        ))
          if (top) _wordKey(p),
  };
  if (have.isEmpty) return text;
  return _clean(
    [
      for (final (p, top) in _topPieces(text))
        if (!top || !have.contains(_wordKey(p))) p,
    ].join(','),
  );
}

/// AI 助手的提议写进创作页的方式。
enum SectionImport {
  /// 只换主体,分区留着;分区里已有的词不再写进主体。
  main,

  /// 接在最后新建一格,原有的不动;已有的词不再写进这一格。
  newSection,

  /// 分区整列清掉,整份写进主体。
  clear,
}

/// 一组正负向按 [mode] 写进 [s]。导入和「直接生成」共用,两条路出同一张图。
GenerateState importPromptsInto(
  GenerateState s,
  String positive,
  String negative,
  SectionImport mode, {
  required String Function() newId,
}) {
  final mainMode = mode == SectionImport.main && s.sections.isNotEmpty;
  if (mode == SectionImport.newSection) {
    final pos = dropSectionWords(
      positive,
      s.sections,
      s.prompt,
      positive: true,
      withMain: true,
    );
    final neg = dropSectionWords(
      negative,
      s.sections,
      s.negativePrompt,
      positive: false,
      withMain: true,
    );
    if (pos.trim().isEmpty && neg.trim().isEmpty) return s;
    final rows = s.sections.isEmpty
        ? const [PromptSection.main()]
        : withMainRow(s.sections, s.prompt);
    return s.copyWith(
      sections: [
        ...rows,
        PromptSection(id: newId(), name: 'AI', positive: pos, negative: neg),
      ],
    );
  }
  final pos = mainMode
      ? dropSectionWords(positive, s.sections, s.prompt, positive: true)
      : positive;
  final neg = mainMode
      ? dropSectionWords(
          negative,
          s.sections,
          s.negativePrompt,
          positive: false,
        )
      : negative;
  return s.copyWith(
    prompt: pos,
    promptRaw: pos == s.prompt ? s.promptRaw : '',
    negativePrompt: neg,
    negativePromptRaw: neg == s.negativePrompt ? s.negativePromptRaw : '',
    sections: !mainMode
        ? const []
        : [
            for (final x in withMainRow(s.sections, pos))
              x.isMain && pos.trim().isNotEmpty ? x.copyWith(enabled: true) : x,
          ],
  );
}

/// Compose raw drafts as well as their paired-fold provenance. Fold names and
/// link IDs are local to an editor, so separate sections may reuse both.
(String, String, List<PromptFoldLink>) _composeDrafts(GenerateState state) {
  final parts = [
    for (final section in _withMain(state.sections))
      (
        positive: _on(section, positive: true)
            ? pickEditorText(
                section.isMain ? state.promptRaw : section.positiveRaw,
                section.isMain ? state.prompt : section.positive,
              )
            : '',
        negative: _on(section, positive: false)
            ? pickEditorText(
                section.isMain ? state.negativePromptRaw : section.negativeRaw,
                section.isMain ? state.negativePrompt : section.negative,
              )
            : '',
        links: section.isMain ? state.promptFoldLinks : section.foldLinks,
      ),
  ];
  return _mergeDraftParts(parts);
}

(String, String, List<PromptFoldLink>) _mergeDraftParts(
  List<({String positive, String negative, List<PromptFoldLink> links})>
  parts, {
  bool deduplicate = true,
}) {
  final reservedPos = {
    for (final p in parts)
      for (final f in parseFolds(p.positive)) f.name,
  };
  final reservedNeg = {
    for (final p in parts)
      for (final f in parseFolds(p.negative)) f.name,
  };
  final usedPos = <String>{}, usedNeg = <String>{}, ids = <String>{};
  final seenNeg = <String>{};
  final positives = <String>[], negatives = <String>[];
  final links = <PromptFoldLink>[];
  for (final part in parts) {
    final valid = validPromptFoldLinks(
      part.positive,
      part.negative,
      part.links,
    );
    final (positive, posNames) = _uniqueFoldNames(
      part.positive,
      usedPos,
      reservedPos,
    );
    final (negative, negNames) = _uniqueFoldNames(
      part.negative,
      usedNeg,
      reservedNeg,
    );
    final pos = positive;
    final neg = deduplicate ? _dropSeenDraft(negative, seenNeg) : negative;
    if (_clean(pos).isNotEmpty) positives.add(_clean(pos));
    if (_clean(neg).isNotEmpty) negatives.add(_clean(neg));
    final posFolds = parseFolds(pos), negFolds = parseFolds(neg);
    for (final link in valid) {
      final pn = posNames[link.positiveName]!,
          nn = negNames[link.negativeName]!;
      final pf = posFolds.where((f) => f.name == pn).firstOrNull;
      final nf = negFolds.where((f) => f.name == nn).firstOrNull;
      if (pf == null ||
          nf == null ||
          pos.substring(pf.bodyStart, pf.bodyEnd).trim().isEmpty ||
          neg.substring(nf.bodyStart, nf.bodyEnd).trim().isEmpty) {
        continue;
      }
      var id = link.id;
      for (var suffix = 2; !ids.add(id); suffix++) {
        id = '${link.id}:$suffix';
      }
      links.add(
        PromptFoldLink(
          id: id,
          positiveName: pn,
          positiveBody: pos.substring(pf.bodyStart, pf.bodyEnd).trim(),
          negativeName: nn,
          negativeBody: neg.substring(nf.bodyStart, nf.bodyEnd).trim(),
        ),
      );
    }
  }
  return (positives.join(', '), negatives.join(', '), links);
}

(String, Map<String, String>) _uniqueFoldNames(
  String raw,
  Set<String> used,
  Set<String> reserved,
) {
  final names = <String, String>{};
  final edits = <(int, int, String)>[];
  for (final fold in parseFolds(raw)) {
    var name = fold.name;
    if (used.contains(name)) {
      for (var suffix = 2; ; suffix++) {
        name = '${fold.name} · $suffix';
        if (!used.contains(name) && !reserved.contains(name)) break;
      }
    }
    used.add(name);
    names[fold.name] = name;
    if (name != fold.name) edits.add((fold.nameStart, fold.nameEnd, name));
  }
  for (final (start, end, name) in edits.reversed) {
    raw = raw.replaceRange(start, end, name);
  }
  return (raw, names);
}

/// Remove the same ordinary duplicates as joinSections, preserving disabled
/// tokens, weights and fold structure. Unusual syntax falls back per section.
String _dropSeenDraft(String raw, Set<String> seen) {
  final previous = {...seen};
  final expected = _dropSeen(_clean(outputOf(raw)), seen);
  var draft = raw;
  final tokens = parseToks(draft);
  for (final original in tokens.reversed) {
    if (original.disabled || original.groupMult != 1) continue;
    final piece = draft.substring(original.coreStart, original.coreEnd);
    if (_syntax.hasMatch(piece) ||
        !previous.contains(cleanPromptToken(piece))) {
      continue;
    }
    draft = deleteTok(draft, original).$1;
  }
  return _clean(outputOf(draft)) == expected ? draft : expected;
}

/// 生成快照:分区拼进主提示词,快照里不再带分区。
///
/// 入库、「重新生成」、图库搜索、图片元数据都按这一整串走,和发给 NAI 的一致;
/// 草稿也照样拼一份,导回创作页时折叠还在。没有分区原样返回。
GenerateState composeSections(GenerateState s) {
  if (s.sections.isEmpty) return s;
  final pos = joinSections(s.sections, s.prompt, positive: true);
  final neg = joinSections(s.sections, s.negativePrompt, positive: false);
  final (posDraft, negDraft, links) = _composeDrafts(s);
  // 跨格去重删过词时草稿对不上定稿,不带(读取侧也会这么判,这里先省一份)
  String draft(String d, String out) =>
      outputOf(d) == out ? draftOf(d, out) : '';
  return s.copyWith(
    prompt: pos,
    negativePrompt: neg,
    promptRaw: draft(posDraft, pos),
    negativePromptRaw: draft(negDraft, neg),
    promptFoldLinks: validPromptFoldLinks(
      draft(posDraft, pos),
      draft(negDraft, neg),
      links,
    ),
    sections: const [],
  );
}

/// token 读数要算进去的分区词(启用、不含主体),[except] 那一格除外
/// (编辑器里正开着它,读数用编辑器里的实时文本)。
List<String> sectionTexts(
  List<PromptSection> sections, {
  required bool positive,
  String? except,
}) => [
  for (final s in sections)
    if (!s.isMain && s.enabled && s.id != except)
      positive ? s.positive : s.negative,
];

/// 主体最多一行(可以没有:那一行删掉了)。只剩主体(或什么都没有)就整列清空,
/// 卡片回到原来的样子 —— 剩下的主体是停用着的除外:回到原样就没处看出它停着,
/// 正向会悄悄又进载荷。
List<PromptSection> normalizeSections(List<PromptSection> list) {
  if (!list.any((s) => !s.isMain)) {
    final main = list.where((s) => s.isMain).firstOrNull;
    return main != null && !main.enabled ? [main] : const [];
  }
  final out = <PromptSection>[];
  var hasMain = false;
  for (final s in list) {
    if (s.isMain) {
      if (hasMain) continue;
      hasMain = true;
    }
    out.add(s);
  }
  return out;
}

/// 整段的词都标成禁用(`~tag~`)。折叠先摊开:折叠单元套不了禁用。
String disableAllTags(String draft) {
  final plain = stripFolds(draft);
  final n = topLevelUnits(plain, const {}).length;
  if (n == 0) return plain;
  return setUnitsDisabled(plain, const {}, [
    for (var i = 0; i < n; i++) i,
  ], true);
}

/// 多选「合并」:勾的几格合成一格。留下的是勾选里的主体(勾了的话,主体删不掉),
/// 否则最上面那格,名字、位置不变;各格的词按行序从上往下接,挨着的几格合完
/// 拼出来的串一字不差。有一格开着合完就开着,停用那几格的词带着禁用标记进来:
/// 原来不出图的合完也不出图。不到两格返回 null。
GenerateState? mergeSectionsIn(GenerateState s, Set<String> ids) {
  final picked = [
    for (final x in s.sections)
      if (ids.contains(x.id)) x,
  ];
  if (picked.length < 2) return null;
  final target = picked.firstWhere((x) => x.isMain, orElse: () => picked.first);
  String pos(PromptSection x) => x.isMain
      ? pickEditorText(s.promptRaw, s.prompt)
      : pickEditorText(x.positiveRaw, x.positive);
  String neg(PromptSection x) => x.isMain
      ? pickEditorText(s.negativePromptRaw, s.negativePrompt)
      : pickEditorText(x.negativeRaw, x.negative);
  final on = picked.any((x) => x.enabled);
  // 合完那一格(那一侧)开着,才需要给停用那几段打禁用标记;主体的负面
  // 一直开着(见 _on),合进主体时负面那侧也就一直开着
  final negOn = target.isMain || on;
  String side(PromptSection x, String d, {required bool positive}) =>
      (positive ? on : negOn) &&
          !_on(x, positive: positive) &&
          d.trim().isNotEmpty
      ? disableAllTags(d)
      : d;
  final (pDraft, nDraft, links) = _mergeDraftParts([
    for (final x in picked)
      (
        positive: side(x, pos(x), positive: true),
        negative: side(x, neg(x), positive: false),
        links: x.isMain ? s.promptFoldLinks : x.foldLinks,
      ),
  ], deduplicate: false);
  final p = outputOf(pDraft), n = outputOf(nDraft);
  final rest = [
    for (final x in s.sections)
      if (!ids.contains(x.id) || x.id == target.id) x,
  ];
  if (target.isMain) {
    return s.copyWith(
      prompt: p,
      promptRaw: draftOf(pDraft, p),
      negativePrompt: n,
      negativePromptRaw: draftOf(nDraft, n),
      promptFoldLinks: links,
      sections: normalizeSections([
        for (final x in rest) x.isMain ? x.copyWith(enabled: on) : x,
      ]),
    );
  }
  return s.copyWith(
    sections: normalizeSections([
      for (final x in rest)
        x.id == target.id
            ? x.copyWith(
                positive: p,
                positiveRaw: draftOf(pDraft, p),
                negative: n,
                negativeRaw: draftOf(nDraft, n),
                foldLinks: links,
                enabled: on,
              )
            : x,
    ]),
  );
}

/// 新画布沿用的骨架:名字、顺序、开关留着,词清空。
List<PromptSection> sectionSkeleton(List<PromptSection> list) => [
  for (final s in list)
    s.isMain
        ? PromptSection.main(name: s.name)
        : PromptSection(
            id: s.id,
            name: s.name,
            enabled: s.enabled,
            artist: s.artist,
          ),
];

/// 新分区的默认名「分区 N」,N 取第一个没被占用的序号。
String nextSectionName(List<PromptSection> list) {
  final used = {for (final s in list) s.name};
  var n = 1;
  while (used.contains('分区 $n')) {
    n++;
  }
  return '分区 $n';
}

/// 删掉的分区放回原位。删的是最后一格时主体也跟着没了,[main] 是当时的主体
/// (那时本来就没有主体那一行就是 null)。
List<PromptSection> restoreSection(
  List<PromptSection> list,
  PromptSection removed,
  int index, {
  PromptSection? main = const PromptSection.main(),
}) {
  final out = list.isEmpty && main != null && !removed.isMain
      ? [main]
      : [...list];
  out.insert(index.clamp(0, out.length), removed);
  return normalizeSections(out);
}

/// 灵感库条目各自成一格,不折叠:名字取条目编号／名称,正负向原样
/// 放进这一格。新格子一律接在最后,按加进来的先后往下排 —— 别按分类插到
/// 主体前后,那样主体看着像在跳。
///
/// 每次导入都建立独立分区,不按已有词或同名分区去重,也不修改旧分区的开关。
/// 没分区时连主体一起建出来。
List<PromptSection> withEntrySections(
  List<PromptSection> list,
  String mainPrompt,
  Iterable<TagEntry> entries, {
  required String Function() newId,
}) {
  final rows = withMainRow(list, mainPrompt);
  final out = rows.isEmpty ? [const PromptSection.main()] : [...rows];
  for (final e in entries) {
    final rawPos = e.positive.trim(), rawNeg = e.negative.trim();
    if (rawPos.isEmpty && rawNeg.isEmpty) continue;
    final pos = outputOf(rawPos), neg = outputOf(rawNeg);
    final name = e.name.trim();
    final sec = PromptSection(
      id: newId(),
      name: name.isEmpty ? nextSectionName(out) : name,
      positive: pos,
      positiveRaw: draftOf(rawPos, pos),
      negative: neg,
      negativeRaw: draftOf(rawNeg, neg),
      artist: e.category == TagCategory.artist,
    );
    out.add(sec);
  }
  return normalizeSections(out);
}
