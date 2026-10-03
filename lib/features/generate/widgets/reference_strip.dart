import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import 'common.dart';
import 'reference_image_preview.dart';

typedef ReferencePreview = ({String id, Uint8List? image, bool enabled});

/// A click selects, a desktop double-click previews, a delayed press reorders.
/// Focus is scoped to this strip so arrow keys in text fields remain untouched.
class ReferenceStrip extends ConsumerStatefulWidget {
  const ReferenceStrip({
    super.key,
    required this.items,
    required this.selectedId,
    required this.onSelect,
    required this.onReorder,
    this.previewTitle = '参考图预览',
  });
  final List<ReferencePreview> items;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final void Function(int, int) onReorder;
  final String previewTitle;

  @override
  ConsumerState<ReferenceStrip> createState() => _ReferenceStripState();
}

class _ReferenceStripState extends ConsumerState<ReferenceStrip> {
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'Reference thumbnails');
  static const _extent = 80.0;
  bool _previewOpen = false;
  ({String id, Offset position, PointerDeviceKind kind})? _lastTap;
  Timer? _tapWindow;
  Timer? _minimumTapWindow;
  bool _doubleTapReady = false;
  int? _pressedPointer;
  Offset? _pressedPosition;

  void _resetClicks() {
    _tapWindow?.cancel();
    _minimumTapWindow?.cancel();
    _lastTap = null;
    _doubleTapReady = false;
  }

  void _tapUp(int index, TapUpDetails details) {
    final id = widget.items[index].id;
    final previous = _lastTap;
    final doubleClick =
        previous != null &&
        _doubleTapReady &&
        previous.id == id &&
        previous.kind == details.kind &&
        (previous.position - details.globalPosition).distance <= kDoubleTapSlop;
    _resetClicks();
    if (doubleClick) {
      unawaited(_preview(index));
      return;
    }
    // A normal tap wins on release. Remember it without holding the gesture
    // arena, so selection and the detail controls update on this frame.
    _select(index);
    if (details.kind == PointerDeviceKind.unknown) {
      return; // Accessibility activation is a single tap.
    }
    _lastTap = (id: id, position: details.globalPosition, kind: details.kind);
    _minimumTapWindow = Timer(kDoubleTapMinTime, () => _doubleTapReady = true);
    _tapWindow = Timer(kDoubleTapTimeout, _resetClicks);
  }

  Future<void> _preview(int index) async {
    if (_previewOpen) return;
    final image = widget.items[index].image;
    if (image == null || image.isEmpty) return;
    _previewOpen = true;
    try {
      await showReferenceImagePreview(
        context,
        image: image,
        title: '${widget.previewTitle} · ${index + 1}',
      );
    } finally {
      _previewOpen = false;
    }
  }

  void _select(int index) {
    if (widget.items.isEmpty) return;
    index = index.clamp(0, widget.items.length - 1);
    _focus.requestFocus();
    widget.onSelect(widget.items[index].id);
    _reveal(index);
  }

  void _reveal(int index) {
    if (!_scroll.hasClients) return;
    final left = index * _extent;
    final right = left + _extent;
    final offset = _scroll.offset;
    final view = _scroll.position.viewportDimension;
    final target = left < offset
        ? left
        : (right > offset + view ? right - view : offset);
    if ((target - offset).abs() < .5) return;
    _scroll.animateTo(
      target.clamp(0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  @override
  void didUpdateWidget(covariant ReferenceStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final itemsChanged =
        widget.items.length != oldWidget.items.length ||
        widget.items.indexed.any((entry) {
          final old = oldWidget.items[entry.$1];
          final next = entry.$2;
          return old.id != next.id ||
              !identical(old.image, next.image) ||
              old.enabled != next.enabled;
        });
    if (itemsChanged ||
        (widget.selectedId != oldWidget.selectedId &&
            widget.selectedId != _lastTap?.id)) {
      _resetClicks();
    }
    if (widget.selectedId != oldWidget.selectedId ||
        widget.items.length != oldWidget.items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final index = widget.items.indexWhere((e) => e.id == widget.selectedId);
        if (index >= 0) _reveal(index);
      });
    }
  }

  @override
  void dispose() {
    _resetClicks();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = ref.watch(desktopModeProvider);
    return Focus(
      focusNode: _focus,
      onFocusChange: (focused) {
        if (!focused) _resetClicks();
      },
      onKeyEvent: (_, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        _resetClicks();
        final delta = event.logicalKey == LogicalKeyboardKey.arrowLeft
            ? -1
            : event.logicalKey == LogicalKeyboardKey.arrowRight
            ? 1
            : 0;
        if (delta == 0) return KeyEventResult.ignored;
        final current = widget.items.indexWhere(
          (e) => e.id == widget.selectedId,
        );
        _select((current < 0 ? 0 : current) + delta);
        return KeyEventResult.handled;
      },
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons != kPrimaryButton || _pressedPointer != null) {
            _resetClicks();
          }
          _pressedPointer = event.pointer;
          _pressedPosition = event.position;
        },
        onPointerMove: (event) {
          if (event.pointer == _pressedPointer &&
              _pressedPosition != null &&
              (event.position - _pressedPosition!).distance >
                  computeHitSlop(event.kind, null)) {
            _resetClicks();
          }
        },
        onPointerUp: (_) {
          _pressedPointer = null;
          _pressedPosition = null;
        },
        onPointerCancel: (_) {
          _pressedPointer = null;
          _pressedPosition = null;
          _resetClicks();
        },
        onPointerSignal: (event) {
          _resetClicks();
          if (event is! PointerScrollEvent || !_scroll.hasClients) return;
          // An ordinary wheel belongs to the vertical sidebar. Only Shift+wheel
          // (or a native horizontal gesture) is allowed to scroll this strip.
          if (event.scrollDelta.dx == 0 &&
              !HardwareKeyboard.instance.isShiftPressed) {
            return;
          }
          final delta = event.scrollDelta.dx != 0
              ? event.scrollDelta.dx
              : event.scrollDelta.dy;
          final next = (_scroll.offset + delta).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          );
          if (next == _scroll.offset) return;
          GestureBinding.instance.pointerSignalResolver.register(
            event,
            (_) => _scroll.jumpTo(next),
          );
        },
        child: SizedBox(
          height: desktop ? 82 : 72,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.mouse,
                PointerDeviceKind.touch,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.stylus,
              },
            ),
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: desktop,
              scrollbarOrientation: ScrollbarOrientation.bottom,
              child: ReorderableListView(
                scrollController: _scroll,
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                itemExtent: _extent,
                padding: EdgeInsets.only(top: 2, bottom: desktop ? 10 : 0),
                proxyDecorator: dragProxy,
                onReorderStart: (index) {
                  _resetClicks();
                  _select(index);
                  dragStartHaptic(index);
                },
                onReorderEnd: (index) {
                  _resetClicks();
                  dragEndHaptic(index);
                },
                onReorderItem: widget.onReorder,
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    _ShortHoldDrag(
                      key: ValueKey(widget.items[i].id),
                      index: i,
                      delay: Duration(milliseconds: desktop ? 100 : 500),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: RefThumb(
                          selected: widget.items[i].id == widget.selectedId,
                          enabled: widget.items[i].enabled,
                          image: widget.items[i].image,
                          onTap: () {
                            _resetClicks();
                            _select(i);
                          },
                          onTapUp:
                              desktop &&
                                  (widget.items[i].image?.isNotEmpty ?? false)
                              ? (details) => _tapUp(i, details)
                              : null,
                          onTapCancel: _resetClicks,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortHoldDrag extends ReorderableDragStartListener {
  const _ShortHoldDrag({
    super.key,
    required super.index,
    required super.child,
    required this.delay,
  });
  final Duration delay;
  @override
  MultiDragGestureRecognizer createRecognizer() =>
      DelayedMultiDragGestureRecognizer(delay: delay, debugOwner: this);
}
