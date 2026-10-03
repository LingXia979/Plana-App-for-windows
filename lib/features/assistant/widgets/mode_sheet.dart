/// 选对话模式:无 / 漫画模式 / 仅自然语言。
///
/// 桌面端贴近按钮显示，移动端使用底部弹层；选中后关闭。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';
import '../../../core/ui/setting_row.dart';
import '../../generate/widgets/common.dart' show dropFocusSoon;
import '../assistant_mode.dart';

IconData assistantModeIcon(AssistantMode m, {bool on = false}) => switch (m) {
  AssistantMode.normal => Icons.layers_clear_outlined,
  AssistantMode.comic => on ? Icons.view_quilt : Icons.view_quilt_outlined,
  AssistantMode.natural => on ? Icons.notes : Icons.notes_outlined,
};

/// 选中的模式;没选就关掉的是 null。
Future<AssistantMode?> showModeSheet(
  BuildContext context, {
  required AssistantMode current,
}) async {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    return showDesktopPopover<AssistantMode>(
      context,
      width: 280,
      maxHeight: 240,
      builder: (_) => _ModeSheet(current: current, desktop: true),
    );
  }
  final picked = await showModalBottomSheet<AssistantMode>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .18),
    builder: (_) => _ModeSheet(current: current),
  );
  // 只是来切个模式,别顺手把软键盘顶出来
  dropFocusSoon();
  return picked;
}

class _ModeSheet extends StatelessWidget {
  const _ModeSheet({required this.current, this.desktop = false});

  final AssistantMode current;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final items = <Widget>[
      for (final m in AssistantMode.values)
        ListTile(
          dense: desktop,
          onTap: () => Navigator.pop(context, m),
          selected: m == current,
          selectedTileColor: scheme.primaryContainer.withValues(alpha: .35),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: Icon(
            m == current ? Icons.check_circle : assistantModeIcon(m),
            size: 21,
            color: m == current ? scheme.primary : null,
          ),
          title: Text(
            assistantModeLabel(m),
            style: context.texts.bodyLarge!.copyWith(
              fontWeight: m == current ? FontWeight.w700 : FontWeight.w500,
              color: m == current ? scheme.primary : null,
            ),
          ),
        ),
    ];
    if (!desktop) return SettingSheet(title: '对话模式', children: items);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Row(
              children: [
                const Expanded(child: Text('对话模式')),
                const CloseButton(),
              ],
            ),
          ),
          ...items,
        ],
      ),
    );
  }
}
