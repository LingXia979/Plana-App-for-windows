import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/settings_scaffold.dart';
import 'preset_file.dart';
import 'prompt_presets.dart';
import 'widgets/common.dart';
import '../../core/util/haptics.dart';

final _openPresetManagers = Expando<Future<void>>('preset-managers');

/// The desktop shortcut shares the full manager's state and actions.
Future<void> showPromptPresetManager(BuildContext context) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final existing = _openPresetManagers[navigator];
  if (existing != null) return existing;
  final opened = showDialog<void>(
    context: context,
    useRootNavigator: true,
    requestFocus: true,
    builder: (_) => const Dialog(
      key: ValueKey('prompt-preset-manager-dialog'),
      constraints: BoxConstraints(maxWidth: 740, maxHeight: 640),
      insetPadding: EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 740,
        height: 640,
        child: PromptPresetManagePage(compact: true),
      ),
    ),
  );
  final result = opened.whenComplete(
    () => _openPresetManagers[navigator] = null,
  );
  _openPresetManagers[navigator] = result;
  return result;
}

typedef _PresetDraft = ({
  String name,
  String positive,
  String negative,
  bool suffix,
});

/// 提示词预设管理页:激活切换 + 自定义增删改/导入 + 拖动排序。
/// 入口:高级设置「管理预设」/ 我的页卡片。
class PromptPresetManagePage extends ConsumerStatefulWidget {
  const PromptPresetManagePage({super.key, this.compact = false});

  final bool compact;

  @override
  ConsumerState<PromptPresetManagePage> createState() =>
      _PromptPresetManagePageState();
}

class _PromptPresetManagePageState
    extends ConsumerState<PromptPresetManagePage> {
  bool _importing = false;
  bool _editing = false;
  final _messages = GlobalKey<ScaffoldMessengerState>();

  Future<void> _importFile() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final selected = await FilePicker.platform.pickFiles(
        dialogTitle: '导入提示词预设',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
        lockParentWindow: true,
      );
      if (!mounted || selected == null || selected.files.isEmpty) return;
      final file = selected.files.single;
      const maxBytes = 5 * 1024 * 1024;
      if (file.size > maxBytes) {
        throw const FormatException('预设文件不能超过 5 MB');
      }
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) throw const FormatException('无法读取预设文件');
      if (bytes.length > maxBytes) {
        throw const FormatException('预设文件不能超过 5 MB');
      }
      final presets = parsePresetFile(utf8.decode(bytes));
      if (!mounted) return;
      final count = await ref
          .read(promptPresetsProvider.notifier)
          .importPresets(presets);
      if (!mounted) return;
      _message(count == 0 ? '文件中没有可导入的自定义预设' : '已导入 $count 个预设，相同编号已更新');
    } on FormatException catch (error) {
      if (mounted) _message('导入失败：${error.message}');
    } catch (_) {
      if (mounted) _message('导入失败，请检查文件是否可读取后重试');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _message(String text) {
    (_messages.currentState ?? ScaffoldMessenger.of(context)).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    PromptPreset? preset,
  }) async {
    if (_editing) return;
    _editing = true;
    try {
      final r = widget.compact
          ? await showDialog<_PresetDraft>(
              context: context,
              requestFocus: true,
              builder: (_) => Dialog(
                key: const ValueKey('prompt-preset-editor-dialog'),
                constraints: const BoxConstraints(
                  maxWidth: 640,
                  maxHeight: 620,
                ),
                insetPadding: const EdgeInsets.all(16),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: 640,
                  child: _PresetEditSheet(preset: preset, compact: true),
                ),
              ),
            )
          : await showModalBottomSheet<_PresetDraft>(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              builder: (_) => _PresetEditSheet(preset: preset),
            );
      if (r == null || !mounted) return; // 取消 / 只读查看
      final n = ref.read(promptPresetsProvider.notifier);
      if (preset == null) {
        await n.add(
          name: r.name,
          positive: r.positive,
          negative: r.negative,
          suffixPositive: r.suffix,
        );
      } else {
        await n.updatePreset(
          preset.id,
          name: r.name,
          positive: r.positive,
          negative: r.negative,
          suffixPositive: r.suffix,
        );
      }
    } finally {
      _editing = false;
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    PromptPreset p,
  ) async {
    final ok = await confirmDialog(
      context,
      title: '删除预设',
      message: '「${p.name}」将被删除;若正在激活,回落到「无」。',
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    await ref.read(promptPresetsProvider.notifier).remove(p.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final s = ref.watch(promptPresetsProvider).value;
    final desktop = ref.watch(desktopModeProvider);
    final actions = <Widget>[
      IconButton(
        tooltip: '导入预设（JSON）',
        onPressed: s == null || _importing ? null : _importFile,
        icon: _importing
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.file_upload_outlined),
      ),
      IconButton(
        tooltip: '新建预设',
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add),
      ),
    ];
    final body = s == null
        ? const Center(child: CircularProgressIndicator())
        // 整块拖动排序;桌面鼠标超过位移阈值即拾起,触摸仍长按。
        : ReorderableListView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
            buildDefaultDragHandles: false,
            proxyDecorator: dragProxy,
            onReorderStart: dragStartHaptic,
            onReorderEnd: dragEndHaptic,
            onReorderItem: (from, to) =>
                ref.read(promptPresetsProvider.notifier).reorder(from, to),
            header: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.compact) const SettingsPageHeader(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 6, 12),
                  child: Text(
                    '激活的预设在生成时按指定位置拼接正/负提示词，不占用输入框。'
                    '默认预设不可修改;右上角可新建或导入 JSON 预设。'
                    '${desktop ? '按住鼠标并移动可调整顺序。' : '长按预设可调整顺序。'}',
                    style: context.texts.bodySmall!.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            children: [
              for (var i = 0; i < s.presets.length; i++)
                _PresetReorderListener(
                  key: ValueKey(s.presets[i].id),
                  index: i,
                  desktop: desktop,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PresetTile(
                      key: ValueKey('prompt-preset-card-${s.presets[i].id}'),
                      preset: s.presets[i],
                      active: s.presets[i].id == s.activeId,
                      onTap: () {
                        Haptics.selection();
                        ref
                            .read(promptPresetsProvider.notifier)
                            .setActive(s.presets[i].id);
                      },
                      onEdit: () => _edit(context, ref, preset: s.presets[i]),
                      onDelete: s.presets[i].isDefault
                          ? null
                          : () => _delete(context, ref, s.presets[i]),
                    ),
                  ),
                ),
            ],
          );
    if (widget.compact) {
      return ScaffoldMessenger(
        key: _messages,
        child: Scaffold(
          backgroundColor: scheme.surface,
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '提示词预设',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleLarge!.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    ...actions,
                    IconButton(
                      key: const ValueKey('prompt-preset-manager-close'),
                      tooltip: '关闭预设窗口',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }
    return SettingsScaffold(
      appBar: AppBar(title: const Text('提示词预设'), actions: actions),
      body: body,
    );
  }
}

/// 和 Flutter 的排序监听器使用同一手势竞技场:移动才拾起,松手不再触发点击。
/// 按输入设备选择识别器,Windows 触屏也不会失去正常的列表滑动。
class _PresetReorderListener extends StatelessWidget {
  const _PresetReorderListener({
    super.key,
    required this.index,
    required this.desktop,
    required this.child,
  });

  final int index;
  final bool desktop;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.buttons != kPrimaryButton) return;
      final MultiDragGestureRecognizer recognizer =
          desktop && event.kind == PointerDeviceKind.mouse
          ? ImmediateMultiDragGestureRecognizer(debugOwner: this)
          : DelayedMultiDragGestureRecognizer(debugOwner: this);
      recognizer.gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
      SliverReorderableList.of(context).startItemDragReorder(
        index: index,
        event: event,
        recognizer: recognizer,
      );
    },
    child: child,
  );
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    super.key,
    required this.preset,
    required this.active,
    required this.onTap,
    required this.onEdit,
    this.onDelete,
  });

  final PromptPreset preset;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final badge = switch (preset.scope) {
      'v5' => 'V5',
      'legacy' => '4.5 及更早',
      _ => preset.isDefault ? '默认' : null,
    };
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              preset.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodyMedium!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: context.texts.labelSmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        if (preset.positive.isEmpty && preset.negative.isEmpty)
          Text(
            '无前缀',
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
          )
        else ...[
          if (preset.positive.isNotEmpty)
            Text(
              '+ ${preset.positive}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelSmall!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (preset.negative.isNotEmpty)
            Text(
              '- ${preset.negative}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
        ],
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('prompt-preset-edit-${preset.id}'),
          tooltip: preset.isDefault ? '查看' : '编辑',
          visualDensity: VisualDensity.compact,
          onPressed: onEdit,
          icon: Icon(
            preset.isDefault ? Icons.visibility_outlined : Icons.edit_outlined,
            size: 19,
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (onDelete != null)
          IconButton(
            key: ValueKey('prompt-preset-delete-${preset.id}'),
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            icon: Icon(
              Icons.delete_outline,
              size: 19,
              color: scheme.error.withValues(alpha: .85),
            ),
          ),
      ],
    );
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: active
            ? BorderSide(color: scheme.primary, width: 1.4)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 340;
              final content = Row(
                children: [
                  Icon(
                    active
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                    color: active ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: 11),
                  Expanded(child: details),
                  if (!narrow) ...[const SizedBox(width: 4), actions],
                ],
              );
              return narrow
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        content,
                        Align(alignment: Alignment.centerRight, child: actions),
                      ],
                    )
                  : content;
            },
          ),
        ),
      ),
    );
  }
}

/// 新建 / 编辑 / 只读查看(默认预设)三合一 sheet。
/// controller 归 State 管(pop future 在退场动画时 resolve,外部 dispose 会崩)。
class _PresetEditSheet extends StatefulWidget {
  const _PresetEditSheet({this.preset, this.compact = false});

  final PromptPreset? preset;
  final bool compact;

  @override
  State<_PresetEditSheet> createState() => _PresetEditSheetState();
}

class _PresetEditSheetState extends State<_PresetEditSheet> {
  late final TextEditingController nameCtl = TextEditingController(
    text: widget.preset?.name ?? '',
  );
  late final TextEditingController posCtl = TextEditingController(
    text: widget.preset?.positive ?? '',
  );
  late final TextEditingController negCtl = TextEditingController(
    text: widget.preset?.negative ?? '',
  );

  /// 正向拼在末尾。存量自定义预设没这个键 → false(前缀),与改动前一致。
  late bool _suffix = widget.preset?.suffixPositive ?? false;

  bool get _readOnly => widget.preset?.isDefault ?? false;

  @override
  void dispose() {
    nameCtl.dispose();
    posCtl.dispose();
    negCtl.dispose();
    super.dispose();
  }

  /// 正向拼在提示词开头还是末尾。
  ///
  /// 官方从 V4 起把质量词放末尾,内置档已照此;自定义档由用户自己定 ——
  /// 有人的档是画风串而不是质量词,那种放开头才对。
  Widget _placementRow(ColorScheme scheme) {
    Widget seg(String label, bool sel, VoidCallback onTap) => Expanded(
      child: InkWell(
        onTap: _readOnly ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: Motion.fast,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: sel ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: context.texts.labelMedium!.copyWith(
              fontWeight: FontWeight.w700,
              color: _readOnly
                  ? scheme.onSurfaceVariant.withValues(alpha: .5)
                  : sel
                  ? scheme.onPrimary
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
    return Row(
      children: [
        Expanded(
          child: Text(
            '拼接位置',
            style: context.texts.labelMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        SizedBox(
          width: 152,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                seg('开头', !_suffix, () => setState(() => _suffix = false)),
                seg('末尾', _suffix, () => setState(() => _suffix = true)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController ctl, {
    bool multiline = false,
  }) {
    final scheme = context.scheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.texts.labelMedium!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: ctl,
          readOnly: _readOnly,
          minLines: multiline ? 2 : 1,
          maxLines: multiline ? 6 : 1,
          style: multiline ? mono(context, size: 13) : null,
          decoration: InputDecoration(
            isDense: true,
            hintText: multiline ? '空…' : '预设名称',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final title = _readOnly
        ? '查看预设'
        : widget.preset == null
        ? '新建预设'
        : '编辑预设';
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: widget.compact ? 20 : 0,
          bottom:
              (widget.compact ? 0 : MediaQuery.viewInsetsOf(context).bottom) +
              20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: context.texts.titleMedium!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_readOnly) ...[
              const SizedBox(height: 4),
              Text(
                '默认预设不可修改,可新建自定义预设替代。',
                style: context.texts.labelSmall!.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
            const SizedBox(height: 14),
            _field('名称', nameCtl),
            const SizedBox(height: 12),
            _field(_suffix ? '正向后缀' : '正向前缀', posCtl, multiline: true),
            const SizedBox(height: 8),
            _placementRow(scheme),
            const SizedBox(height: 12),
            // 负向没有这个选择:官方一律前缀,我们也从没变过
            _field('负向前缀', negCtl, multiline: true),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(_readOnly ? '关闭' : '取消'),
                ),
                if (!_readOnly) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final name = nameCtl.text.trim();
                      Navigator.pop(context, (
                        name: name.isEmpty ? '未命名' : name,
                        positive: posCtl.text.trim(),
                        negative: negCtl.text.trim(),
                        suffix: _suffix,
                      ));
                    },
                    child: const Text('保存'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
