import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/store/blob_store.dart';
import 'package:plana_app/features/gallery/gallery_store.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/inpaint/inpaint_comparison.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

Uint8List solid(int w, int h, int r, int g, int b) => Uint8List.fromList(
  img.encodePng(
    img.fill(
      img.Image(width: w, height: h),
      color: img.ColorRgb8(r, g, b),
    ),
  ),
);

List<int> pixel(img.Image image, int x, int y) {
  final p = image.getPixel(x, y);
  return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'comparison changes only raw mask cells and marks them translucent white',
    () async {
      final grid = MaskGrid(32, 32)..paintDot(12, 12, 8);
      final job = InpaintJob(
        image: solid(32, 32, 255, 0, 0),
        // Expanded API masks must not enlarge the saved raw comparison region.
        mask: solid(32, 32, 255, 255, 255),
        strength: .7,
        grid: grid.encode(),
      );
      final result = solid(32, 32, 0, 0, 255);
      final before = Uint8List.fromList(result);
      final preview = img.decodePng(
        await buildInpaintComparison(result: result, job: job),
      )!;
      expect(pixel(preview, 12, 12), [255, 89, 89]);
      expect(pixel(preview, 20, 12), [0, 0, 255]);
      expect(
        result,
        before,
        reason: 'comparison must never change the saved result',
      );
    },
  );

  test(
    'black/white API mask is aligned to crop coordinates and tight bounds',
    () async {
      final mask = img.Image(width: 32, height: 32);
      img.fillRect(
        mask,
        x1: 8,
        y1: 8,
        x2: 31,
        y2: 31,
        color: img.ColorRgb8(255, 255, 255),
      );
      final job = InpaintJob(
        image: solid(32, 32, 255, 0, 0),
        mask: Uint8List.fromList(img.encodePng(mask)),
        strength: .7,
        paste: InpaintPaste(
          original: solid(80, 64, 255, 0, 0),
          sendX: 32,
          sendY: 16,
          tightX: 40,
          tightY: 24,
          tightW: 8,
          tightH: 8,
          outW: 80,
          outH: 64,
        ),
      );
      final preview = img.decodePng(
        await buildInpaintComparison(
          result: solid(80, 64, 0, 0, 255),
          job: job,
        ),
      )!;
      expect(pixel(preview, 42, 26), [255, 89, 89]);
      expect(pixel(preview, 34, 18), [0, 0, 255]);
      expect(pixel(preview, 52, 36), [0, 0, 255]);
      expect(pixel(preview, 8, 8), [0, 0, 255]);

      final crop = img.decodePng(
        await buildInpaintComparison(
          result: solid(32, 32, 0, 0, 255),
          job: job,
        ),
      )!;
      expect(pixel(crop, 12, 12), [255, 89, 89]);
      expect(pixel(crop, 4, 4), [0, 0, 255]);
    },
  );

  test(
    'expanded canvas compares new area using padded source, without shifting original',
    () async {
      final source = img.fill(
        img.Image(width: 48, height: 32),
        color: img.ColorRgb8(255, 255, 255),
      );
      img.fillRect(
        source,
        x1: 16,
        y1: 0,
        x2: 47,
        y2: 31,
        color: img.ColorRgb8(255, 0, 0),
      );
      final mask = img.Image(width: 48, height: 32);
      img.fillRect(
        mask,
        x1: 0,
        y1: 0,
        x2: 15,
        y2: 31,
        color: img.ColorRgb8(255, 255, 255),
      );
      final preview = img.decodePng(
        await buildInpaintComparison(
          result: solid(48, 32, 0, 0, 255),
          job: InpaintJob(
            image: Uint8List.fromList(img.encodePng(source)),
            mask: Uint8List.fromList(img.encodePng(mask)),
            strength: .7,
            grid: MaskGrid(
              32,
              32,
            ).encode(), // old unexpanded grid must be ignored
          ),
        ),
      )!;
      expect(pixel(preview, 4, 12), [255, 255, 255]);
      expect(pixel(preview, 20, 12), [0, 0, 255]);
    },
  );

  test(
    'each result retains its own comparison after restart, even without source image',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'plana_inpaint_comparison_',
      );
      addTearDown(() => root.delete(recursive: true));
      final blobs = BlobStore(root);
      await blobs.ensureReady();
      final store = GalleryStore(blobs, root);
      await store.load();
      final images = <ResultImage>[];
      for (var i = 0; i < 2; i++) {
        final grid = MaskGrid(32, 32)..paintDot(4 + i * 16, 12, 8);
        final image = ResultImage(
          id: 'gen$i',
          width: 32,
          height: 32,
          seed: i,
          badge: ResultBadge.inpaint,
          inpaintFrom: 'deleted-source',
          bytes: solid(32, 32, 0, 0, 255),
          input: GenerateState.initial().copyWith(
            inpaint: InpaintJob(
              image: solid(32, 32, 255, 0, 0),
              mask: await maskToPng(grid),
              strength: .7,
              grid: grid.encode(),
            ),
          ),
        );
        images.add(image);
        await store.persistResult(image);
      }
      store.scheduleIndex(results: images, selectedId: 'gen1', seq: 2);
      await store.flushIndex();
      final reopened = GalleryStore(blobs, root);
      await reopened.load();
      expect(
        reopened.initialResults.map((r) => r.inpaintFrom),
        everyElement('deleted-source'),
      );
      for (var i = 0; i < 2; i++) {
        final result = reopened.initialResults[i];
        expect(result.hasInpaintComparison, isTrue);
        final input = await reopened.readInput(result.id);
        final bytes = await reopened.readImage(result.id);
        final preview = img.decodePng(
          await buildInpaintComparison(result: bytes!, job: input!.inpaint!),
        )!;
        expect(pixel(preview, 4 + i * 16, 12), [255, 89, 89]);
        expect(pixel(preview, 20 - i * 16, 12), [0, 0, 255]);
      }
      // Older indexes omitted inpaintFrom, while keeping badge and parameters.
      final file = File('${root.path}/gallery/index.json');
      final index =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final item in index['items'] as List) {
        (item as Map).remove('inpaintFrom');
      }
      await file.writeAsString(jsonEncode(index));
      final legacy = GalleryStore(blobs, root);
      await legacy.load();
      expect(
        legacy.initialResults.every((r) => r.hasInpaintComparison),
        isTrue,
      );
    },
  );
}
