import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/util/image_ops.dart';

Uint8List _png(int w, int h) => Uint8List.fromList(
  img.encodePng(img.Image(width: w, height: h, numChannels: 4)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'aligned base preserves bytes; non-aligned base is actually normalized',
    () async {
      final aligned = _png(512, 768);
      expect((await prepareImg2ImgBase(aligned)).image, same(aligned));
      final raw = _png(501, 777);
      final prepared = await prepareImg2ImgBase(raw);
      expect((prepared.w, prepared.h), (512, 768));
      expect(await decodeImageSize(prepared.image), (512, 768));
      expect(await decodeImageSize(raw), (501, 777));
      expect(img.decodePng(prepared.image)!.getPixel(0, 0).a, 0);
    },
  );

  test(
    'large imported base fits the request budget before mask coordinates exist',
    () async {
      final raw = _png(4096, 2048);
      final prepared = await prepareImg2ImgBase(raw);
      expect(prepared.w * prepared.h, lessThanOrEqualTo(1024 * 3072));
      expect(prepared.w % 64, 0);
      expect(prepared.h % 64, 0);
      expect(await decodeImageSize(prepared.image), (prepared.w, prepared.h));
      expect(await decodeImageSize(raw), (4096, 2048));
    },
  );
}
