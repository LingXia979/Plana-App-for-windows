import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The whole prompt/character group, including its heading. Only automatic
/// reorder scrolling is constrained here; normal sidebar scrolling is unchanged.
class PromptReorderBoundary extends InheritedWidget {
  const PromptReorderBoundary({super.key, required super.child});

  @override
  bool updateShouldNotify(PromptReorderBoundary oldWidget) => false;
}

/// Keep Flutter's immediate reordering, while scrolling the enclosing sidebar
/// instead of the non-scrollable, shrink-wrapped list inside each group.
class PromptReorderDragStartListener extends StatelessWidget {
  const PromptReorderDragStartListener({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inner = Scrollable.maybeOf(context, axis: Axis.vertical);
    final outer = inner == null
        ? null
        : Scrollable.maybeOf(inner.context, axis: Axis.vertical);
    final boundary = context
        .getElementForInheritedWidgetOfExactType<PromptReorderBoundary>();
    final count = SliverReorderableList.maybeOf(context)?.widget.itemCount ?? 0;
    return _ScrollAwareListener(
      index: index,
      scrollable: count > 1 ? outer : null,
      boundary: boundary,
      child: child,
    );
  }
}

class _ScrollAwareListener extends ReorderableDragStartListener {
  const _ScrollAwareListener({
    required super.index,
    required super.child,
    required this.scrollable,
    required this.boundary,
  });

  final ScrollableState? scrollable;
  final BuildContext? boundary;

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      scrollable == null || boundary == null
      ? super.createRecognizer()
      : _SidebarRecognizer(scrollable!, boundary!);
}

class _SidebarRecognizer extends ImmediateMultiDragGestureRecognizer {
  _SidebarRecognizer(this.scrollable, this.boundary);

  final ScrollableState scrollable;
  final BuildContext boundary;
  _SidebarDrag? _drag;

  @override
  set onStart(GestureMultiDragStartCallback? callback) {
    super.onStart = callback == null
        ? null
        : (position) {
            final delegate = callback(position);
            return delegate == null
                ? null
                : _drag = _SidebarDrag(
                    delegate,
                    scrollable,
                    boundary,
                    position,
                  );
          };
  }

  @override
  void dispose() {
    // Flutter disposes the recognizer when the source list is replaced or its
    // item count changes. Stop without cancelling its already-disposed drag.
    _drag?.stop();
    super.dispose();
  }
}

class _SidebarDrag extends Drag {
  _SidebarDrag(this.delegate, this.scrollable, this.boundary, this.position) {
    _ticker = Ticker(_tick);
  }

  final Drag delegate;
  final ScrollableState scrollable;
  final BuildContext boundary;
  Offset position;
  late final Ticker _ticker;
  Duration? _previous;
  bool _stopped = false;
  bool _refreshQueued = false;

  Rect? _rect(BuildContext context) {
    if (!context.mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // A small margin makes both end insertion positions reachable without
  // scrolling on into the preceding/following module.
  static const _margin = 8.0;
  static const _edge = 48.0;

  double _delta(double seconds) {
    if (!scrollable.mounted) return 0;
    final viewport = _rect(scrollable.context);
    final group = _rect(boundary);
    if (viewport == null || group == null || !viewport.contains(position)) {
      return 0;
    }
    final band = _edge.clamp(0.0, viewport.height / 2);
    final speed = position.dy < viewport.top + band
        ? -(viewport.top + band - position.dy) / band
        : position.dy > viewport.bottom - band
        ? (position.dy - viewport.bottom + band) / band
        : 0.0;
    final scroll = scrollable.position;
    final current = scroll.pixels;
    final minimum = (current + group.top - viewport.top - _margin).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    final maximum = (current + group.bottom - viewport.bottom + _margin).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    final proposed = current + speed * 700 * seconds;
    if (speed < 0 && current > minimum) {
      return proposed.clamp(minimum, current) - current;
    }
    if (speed > 0 && current < maximum) {
      return proposed.clamp(current, maximum) - current;
    }
    return 0;
  }

  void _syncTicker() {
    if (_stopped) return;
    if (_delta(1 / 60) == 0) {
      _ticker.stop();
      _previous = null;
    } else if (!_ticker.isActive) {
      _previous = null;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final previous = _previous;
    _previous = elapsed;
    if (previous == null) return;
    final seconds = ((elapsed - previous).inMicroseconds / 1000000).clamp(
      0.0,
      .05,
    );
    final delta = _delta(seconds);
    if (delta == 0) {
      _syncTicker();
      return;
    }
    scrollable.position.jumpTo(scrollable.position.pixels + delta);
    if (_refreshQueued) return;
    _refreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshQueued = false;
      if (_stopped || !scrollable.mounted || !boundary.mounted) return;
      // The pointer can remain still while the outer viewport moves the rows.
      // Refresh Flutter's insertion gap using the newly laid-out geometry.
      delegate.update(
        DragUpdateDetails(delta: Offset.zero, globalPosition: position),
      );
    });
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _ticker.dispose();
  }

  @override
  void update(DragUpdateDetails details) {
    if (_stopped) return;
    position += details.delta;
    delegate.update(details);
    _syncTicker();
  }

  @override
  void end(DragEndDetails details) {
    stop();
    delegate.end(details);
  }

  @override
  void cancel() {
    stop();
    delegate.cancel();
  }
}
