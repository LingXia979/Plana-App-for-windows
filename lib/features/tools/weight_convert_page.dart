import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/platform/desktop.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/editor_theme.dart';
import '../../core/util/prompt_convert.dart';
import '../generate/generate_state.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../shell/shell_state.dart';

enum _Dir { sd2nai, nai2sd }

/// 权重转换(工具箱页签):SD ↔ NAI 提示词语法整串互转,
/// 结果带权重高亮;SD→NAI 可去 Lora、可一键导入创作页提示词。
class WeightConvertView extends ConsumerStatefulWidget {
  const WeightConvertView({super.key});

  @override
  ConsumerState<WeightConvertView> createState() => _WeightConvertViewState();
}

class _WeightConvertViewState extends ConsumerState<WeightConvertView> {
  final _input = TextEditingController();
  final _resultScroll = ScrollController();
  _Dir _dir = _Dir.sd2nai;
  bool _stripLora = true;
  String? _output;

  @override
  void dispose() {
    _input.dispose();
    _resultScroll.dispose();
    super.dispose();
  }

  void _convert() {
    var text = _input.text.trim();
    if (text.isEmpty) return;
    if (_dir == _Dir.sd2nai && _stripLora) text = stripLoraTags(text);
    setState(() {
      _output = _dir == _Dir.sd2nai
          ? convertSdToNai(text)
          : convertNaiToSd(text);
    });
  }

  void _copy() {
    final out = _output;
    if (out == null || out.isEmpty) return;
    Clipboard.setData(ClipboardData(text: out));
    hintSnack(context, '已复制', icon: Icons.check_circle_outline);
  }

  void _import() {
    final out = _output;
    if (out == null || out.isEmpty) return;
    ref.read(generateProvider.notifier).setPrompts(positive: out);
    hintSnack(context, '已导入提示词', icon: Icons.download_done);
    ref.read(shellIndexProvider.notifier).select(kTabCreate);
    if (!ref.read(desktopModeProvider)) Navigator.of(context).maybePop();
  }

  Widget _directionSwitch() => SegmentedButton<_Dir>(
    segments: const [
      ButtonSegment(value: _Dir.sd2nai, label: Text('SD → NAI')),
      ButtonSegment(value: _Dir.nai2sd, label: Text('NAI → SD')),
    ],
    selected: {_dir},
    onSelectionChanged: (s) => setState(() {
      _dir = s.first;
      _output = null;
    }),
    showSelectedIcon: false,
  );

  Widget _panel({
    required String title,
    required Widget editor,
    required Widget actions,
  }) {
    final scheme = context.scheme;
    return Material(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: context.texts.titleSmall),
            const SizedBox(height: 12),
            editor,
            const SizedBox(height: 12),
            actions,
          ],
        ),
      ),
    );
  }

  Widget _desktopView() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter, control: true): _convert,
      const SingleActivator(LogicalKeyboardKey.enter, meta: true): _convert,
    },
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scheme = context.scheme;
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final height = (MediaQuery.sizeOf(context).height * .44).clamp(
          240.0,
          420.0,
        );
        final hasOutput = _output != null && _output!.isNotEmpty;
        final input = _panel(
          title: _dir == _Dir.sd2nai ? 'SD 提示词' : 'NAI 提示词',
          editor: SizedBox(
            height: height,
            child: TextField(
              key: const ValueKey('weight-convert-input'),
              controller: _input,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              onChanged: (_) => setState(() => _output = null),
              style: mono(context, size: 14, weight: FontWeight.w400),
              decoration: InputDecoration(
                hintText: _dir == _Dir.sd2nai
                    ? '(masterpiece:1.2), (best quality), 1girl'
                    : '1.2::masterpiece::, {best quality}, 1girl',
                filled: true,
                fillColor: scheme.surfaceContainerLowest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
          actions: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Tooltip(
                message: Theme.of(context).platform == TargetPlatform.macOS
                    ? '⌘Enter 转换'
                    : 'Ctrl+Enter 转换',
                child: FilledButton.icon(
                  key: const ValueKey('weight-convert-run'),
                  onPressed: _input.text.trim().isEmpty ? null : _convert,
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('转换'),
                ),
              ),
              TextButton.icon(
                onPressed: _input.text.isEmpty
                    ? null
                    : () => setState(() {
                        _input.clear();
                        _output = null;
                      }),
                icon: const Icon(Icons.clear, size: 18),
                label: const Text('清空输入'),
              ),
            ],
          ),
        );
        final output = _panel(
          title: _dir == _Dir.sd2nai ? 'NAI 转换结果' : 'SD 转换结果',
          editor: SizedBox(
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: hasOutput
                  ? Scrollbar(
                      controller: _resultScroll,
                      child: SingleChildScrollView(
                        controller: _resultScroll,
                        padding: const EdgeInsets.all(14),
                        child: SelectableText.rich(
                          key: const ValueKey('weight-convert-output'),
                          TextSpan(
                            style: mono(
                              context,
                              size: 14,
                              weight: FontWeight.w400,
                            ),
                            children: _dir == _Dir.sd2nai
                                ? _naiSpans(context, _output!)
                                : _sdSpans(context, _output!),
                          ),
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        '转换结果会显示在这里',
                        style: context.texts.bodySmall!.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
            ),
          ),
          actions: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_dir == _Dir.sd2nai)
                FilledButton.tonalIcon(
                  onPressed: hasOutput ? _import : null,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('导入提示词'),
                ),
              FilledButton.icon(
                onPressed: hasOutput ? _copy : null,
                icon: const Icon(Icons.content_copy, size: 18),
                label: const Text('复制结果'),
              ),
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [
                _directionSwitch(),
                if (_dir == _Dir.sd2nai)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _stripLora,
                        onChanged: (value) => setState(() {
                          _stripLora = value ?? true;
                          _output = null;
                        }),
                      ),
                      const Text('去除 LoRA'),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (constraints.maxWidth >= 880 * scale)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: input),
                  const SizedBox(width: 16),
                  Expanded(child: output),
                ],
              )
            else ...[
              input,
              const SizedBox(height: 16),
              output,
            ],
          ],
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final desktop = ref.watch(desktopModeProvider);
    if (desktop) return _desktopView();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _directionSwitch()),
                if (_dir == _Dir.sd2nai) ...[
                  const SizedBox(width: 4),
                  Checkbox(
                    value: _stripLora,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setState(() => _stripLora = v ?? true),
                  ),
                  Text('去 Lora', style: context.texts.bodySmall),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _input,
                expands: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: mono(context, size: 13, weight: FontWeight.w400),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: scheme.surfaceContainerLow,
                  hintText: _dir == _Dir.sd2nai
                      ? '(masterpiece:1.2), (best quality), 1girl'
                      : '1.2::masterpiece::, {best quality}, 1girl',
                  hintStyle: TextStyle(color: scheme.outline, fontSize: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _convert,
              icon: const Icon(Icons.swap_horiz, size: 19),
              label: const Text('转换'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
            ),
            if (_output != null) ...[
              const SizedBox(height: 12),
              Expanded(
                flex: 3,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText.rich(
                      TextSpan(
                        style: mono(context, size: 13, weight: FontWeight.w400),
                        children: _dir == _Dir.sd2nai
                            ? _naiSpans(context, _output!)
                            : _sdSpans(context, _output!),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (_dir == _Dir.sd2nai)
                    FilledButton.tonalIcon(
                      onPressed: _import,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('导入提示词'),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.content_copy, size: 17),
                    label: const Text('复制结果'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---- 结果权重高亮(与编辑器同一套强调色,亮暗自适应) ----

EditorPalette _pal(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? EditorPalette.dark
    : EditorPalette.light;

final _naiNumRe = RegExp(r'(-?\d+(?:\.\d+)?)::');

/// NAI 结果:`w::…::` 按符号着色,`{…}` 加权底色,`[…]` 降权底色。
List<TextSpan> _naiSpans(BuildContext context, String text) {
  final pal = _pal(context);
  final up = pal.weightUpWash.withValues(alpha: .40);
  final upStrong = pal.weightUpWash.withValues(alpha: .55);
  final down = pal.weightDownWash.withValues(alpha: .22);
  final spans = <TextSpan>[];
  final buf = StringBuffer();
  var i = 0;
  final n = text.length;
  void flush() {
    if (buf.isNotEmpty) {
      spans.add(TextSpan(text: buf.toString()));
      buf.clear();
    }
  }

  while (i < n) {
    final ch = text[i];
    if (RegExp(r'\d').hasMatch(ch) || ch == '-') {
      final m = _naiNumRe.matchAsPrefix(text, i);
      if (m != null) {
        final end = text.indexOf('::', m.end);
        if (end != -1) {
          flush();
          final w = double.parse(m.group(1)!);
          spans.add(
            TextSpan(
              text: text.substring(i, end + 2),
              style: TextStyle(backgroundColor: w >= 1 ? upStrong : down),
            ),
          );
          i = end + 2;
          continue;
        }
      }
    }
    if (ch == '{' || ch == '[') {
      final close = ch == '{' ? '}' : ']';
      var d = 1;
      var j = i + 1;
      while (j < n && d > 0) {
        if (text[j] == ch) {
          d++;
        } else if (text[j] == close) {
          d--;
        }
        j++;
      }
      if (d == 0) {
        flush();
        spans.add(
          TextSpan(
            text: text.substring(i, j),
            style: TextStyle(backgroundColor: ch == '{' ? up : down),
          ),
        );
        i = j;
        continue;
      }
    }
    buf.write(ch);
    i++;
  }
  flush();
  return spans;
}

/// SD 结果:`(…:w)` 按 w 大小着色,`[…]` 降权底色。
List<TextSpan> _sdSpans(BuildContext context, String text) {
  final pal = _pal(context);
  final up = pal.weightUpWash.withValues(alpha: .40);
  final down = pal.weightDownWash.withValues(alpha: .22);
  final spans = <TextSpan>[];
  final buf = StringBuffer();
  var i = 0;
  final n = text.length;
  void flush() {
    if (buf.isNotEmpty) {
      spans.add(TextSpan(text: buf.toString()));
      buf.clear();
    }
  }

  while (i < n) {
    final ch = text[i];
    // 转义括号是字面内容,不参与着色
    if (ch == r'\' && i + 1 < n) {
      buf.write(text[i + 1]);
      i += 2;
      continue;
    }
    if (ch == '(' || ch == '[') {
      final close = ch == '(' ? ')' : ']';
      var d = 1;
      var j = i + 1;
      while (j < n && d > 0) {
        if (text[j] == ch) {
          d++;
        } else if (text[j] == close) {
          d--;
        }
        j++;
      }
      if (d == 0) {
        flush();
        var bg = ch == '[' ? down : up;
        if (ch == '(') {
          final inner = text.substring(i + 1, j - 1);
          final lc = inner.lastIndexOf(':');
          if (lc > 0) {
            final w = double.tryParse(inner.substring(lc + 1).trim());
            if (w != null && w < 1) bg = down;
          }
        }
        spans.add(
          TextSpan(
            text: text.substring(i, j),
            style: TextStyle(backgroundColor: bg),
          ),
        );
        i = j;
        continue;
      }
    }
    buf.write(ch);
    i++;
  }
  flush();
  return spans;
}
