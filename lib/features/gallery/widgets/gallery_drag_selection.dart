import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/primary_mouse_drag.dart';

/// Album-style continuous selection, shared by galleries and history pickers.
///
/// Wrap the scroll viewport, and mark each image with
/// `MetaData(metaData: image.id, child: ...)`. Only descendant image IDs in
/// [order] can become endpoints. Mouse drags work in every direction. For
/// touch, a horizontal start selects; a vertical start remains a scroll.
class GalleryDragSelection extends StatefulWidget {
  const GalleryDragSelection({
    super.key,
    required this.enabled,
    required this.scrollController,
    required this.order,
    required this.selected,
    required this.onChanged,
    required this.child,
    this.handleEscape = true,
  });

  final bool enabled;
  final ScrollController scrollController;
  final List<String> order;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final Widget child;

  /// A containing gallery can own Escape for its whole selection mode. Avoid
  /// a global drag handler competing with that route-scoped keyboard action.
  final bool handleEscape;

  @override
  State<GalleryDragSelection> createState() => GalleryDragSelectionState();
}

class GalleryDragSelectionState extends State<GalleryDragSelection>
    with SingleTickerProviderStateMixin {
  final _viewportKey = GlobalKey();
  bool? _adding;
  String? _anchor, _current;
  Set<String> _base = const {};
  Set<String> _lastEmitted = const {};
  List<String> _order = const [];
  Map<String, int> _index = const {};
  Offset? _position;
  double _startY = 0;
  Ticker? _edgeTicker;
  Duration _edgeLast = Duration.zero;
  int? _pointer;
  List<String>? _pointerOrder;
  bool _interrupted = false;
  Offset? _downPosition;
  Offset? _lastPointerPosition;
  bool _holding = false;

  static const _edgeBand = 56.0;
  static const _edgeMinSpeed = 120.0;
  static const _edgeMaxSpeed = 1500.0;

  RenderBox? get _viewport =>
      _viewportKey.currentContext?.findRenderObject() as RenderBox?;

  @override
  void didUpdateWidget(GalleryDragSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.enabled && !widget.enabled) ||
        oldWidget.scrollController != widget.scrollController ||
        (_pointerOrder != null && !listEquals(_pointerOrder, widget.order))) {
      cancel();
    }
  }

  /// Stop an active or pending sweep, for example before changing albums or
  /// entering a two-finger pinch. Keep the selection already made.
  void cancel() {
    _interrupted = true;
    _finish();
  }

  void _down(PointerDownEvent event) {
    // Observe the first press even before selection mode is enabled. The
    // tile's hold recognizer can hand that same pointer to beginHold below.
    if (event.buttons != kPrimaryButton) return;
    if (_pointer != null) {
      cancel();
      return;
    }
    _pointer = event.pointer;
    _downPosition = _lastPointerPosition = event.position;
    _pointerOrder = List.of(widget.order);
    _interrupted = false;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_globalEvent);
    HardwareKeyboard.instance.addHandler(_keyEvent);
  }

  void _globalEvent(PointerEvent event) {
    if (event is PointerSignalEvent ||
        event is PointerPanZoomStartEvent ||
        (event is PointerDownEvent && event.pointer != _pointer)) {
      cancel();
    }
  }

  void _release(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerCancelEvent) cancel();
    if (_holding) _finish();
    _stopWatching();
  }

  bool _keyEvent(KeyEvent event) {
    if (!widget.handleEscape ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    final wasSelecting = _adding != null;
    cancel();
    return wasSelecting;
  }

  void _stopWatching() {
    if (_pointer == null) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_globalEvent);
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    _pointer = null;
    _pointerOrder = null;
    _downPosition = _lastPointerPosition = null;
  }

  /// Continue the press that entered multi-selection without lifting first.
  /// The tile already owns the gesture arena; raw moves extend its range.
  bool beginHold(String id) {
    final position = _downPosition;
    if (_pointer == null ||
        _interrupted ||
        position == null ||
        !widget.order.contains(id)) {
      return false;
    }
    _holding = true;
    _begin(id, position);
    // The threshold-crossing move was observed by this listener before the
    // tile won the arena. Include it even if the next event is pointer-up.
    if (_lastPointerPosition case final current? when current != position) {
      _update(DragUpdateDetails(globalPosition: current));
    }
    return true;
  }

  void _moveHeld(PointerMoveEvent event) {
    if (event.pointer == _pointer && event.buttons != kPrimaryButton) {
      cancel();
      return;
    }
    if (event.pointer == _pointer) _lastPointerPosition = event.position;
    if (_holding && event.pointer == _pointer) {
      _update(DragUpdateDetails(globalPosition: event.position));
    }
  }

  bool _isDescendant(RenderObject target, RenderObject viewport) {
    RenderObject? current = target;
    while (current != null) {
      if (identical(current, viewport)) return true;
      current = current.parent;
    }
    return false;
  }

  String? _idAt(Offset globalPosition) {
    final viewport = _viewport;
    if (viewport == null || !viewport.hasSize) return null;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      globalPosition,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData &&
          target.metaData is String &&
          _isDescendant(target, viewport)) {
        final id = target.metaData as String;
        if (_index.containsKey(id)) return id;
      }
    }
    return null;
  }

  void _start(DragStartDetails details) {
    if (!widget.enabled || _interrupted || _pointer == null) return;
    _order = List.of(widget.order);
    _index = {for (var i = 0; i < _order.length; i++) _order[i]: i};
    // DragStartBehavior.down preserves the image actually pressed, not the
    // different image reached when the horizontal gesture passes its slop.
    final id = _idAt(details.globalPosition);
    if (id == null) {
      _finish();
      return;
    }
    _begin(id, details.globalPosition);
  }

  void _begin(String id, Offset position) {
    _order = List.of(widget.order);
    _index = {for (var i = 0; i < _order.length; i++) _order[i]: i};
    _anchor = _current = id;
    _adding = !widget.selected.contains(id);
    _base = Set.of(widget.selected);
    _lastEmitted = Set.of(widget.selected);
    _position = position;
    _startY = position.dy;
    _applyRange();
  }

  void _update(DragUpdateDetails details) {
    if (_adding == null || _interrupted) return;
    _position = details.globalPosition;
    _track();
    if (_edgePull() == 0) {
      _edgeTicker?.stop();
    } else if (!(_edgeTicker?.isActive ?? false)) {
      _edgeLast = Duration.zero;
      (_edgeTicker ??= createTicker(_edgeTick)).start();
    }
  }

  void _finish() {
    _holding = false;
    _edgeTicker?.stop();
    _adding = null;
    _anchor = _current = null;
    _base = const {};
    _lastEmitted = const {};
    _order = const [];
    _index = const {};
    _position = null;
  }

  void _track() {
    final position = _position;
    final box = _viewport;
    if (position == null || box == null || !box.hasSize) return;
    final local = box.globalToLocal(position);
    final id = _idAt(
      box.localToGlobal(
        Offset(
          local.dx.clamp(1.0, math.max(1.0, box.size.width - 1)),
          local.dy.clamp(1.0, math.max(1.0, box.size.height - 1)),
        ),
      ),
    );
    // Date headings and gaps keep the last endpoint. Outside the viewport,
    // clamp to its edge so scrolling still extends the whole ordered range.
    if (id == null || id == _current) return;
    _current = id;
    _applyRange();
  }

  void _applyRange() {
    final a = _index[_anchor], b = _index[_current];
    final adding = _adding;
    if (a == null || b == null || adding == null) return;
    final next = Set<String>.of(_base);
    for (var i = math.min(a, b); i <= math.max(a, b); i++) {
      adding ? next.add(_order[i]) : next.remove(_order[i]);
    }
    // Multiple pointer updates can arrive before the parent rebuilds with
    // its new selection. Compare with what we emitted, not a stale widget.
    if (!setEquals(next, _lastEmitted)) {
      _lastEmitted = Set.of(next);
      widget.onChanged(next);
    }
  }

  double _edgePull() {
    final position = _position;
    final box = _viewport;
    if (position == null || box == null || !box.hasSize) return 0;
    final height = box.size.height;
    if (height <= 0) return 0;
    final band = math.min(_edgeBand, height / 4);
    final y = box.globalToLocal(position).dy;
    final startY = box.globalToLocal(Offset(position.dx, _startY)).dy;
    // Starting within the edge band must not immediately move the grid when
    // sweeping a row. First move another 16px toward that edge to arm it.
    const arm = 16.0;
    if (y > height - band && (startY <= height - band || y - startY > arm)) {
      return ((y - (height - band)) / band).clamp(0.0, 1.0);
    }
    if (y < band && (startY >= band || startY - y > arm)) {
      return -((band - y) / band).clamp(0.0, 1.0);
    }
    return 0;
  }

  void _edgeTick(Duration elapsed) {
    final dt = (elapsed - _edgeLast).inMicroseconds / 1e6;
    _edgeLast = elapsed;
    final pull = _edgePull();
    final scroll = widget.scrollController;
    if (pull == 0 ||
        _adding == null ||
        _interrupted ||
        !widget.enabled ||
        !scroll.hasClients ||
        scroll.positions.length != 1) {
      _edgeTicker?.stop();
      return;
    }
    _track();
    final position = scroll.position;
    final t = pull.abs();
    final speed = _edgeMinSpeed + (_edgeMaxSpeed - _edgeMinSpeed) * t * t;
    final to = (position.pixels + pull.sign * speed * dt).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (to == position.pixels) {
      if (dt > 0) _edgeTicker?.stop();
      return;
    }
    scroll.jumpTo(to);
  }

  @override
  void dispose() {
    _edgeTicker?.dispose();
    _stopWatching();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    key: _viewportKey,
    onPointerDown: _down,
    onPointerMove: _moveHeld,
    onPointerUp: _release,
    onPointerCancel: _release,
    onPointerSignal: (_) => cancel(),
    onPointerPanZoomStart: (_) => cancel(),
    child: RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        if (widget.enabled) ...{
          PrimaryMouseDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                PrimaryMouseDragGestureRecognizer
              >(PrimaryMouseDragGestureRecognizer.new, (recognizer) {
                recognizer
                  ..onStart = _start
                  ..onUpdate = _update
                  ..onCancel = _finish
                  ..onEnd = (_) => _finish();
              }),
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(HorizontalDragGestureRecognizer.new, (recognizer) {
                recognizer
                  ..supportedDevices = {
                    for (final kind in PointerDeviceKind.values)
                      if (kind != PointerDeviceKind.mouse) kind,
                  }
                  ..dragStartBehavior = DragStartBehavior.down
                  // Canceling a tile's tap/hold (wheel, second contact) can
                  // leave this as the only arena member. That alone must not
                  // begin selection without an actual horizontal movement.
                  ..onlyAcceptDragOnThreshold = true
                  ..onStart = _start
                  ..onUpdate = _update
                  ..onCancel = _finish;
                recognizer.onEnd = (_) => _finish();
              }),
        },
      },
      child: widget.child,
    ),
  );
}
