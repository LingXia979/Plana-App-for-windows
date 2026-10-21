import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/nai_tokenizer.dart';
import '../../editor/editor_page.dart';
import '../generate_state.dart';
import '../models.dart' show tokenLimitOf;
import '../prompt_presets.dart';
import 'common.dart';

/// 提示词卡:头部 token 进度条 + 正文段落预览 + 负面单行(带 +N 溢出与独立计数)。
/// 常驻展开;头部右侧为「清空正向」(可撤销)。
class PromptCard extends ConsumerWidget {
  const PromptCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    // web totalTokenCount 口径:主串 + 启用角色串 + 激活预设(都实际参与生成)。
    // 角色串取 countedCharactersProvider —— 模块不可见(anima 等)时为空,
    // 不然会出现「切到 anima 计数凭空变大」的幽灵。
    final tok = ref.watch(naiTokenizerProvider).value;
    final preset = ref.watch(activePromptPresetProvider);
    final chars = ref.watch(countedCharactersProvider);
    final promptTokens = totalPromptTokens(
      tok,
      main: state.prompt,
      parts: [for (final c in chars) c.positive],
      preset: preset?.positive ?? '',
    );
    final negTokens = totalPromptTokens(
      tok,
      main: state.negativePrompt,
      parts: [for (final c in chars) c.negative],
      preset: preset?.negative ?? '',
    );
    // 上限按当前模型取(NAI 5 抬到 703/1471,其余 512),读数与编辑器顶栏同源。
    final limit = tokenLimitOf(state.params.model);
    final over = promptTokens > limit;
    final ratio = (promptTokens / limit).clamp(0.0, 1.0);
    final barColor = over ? scheme.error : scheme.primary;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 8, 13, 4),
            child: Row(
              children: [
                Icon(Icons.subject, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 9),
                Text(
                  '提示词',
                  style: context.texts.bodyLarge!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  '$promptTokens',
                  style: mono(
                    context,
                    size: 11,
                    weight: FontWeight.w700,
                  ).copyWith(color: over ? scheme.error : scheme.onSurface),
                ),
                Text(
                  ' / $limit',
                  style: mono(
                    context,
                    size: 11,
                    weight: FontWeight.w500,
                  ).copyWith(color: scheme.outline),
                ),
                const Spacer(),
                RoundIconBtn(
                  Icons.delete_sweep_outlined,
                  tooltip: '清空正向提示词',
                  color: scheme.onSurfaceVariant,
                  onTap: () {
                    final old = state.prompt;
                    if (old.isEmpty) return;
                    notifier.setPrompts(positive: '');
                    hintSnack(
                      context,
                      '已清空正向提示词',
                      icon: Icons.delete_sweep_outlined,
                      actionLabel: '撤销',
                      onAction: () => notifier.setPrompts(positive: old),
                    );
                  },
                ),
                const SizedBox(width: 6),
                // 常驻下拉图标:提示词卡固定展开(不折叠),此处仅为让卡头与下方
                // 各功能卡(SectionCard 尾部 chevron)在视觉上对齐,不接手势。
                Icon(Icons.expand_more, size: 22, color: scheme.outline),
              ],
            ),
          ),
          // token 用量进度条
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 0, 15, 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: ratio, end: ratio),
                duration: Motion.medium,
                builder: (_, v, _) => LinearProgressIndicator(
                  value: v,
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: barColor,
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 正面:段落预览
              InkWell(
                onTap: () => _openEditor(context, positive: true),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(15, 12, 15, 10),
                  child: Text(
                    state.prompt.isEmpty ? '点击编辑正面提示词…' : state.prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodyLarge!.copyWith(
                      height: 1.5,
                      color: state.prompt.isEmpty
                          ? scheme.outline
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ),
              // 负面:块标 + 单行(+N)+ 独立计数
              if (state.params.isNaiMedium)
                const Padding(
                  padding: EdgeInsets.fromLTRB(15, 6, 15, 14),
                  child: Text('Medium 使用固定负面预设，原负面词已保留'),
                )
              else
                InkWell(
                  onTap: () => _openEditor(context, positive: false),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(15, 6, 15, 14),
                    child: Row(
                      children: [
                        Icon(Icons.block, size: 17, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _negPreview(state.negativePrompt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodyMedium!.copyWith(
                              color: scheme.error,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$negTokens',
                          style: mono(
                            context,
                            size: 12,
                            weight: FontWeight.w500,
                          ).copyWith(color: scheme.outline),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 负面预览:前 3 个 tag + "+N" 溢出提示
  static String _negPreview(String neg) {
    final tags = neg
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (tags.isEmpty) return '点击编辑负面提示词…';
    final shown = tags.take(3).join(', ');
    final extra = tags.length - 3;
    return extra > 0 ? '$shown +$extra' : shown;
  }

  void _openEditor(BuildContext context, {required bool positive}) {
    Navigator.of(context).push(sharedAxisRoute(EditorPage(positive: positive)));
  }
}
