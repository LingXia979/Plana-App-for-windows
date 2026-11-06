import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/clipboard_image.dart';
import '../platform/image_transfer.dart';
import 'image_drop.dart';

/// Inside Plana this is the existing Flutter drag. Crossing the window edge
/// hands the same gesture to Windows OLE, exposing only a processed export.
class ExternalImageDrag extends StatefulWidget {
  const ExternalImageDrag({
    super.key,
    required this.data,
    required this.prepare,
    required this.feedback,
    required this.child,
    this.enabled = true,
    this.onStart,
    this.onEnd,
  });

  final ImageDropPayload data;
  final Future<PreparedImageTransfer> Function() prepare;
  final Widget feedback;
  final Widget child;
  final bool enabled;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;

  @override
  State<ExternalImageDrag> createState() => _ExternalImageDragState();
}

class _DragSession {
  _DragSession(this.pointer, this.payload, this.prepared);
  final int pointer;
  final ImageDropPayload payload;
  final Future<PreparedImageTransfer?> prepared;
  Offset position = Offset.zero;
  bool active = true;
  bool handingOff = false;
  bool native = false;
  bool failed = false;
}

class _ExternalImageDragState extends State<ExternalImageDrag> {
  int? _pointer;
  _DragSession? _session;

  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  void _start() {
    if (_windows && _pointer != null) {
      // Encode early, but materialize no file for an entirely internal drag.
      final prepared = Future.sync(widget.prepare).then<PreparedImageTransfer?>(
        (value) => value,
        onError: (Object _, StackTrace _) => null,
      );
      _session = _DragSession(_pointer!, widget.data, prepared);
      HardwareKeyboard.instance.addHandler(_keyEvent);
    }
    widget.onStart?.call();
  }

  bool _outside(Offset position) {
    final view = View.of(context);
    return !(Offset.zero & (view.physicalSize / view.devicePixelRatio))
        .contains(position);
  }

  bool _keyEvent(KeyEvent event) {
    final session = _session;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        session != null &&
        session.active &&
        !session.native) {
      session.active = false;
      GestureBinding.instance.cancelPointer(session.pointer);
      return true;
    }
    return false;
  }

  Future<void> _handoff(_DragSession session) async {
    if (!session.active ||
        session.handingOff ||
        session.native ||
        session.failed ||
        !mounted ||
        !_outside(session.position)) {
      return;
    }
    session.handingOff = true;
    bool ready() =>
        mounted &&
        identical(_session, session) &&
        session.active &&
        _pointer == session.pointer &&
        _outside(session.position);
    try {
      final prepared = await session.prepared;
      if (!ready()) return;
      if (prepared == null) throw const FileSystemException('图片导出失败');
      final file = await prepared.file();
      if (!ready()) return;
      session.native = true;
      final token = NativeImageDragRegistry.register(session.payload);
      try {
        // Remove Flutter's avatar/capture before entering OLE's modal loop.
        GestureBinding.instance.cancelPointer(session.pointer);
        await Future<void>.delayed(Duration.zero);
        await DesktopClipboard.channel.invokeMethod<String>('startDrag', {
          'filePath': file.path,
          'internalToken': token,
        });
      } finally {
        NativeImageDragRegistry.finish(token);
      }
    } catch (_) {
      session.failed = true;
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('无法拖出这张图片，请重试或使用复制图片')));
      }
    } finally {
      session.handingOff = false;
    }
  }

  @override
  void dispose() {
    _session?.active = false;
    HardwareKeyboard.instance.removeHandler(_keyEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.kind == PointerDeviceKind.mouse &&
          event.buttons == kPrimaryMouseButton) {
        _pointer = event.pointer;
      }
    },
    onPointerUp: (event) {
      if (_pointer == event.pointer) _pointer = null;
    },
    onPointerCancel: (event) {
      if (_pointer == event.pointer) _pointer = null;
    },
    child: DesktopImageDraggable(
      data: widget.data,
      maxSimultaneousDrags: widget.enabled ? 1 : 0,
      onDragStarted: _start,
      onDragUpdate: (details) {
        final session = _session;
        if (session == null) return;
        session.position = details.globalPosition;
        unawaited(_handoff(session));
      },
      onDragEnd: (_) {
        _session?.active = false;
        HardwareKeyboard.instance.removeHandler(_keyEvent);
        widget.onEnd?.call();
      },
      feedback: widget.feedback,
      child: widget.child,
    ),
  );
}
