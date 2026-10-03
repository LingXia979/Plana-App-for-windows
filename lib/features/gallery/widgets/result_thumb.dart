import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../generate/widgets/common.dart' show StripeThumb;
import '../gallery_state.dart' show galleryThumbProvider;
import '../models.dart';
import '../../../core/store/app_stores.dart';
import '../../../core/util/preview_cache.dart';

/// 缩略图:内存有字节直接用;没有(重启水合/RAM 减负)按 id 懒读盘上
/// 缩略图,读到前垫斜纹占位。胶片条与网格共用,尺寸由外部给定。
class ResultThumb extends ConsumerWidget {
  const ResultThumb({
    super.key,
    required this.result,
    required this.width,
    required this.height,
    this.radius = 10,
    this.fit = BoxFit.cover,
  });

  final ResultImage result;
  final double width;
  final double height;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (fit == BoxFit.contain && result.bytes == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: width,
          height: height,
          child: FittedFilePreview(
            ref.watch(appStoresProvider).gallery.imageFileForPreview(result.id),
          ),
        ),
      );
    }
    final bytes =
        result.bytes ?? ref.watch(galleryThumbProvider(result.id)).value;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.memory(
          bytes,
          width: width,
          height: height,
          fit: fit,
          cacheWidth: fit == BoxFit.contain ? 420 : null,
          gaplessPlayback: true,
        ),
      );
    }
    return StripeThumb(width: width, height: height, radius: radius);
  }
}
