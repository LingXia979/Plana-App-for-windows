import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/ui/image_drop.dart';
import '../../core/ui/external_image_drag.dart';
import '../../core/theme/app_theme.dart';
import '../gallery/gallery_state.dart';
import '../gallery/models.dart';
import '../gallery/result_clipboard.dart';
import '../gallery/widgets/result_canvas.dart';
import '../gallery/widgets/result_thumb.dart';
import '../generate/widgets/common.dart';
import 'import_panel.dart';

ImageDropPayload galleryDragPayload(
  WidgetRef ref,
  ResultImage result, {
  bool canvas = false,
}) {
  final store = result.bytes == null
      ? ref.read(appStoresProvider).gallery
      : null;
  return ImageDropPayload.image(
    imageId: result.id,
    source: canvas ? 'canvas' : 'history',
    name: 'plana_${result.seed}.png',
    load: () async => result.bytes ?? await store?.readImage(result.id),
  );
}

class GalleryImageDrag extends ConsumerWidget {
  const GalleryImageDrag({
    super.key,
    required this.result,
    required this.child,
    this.enabled = true,
    this.onStart,
    this.onEnd,
    this.canvas = false,
  });
  final ResultImage result;
  final Widget child;
  final bool enabled;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;
  final bool canvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ExternalImageDrag(
    data: galleryDragPayload(ref, result, canvas: canvas),
    prepare: () => prepareResultTransfer(ref, result),
    enabled: enabled,
    onStart: onStart,
    onEnd: onEnd,
    feedback: Material(
      color: Colors.transparent,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: ResultThumb(result: result, width: 96, height: 112, radius: 10),
    ),
    child: child,
  );
}

/// Grid tiles already use mouse dragging for range selection. A separate
/// hover handle exports the picture without changing that established gesture.
class GalleryImageTransferOverlay extends StatefulWidget {
  const GalleryImageTransferOverlay({
    super.key,
    required this.result,
    required this.child,
    this.enabled = true,
  });
  final ResultImage result;
  final Widget child;
  final bool enabled;

  @override
  State<GalleryImageTransferOverlay> createState() =>
      _GalleryImageTransferOverlayState();
}

class _GalleryImageTransferOverlayState
    extends State<GalleryImageTransferOverlay> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        children: [
          widget.child,
          Positioned(
            left: 9,
            bottom: 9,
            child: IgnorePointer(
              ignoring: !_hover && !_dragging,
              child: Opacity(
                opacity: _hover || _dragging ? 1 : 0,
                child: Consumer(
                  builder: (context, ref, _) => GalleryImageDrag(
                    result: widget.result,
                    onStart: () => setState(() => _dragging = true),
                    onEnd: () {
                      if (mounted) setState(() => _dragging = false);
                    },
                    child: Material(
                      color: context.scheme.surfaceContainerHigh,
                      shape: const CircleBorder(),
                      child: IconButton(
                        key: ValueKey(
                          'gallery-image-transfer-${widget.result.id}',
                        ),
                        tooltip: '点击复制图片；按住拖到其他应用',
                        icon: const Icon(Icons.copy_outlined, size: 17),
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        onPressed: () =>
                            copyResultToClipboard(context, ref, widget.result),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A normal drop opens the existing review panel; it never silently replaces
/// prompt/settings. Specific image-purpose regions handle their own drops.
class DesktopImportRegion extends ConsumerWidget {
  const DesktopImportRegion({
    super.key,
    required this.child,
    this.acceptInternal = true,
    this.canvas = false,
    this.pasteFallback = false,
  });
  final Widget child;
  final bool acceptInternal;
  final bool canvas;
  final bool pasteFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ImageDropRegion(
    label: '导入图片',
    acceptInternal: acceptInternal,
    pasteFallback: pasteFallback,
    accept: (payload) => !canvas || payload.source != 'canvas',
    onDrop: (images, payload) async {
      final result = ref
          .read(galleryProvider)
          .results
          .where((r) => r.id == payload.imageId)
          .firstOrNull;
      if (result != null) {
        await openResultImport(context, ref, result);
      } else {
        final image = images.single;
        await Navigator.of(context).push(
          sharedAxisRoute(
            ImportImagePanel(
              bytes: image.bytes,
              fileName: image.name,
              displayName: image.baseName,
            ),
          ),
        );
      }
    },
    child: child,
  );
}
