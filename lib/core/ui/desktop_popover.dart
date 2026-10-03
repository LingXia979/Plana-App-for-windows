import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A compact desktop panel anchored to the control that opened it.
/// Use the navigator's actual bounds: embedded panels override MediaQuery.size.
Future<T?> showDesktopPopover<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double width = 380,
  double maxHeight = 480,
}) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final button = context.findRenderObject()! as RenderBox;
  final anchor =
      button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, animation, secondaryAnimation) => themes.wrap(
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              navigator.pop(),
        },
        child: Focus(
          autofocus: true,
          child: CustomSingleChildLayout(
            delegate: _PopoverLayout(
              anchor: anchor,
              width: width,
              maxHeight: maxHeight,
              padding: MediaQuery.paddingOf(context),
            ),
            child: Material(
              key: const ValueKey('desktop-popover'),
              elevation: 8,
              shadowColor: Colors.black26,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Builder(builder: builder),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  const _PopoverLayout({
    required this.anchor,
    required this.width,
    required this.maxHeight,
    required this.padding,
  });
  final Rect anchor;
  final double width;
  final double maxHeight;
  final EdgeInsets padding;
  static const gap = 8.0;
  Rect _bounds(Size size) => Rect.fromLTRB(
    padding.left + 12,
    padding.top + 12,
    math.max(padding.left + 12, size.width - padding.right - 12),
    math.max(padding.top + 12, size.height - padding.bottom - 12),
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final bounds = _bounds(constraints.biggest);
    final above = (anchor.top - gap - bounds.top).clamp(0.0, bounds.height);
    final below = (bounds.bottom - anchor.bottom - gap).clamp(
      0.0,
      bounds.height,
    );
    return BoxConstraints(
      minWidth: math.min(width, bounds.width),
      maxWidth: math.min(width, bounds.width),
      maxHeight: math.min(maxHeight, math.max(above, below)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = _bounds(size);
    final below = anchor.bottom + gap;
    final top = below + childSize.height <= bounds.bottom
        ? below
        : anchor.top - gap - childSize.height;
    return Offset(
      (anchor.right - childSize.width).clamp(
        bounds.left,
        bounds.right - childSize.width,
      ),
      top.clamp(bounds.top, bounds.bottom - childSize.height),
    );
  }

  @override
  bool shouldRelayout(_PopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      width != oldDelegate.width ||
      maxHeight != oldDelegate.maxHeight ||
      padding != oldDelegate.padding;
}
