import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Decode enough pixels to cover both edges of a thumbnail, preserving aspect
/// ratio. The target is in physical pixels; callers can oversample for detail.
class CoverThumbnailProvider extends ImageProvider<CoverThumbnailProvider> {
  const CoverThumbnailProvider(
    this.bytes, {
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width, height;

  @override
  Future<CoverThumbnailProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CoverThumbnailProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _decode(decode),
    scale: 1,
    debugLabel: 'Cover thumbnail',
  );

  Future<ui.Codec> _decode(ImageDecoderCallback decode) async => decode(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    getTargetSize: (w, h) {
      // Avoid full-resolution decodes and extreme panorama allocations. Small
      // source images stay at their original size rather than being enlarged.
      final scale = math.min(
        math.min(1.0, math.max(width / w, height / h)),
        math.min(4096 / math.max(w, h), math.sqrt(1048576 / (w * h))),
      );
      return ui.TargetImageSize(
        width: math.max(1, (w * scale).floor()),
        height: math.max(1, (h * scale).floor()),
      );
    },
  );

  @override
  bool operator ==(Object other) =>
      other is CoverThumbnailProvider &&
      identical(bytes, other.bytes) &&
      width == other.width &&
      height == other.height;

  @override
  int get hashCode => Object.hash(bytes, width, height);
}
