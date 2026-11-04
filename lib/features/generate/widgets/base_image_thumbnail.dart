import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/image_ops.dart';
import '../models.dart' show pngSizeOf;
import 'common.dart';

/// The card follows the image's aspect ratio within the sidebar's thumbnail
/// budget. Image metadata is read once per source, not on every slider update.
class BaseImageThumbnail extends StatefulWidget {
  const BaseImageThumbnail({
    super.key,
    required this.image,
    required this.onTap,
    this.mask,
  });
  final Uint8List image;
  final Uint8List? mask;
  final VoidCallback onTap;

  @override
  State<BaseImageThumbnail> createState() => _BaseImageThumbnailState();
}

class _BaseImageThumbnailState extends State<BaseImageThumbnail> {
  late Future<(int, int)> _size = _readSize();

  Future<(int, int)> _readSize() {
    final size = pngSizeOf(widget.image);
    return size == null
        ? decodeImageSize(widget.image)
        : SynchronousFuture(size);
  }

  @override
  void didUpdateWidget(BaseImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.image, widget.image)) _size = _readSize();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(int, int)>(
    future: _size,
    builder: (context, snapshot) {
      final dimensions = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : pngSizeOf(widget.image);
      final source = dimensions == null
          ? const Size(1, 1)
          : Size(dimensions.$1.toDouble(), dimensions.$2.toDouble());
      final size = applyBoxFit(
        BoxFit.contain,
        source,
        const Size(90, 118),
      ).destination;
      return SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            StripeThumb(
              width: size.width,
              height: size.height,
              radius: 12,
              image: widget.image,
            ),
            if (widget.mask != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Opacity(
                  opacity: .55,
                  child: Image.memory(
                    widget.mask!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: Container(
                    margin: const EdgeInsets.all(6),
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: context.scheme.primary,
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 3),
                      ],
                    ),
                    child: Icon(
                      Icons.brush,
                      size: 15,
                      color: context.scheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
