import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/util/image_ops.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = Uint8List.fromList(
    img.encodePng(img.Image(width: 64, height: 64)),
  );
  late List<ui.Image> images;
  late List<ui.Picture> pictures;
  ui.ImageEventCallback? previousImageCallback;
  ui.PictureEventCallback? previousPictureCallback;

  setUp(() {
    images = [];
    pictures = [];
    previousImageCallback = ui.Image.onCreate;
    previousPictureCallback = ui.Picture.onCreate;
    ui.Image.onCreate = images.add;
    ui.Picture.onCreate = pictures.add;
  });

  tearDown(() {
    ui.Image.onCreate = previousImageCallback;
    ui.Picture.onCreate = previousPictureCallback;
    // Clean up even when a regression leaves a handle open.
    for (final image in images.where((image) => !image.debugDisposed)) {
      image.dispose();
    }
    for (final picture in pictures.where((picture) => !picture.debugDisposed)) {
      picture.dispose();
    }
  });

  void expectReleased() {
    expect(images, isNotEmpty);
    expect(
      images.where((image) => !image.debugDisposed),
      isEmpty,
      reason: 'Decoded and rendered native image handles must be released',
    );
    expect(
      pictures.where((picture) => !picture.debugDisposed),
      isEmpty,
      reason: 'Recorded pictures must be released even after an error',
    );
  }

  test('dimension probing creates no decoded pixel frame', () async {
    expect(await decodeImageSize(png), (64, 64));
    expect(images, isEmpty);
    expect(pictures, isEmpty);
    await expectLater(
      decodeImageSize(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
  });

  test('a failed patch decode releases the already decoded original', () async {
    await expectLater(
      pasteBack(
        original: png,
        patch: Uint8List.fromList([1, 2, 3]),
        send: (x: 0, y: 0, w: 64, h: 64),
        tight: (x: 0, y: 0, w: 32, h: 32),
      ),
      throwsA(anything),
    );
    expectReleased();
  });

  test('failed image rendering releases the source and picture', () async {
    await expectLater(coverResizePng(png, 0, 64), throwsA(anything));
    expectReleased();
  });

  test(
    'repeated resize, crop and paste operations release every handle',
    () async {
      for (var i = 0; i < 3; i++) {
        expect(await decodeImageSize(png), (64, 64));
        await coverResizePng(png, 32, 32);
        await cropPng(png, (x: 0, y: 0, w: 32, h: 32));
        await pasteBack(
          original: png,
          patch: png,
          send: (x: 0, y: 0, w: 64, h: 64),
          tight: (x: 0, y: 0, w: 32, h: 32),
        );
        expectReleased();
      }
    },
  );
}
