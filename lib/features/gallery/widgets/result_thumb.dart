import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../generate/widgets/common.dart' show StripeThumb;
import '../gallery_state.dart' show galleryThumbProvider;
import '../models.dart';
import '../../../core/util/image_ops.dart' show kThumbShortSide;

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
    final bytes =
        result.bytes ?? ref.watch(galleryThumbProvider(result.id)).value;
    if (bytes != null) {
      // Fresh results still hold the original bytes. Bound their decoded size
      // to the same budget as disk thumbnails, without upscaling small images.
      int? decodeWidth;
      if (result.bytes != null && result.width > 0 && result.height > 0) {
        final scale = math.min(
          1.0,
          math.min(
            kThumbShortSide / math.min(result.width, result.height),
            kThumbShortSide * 3 / math.max(result.width, result.height),
          ),
        );
        decodeWidth = math.max(1, (result.width * scale).round());
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.memory(
          bytes,
          width: width,
          height: height,
          fit: fit,
          cacheWidth: decodeWidth,
          gaplessPlayback: true,
        ),
      );
    }
    return StripeThumb(width: width, height: height, radius: radius);
  }
}
