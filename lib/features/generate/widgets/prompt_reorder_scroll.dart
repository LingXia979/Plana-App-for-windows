import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The whole prompt/character group, including its heading. Only automatic
/// reorder scrolling is constrained here; normal sidebar scrolling is unchanged.
class PromptReorderBoundary extends StatefulWidget {
  const PromptReorderBoundary({super.key, required this.child});

  final Widget child;

  @override
  State<PromptReorderBoundary> createState() => _BoundaryState();
}

class _BoundaryState extends State<PromptReorderBoundary> {
  Object? _drag;

  Object beginDrag() {
    final token = Object();
    Tooltip.dismissAllToolTips();
    setState(() => _drag = token);
    return token;
  }

  void endDrag(Object token) {
    void clear() {
      if (mounted && identical(_drag, token)) setState(() => _drag = null);
    }

    // A changed canvas/item count can dispose the recognizer during a build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => clear());
    } else {
      clear();
    }
  }

  @override
  Widget build(BuildContext context) => _BoundaryScope(
    state: this,
    child: TooltipVisibility(visible: _drag == null, child: widget.child),
  );
}

class _BoundaryScope extends InheritedWidget {
  const _BoundaryScope({required this.state, required super.child});

  final _BoundaryState state;

  @override
  bool updateShouldNotify(_BoundaryScope oldWidget) => false;
}

/// Keep the row under the pointer at its original size. The proxy is a visual
/// only: its copied headers/buttons must not create a second hover tooltip.
Widget desktopPromptDragProxy(
  Widget child,
  int index,
  Animation<double> animation,
) => IgnorePointer(
  child: TooltipVisibility(
    visible: false,
    child: AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) => Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 4 * Curves.easeOut.transform(animation.value),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    ),
  ),
);

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
        .getInheritedWidgetOfExactType<_BoundaryScope>()
        ?.state;
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
  final _BoundaryState? boundary;

  @override
  MultiDragGestureRecognizer createRecognizer() => boundary == null
      ? super.createRecognizer()
      : _SidebarRecognizer(scrollable, boundary!);
}

class _SidebarRecognizer extends ImmediateMultiDragGestureRecognizer {
  _SidebarRecognizer(this.scrollable, this.boundary);

  final ScrollableState? scrollable;
  final _BoundaryState boundary;
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
    _token = boundary.beginDrag();
  }

  final Drag delegate;
  final ScrollableState? scrollable;
  final _BoundaryState boundary;
  Offset position;
  late final Ticker _ticker;
  late final Object _token;
  Duration? _previous;
  double _velocity = 0;
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
  static const _edge = 80.0;
  static const _maxSpeed = 800.0; // Logical pixels per second, not per frame.

  double _targetVelocity() {
    final sidebar = scrollable;
    if (sidebar == null || !sidebar.mounted || !boundary.mounted) return 0;
    final viewport = _rect(sidebar.context);
    final view = View.of(sidebar.context);
    final window = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    // Keep scrolling through this column's fixed header/footer. Crossing the
    // viewport vertically is intentional; leaving the column/window is not.
    if (viewport == null ||
        !window.contains(position) ||
        position.dx < viewport.left ||
        position.dx > viewport.right) {
      return 0;
    }
    final band = _edge.clamp(0.0, viewport.height / 2);
    if (band == 0) return 0;
    final proximity = position.dy < viewport.top + band
        ? -(viewport.top + band - position.dy) / band
        : position.dy > viewport.bottom - band
        ? (position.dy - viewport.bottom + band) / band
        : 0.0;
    return proximity.clamp(-1.0, 1.0) * _maxSpeed;
  }

  double _delta(double velocity, double seconds) {
    final sidebar = scrollable;
    if (sidebar == null || !sidebar.mounted || !boundary.mounted) return 0;
    final viewport = _rect(sidebar.context);
    final group = _rect(boundary.context);
    if (viewport == null || group == null) return 0;
    final scroll = sidebar.position;
    final current = scroll.pixels;
    final minimum = (current + group.top - viewport.top - _margin).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    final maximum = (current + group.bottom - viewport.bottom + _margin).clamp(
      scroll.minScrollExtent,
      scroll.maxScrollExtent,
    );
    final proposed = current + velocity * seconds;
    if (velocity < 0 && current > minimum) {
      return proposed.clamp(minimum, current) - current;
    }
    if (velocity > 0 && current < maximum) {
      return proposed.clamp(current, maximum) - current;
    }
    return 0;
  }

  void _syncTicker() {
    if (_stopped) return;
    final target = _targetVelocity();
    if (_delta(target, 1 / 60) == 0) {
      _ticker.stop();
      _previous = null;
      _velocity = 0;
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
    final target = _targetVelocity();
    if (target == 0) {
      _syncTicker();
      return;
    }
    // Ease into edge scrolling without continuing in the old direction after
    // a reversal. Leaving the band stops immediately; there is no inertia.
    if (_velocity.sign != target.sign) _velocity = 0;
    _velocity += (target - _velocity) * (1 - math.exp(-seconds / .08));
    final delta = _delta(_velocity, seconds);
    if (delta == 0) {
      _syncTicker();
      return;
    }
    final sidebar = scrollable!;
    sidebar.position.jumpTo(sidebar.position.pixels + delta);
    if (_refreshQueued) return;
    _refreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshQueued = false;
      if (_stopped || !sidebar.mounted || !boundary.mounted) return;
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
    boundary.endDrag(_token);
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
