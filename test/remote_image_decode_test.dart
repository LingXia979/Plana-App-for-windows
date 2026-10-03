import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/net/remote_image.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_decode_bounds_');
    RemoteImageStore.bind(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  for (final size in [const Size(800, 1200), const Size(1600, 600)]) {
    testWidgets('contained thumbnail decodes within both bounds: $size', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final url = 'https://images.invalid/${size.width}x${size.height}.png';
      await tester.runAsync(() async {
        await RemoteImageStore.write(
          url,
          Uint8List.fromList(
            img.encodePng(
              img.Image(width: size.width.toInt(), height: size.height.toInt()),
            ),
          ),
        );
        RemoteImageStore.markChecked(url);
      });

      Future<Size> decoded({required bool capHeight}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 300,
                height: 200,
                child: RemoteImage(
                  url,
                  key: ValueKey(capHeight),
                  decodeHeight: capHeight ? 200 : null,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          final pixels = tester.widget<RawImage>(find.byType(RawImage)).image;
          if (pixels != null) {
            return Size(pixels.width.toDouble(), pixels.height.toDouble());
          }
        }
        throw StateError('Cached thumbnail did not decode');
      }

      final widthOnly = await decoded(capHeight: false);
      final bounded = await decoded(capHeight: true);
      expect(bounded.width, lessThanOrEqualTo(600));
      expect(bounded.height, lessThanOrEqualTo(400));
      expect(bounded.aspectRatio, closeTo(size.aspectRatio, .003));
      if (size.height > size.width) {
        expect(widthOnly, const Size(600, 900));
        expect(bounded.height, 400);
        expect(bounded.width, closeTo(800 * 400 / 1200, 1));
        expect(
          bounded.width * bounded.height,
          lessThan(widthOnly.width * widthOnly.height * .2),
        );
      } else {
        expect(bounded, widthOnly);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(RemoteImageStore.clear);
    });
  }
}
