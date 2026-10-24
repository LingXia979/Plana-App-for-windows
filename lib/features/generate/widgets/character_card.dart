import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/net/remote_image.dart';
import '../../../core/platform/desktop.dart';
import '../../../core/theme/theme_settings.dart';
import '../../../core/util/nai_tokenizer.dart';
import '../../editor/editor_page.dart';
import '../../editor/editor_models.dart' show outputOf, draftOf;
import '../../inspiration/widgets/char_pick_sheet.dart';
import '../../inspiration/widgets/tag_card.dart' show TagCardPreview;
import '../../inspiration/tag_models.dart'
    show appendTagPromptsFolded, TagCategory, tagCategoryDef;
import '../canvas_state.dart';
import '../char_position.dart';
import '../generate_state.dart';
import '../models.dart';
import 'common.dart';
import 'position_grid_dialog.dart';
import 'section_card.dart';
import 'desktop_prompt_card.dart';
import 'prompt_card.dart' show negativePreview;
import 'reference_image_preview.dart';

/// 角色面板(定稿版):每个角色一张内嵌圆角小卡。
/// 行 1:电源开关 · 名称(点名字改名,+状态说明)· 站位徽章 · 删除
/// 行 2:提示词单行预览 + token 计数
class CharacterCard extends ConsumerWidget {
  const CharacterCard({super.key, this.reorderIndex});

  final int? reorderIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(generateProvider);
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final chars = state.characters;
    final cap = maxCharactersOf(state.params.model);
    final canAdd = chars.length < cap;
    final actionSize =
        !ref.watch(desktopModeProvider) &&
            MediaQuery.sizeOf(context).width < 350
        ? 32.0
        : 36.0;
    // 读数按**启用**数算:上限管的是进载荷的那几个,停用的不占额度。切模型时
    // 超出的尾巴会自动停用(见 GenerateNotifier._capEnabled),之后还标红就只剩
    // 一种来路 —— 用户在小槽位模型下自己又勾回来了,那确实该红。
    final active = chars.where((c) => c.enabled).length;

    return SectionCard(
      icon: Icons.group_outlined,
      title: ref.watch(desktopModeProvider) ? '角色提示词' : '角色',
      reorderIndex: reorderIndex,
      badge: CountBadge('$active / $cap', error: active > cap),
      actions: [
        if (chars.isNotEmpty)
          RoundIconBtn(
            Icons.delete_sweep_outlined,
            size: actionSize,
            tooltip: '清空全部角色',
            color: scheme.onSurfaceVariant,
            onTap: () => _confirmClear(context, notifier),
          ),
        RoundIconBtn(
          Icons.grid_view,
          size: actionSize,
          tooltip: '角色库',
          color: canAdd ? scheme.onSurfaceVariant : scheme.outline,
          onTap: canAdd ? () => _addFromLibrary(context, ref) : null,
        ),
        RoundIconBtn(
          Icons.add,
          size: actionSize,
          tooltip: '添加角色',
          color: canAdd ? null : scheme.outline,
          onTap: canAdd ? notifier.addCharacter : null,
        ),
      ],
      // 没有角色时整卡不可展开(展开体本就是空的),但保留一个静态 chevron 占位,
      // 让空卡卡头与下方各功能卡视觉对齐;箭头不接手势、不旋转、不点开空白。
      expanded: chars.isNotEmpty && state.openPanels.contains(Panel.characters),
      onHeaderTap: chars.isEmpty
          ? null
          : () => notifier.togglePanel(Panel.characters),
      chevronPlaceholder: chars.isEmpty,
      body: chars.isEmpty
          ? null
          // 长按卡片拖动排序。删除只走行内那枚按钮 —— 横滑抹掉的是整份角色配置
          // (提示词/站位/开关),而这里没有撤销可给。
          : ReorderableListView(
              buildDefaultDragHandles: !ref.watch(desktopModeProvider),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              proxyDecorator: dragProxy,
              onReorderStart: dragStartHaptic,
              onReorderEnd: dragEndHaptic,
              onReorderItem: notifier.reorderCharacters,
              children: [
                for (var i = 0; i < chars.length; i++)
                  Padding(
                    key: ValueKey('char${chars[i].id}'),
                    padding: EdgeInsets.only(top: i > 0 ? 9 : 0),
                    child: _CharacterTile(char: chars[i], index: i),
                  ),
              ],
            ),
    );
  }

  Future<void> _addFromLibrary(BuildContext context, WidgetRef ref) async {
    final canvasId = ref.read(canvasWorkspaceProvider).activeId;
    final s = ref.read(generateProvider);
    final room = maxCharactersOf(s.params.model) - s.characters.length;
    if (room <= 0) return;
    final canvases = ref.read(canvasWorkspaceProvider.notifier);
    final gen = ref.read(generateProvider.notifier);
    final picked = await showCharPickSheet(context, max: room);
    if (picked == null || picked.isEmpty || !context.mounted) return;
    canvases.updatePrompts(canvasId, (p) {
      final chars = [...p.characters];
      final model = p.sampling?.model ?? s.params.model;
      for (final pick in picked) {
        if (chars.length >= maxCharactersOf(model)) break;
        final draft = appendTagPromptsFolded(
          positiveDraft: '',
          negativeDraft: '',
          entries: [pick.entry],
        );
        final positive = outputOf(draft.positiveDraft),
            negative = outputOf(draft.negativeDraft);
        chars.add(
          CharacterPrompt(
            id: gen.allocateItemId(),
            name: pick.entry.name,
            positive: positive,
            negative: negative,
            positiveRaw: draftOf(draft.positiveDraft, positive),
            negativeRaw: draftOf(draft.negativeDraft, negative),
            foldLinks: draft.links,
            position: nextSpawnPosition(
              chars.map((c) => c.position),
              freeform: isNai5Model(model),
            ),
            avatar: pick.preview,
          ),
        );
      }
      return p.copyWith(characters: chars);
    });
    if (ref.read(canvasWorkspaceProvider).activeId == canvasId) {
      gen.openPanel(Panel.characters);
    }
  }

  Future<void> _confirmClear(
    BuildContext context,
    GenerateNotifier notifier,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部角色?'),
        content: const Text('将移除所有角色及其配置,此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: context.scheme.error,
              foregroundColor: context.scheme.onError,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) notifier.clearCharacters();
  }
}

class _CharacterTile extends ConsumerStatefulWidget {
  const _CharacterTile({required this.char, required this.index});

  final CharacterPrompt char;

  /// 行序,只用来算改名留空时回落的默认名。
  final int index;

  @override
  ConsumerState<_CharacterTile> createState() => _CharacterTileState();
}

class _CharacterTileState extends ConsumerState<_CharacterTile> {
  CharacterPrompt get char => widget.char;
  int get index => widget.index;
  bool _collapsed = false;
  bool _avatarPreviewOpen = false;

  Future<void> _previewAvatar() async {
    final avatar = char.avatar;
    if (_avatarPreviewOpen || avatar == null || avatar.isEmpty) return;
    _avatarPreviewOpen = true;
    try {
      await showImageProviderPreview(
        context,
        image: avatar.startsWith('http')
            ? RemoteImageProvider(
                avatar,
                version: RemoteImageStore.versionOf(avatar),
              )
            : FileImage(File(avatar)),
        title: char.name,
        errorMessage: '这张角色图片暂时无法读取',
      );
    } finally {
      _avatarPreviewOpen = false;
    }
  }

  /// 点名字改名。留空 = 回到默认的「角色 N」,N 按当前行序算,与新增时同一口径
  /// (名字本就不是稳定句柄,认人靠 id)。
  ///
  /// 名字只在 app 内显示:载荷里没有这一项,导入也读不回来,所以改名不影响出图,
  /// 也不必跟着图走。
  Future<void> _rename(BuildContext context, GenerateNotifier notifier) async {
    final fallback = '角色 ${index + 1}';
    final ctrl = TextEditingController(text: char.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            isDense: true,
            hintText: fallback, // 留空就按默认编号显示
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null) return; // 取消
    final trimmed = name.trim();
    notifier.updateCharacter(
      char.id,
      name: trimmed.isEmpty ? fallback : trimmed,
    );
  }

  Future<void> _pickFromLibrary(BuildContext context, WidgetRef ref) async {
    final canvasId = ref.read(canvasWorkspaceProvider).activeId;
    final canvases = ref.read(canvasWorkspaceProvider.notifier);
    final picked = await showCharPickSheet(context);
    if (picked == null || picked.isEmpty || !context.mounted) return;
    final chosen = picked.first;
    final current = ref
        .read(canvasWorkspaceProvider)
        .find(canvasId)
        ?.prompts
        .characters
        .where((c) => c.id == char.id)
        .firstOrNull;
    if (current == null) return;
    if (current.avatar == null &&
        (current.positive.isNotEmpty || current.negative.isNotEmpty)) {
      final ok = await confirmDialog(
        context,
        title: '替换「${current.name}」？',
        message: '提示词将换成「${chosen.entry.name}」的。',
        confirmLabel: '替换',
      );
      if (!ok || !context.mounted) return;
    }
    final draft = appendTagPromptsFolded(
      positiveDraft: '',
      negativeDraft: '',
      entries: [chosen.entry],
    );
    final positive = outputOf(draft.positiveDraft),
        negative = outputOf(draft.negativeDraft);
    canvases.updatePrompts(
      canvasId,
      (p) => p.copyWith(
        characters: [
          for (final c in p.characters)
            if (c.id == char.id)
              c.copyWith(
                name: chosen.entry.name,
                positive: positive,
                negative: negative,
                positiveRaw: draftOf(draft.positiveDraft, positive),
                negativeRaw: draftOf(draft.negativeDraft, negative),
                foldLinks: draft.links,
                avatar: chosen.preview,
              )
            else
              c,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(generateProvider.notifier);
    final desktop = ref.watch(desktopModeProvider);
    if (!desktop) return _buildMobile(context, ref);
    final scheme = context.scheme;
    final enabled = char.enabled;
    final collapsible = ref.watch(
      themeSettingsProvider.select((t) => t.collapsiblePromptCards),
    );
    final compact = collapsible && _collapsed;
    // 只有站位徽章的写法跟模型走(见下),select 一下别让整张卡跟着全局状态重建。
    final isV5 = ref.watch(
      generateProvider.select((s) => isNai5Model(s.params.model)),
    );
    // AUTO 是整张图的档(官方 AI's Choice = use_coords false),不是这张卡的属性:
    // 坐标一直在,只是模型不理会。同样 select 一下,别让整张卡跟着全局重建。
    final autoPos = ref.watch(
      generateProvider.select((s) => !s.params.useCoords),
    );

    return AnimatedOpacity(
      duration: Motion.fast,
      opacity: enabled ? 1 : .5,
      child: Material(
        color: desktop ? scheme.surface : scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: desktop
              ? BorderSide(color: scheme.outlineVariant)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: desktop
              ? null
              : () => Navigator.of(context).push(
                  sharedAxisRoute(EditorPage(positive: true, charId: char.id)),
                ),
          child: Padding(
            // 上边距保持 10:行 1 高度由那枚删除按钮(40)定死,加了也只是把
            // 开关和名字整体往下推。加高的是下边距,见行 2 那里。
            padding: desktop
                ? const EdgeInsets.all(12)
                : const EdgeInsets.fromLTRB(12, 10, 8, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(
                  context,
                  ref,
                  notifier,
                  autoPos: autoPos,
                  isV5: isV5,
                  compact: compact,
                  collapsible: collapsible,
                ),
                if (compact)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: InkWell(
                      onTap: () => setState(() => _collapsed = false),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            char.positive.isEmpty
                                ? '点击展开编辑提示词…'
                                : char.positive,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodyMedium,
                          ),
                          if (!ref.watch(
                                generateProvider.select(
                                  (s) => s.params.isNaiMedium,
                                ),
                              ) &&
                              char.negative.isNotEmpty)
                            Text(
                              char.negative,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.bodySmall!.copyWith(
                                color: scheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Visibility(
                  visible: !compact,
                  maintainState: true,
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Divider(
                        height: 16,
                        color: scheme.outlineVariant.withValues(alpha: .6),
                      ),
                      DesktopPromptCard(
                        key: ValueKey(char.id),
                        charId: char.id,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Let the action group move below the name rather than wrapping position
  /// labels or squeezing all useful name text out of a narrow sidebar.
  Widget _header(
    BuildContext context,
    WidgetRef ref,
    GenerateNotifier notifier, {
    required bool autoPos,
    required bool isV5,
    required bool compact,
    required bool collapsible,
  }) {
    final scheme = context.scheme;
    final enabled = char.enabled;
    final position = autoPos
        ? 'AUTO'
        : positionChipLabel(char.position, grid: !isV5);
    double textWidth(String value, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      final width = painter.width.ceilToDouble();
      painter.dispose();
      return width;
    }

    final positionWidth = textWidth(
      position,
      mono(context, size: 12, weight: FontWeight.w700),
    ).clamp(36.0, double.infinity);
    final nameWidth = textWidth(
      '角色 1',
      context.texts.bodyLarge!.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
    final statusWidth = enabled
        ? 0.0
        : 4 + textWidth('已禁用', context.texts.labelSmall!);
    // Avatar, toggle, name padding, separation and trailing controls.
    final leadingWidth = 34 + 5 + 38 + 8 + nameWidth + statusWidth;
    final actionsWidth =
        26 + (collapsible ? 36 : 0) + 16 + 15 + 5 + positionWidth + 2 + 30 + 18;
    final requiredWidth = leadingWidth + 8 + actionsWidth;
    final leading = Row(
      children: [
        Tooltip(
          message: char.avatar?.isNotEmpty == true
              ? '左键从角色库选择 · 右键放大预览'
              : '从角色库选择',
          child: InkWell(
            key: ValueKey('character-avatar-${char.id}'),
            onTap: () => _pickFromLibrary(context, ref),
            onSecondaryTap: char.avatar?.isNotEmpty == true
                ? _previewAvatar
                : null,
            borderRadius: BorderRadius.circular(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 34,
                height: 34,
                child: TagCardPreview(
                  url: char.avatar,
                  name: char.name,
                  decodeWidth: 34,
                  alignment: Alignment.topCenter,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        // 电源开关(裸图标)
        IconButton(
          onPressed: () => notifier.updateCharacter(char.id, enabled: !enabled),
          icon: Icon(
            Icons.power_settings_new,
            size: 24,
            color: enabled ? scheme.primary : scheme.outline,
          ),
          // 与参考图那枚同款:字号 + 启用时的主色底托(见 RefEnableToggle)
          style: IconButton.styleFrom(
            backgroundColor: enabled
                ? scheme.primary.withValues(alpha: .12)
                : Colors.transparent,
          ),
          tooltip: enabled ? '停用(保留配置)' : '启用',
          visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
        ),
        // 名称 + 状态说明:占满中间,把尾部(徽章+删除)顶到最右
        Expanded(
          child: Row(
            children: [
              Flexible(
                // 点名字改名:热区只包名字本身,外层那圈照旧点开编辑器
                // (里层先拿到这一下)。长按是整卡拖排序,这里不接。
                // 开关与名字之间原先的 4px 挪进内边距,名字位置不变。
                child: InkWell(
                  onTap: () => _rename(context, notifier),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Text(
                      char.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyLarge!.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: enabled ? scheme.onSurface : scheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
              if (!enabled) ...[
                const SizedBox(width: 4),
                // 不给 Flexible:状态标签是定长的,该让角色名去挤。
                // 原先两个都 flex:1 平分,标签分到的一半装不下,
                // 就从尾巴开始吃 —— 屏幕上只剩「已禁用 ·…」。
                Text(
                  '已禁用',
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      runSpacing: 4,
      children: [
        PromptFullscreenButton(
          key: ValueKey('character-fullscreen-${char.id}'),
          charId: char.id,
        ),
        if (collapsible)
          IconButton(
            key: ValueKey('character-collapse-${char.id}'),
            tooltip: compact ? '展开角色提示词' : '收起角色提示词',
            onPressed: () => setState(() => _collapsed = !compact),
            icon: Icon(
              compact ? Icons.expand_more : Icons.expand_less,
              size: 22,
            ),
            constraints: const BoxConstraints.tightFor(width: 34, height: 38),
            padding: EdgeInsets.zero,
          ),
        // 站位徽章
        Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(17),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('character-position-${char.id}'),
            onTap: () => showPositionGridDialog(context, char.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.grid_on,
                    size: 15,
                    color: autoPos ? scheme.onSurfaceVariant : scheme.primary,
                  ),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints: BoxConstraints(minWidth: positionWidth),
                    child: Text(
                      position,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      style: mono(context, size: 12, weight: FontWeight.w700)
                          .copyWith(
                            color: autoPos
                                ? scheme.onSurfaceVariant
                                : scheme.primary,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 30,
              height: 40,
              child: IconButton(
                onPressed: () => notifier.removeCharacter(char.id),
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: scheme.error.withValues(alpha: .85),
                ),
                tooltip: '删除角色',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ),
            ReorderableDragStartListener(
              index: index,
              child: Tooltip(
                message: '拖动角色排序',
                child: Icon(
                  Icons.drag_indicator,
                  size: 18,
                  color: scheme.outline,
                ),
              ),
            ),
          ],
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < requiredWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              leading,
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: leading),
            const SizedBox(width: 8),
            actions,
          ],
        );
      },
    );
  }

  void _openEditor(BuildContext context, {required bool positive}) =>
      Navigator.of(
        context,
      ).push(sharedAxisRoute(EditorPage(positive: positive, charId: char.id)));

  Widget _buildMobile(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(generateProvider.notifier);
    final scheme = context.scheme;
    final enabled = char.enabled;
    // 只有站位徽章的写法跟模型走(见下),select 一下别让整张卡跟着全局状态重建。
    final isV5 = ref.watch(
      generateProvider.select((s) => isNai5Model(s.params.model)),
    );
    // AUTO 是整张图的档(官方 AI's Choice = use_coords false),不是这张卡的属性:
    // 坐标一直在,只是模型不理会。同样 select 一下,别让整张卡跟着全局重建。
    final autoPos = ref.watch(
      generateProvider.select((s) => !s.params.useCoords),
    );
    final compact = ref.watch(
      themeSettingsProvider.select((t) => t.compactCharCards),
    );
    final tokenizer = ref.watch(naiTokenizerProvider).value;
    final hasNeg =
        !ref.watch(generateProvider.select((s) => s.params.isNaiMedium)) &&
        char.negative.trim().isNotEmpty;
    final positionLabel = autoPos
        ? 'AUTO'
        : positionChipLabel(char.position, grid: !isV5);
    final controlSize = MediaQuery.sizeOf(context).width < 350 ? 32.0 : 36.0;
    // 停用只弱化内容,操作按钮保持可用。
    final posColor = enabled ? scheme.primary : scheme.outline;
    final negColor = enabled ? scheme.error : scheme.outline;
    final promptStyle = context.texts.bodyMedium!;
    final countStyle = mono(
      context,
      size: 11,
      weight: FontWeight.w500,
    ).copyWith(color: scheme.outline);

    final name = InkWell(
      onTap: () => _rename(context, notifier),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          char.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.texts.bodyLarge!.copyWith(
            fontWeight: FontWeight.w700,
            color: enabled ? scheme.onSurface : scheme.outline,
          ),
        ),
      ),
    );
    final toggleBtn = RoundIconBtn(
      Icons.power_settings_new,
      size: controlSize,
      color: enabled ? scheme.primary : scheme.outline,
      onTap: () => notifier.updateCharacter(char.id, enabled: !enabled),
      tooltip: enabled ? '停用(保留配置)' : '启用',
    );
    final deleteBtn = RoundIconBtn(
      Icons.delete_outline,
      size: controlSize,
      color: scheme.error,
      onTap: () => notifier.removeCharacter(char.id),
      tooltip: '删除角色',
    );
    void openPosition() => showPositionGridDialog(context, char.id);
    final positionTip = '设置角色位置：$positionLabel';
    final positive = Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        crossAxisAlignment: compact
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.end,
        children: [
          // 紧凑版的位置签排在正向预览左侧
          if (compact) ...[
            _PositionChip(
              label: positionLabel,
              auto: autoPos || positionLabel == 'AUTO',
              enabled: enabled,
              onTap: openPosition,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              char.positive.isEmpty ? '点击编辑提示词…' : char.positive,
              maxLines: compact || hasNeg ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: promptStyle.copyWith(
                color: char.positive.isEmpty || !enabled
                    ? scheme.outline
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (char.positive.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              '${totalPromptTokens(tokenizer, main: char.positive)}',
              style: countStyle,
            ),
          ],
        ],
      ),
    );
    final negative = InkWell(
      onTap: () => _openEditor(context, positive: false),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 3, 4, 3),
        child: Row(
          children: [
            Icon(Icons.block, size: 14, color: negColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                negativePreview(char.negative),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: promptStyle.copyWith(color: negColor),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${totalPromptTokens(tokenizer, main: char.negative)}',
              style: countStyle,
            ),
          ],
        ),
      ),
    );

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openEditor(context, positive: true),
        child: Padding(
          // 紧凑版没有头像垫在左边,文字离卡边留宽一些
          padding: compact
              ? const EdgeInsets.fromLTRB(14, 8, 8, 8)
              : const EdgeInsets.all(8),
          child: compact
              // 紧凑:名称 + 三个圆钮一行,下面位置签 + 提示词铺满整行。
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: name),
                        const SizedBox(width: 4),
                        RoundIconBtn(
                          Icons.location_on_outlined,
                          size: controlSize,
                          color: posColor,
                          onTap: openPosition,
                          tooltip: positionTip,
                        ),
                        const SizedBox(width: 6),
                        toggleBtn,
                        const SizedBox(width: 6),
                        deleteBtn,
                      ],
                    ),
                    const SizedBox(height: 6),
                    positive,
                    if (hasNeg) ...[const SizedBox(height: 2), negative],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Avatar(
                      url: char.avatar,
                      name: char.name,
                      enabled: enabled,
                      onTap: () => _pickFromLibrary(context, ref),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 名称与三个等大的公共圆形按钮共用顶行。
                          Row(
                            children: [
                              Expanded(child: name),
                              const SizedBox(width: 4),
                              RoundIconBtn(
                                Icons.location_on_outlined,
                                size: controlSize,
                                color: posColor,
                                onTap: openPosition,
                                tooltip: positionTip,
                              ),
                              const SizedBox(width: 6),
                              toggleBtn,
                              const SizedBox(width: 6),
                              deleteBtn,
                            ],
                          ),
                          // 坐标读数与名字分开,位置按钮只占一个图标的宽度。
                          Row(
                            children: [
                              Icon(
                                Icons.location_on_outlined,
                                size: 14,
                                color: posColor,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  autoPos ? '自动定位' : positionLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.bodySmall!.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: posColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          // 名称和提示词都占满预览图右侧。
                          positive,
                          if (hasNeg) ...[const SizedBox(height: 4), negative],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 紧凑角色卡正向预览左侧的位置签:定了位是填色签,自动定位 / 停用是描边灰字。
/// 点它打开定位面板。
class _PositionChip extends StatelessWidget {
  const _PositionChip({
    required this.label,
    required this.auto,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool auto;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final filled = enabled && !auto;
    return Material(
      color: filled ? scheme.primaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: filled
            ? BorderSide.none
            : BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            auto ? '自动' : label,
            maxLines: 1,
            style: context.texts.labelMedium!.copyWith(
              fontWeight: FontWeight.w600,
              color: filled
                  ? scheme.onPrimaryContainer
                  : enabled
                  ? scheme.onSurfaceVariant
                  : scheme.outline,
            ),
          ),
        ),
      ),
    );
  }
}

/// 停用时头像去色。
const _greyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0,
]);

/// 竖向头像:固定使用角色库的 832:1216 比例,不随提示词高度拉伸。
/// 点它从灵感角色库挑人。
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.url,
    required this.name,
    required this.enabled,
    required this.onTap,
  });

  final String? url;
  final String name;
  final bool enabled;
  final VoidCallback onTap;

  static const width = 72.0;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final slot = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.person_search_outlined,
          size: 24,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final aspect = tagCategoryDef(TagCategory.character).previewAspect;
    Widget child = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url == null
          ? slot
          : TagCardPreview(
              url: url,
              name: name,
              decodeWidth: width,
              placeholder: slot,
            ),
    );
    if (!enabled) {
      child = Opacity(
        opacity: .55,
        child: ColorFiltered(colorFilter: _greyscale, child: child),
      );
    }
    return Tooltip(
      message: url == null ? '从角色库选' : '换角色',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: width,
          child: AspectRatio(aspectRatio: aspect, child: child),
        ),
      ),
    );
  }
}
