import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../util/image_ops.dart';
import '../util/image_pick.dart';

/// One drag has one payload and one recipient. Bytes are read only on drop.
class ImageDropPayload {
  ImageDropPayload.files(List<String> paths, {this.source})
    : paths = List.unmodifiable(paths),
      imageId = null,
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

  factory ImageDropPayload.clipboard(Map<Object?, Object?> arguments) {
    final paths = (arguments['paths'] as List?)?.cast<String>() ?? const [];
    final error = arguments['error'] as String? ?? '';
    if (error.isEmpty && paths.isNotEmpty) {
      return ImageDropPayload.files(paths, source: 'clipboard');
    }
    return ImageDropPayload.image(
      name: 'clipboard.png',
      source: 'clipboard',
      load: () async {
        if (error.isNotEmpty) {
          throw FormatException(switch (error) {
            'clipboard_busy' => '剪贴板暂时被占用，请重试粘贴',
            'too_many_images' => '一次最多粘贴 64 张图片',
            _ => '无法读取剪贴板图片，请重新复制；单张最多 64 MB',
          });
        }
        final bytes = arguments['bytes'] as Uint8List?;
        if (bytes == null || bytes.isEmpty) {
          throw const FormatException('剪贴板中没有可读取的图片');
        }
        // A DIB gains a small BMP header in the native reader.
        if (bytes.length > 64 * 1024 * 1024 + 14) {
          throw const FormatException('剪贴板图片过大：单张最多 64 MB');
        }
        if (arguments['bitmap'] != true) return bytes;
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          try {
            final png = await frame.image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            return png?.buffer.asUint8List();
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      },
    );
  }

  final List<String> paths;
  final String? imageId;
  final String? source;
  final Future<List<PickedImage>> Function()? _load;
  int get count => _load == null ? paths.length : 1;

  Future<List<PickedImage>> read() async {
    if (count == 0 || count > 64) {
      throw const FormatException('一次最多导入 64 张图片');
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
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += file.bytes.length;
      if (file.bytes.length > 64 * 1024 * 1024 ||
          totalBytes > 256 * 1024 * 1024) {
        throw const FormatException('图片过大：单张最多 64 MB，一次最多 256 MB');
      }
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
    this.pasteDefault = false,
    this.pasteFallback = false,
  });

  final String label;
  final ImageDropCallback onDrop;
  final Widget child;
  final bool multiple;
  final bool enabled;
  final bool acceptInternal;
  final bool Function(ImageDropPayload)? accept;

  /// The active full page receives a paste even over its navigation header.
  final bool pasteDefault;

  /// A generic page-wide receiver yields to a more specific active page.
  final bool pasteFallback;

  @override
  State<ImageDropRegion> createState() => _ImageDropRegionState();
}

class _ImageDropRegionState extends State<ImageDropRegion> {
  _DesktopImageDropHostState? _host;
  bool _externalHover = false;
  bool _busy = false;
  bool get _enabled => widget.enabled && !_busy;
  bool _accepts(ImageDropPayload payload) =>
      _enabled &&
      (widget.acceptInternal ||
          payload.paths.isNotEmpty ||
          payload.source == 'clipboard') &&
      (widget.accept?.call(payload) ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = context.findAncestorStateOfType<_DesktopImageDropHostState>();
    if (_host != host) {
      _host?._regions.remove(this);
      _host = host;
      _host?._regions.add(this);
    }
  }

  @override
  void dispose() {
    _host?._regions.remove(this);
    super.dispose();
  }

  void _hover(bool value) {
    if (mounted && value != _externalHover) {
      setState(() => _externalHover = value);
    }
  }

  Future<void> _receive(
    ImageDropPayload payload, {
    bool Function()? stillVisible,
  }) async {
    if (!_accepts(payload)) return;
    setState(() => _busy = true);
    try {
      if (!widget.multiple && payload.count > 1) {
        throw const FormatException('此处一次接收一张图片，请选择单张图片');
      }
      final images = await payload.read();
      if (mounted && widget.enabled && (stillVisible?.call() ?? true)) {
        await widget.onDrop(images, payload);
      }
    } catch (error) {
      if (mounted && (stillVisible?.call() ?? true)) {
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

/// Extends a pane's paste target to its header without changing drag targets.
class ImagePasteProxy extends StatelessWidget {
  const ImagePasteProxy({
    super.key,
    required this.target,
    required this.child,
    this.enabled = true,
  });
  final GlobalKey target;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    behavior: HitTestBehavior.translucent,
    child: child,
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
  final _regions = <_ImageDropRegionState>{};

  @override
  void initState() {
    super.initState();
    DesktopImageDropHost.channel.setMethodCallHandler(_nativeEvent);
  }

  HitTestResult _hit(Offset position) {
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      hit,
      position,
      View.of(context).viewId,
    );
    return hit;
  }

  _ImageDropRegionState? _at(Offset position) {
    for (final entry in _hit(position).path) {
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

  bool _visible(_ImageDropRegionState region, {Offset? at}) {
    if (!region.mounted || ModalRoute.of(region.context)?.isCurrent == false) {
      return false;
    }
    final box = region.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return false;
    }
    final point = at ?? box.localToGlobal(box.size.center(Offset.zero));
    return _hit(point).path.any(
      (entry) =>
          entry.target is RenderMetaData &&
          (entry.target as RenderMetaData).metaData == region,
    );
  }

  _ImageDropRegionState? _pasteAt(Offset position) {
    _ImageDropRegionState? fallback;
    for (final entry in _hit(position).path) {
      final render = entry.target;
      if (render is! RenderMetaData) continue;
      final data = render.metaData;
      if (data is _ImageDropRegionState) {
        if (!data.widget.pasteFallback) return data;
        fallback = data;
        break;
      }
      if (data is ImagePasteProxy && data.enabled) {
        return data.target.currentState as _ImageDropRegionState?;
      }
    }
    final activePage = _regions
        .where((region) => region.widget.pasteDefault && _visible(region))
        .lastOrNull;
    if (activePage != null) return activePage;
    if (fallback != null) return fallback;
    // Pointer outside the window: use the focused, still-visible input area.
    _ImageDropRegionState? focused;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
      element,
    ) {
      if (element is StatefulElement &&
          element.state is _ImageDropRegionState) {
        final region = element.state as _ImageDropRegionState;
        if (_visible(region)) {
          focused = region;
          return false;
        }
      }
      return true;
    });
    return focused ??
        _regions
            .where((region) => region.widget.pasteFallback && _visible(region))
            .lastOrNull;
  }

  Future<void> _nativeEvent(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'leave') {
      _hovered?._hover(false);
      _hovered = null;
      return;
    }
    if (call.method != 'over' &&
        call.method != 'drop' &&
        call.method != 'paste') {
      return;
    }
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final scale = View.of(context).devicePixelRatio;
    final point = Offset(
      (args['x'] as num).toDouble() / scale,
      (args['y'] as num).toDouble() / scale,
    );
    if (call.method == 'paste') {
      final target = _pasteAt(point);
      if (target == null || !target._enabled) return;
      // Region-local busy state prevents duplicates without locking a newly
      // opened import dialog for the lifetime of its parent callback.
      await target._receive(
        ImageDropPayload.clipboard(args),
        stillVisible: () => _visible(target, at: point) || _visible(target),
      );
      return;
    }
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
