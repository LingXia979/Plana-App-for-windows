import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A narrow hit area; the workspace fits both panes as this divider is dragged.
class DesktopPaneDivider extends StatefulWidget {
  const DesktopPaneDivider({
    super.key,
    required this.label,
    required this.paneWidth,
    required this.onResizeStart,
    required this.onResize,
    required this.onResizeEnd,
    required this.onReset,
    this.trailingPane = false,
  });

  static const extent = 8.0;
  final String label;
  final double paneWidth;
  final bool trailingPane;
  final VoidCallback onResizeStart;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback onReset;

  @override
  State<DesktopPaneDivider> createState() => _DesktopPaneDividerState();
}

class _DesktopPaneDividerState extends State<DesktopPaneDivider> {
  bool _hovered = false;
  bool _dragging = false;
  double _startX = 0;
  double _startWidth = 0;

  void _endDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onResizeEnd();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hovered || _dragging;
    return Semantics(
      label: '${widget.label}宽度',
      value: '${widget.paneWidth.round()} 像素',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Tooltip(
          message: '拖动调整${widget.label}宽度，双击恢复默认',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (details) {
              _startX = details.globalPosition.dx;
              _startWidth = widget.paneWidth;
              widget.onResizeStart();
              setState(() => _dragging = true);
            },
            onHorizontalDragUpdate: (details) {
              final delta = details.globalPosition.dx - _startX;
              widget.onResize(
                _startWidth + (widget.trailingPane ? -delta : delta),
              );
            },
            onHorizontalDragEnd: (_) => _endDrag(),
            onHorizontalDragCancel: _endDrag,
            onDoubleTap: widget.onReset,
            child: SizedBox(
              width: DesktopPaneDivider.extent,
              child: ColoredBox(
                color: active
                    ? scheme.primary.withValues(alpha: .10)
                    : scheme.surfaceContainerLow,
                child: Center(
                  child: Container(
                    width: 1,
                    color: active ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
