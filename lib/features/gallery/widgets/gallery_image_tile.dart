import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/primary_mouse_drag.dart';
import '../gallery_dates.dart';
import '../models.dart';
import 'result_badge_chip.dart';
import 'result_thumb.dart';

const gallerySelectionHold = Duration(milliseconds: 200);

/// The gallery and history picker share the same thumbnail, selection ring,
/// checked marker, and pointer gestures. Selecting by hold or mouse drag
/// consumes the eventual tap.
class GalleryImageTile extends StatelessWidget {
  const GalleryImageTile({
    super.key,
    required this.result,
    required this.onTap,
    this.selected = false,
    this.picked = false,
    this.selecting = false,
    this.onLongPress,
    this.onSecondaryTap,
    this.onFavorite,
    this.mouseDragSelect = false,
    this.longPressDuration = kLongPressTimeout,
    this.fit = BoxFit.cover,
  });

  final ResultImage result;
  final BoxFit fit;
  final bool selected;
  final bool picked;
  final bool selecting;
  final VoidCallback onTap;

  /// The image's current screen bounds support the existing lifted menu.
  final ValueChanged<Rect>? onLongPress;
  final ValueChanged<Rect>? onSecondaryTap;
  final VoidCallback? onFavorite;
  final bool mouseDragSelect;
  final Duration longPressDuration;

  void _fromImage(BuildContext context, ValueChanged<Rect>? callback) {
    final box = context.findRenderObject() as RenderBox?;
    if (callback != null && box != null && box.hasSize) {
      callback((box.localToGlobal(Offset.zero) & box.size).deflate(5));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final ring = selecting ? picked : selected;
    return Semantics(
      button: true,
      selected: ring,
      checked: selecting ? picked : null,
      onTap: onTap,
      onLongPress: onLongPress == null
          ? null
          : () => _fromImage(context, onLongPress),
      child: GalleryTileGestures(
        onTap: onTap,
        onLongPress: onLongPress == null
            ? null
            : () => _fromImage(context, onLongPress),
        onSecondaryTap: onSecondaryTap == null
            ? null
            : () => _fromImage(context, onSecondaryTap),
        onMouseDragStart: mouseDragSelect && onLongPress != null
            ? () => _fromImage(context, onLongPress)
            : null,
        duration: longPressDuration,
        child: AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.standard,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: ring ? scheme.primary : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2.5),
            child: LayoutBuilder(
              builder: (_, c) {
                final size = Size(
                  c.maxWidth,
                  c.hasBoundedHeight ? c.maxHeight : c.maxWidth,
                );
                final fitted = result.width > 0 && result.height > 0
                    ? applyBoxFit(
                        fit,
                        Size(result.width.toDouble(), result.height.toDouble()),
                        size,
                      ).destination
                    : size;
                final imageRect = Alignment.center.inscribe(
                  fitted,
                  Offset.zero & size,
                );
                // The check marker belongs to the tile. Image badges follow
                // the fitted pixels, moving below the marker only if needed.
                final badgeTop =
                    selecting && imageRect.left < 22 && imageRect.top < 22
                    ? 33 - imageRect.top
                    : 5.0;
                return SizedBox.fromSize(
                  size: size,
                  child: Stack(
                    children: [
                      Positioned.fromRect(
                        rect: imageRect,
                        child: SizedBox(
                          key: ValueKey('gallery-image-content-${result.id}'),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ResultThumb(
                                result: result,
                                width: imageRect.width,
                                height: imageRect.height,
                                radius: 10,
                                fit: fit,
                              ),
                              if (result.badge != ResultBadge.none)
                                Positioned(
                                  left: 5,
                                  right: 5,
                                  top: badgeTop,
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: ResultBadgeChip(
                                        badge: result.badge,
                                      ),
                                    ),
                                  ),
                                ),
                              if (onFavorite != null)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: GestureDetector(
                                    // A drag starting on the star must not
                                    // turn into a range selection behind it.
                                    onPanUpdate: (_) {},
                                    child: Material(
                                      color: Colors.black.withValues(
                                        alpha: .38,
                                      ),
                                      shape: const CircleBorder(),
                                      child: GalleryTileGestures(
                                        key: ValueKey(
                                          'gallery-favorite-${result.id}',
                                        ),
                                        duration: gallerySelectionHold,
                                        onTap: onFavorite!,
                                        onLongPress: () {},
                                        onSecondaryTap: () {},
                                        onMouseDragStart: () {},
                                        child: IconButton(
                                          tooltip: result.favorite
                                              ? '取消收藏'
                                              : '收藏',
                                          onPressed: onFavorite,
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 30,
                                                height: 30,
                                              ),
                                          padding: const EdgeInsets.all(5),
                                          icon: Icon(
                                            result.favorite
                                                ? Icons.star
                                                : Icons.star_border,
                                            size: 20,
                                            color: result.favorite
                                                ? Colors.amber
                                                : Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (galleryTimeBadge(result.createdAt)
                                  case final String t when t.isNotEmpty)
                                Positioned(
                                  left: 5,
                                  right: 5,
                                  bottom: 5,
                                  child: Align(
                                    alignment: Alignment.bottomRight,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Container(
                                        key: ValueKey(
                                          'gallery-time-badge-${result.id}',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: .45,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            7,
                                          ),
                                        ),
                                        child: Text(
                                          t,
                                          style:
                                              mono(
                                                context,
                                                size: 9,
                                                weight: FontWeight.w600,
                                              ).copyWith(
                                                color: Colors.white.withValues(
                                                  alpha: .92,
                                                ),
                                                height: 1,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (selecting)
                        Positioned(
                          left: 5,
                          top: 5,
                          child: AnimatedContainer(
                            duration: Motion.fast,
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: picked
                                  ? scheme.primary
                                  : Colors.black.withValues(alpha: .35),
                              border: picked
                                  ? null
                                  : Border.all(
                                      color: Colors.white.withValues(
                                        alpha: .85,
                                      ),
                                      width: 1.5,
                                    ),
                            ),
                            child: picked
                                ? Icon(
                                    Icons.check,
                                    size: 15,
                                    color: scheme.onPrimary,
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Tap, touch hold, and optional immediate mouse drag for images and covers.
/// Scrolling or a second pointer cancels a pending tap or hold.
class GalleryTileGestures extends StatefulWidget {
  const GalleryTileGestures({
    super.key,
    required this.onTap,
    required this.onLongPress,
    required this.onSecondaryTap,
    required this.duration,
    required this.child,
    this.onMouseDragStart,
  });

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final VoidCallback? onMouseDragStart;
  final Duration duration;
  final Widget child;

  @override
  State<GalleryTileGestures> createState() => _GalleryTileGesturesState();
}

class _GalleryTileGesturesState extends State<GalleryTileGestures> {
  _CancelableTap? _tap;
  _CancelableHold? _hold;
  ScrollPosition? _scroll;
  int? _pointer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scroll = Scrollable.maybeOf(context)?.position;
    if (identical(scroll, _scroll)) return;
    _scroll?.removeListener(_cancelPending);
    _scroll = scroll;
    _scroll?.addListener(_cancelPending);
  }

  @override
  void didUpdateWidget(GalleryTileGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onLongPress != null && widget.onLongPress == null) {
      _cancelPending();
    }
  }

  void _down(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) return;
    if (_pointer != null) {
      _cancelPending();
      return;
    }
    _pointer = event.pointer;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_globalEvent);
    HardwareKeyboard.instance.addHandler(_keyEvent);
  }

  void _globalEvent(PointerEvent event) {
    // Wheel/trackpad scrolling can move the image while the pressed pointer
    // remains still; a second contact also must not turn a pinch into a hold.
    if (event is PointerSignalEvent ||
        event is PointerPanZoomStartEvent ||
        (event is PointerDownEvent && event.pointer != _pointer)) {
      _cancelPending();
    }
  }

  void _release(PointerEvent event) {
    if (event.pointer == _pointer) _stopWatching();
  }

  bool _keyEvent(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelPending();
    }
    return false;
  }

  void _stopWatching() {
    if (_pointer == null) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_globalEvent);
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    _pointer = null;
  }

  void _cancelPending() {
    if (_pointer == null) return;
    _tap?.cancelPending();
    _hold?.cancelPending();
    _stopWatching();
  }

  @override
  void dispose() {
    _scroll?.removeListener(_cancelPending);
    _stopWatching();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: (event) {
      if (event.pointer == _pointer && event.buttons != kPrimaryButton) {
        _cancelPending();
      }
    },
    onPointerUp: _release,
    onPointerCancel: _release,
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      gestures: {
        _CancelableTap: GestureRecognizerFactoryWithHandlers<_CancelableTap>(
          _CancelableTap.new,
          (recognizer) {
            _tap = recognizer;
            recognizer
              ..onTap = widget.onTap
              ..onSecondaryTapUp = widget.onSecondaryTap == null
                  ? null
                  : (_) => widget.onSecondaryTap!();
          },
        ),
        if (widget.onLongPress != null)
          _CancelableHold:
              GestureRecognizerFactoryWithHandlers<_CancelableHold>(
                () => _CancelableHold(widget.duration),
                (recognizer) {
                  _hold = recognizer;
                  recognizer
                    ..supportedDevices = widget.onMouseDragStart == null
                        ? null
                        : {
                            for (final kind in PointerDeviceKind.values)
                              if (kind != PointerDeviceKind.mouse) kind,
                          }
                    ..onLongPress = widget.onLongPress;
                },
              ),
        if (widget.onMouseDragStart != null)
          PrimaryMouseDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                PrimaryMouseDragGestureRecognizer
              >(PrimaryMouseDragGestureRecognizer.new, (recognizer) {
                recognizer.onStart = (_) {
                  // A wheel, second pointer, or Escape may have interrupted
                  // the original press before it crossed the drag threshold.
                  if (_pointer != null) widget.onMouseDragStart!();
                };
              }),
      },
      child: widget.child,
    ),
  );
}

class _CancelableTap extends TapGestureRecognizer {
  void cancelPending() {
    if (state == GestureRecognizerState.ready) return;
    resolve(GestureDisposition.rejected);
    if (primaryPointer case final pointer?) stopTrackingPointer(pointer);
  }
}

class _CancelableHold extends LongPressGestureRecognizer {
  _CancelableHold(Duration duration)
    : super(
        duration: duration,
        allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
      );

  void cancelPending() {
    if (state == GestureRecognizerState.ready) return;
    resolve(GestureDisposition.rejected);
    // Stop the deadline even if this recognizer just won the arena because
    // its competing tap was canceled first.
    if (primaryPointer case final pointer?) stopTrackingPointer(pointer);
  }
}
