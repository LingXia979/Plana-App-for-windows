import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/nai_tokenizer.dart';
import '../../generate/generate_state.dart';
import '../../generate/models.dart' show tokenLimitOf;
import '../../generate/prompt_presets.dart';
import '../../generate/prompt_sections.dart' show mainEnabled, sectionTexts;
import '../../generate/widgets/common.dart' show hintSnack;
import '../data/tag_favorites.dart';
import '../editor_state.dart';
import 'prompt_preset_menu_button.dart';

/// Compact desktop controls around the same editor used on mobile.
class InlineEditorChrome extends ConsumerWidget {
  const InlineEditorChrome({
    super.key,
    required this.child,
    required this.onSettings,
    required this.onToggleMode,
    required this.chipMode,
    this.charId,
    this.sectionId,
    this.onInsertFavorite,
  });

  final Widget child;
  final VoidCallback onSettings;
  final VoidCallback onToggleMode;
  final bool chipMode;
  final String? charId;
  final String? sectionId;
  final void Function(String)? onInsertFavorite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final state = ref.watch(editorProvider);
    final medium = ref.watch(
      generateProvider.select((s) => s.params.isNaiMedium),
    );
    final notifier = ref.read(editorProvider.notifier);
    final character = charId != null;
    final prefix = character
        ? 'desktop-character-$charId'
        : sectionId != null
        ? 'desktop-section-$sectionId'
        : 'desktop-prompt';
    final generated = ref.watch(generateProvider);
    final favorites = ref.watch(tagFavoritesProvider);
    final preset = character ? null : ref.watch(activePromptPresetProvider);
    final mainOn =
        character || !state.activePositive || mainEnabled(generated.sections);
    final tokens = totalPromptTokens(
      ref.watch(naiTokenizerProvider).value,
      main: sectionId == null && !mainOn ? '' : state.activeOutput,
      parts: [
        if (!character) ...[
          if (sectionId != null && mainOn)
            state.activePositive ? generated.prompt : generated.negativePrompt,
          ...sectionTexts(
            generated.sections,
            positive: state.activePositive,
            except: sectionId,
          ),
        ],
        if (!character)
          for (final c in ref.watch(countedCharactersProvider))
            state.activePositive ? c.positive : c.negative,
      ],
      preset: preset == null
          ? ''
          : (state.activePositive ? preset.positive : preset.negative),
    );
    final limit = tokenLimitOf(
      ref.watch(generateProvider.select((s) => s.params.model)),
    );
    final over = tokens > limit;
    Widget tab(bool positive, String label, IconData icon) {
      final selected = state.activePositive == positive;
      return TextButton.icon(
        key: ValueKey('$prefix-${positive ? 'positive-tab' : 'negative-tab'}'),
        onPressed: () => notifier.setActivePositive(positive),
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          textStyle: context.texts.labelMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
          foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
          backgroundColor: selected
              ? scheme.primary.withValues(alpha: .10)
              : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              minimumSize: const Size(30, 30),
              padding: const EdgeInsets.all(5),
              iconSize: 18,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: scheme.onSurfaceVariant,
            ),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  tab(true, '提示', Icons.edit_outlined),
                  if (!medium) ...[
                    const SizedBox(width: 4),
                    tab(false, '排除', Icons.block),
                  ],
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: chipMode ? '切换文本编辑' : '切换标签视图',
                    key: ValueKey('$prefix-mode'),
                    onPressed: onToggleMode,
                    icon: Icon(
                      chipMode ? Icons.notes_rounded : Icons.sell_outlined,
                    ),
                  ),
                  if (!character && sectionId == null)
                    const PromptPresetMenuButton(),
                  PopupMenuButton<String>(
                    key: ValueKey('$prefix-favorites'),
                    tooltip: '收藏标签',
                    enabled: favorites.isNotEmpty && onInsertFavorite != null,
                    constraints: const BoxConstraints(
                      minWidth: 180,
                      maxWidth: 320,
                    ),
                    icon: const Icon(Icons.star_border_rounded, size: 18),
                    onSelected: onInsertFavorite,
                    itemBuilder: (_) => [
                      for (final tag in favorites)
                        PopupMenuItem(
                          value: tag,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tag,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                tooltip: '移出收藏',
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () {
                                  final n = ref.read(
                                    tagFavoritesProvider.notifier,
                                  );
                                  final index = n.remove(tag);
                                  Navigator.of(context).pop();
                                  hintSnack(
                                    context,
                                    '已移出收藏',
                                    actionLabel: '撤销',
                                    onAction: () => n.restore(tag, index),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  IconButton(
                    tooltip: '撤销',
                    key: ValueKey('$prefix-undo'),
                    onPressed: state.canUndo ? notifier.undo : null,
                    icon: const Icon(Icons.undo_rounded),
                  ),
                  if (!character && sectionId == null)
                    IconButton(
                      key: const ValueKey('desktop-editor-settings'),
                      tooltip: '编辑器设置',
                      onPressed: onSettings,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (medium) ...[
          Text(
            'Medium 使用固定负面预设，原负面词已保留',
            style: context.texts.labelSmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
        ],
        child,
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (tokens / limit).clamp(0, 1),
            minHeight: 2,
            color: over ? scheme.error : scheme.primary,
            backgroundColor: scheme.outlineVariant.withValues(alpha: .45),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$tokens / $limit',
          textAlign: TextAlign.end,
          style: context.texts.labelSmall!.copyWith(
            color: over ? scheme.error : scheme.outline,
          ),
        ),
      ],
    );
  }
}
