import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/ui/image_drop.dart';
import '../gallery/gallery_state.dart';
import '../gallery/models.dart';
import '../gallery/widgets/result_canvas.dart';
import '../gallery/widgets/result_thumb.dart';
import '../generate/widgets/common.dart';
import 'import_panel.dart';

ImageDropPayload galleryDragPayload(
  WidgetRef ref,
  ResultImage result, {
  bool canvas = false,
}) {
  final store = ref.read(appStoresProvider).gallery;
  return ImageDropPayload.image(
    imageId: result.id,
    source: canvas ? 'canvas' : 'history',
    name: 'plana_${result.seed}.png',
    load: () async => result.bytes ?? await store.readImage(result.id),
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
  Widget build(BuildContext context, WidgetRef ref) => DesktopImageDraggable(
    data: galleryDragPayload(ref, result, canvas: canvas),
    maxSimultaneousDrags: enabled ? 1 : 0,
    onDragStarted: onStart,
    onDragEnd: (_) => onEnd?.call(),
    feedback: Material(
      color: Colors.transparent,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: ResultThumb(result: result, width: 96, height: 112, radius: 10),
    ),
    child: child,
  );
}

/// A normal drop opens the existing review panel; it never silently replaces
/// prompt/settings. Specific image-purpose regions handle their own drops.
class DesktopImportRegion extends ConsumerWidget {
  const DesktopImportRegion({
    super.key,
    required this.child,
    this.acceptInternal = true,
    this.canvas = false,
  });
  final Widget child;
  final bool acceptInternal;
  final bool canvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ImageDropRegion(
    label: '导入图片',
    acceptInternal: acceptInternal,
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
