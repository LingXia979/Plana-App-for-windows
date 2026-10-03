import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../util/image_ops.dart';
import '../util/image_pick.dart';

/// One drag has one payload and one recipient. Bytes are read only on drop.
class ImageDropPayload {
  ImageDropPayload.files(List<String> paths)
    : paths = List.unmodifiable(paths),
      imageId = null,
      source = null,
      _load = null;

  ImageDropPayload.image({
    required String name,
    required Future<Uint8List?> Function() load,
    this.imageId,
    this.source,
  }) : paths = const [],
       _load = (() async {
         final bytes = await load();
         if (bytes == null || bytes.isEmpty) {
           throw const FormatException('图片已删除或尚未就绪');
         }
         return [PickedImage(name, bytes)];
       });

  final List<String> paths;
  final String? imageId;
  final String? source;
  final Future<List<PickedImage>> Function()? _load;
  int get count => _load == null ? paths.length : 1;

  Future<List<PickedImage>> read() async {
    if (count == 0 || count > 64) {
      throw const FormatException('一次最多拖入 64 张图片');
    }
    final files = <PickedImage>[];
    if (_load != null) {
      files.addAll(await _load());
    } else {
      var total = 0;
      for (final path in paths) {
        final file = File(path);
        final size = await file.length();
        total += size;
        if (size > 64 * 1024 * 1024 || total > 256 * 1024 * 1024) {
          throw const FormatException('图片过大：单张最多 64 MB，一次最多 256 MB');
        }
        files.add(PickedImage(p.basename(path), await file.readAsBytes()));
      }
    }
    // Validate the entire batch before any recipient changes its state.
    for (final file in files) {
      try {
        final (width, height) = await decodeImageSize(file.bytes);
        if (width <= 0 || height <= 0) throw const FormatException();
      } catch (_) {
        throw FormatException('无法读取图片：${file.name}');
      }
    }
    return files;
  }
}

typedef ImageDropCallback =
    Future<void> Function(List<PickedImage> images, ImageDropPayload payload);

/// Flutter's drag target arbitration also selects the innermost native target.
/// Hit testing (rather than rectangle registration) excludes obscured/offstage
/// pages and prevents drops through modal barriers.
class ImageDropRegion extends StatefulWidget {
  const ImageDropRegion({
    super.key,
    required this.label,
    required this.onDrop,
    required this.child,
    this.multiple = false,
    this.enabled = true,
    this.acceptInternal = true,
    this.accept,
  });

  final String label;
  final ImageDropCallback onDrop;
  final Widget child;
  final bool multiple;
  final bool enabled;
  final bool acceptInternal;
  final bool Function(ImageDropPayload)? accept;

  @override
  State<ImageDropRegion> createState() => _ImageDropRegionState();
}

class _ImageDropRegionState extends State<ImageDropRegion> {
  bool _externalHover = false;
  bool _busy = false;
  bool get _enabled => widget.enabled && !_busy;
  bool _accepts(ImageDropPayload payload) =>
      _enabled &&
      (widget.acceptInternal || payload.paths.isNotEmpty) &&
      (widget.accept?.call(payload) ?? true);

  void _hover(bool value) {
    if (mounted && value != _externalHover) {
      setState(() => _externalHover = value);
    }
  }

  Future<void> _receive(ImageDropPayload payload) async {
    if (!_accepts(payload)) return;
    setState(() => _busy = true);
    try {
      if (!widget.multiple && payload.count > 1) {
        throw const FormatException('此处一次接收一张图片，请拖入单张图片');
      }
      final images = await payload.read();
      if (mounted) await widget.onDrop(images, payload);
    } catch (error) {
      if (mounted) {
        final message = error is FormatException
            ? error.message
            : '图片导入失败，请检查文件是否可读';
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    behavior: HitTestBehavior.translucent,
    child: DragTarget<ImageDropPayload>(
      onWillAcceptWithDetails: (details) => _accepts(details.data),
      onAcceptWithDetails: (details) => unawaited(_receive(details.data)),
      builder: (context, candidates, rejected) {
        final hover = _enabled && (_externalHover || candidates.isNotEmpty);
        return Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (hover)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: .08),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Material(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Text('松开以${widget.label}'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class DesktopImageDropHost extends StatefulWidget {
  const DesktopImageDropHost({super.key, required this.child});
  final Widget child;
  static const channel = MethodChannel('plana/image_drop');

  @override
  State<DesktopImageDropHost> createState() => _DesktopImageDropHostState();
}

class _DesktopImageDropHostState extends State<DesktopImageDropHost> {
  _ImageDropRegionState? _hovered;
  bool _receiving = false;

  @override
  void initState() {
    super.initState();
    DesktopImageDropHost.channel.setMethodCallHandler(_nativeEvent);
  }

  _ImageDropRegionState? _at(Offset position) {
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      hit,
      position,
      View.of(context).viewId,
    );
    for (final entry in hit.path) {
      final target = entry.target;
      if (target is RenderMetaData &&
          target.metaData is _ImageDropRegionState) {
        final region = target.metaData as _ImageDropRegionState;
        // A disabled local receiver blocks the fallback behind it too.
        return region._enabled ? region : null;
      }
    }
    return null;
  }

  Future<void> _nativeEvent(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'leave') {
      _hovered?._hover(false);
      _hovered = null;
      return;
    }
    if (call.method != 'over' && call.method != 'drop') return;
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final scale = View.of(context).devicePixelRatio;
    final point = Offset(
      (args['x'] as num).toDouble() / scale,
      (args['y'] as num).toDouble() / scale,
    );
    final target = _receiving ? null : _at(point);
    if (_hovered != target) {
      _hovered?._hover(false);
      _hovered = target;
      target?._hover(true);
    }
    if (call.method == 'drop') {
      _hovered?._hover(false);
      _hovered = null;
      if (target == null) return;
      final paths = (args['paths'] as List).cast<String>();
      _receiving = true;
      try {
        await target._receive(ImageDropPayload.files(paths));
      } finally {
        _receiving = false;
      }
    }
  }

  @override
  void dispose() {
    DesktopImageDropHost.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Mouse drags move images; touch keeps the child's existing gestures.
class DesktopImageDraggable extends Draggable<ImageDropPayload> {
  const DesktopImageDraggable({
    super.key,
    required ImageDropPayload super.data,
    required super.child,
    required super.feedback,
    super.onDragStarted,
    super.onDragEnd,
    super.maxSimultaneousDrags = 1,
  }) : super(dragAnchorStrategy: pointerDragAnchorStrategy);

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _ImageMouseDragRecognizer()..onStart = onStart;
}

class _ImageMouseDragRecognizer extends ImmediateMultiDragGestureRecognizer {
  _ImageMouseDragRecognizer()
    : super(
        supportedDevices: {PointerDeviceKind.mouse},
        allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
      );

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _ImageMouseDragState(event.position, event.kind, gestureSettings);
}

class _ImageMouseDragState extends MultiDragPointerState {
  _ImageMouseDragState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
  );

  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distanceSquared > 16) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) =>
      starter(initialPosition);
}
