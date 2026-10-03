import 'package:flutter/gestures.dart';

/// Starts a primary-button mouse drag after a small displacement, without a
/// timer or a preferred axis. Sub-threshold jitter still belongs to the tap.
class PrimaryMouseDragGestureRecognizer extends PanGestureRecognizer {
  PrimaryMouseDragGestureRecognizer()
    : super(
        supportedDevices: {PointerDeviceKind.mouse},
        allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
      ) {
    dragStartBehavior = DragStartBehavior.down;
    onlyAcceptDragOnThreshold = true;
  }

  static const threshold = 4.0;
  Offset? _origin;
  Offset? _position;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = _position = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _position = event.position;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      _origin != null &&
      _position != null &&
      (_position! - _origin!).distanceSquared > threshold * threshold;

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _origin = _position = null;
  }
}
