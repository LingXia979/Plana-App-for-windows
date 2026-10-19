import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The caller owns the returned frame. The decoder is closed on every path.
Future<ui.Image> decodeFirstImage(
  Uint8List bytes, {
  int? targetWidth,
  int? targetHeight,
  bool allowUpscaling = true,
}) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    allowUpscaling: allowUpscaling,
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<T> withDecodedImage<T>(
  Uint8List bytes,
  FutureOr<T> Function(ui.Image image) action, {
  int? targetWidth,
  int? targetHeight,
  bool allowUpscaling = true,
}) async {
  final image = await decodeFirstImage(
    bytes,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    allowUpscaling: allowUpscaling,
  );
  try {
    return await action(image);
  } finally {
    image.dispose();
  }
}

/// Takes ownership of the picture and releases both rendering resources.
Future<Uint8List> pictureToPng(
  ui.Picture picture,
  int width,
  int height,
) async {
  ui.Image? output;
  try {
    output = await picture.toImage(width, height);
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG 编码失败');
    return data.buffer.asUint8List();
  } finally {
    output?.dispose();
    picture.dispose();
  }
}
