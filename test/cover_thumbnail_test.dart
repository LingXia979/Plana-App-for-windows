import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/ui/cover_thumbnail.dart';

Future<ImageInfo> _decode(CoverThumbnailProvider provider) async {
  final completer = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (image, _) => completer.complete(image),
    onError: completer.completeError,
  );
  stream.addListener(listener);
  try {
    return await completer.future;
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uint8List png(int w, int h) =>
      Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)));
  tearDown(() => PaintingBinding.instance.imageCache.clear());

  test(
    'landscape source covers a portrait preview without undersampling its height',
    () async {
      final bytes = png(1024, 256);
      final portrait = await _decode(
        CoverThumbnailProvider(bytes, width: 180, height: 236),
      );
      final square = await _decode(
        CoverThumbnailProvider(bytes, width: 144, height: 144),
      );
      try {
        expect((portrait.image.width, portrait.image.height), (944, 236));
        expect((square.image.width, square.image.height), (576, 144));
      } finally {
        portrait.dispose();
        square.dispose();
      }
    },
  );

  test(
    'small sources are not enlarged and large preview decodes stay bounded',
    () async {
      final small = await _decode(
        CoverThumbnailProvider(png(32, 16), width: 180, height: 236),
      );
      final large = await _decode(
        CoverThumbnailProvider(png(4096, 2048), width: 8000, height: 8000),
      );
      try {
        expect((small.image.width, small.image.height), (32, 16));
        expect(
          large.image.width * large.image.height,
          lessThanOrEqualTo(1048576),
        );
        expect(large.image.width / large.image.height, closeTo(2, .01));
      } finally {
        small.dispose();
        large.dispose();
      }
    },
  );
}
