import 'package:flutter/material.dart';

/// Only the empty space beside a fitted image is a navigation target.
/// The image itself keeps its zoom/pan gestures; controls sit above this layer.
class DesktopCanvasGutters extends StatelessWidget {
  const DesktopCanvasGutters({
    super.key,
    required this.imageSize,
    this.onPrevious,
    this.onNext,
  });

  final Size imageSize;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (imageSize.isEmpty) return const SizedBox.shrink();
      final fitted = applyBoxFit(
        BoxFit.contain,
        imageSize,
        box.biggest,
      ).destination;
      final gutter = (box.maxWidth - fitted.width) / 2;
      if (gutter < 1) return const SizedBox.shrink();
      return Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: gutter,
            child: _Gutter(
              key: const ValueKey('canvas-previous-gutter'),
              onTap: onPrevious,
              label: '上一张',
              icon: Icons.chevron_left,
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: gutter,
            child: _Gutter(
              key: const ValueKey('canvas-next-gutter'),
              onTap: onNext,
              label: '下一张',
              icon: Icons.chevron_right,
            ),
          ),
        ],
      );
    },
  );
}

class _Gutter extends StatefulWidget {
  const _Gutter({
    super.key,
    required this.onTap,
    required this.label,
    required this.icon,
  });
  final VoidCallback? onTap;
  final String label;
  final IconData icon;

  @override
  State<_Gutter> createState() => _GutterState();
}

class _GutterState extends State<_Gutter> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => hover = true),
    onExit: (_) => setState(() => hover = false),
    child: Semantics(
      button: true,
      label: widget.label,
      enabled: widget.onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: hover && widget.onTap != null ? .65 : 0,
            child: Icon(widget.icon, size: 28),
          ),
        ),
      ),
    ),
  );
}
