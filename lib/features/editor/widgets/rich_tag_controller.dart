import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../editor_models.dart';

/// 富文本域基准样式。行高留高(2.0)给下方翻译预留空间。
/// letterSpacing 必须显式钉 0:TextField 会把主题 titleMedium(M3 带
/// letterSpacing .15)merge 进来,注音层布局却无主题——每字符差 .15px,
/// 累积到临界行翻转断行点,断行一漂整行注音错位(真机截图踩过)。
const TextStyle kEditorBaseStyle = TextStyle(
  fontSize: 16,
  height: 2.0,
  fontWeight: FontWeight.w500,
  letterSpacing: 0,
);

// ---- tag 宽度补偿(web chip 的 max(英文宽, 译文宽) 定总宽,移植到字符串模型)----
// 译文比词宽时,给词尾逗号动态加 letterSpacing 把下一词推开——注音地皮恒足,
// 相邻译文不再重叠。TextField 与注音/圈框/排序层共用同一间距,布局始终同构。
//
// 注意:这里**没有任何隐藏字符的手段**。折叠体不进正文(占位符 `<#名字>` +
// 旁路表,见 editor_models 的折叠占位符一节),正文所见即所有——此前两版
// 「藏字」实现(fontSize 0.01 / 负 letterSpacing 收零)都在真机字形引擎上
// 翻了车(撑宽换行 / 鬼缩进),教训:不要跟断行器搏斗。

/// 注音字号(与 _FuriganaPainter 的 _transSize 一致,宽度测量用)。
const TextStyle kTransMeasureStyle = TextStyle(fontSize: 9.5, height: 1);

final _widthCache = <(String, TextStyle, TextScaler), double>{};

double _textWidth(String s, TextStyle style, TextScaler scaler) {
  final key = (s, style, scaler);
  final hit = _widthCache[key];
  if (hit != null) return hit;
  final tp = TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final w = tp.width;
  tp.dispose();
  if (_widthCache.length > 6000) _widthCache.clear();
  return _widthCache[key] = w;
}

/// 需要补偿的字符下标(**词段最后一个字符**)→ 额外 letterSpacing。
/// 附着词尾字符:词内不可断行,断行器把「词+译文预算」当整体处理——
/// 行尾放不下就整词(带译文)折到下一行,译文永不出屏。
/// [base] 必须与 TextField 实际渲染样式同字号,否则补偿量对不上。
Map<int, double> tagExtraSpacing(
  String text,
  TextScaler scaler, {
  TextStyle base = kEditorBaseStyle,
}) {
  final out = <int, double>{};
  for (final t in parseToks(text)) {
    final tr = t.trans;
    if (tr == null || tr.isEmpty || t.segEnd <= t.segStart) continue;
    final segW = _textWidth(text.substring(t.segStart, t.segEnd), base, scaler);
    final transW = _textWidth(tr, kTransMeasureStyle, scaler);
    final extra = transW - segW;
    if (extra > 0) out[t.segEnd - 1] = extra;
  }
  return out;
}

/// 布局同构 span(注音/圈框/排序层测量用):基准样式 + 同款间距。
TextSpan measureSpan(
  String text,
  TextScaler scaler, {
  TextStyle base = kEditorBaseStyle,
}) {
  final spacing = tagExtraSpacing(text, scaler, base: base);
  if (spacing.isEmpty) {
    return TextSpan(text: text, style: base);
  }
  final children = <InlineSpan>[];
  var start = 0;
  for (final k in spacing.keys.toList()..sort()) {
    if (k > start) children.add(TextSpan(text: text.substring(start, k)));
    children.add(
      TextSpan(
        text: text[k],
        style: TextStyle(letterSpacing: spacing[k]),
      ),
    );
    start = k + 1;
  }
  if (start < text.length) children.add(TextSpan(text: text.substring(start)));
  return TextSpan(style: base, children: children);
}

/// 光标驱动编辑器的文本控制器:文本含**原样权重语法**(`N::tag::`/`{}`/`[]`)
/// 与折叠占位符 `<#名字>`,[buildTextSpan] 现算 token 做文字着色:禁用灰+
/// 删除线,`::`/括号等记号淡显 45%,折叠占位符整体 primary(尖括号淡一档)。
/// 权重底色不在这里画——由 AnnotatedField 的权重底色绘制层负责。
/// 只改颜色不改字号字重,与绘制层布局一致。
class RichTagController extends TextEditingController {
  RichTagController({super.text});

  /// 注音翻译开关(编辑器设置)。关掉时不再做译文宽度补偿——
  /// 注音层同时被 AnnotatedField 摘除,无布局同构需求。
  bool showTrans = true;

  /// 折叠表(名字 → 折叠体),由页面随编辑器状态灌入。
  /// 只用于判定哪些 `<#x>` 是真占位符(挂了号才染色/热区),不参与布局。
  Map<String, String> foldBodies = const {};

  /// 文本没变但外部数据到了(翻译缓存灌注完成)时手动触发重建/重绘。
  void refresh() => notifyListeners();

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? kEditorBaseStyle;
    final scheme = context.scheme;
    final t = text;
    final spans = <WeightSpan>[];
    final toks = parseToks(t, weightSpans: spans);
    final refs = parseFoldRefs(t, foldBodies);
    final spacing = showTrans
        ? tagExtraSpacing(t, MediaQuery.textScalerOf(context), base: base)
        : const <int, double>{};

    bool isMarker(String ch) =>
        ch == ':' ||
        ch == '{' ||
        ch == '}' ||
        ch == '[' ||
        ch == ']' ||
        ch == '~';

    // 跨词条的组记号落在 token 之外,但前景色应和单词条一致:
    // 数字用正文色,语法记号淡显。倍率方向和强度只由权重底色表达。
    Color? groupMarkColor(int k) {
      final ch = t[k];
      final marker = isMarker(ch);
      final isSyntax =
          marker ||
          ch == '-' ||
          ch == '.' ||
          (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39);
      if (!isSyntax || !spans.any((s) => k >= s.start && k < s.end)) {
        return null;
      }
      return marker
          ? scheme.onSurface.withValues(alpha: .45)
          : scheme.onSurface;
    }

    // 折叠占位符 `<#名字>`:`#名字` 全彩 primary 当标题读,两侧尖括号淡一档。
    // 占位符是货真价实的正文字符,只着色、零布局技巧。
    Color? foldColor(int k) {
      for (final r in refs) {
        if (k < r.start || k >= r.end) continue;
        final edge = k == r.start || k == r.end - 1;
        return edge ? scheme.primary.withValues(alpha: .40) : scheme.primary;
      }
      return null;
    }

    // 逐字符着色:token 内=正文色(记号淡一档),token 外=分隔色
    final children = <InlineSpan>[];
    final buf = StringBuffer();
    Color? curColor;
    var curStrike = false;
    var ti = 0;

    void flush() {
      if (buf.isEmpty) return;
      children.add(
        TextSpan(
          text: buf.toString(),
          style: base.copyWith(
            color: curColor,
            decoration: curStrike ? TextDecoration.lineThrough : null,
            decorationColor: curColor,
            // 划线加粗:1px 的细线在正文字号下几乎看不见
            decorationThickness: curStrike ? 2 : null,
          ),
        ),
      );
      buf.clear();
    }

    for (var k = 0; k < t.length; k++) {
      while (ti < toks.length && toks[ti].segEnd <= k) {
        ti++;
      }
      final inTok =
          ti < toks.length && k >= toks[ti].segStart && k < toks[ti].segEnd;
      Color c;
      var strike = false;
      final fc = foldColor(k);
      if (fc != null) {
        c = fc;
      } else if (!inTok) {
        // 逗号/空隙灰;组权重记号沿用词条内的中性前景色
        c = groupMarkColor(k) ?? scheme.outline;
      } else {
        final tok = toks[ti];
        final ch = t[k];
        final marker = isMarker(ch);
        // 禁用要**一眼看得出来**。原先只降到 onSurfaceVariant,那个色和正常
        // 正文差得太少,加一道细划线基本看不出区别(实测反馈)。改成 outline
        // (最暗的那档前景色),配合加粗的划线和底下那层灰色带,三样一起说。
        final tc = tok.disabled ? scheme.outline : scheme.onSurface;
        c = marker ? tc.withValues(alpha: tok.disabled ? .3 : .45) : tc;
        strike = tok.disabled;
      }
      final sp = spacing[k];
      if (sp != null) {
        // 宽度补偿的词尾字符:独立 span 携带 letterSpacing(把下一词推开)
        flush();
        children.add(
          TextSpan(
            text: t[k],
            style: base.copyWith(
              color: c,
              decoration: strike ? TextDecoration.lineThrough : null,
              decorationColor: c,
              decorationThickness: strike ? 2 : null,
              letterSpacing: sp,
            ),
          ),
        );
        curColor = c;
        curStrike = strike;
        continue;
      }
      if (c != curColor || strike != curStrike) {
        flush();
        curColor = c;
        curStrike = strike;
      }
      buf.write(t[k]);
    }
    flush();

    return TextSpan(style: base, children: children);
  }
}
