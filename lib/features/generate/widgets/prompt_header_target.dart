import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'prompt_reorder_scroll.dart';

/// Only the empty header area is a collapse/selection target. Name controls can
/// sit above it in a Stack; action buttons must remain outside this widget.
class PromptHeaderTarget extends StatelessWidget {
  const PromptHeaderTarget({
    super.key,
    required this.identifier,
    required this.label,
    required this.onTap,
    this.reorderIndex,
    this.child,
  });

  final String identifier;
  final String label;
  final VoidCallback? onTap;
  final int? reorderIndex;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    Widget target = Tooltip(
      message: reorderIndex == null ? label : '$label · 按住拖动排序',
      child: Semantics(
        button: onTap != null,
        label: label,
        child: InkWell(
          key: ValueKey(identifier),
          onTap: onTap,
          mouseCursor: reorderIndex != null
              ? SystemMouseCursors.grab
              : onTap != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: context.scheme.primary.withValues(alpha: .12),
          splashFactory: NoSplash.splashFactory,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: child ?? const SizedBox.expand(),
          ),
        ),
      ),
    );
    if (reorderIndex != null) {
      target = PromptReorderDragStartListener(
        index: reorderIndex!,
        child: target,
      );
    }
    return target;
  }
}
