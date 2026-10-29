import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/util/image_ops.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/result_thumb.dart';

Uint8List _png(int w, int h, {bool transparent = false}) {
  final pixels = img.Image(width: w, height: h, numChannels: 4);
  pixels.clear(img.ColorRgba8(255, 0, 0, 255));
  if (transparent) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x <= w ~/ 2; x++) {
        pixels.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }
  return Uint8List.fromList(img.encodePng(pixels));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  var widgetFlushed = false;
  setUp(() async {
    widgetFlushed = false;
    root = await Directory.systemTemp.createTemp('plana_thumb_v3_');
    stores = await AppStores.open(rootOverride: root);
  });
  tearDown(() async {
    if (!widgetFlushed) await stores.flushForExit();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      root.uri.pathSegments.where((p) => p.isNotEmpty).last,
      startsWith('plana_thumb_v3_'),
    );
    await root.delete(recursive: true);
  });

  File cache(String id, String extension) =>
      File('${root.path}/gallery/thumbs/$id.$extension');

  Future<ResultImage> persist(
    String id,
    int w,
    int h, {
    bool transparent = false,
  }) async {
    final r = ResultImage(
      id: id,
      width: w,
      height: h,
      seed: 1,
      bytes: _png(w, h, transparent: transparent),
    );
    await stores.gallery.persistResult(r);
    return r;
  }

  test(
    'very wide and tall thumbnails cap the long edge without cropping',
    () async {
      for (final (w, h, tw, th) in [
        (3200, 400, 1536, 192),
        (400, 3200, 192, 1536),
        (480, 1200, 480, 1200),
      ]) {
        final thumbnail = await makeThumb(_png(w, h));
        expect(thumbnail.jpeg, isTrue);
        expect(await decodeImageSize(thumbnail.bytes), (tw, th));
      }
    },
  );

  test(
    'v2 square cache and unsigned JPEG are rebuilt from the untouched original',
    () async {
      final original = await persist('gen1', 768, 1152);
      final file = stores.gallery.imageFileForPreview(original.id);
      final source = await file.stat();
      final old = _png(256, 256, transparent: true);
      await cache(original.id, 'png').writeAsBytes(old);
      await cache(original.id, 'png.bak').writeAsBytes(old);
      await cache(original.id, 'png.tmp').writeAsBytes(old);
      await cache(original.id, 'png.pending').writeAsString('{}');
      await cache(original.id, 'jpg').writeAsBytes(old);
      await cache(original.id, 'json').writeAsString(
        jsonEncode({
          'v': 2,
          'id': original.id,
          'size': source.size,
          'modified': source.modified.microsecondsSinceEpoch,
          'thumbSha256': sha256.convert(old).toString(),
        }),
      );
      final rebuilt = (await stores.gallery.readThumb(original.id))!;
      expect(rebuilt.take(2), [0xff, 0xd8]);
      expect(await decodeImageSize(rebuilt), (512, 768));
      expect(await file.readAsBytes(), original.bytes);
      expect((await file.stat()).modified, source.modified);
      final signature = jsonDecode(
        await cache(original.id, 'json').readAsString(),
      );
      expect(signature['v'], 3);
      expect(signature['format'], 'jpg');
      expect(signature['thumbSha256'], sha256.convert(rebuilt).toString());
      for (final suffix in ['png', 'png.tmp', 'png.bak', 'png.pending']) {
        expect(await cache(original.id, suffix).exists(), isFalse);
      }
    },
  );

  test(
    'changing source transparency switches format and revokes obsolete recovery',
    () async {
      final original = await persist('gen2', 160, 240);
      final file = stores.gallery.imageFileForPreview(original.id);
      final jpeg = await cache(original.id, 'jpg').readAsBytes();
      for (final suffix in ['jpg.bak', 'jpg.tmp']) {
        await cache(original.id, suffix).writeAsBytes(jpeg);
      }
      await cache(original.id, 'jpg.pending').writeAsString('{}');
      final alpha = _png(160, 240, transparent: true);
      await file.writeAsBytes(alpha);
      await file.setLastModified(DateTime(2030));
      final thumbnail = (await stores.gallery.readThumb(original.id))!;
      final decoded = img.decodePng(thumbnail)!;
      expect(decoded.getPixel(0, 0).a, 0);
      expect(decoded.getPixel(159, 239).a, 255);
      expect((decoded.width, decoded.height), (160, 240));
      for (final suffix in ['jpg', 'jpg.bak', 'jpg.tmp', 'jpg.pending']) {
        expect(await cache(original.id, suffix).exists(), isFalse);
      }
      expect(await file.readAsBytes(), alpha);
      expect(
        jsonDecode(await cache(original.id, 'json').readAsString())['format'],
        'png',
      );
    },
  );

  test(
    'concurrent cache reads share regeneration and survive a decode failure',
    () async {
      final original = await persist('gen3', 640, 960);
      await cache(original.id, 'json').delete();
      final a = stores.gallery.readThumb(original.id);
      final b = stores.gallery.readThumb(original.id);
      expect(identical(a, b), isTrue);
      expect(await a, await b);
      final modified = (await cache(original.id, 'jpg').stat()).modified;
      expect(await stores.gallery.readThumb(original.id), await a);
      expect((await cache(original.id, 'jpg').stat()).modified, modified);

      final bad = stores.gallery.imageFileForPreview('gen_bad');
      await bad.writeAsBytes([1, 2, 3]);
      expect(await stores.gallery.readThumb('gen_bad'), [1, 2, 3]);
      await bad.writeAsBytes(original.bytes!);
      expect(
        await decodeImageSize((await stores.gallery.readThumb('gen_bad'))!),
        (512, 768),
      );
    },
  );

  for (final clearAll in [false, true]) {
    test(
      'queued cache rebuilds cannot recreate files after ${clearAll ? 'clear' : 'delete'}',
      () async {
        final images = [
          for (var i = 0; i < 8; i++) await persist('gen$i', 640, 960),
        ];
        for (final image in images) {
          await cache(image.id, 'json').delete();
        }
        final reads = [
          for (final image in images) stores.gallery.readThumb(image.id),
        ];
        if (clearAll) {
          await stores.gallery.clearAllFiles(seq: 8);
        } else {
          expect(
            await stores.gallery.deleteResultFilesVerified(
              images.map((r) => r.id).toList(),
            ),
            images.map((r) => r.id).toSet(),
          );
        }
        await Future.wait(reads);
        await stores.gallery.idle;
        for (final image in images) {
          expect(await stores.gallery.readImage(image.id), isNull);
          expect(await stores.gallery.readThumb(image.id), isNull);
          for (final extension in ['jpg', 'png', 'json']) {
            for (final suffix in ['', '.tmp', '.bak', '.pending']) {
              expect(
                await cache(image.id, '$extension$suffix').exists(),
                isFalse,
              );
            }
          }
        }
      },
    );
  }

  testWidgets(
    'desktop contain previews use verified 512-short-edge thumbnails',
    (tester) async {
      final original = (await tester.runAsync(
        () => persist('gen9', 768, 1152),
      ))!;
      final container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ResultThumb(
                result: original.stripped(),
                width: 400,
                height: 600,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      );
      final image = find.byType(RawImage);
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (image.evaluate().isNotEmpty &&
            tester.widget<RawImage>(image).image != null) {
          break;
        }
      }
      final decoded = tester.widget<RawImage>(image).image!;
      expect((decoded.width, decoded.height), (512, 768));
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
      expect(
        await tester.runAsync(() => stores.gallery.readImage(original.id)),
        original.bytes,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      container.dispose();
      disposed = true;
      unawaited(stores.flushForExit().then((_) => widgetFlushed = true));
      for (var i = 0; i < 300 && !widgetFlushed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(widgetFlushed, isTrue);
    },
  );
}
