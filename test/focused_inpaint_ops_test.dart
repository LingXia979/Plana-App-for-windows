import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/generate/char_position.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/import/image_metadata.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

Uint8List _png(int width, int height, {bool pattern = false, int alpha = 255}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        pattern ? x % 255 : 0,
        pattern ? y % 255 : 255,
        pattern ? 80 : 0,
        pattern && x < 16 ? 0 : alpha,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

List<int> _rgba(img.Pixel p) => [
  p.r.toInt(),
  p.g.toInt(),
  p.b.toInt(),
  p.a.toInt(),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const outer = (x: 8, y: 16, w: 128, h: 192);
  late Uint8List source;
  late MaskGrid raw;
  late ({InpaintJob job, int width, int height}) prepared;
  late Uint8List generated;

  setUpAll(() async {
    source = _png(256, 256, pattern: true);
    raw = MaskGrid(256, 256)
      ..paintDot(68, 76, 8)
      ..paintDot(12, 28, 8); // context-only mark must never be generated
    prepared = await prepareFocusedInpaint(
      original: source,
      grid: raw,
      outer: outer,
      strength: .7,
      sourceId: 'source',
    );
    generated = _png(prepared.width, prepared.height);
  });

  test(
    'focused request scales to around 1MP and floors axes independently',
    () {
      expect(focusedSendSize(624, 936), (width: 832, height: 1216));
      expect(focusedSendSize(936, 624), (width: 1216, height: 832));
      expect(focusedSendSize(768, 768), (width: 1024, height: 1024));
      expect(() => focusedSendSize(0, 128), throwsArgumentError);
      expect(() => focusedSendSize(8, 73728), throwsArgumentError);
    },
  );

  test(
    'context and area validation use the unscaled eight-pixel outer frame',
    () {
      expect(focusRegionError(outer, 32, 256, 256), isNull);
      expect(focusedInnerRect(outer, 32), (x: 40, y: 48, w: 64, h: 128));
      expect(focusRegionError(outer, 64, 256, 256), isNotNull);
      expect(
        focusRegionError((x: 8, y: 16, w: 256, h: 256), 96, 512, 512),
        isNull,
      );
      expect(
        focusRegionError((x: 8, y: 16, w: 256, h: 256), 104, 512, 512),
        isNotNull,
      );
      expect(focusRegionError(outer, 36, 256, 256), isNotNull);
      expect(
        focusRegionError((x: 9, y: 16, w: 128, h: 192), 32, 256, 256),
        isNotNull,
      );
      expect(
        focusRegionError((x: 0, y: 0, w: 768, h: 768), 32, 1024, 1024),
        isNull,
      );
      expect(
        focusRegionError((x: 0, y: 0, w: 776, h: 768), 32, 1024, 1024),
        isNotNull,
      );
      expect(
        focusRegionError((x: 192, y: 0, w: 128, h: 128), 32, 256, 256),
        isNotNull,
      );
    },
  );

  test(
    'new frame and movement stay eight-aligned and inside all image edges',
    () {
      expect(
        boundedFocusRect(
          const ui.Offset(8 - 1e-12, 512 - 1e-12),
          const ui.Offset(136 - 1e-12, 640 + 1e-12),
          512,
          768,
        ),
        (x: 8, y: 512, w: 128, h: 128),
      );
      for (final pair in [
        (const ui.Offset(17, 33), const ui.Offset(1001, 2001)),
        (const ui.Offset(1001, 2001), const ui.Offset(-500, -500)),
      ]) {
        final rect = boundedFocusRect(pair.$1, pair.$2, 1024, 2048)!;
        expect(
          [rect.x, rect.y, rect.w, rect.h].map((v) => v % 8),
          everyElement(0),
        );
        expect(rect.w * rect.h, lessThanOrEqualTo(kFocusMaxPixels));
        expect(rect.x, greaterThanOrEqualTo(0));
        expect(rect.y, greaterThanOrEqualTo(0));
        expect(rect.x + rect.w, lessThanOrEqualTo(1024));
        expect(rect.y + rect.h, lessThanOrEqualTo(2048));
      }
      expect(
        boundedFocusRect(ui.Offset.zero, const ui.Offset(7, 70), 256, 256),
        isNull,
      );
      expect(moveFocusRect(outer, const ui.Offset(16, 24), 256, 256), (
        x: 24,
        y: 40,
        w: 128,
        h: 192,
      ));
      expect(moveFocusRect(outer, const ui.Offset(900, 900), 257, 257), (
        x: 128,
        y: 64,
        w: 128,
        h: 192,
      ));
      expect(moveFocusRect(outer, const ui.Offset(-900, -900), 256, 256), (
        x: 0,
        y: 0,
        w: 128,
        h: 192,
      ));
    },
  );

  test(
    'marks only in the context or outside the frame still select the whole interior',
    () {
      final onlyOutside = MaskGrid(256, 256)
        ..paintDot(12, 28, 8)
        ..paintDot(220, 220, 8);
      final before = onlyOutside.encode();
      final selected = focusedSelection(onlyOutside, outer, 32);
      expect(maskBounds(selected), (x: 40, y: 48, w: 64, h: 128));
      expect(selected.cells.where((v) => v != 0).length, 8 * 16);
      expect(onlyOutside.encode(), before);
      final painted = focusedSelection(raw, outer, 32);
      expect(maskBounds(painted), (x: 64, y: 72, w: 8, h: 8));
    },
  );

  test(
    'prepared request keeps raw strokes separately from its effective inner mask',
    () {
      expect((prepared.width, prepared.height), (832, 1216));
      expect(prepared.job.grid, raw.encode());
      expect(prepared.job.sourceId, 'source');
      expect(prepared.job.strength, .7);
      final paste = prepared.job.paste!;
      expect(paste.original, source);
      expect((paste.outW, paste.outH), (256, 256));
      expect(
        (
          paste.focus!.x,
          paste.focus!.y,
          paste.focus!.width,
          paste.focus!.height,
          paste.focus!.context,
        ),
        (8, 16, 128, 192, 32),
      );
      final selected = MaskGrid(256, 256);
      expect(selected.decodeInto(paste.focusMask!), isTrue);
      expect(maskBounds(selected), (x: 64, y: 72, w: 8, h: 8));
    },
  );

  test(
    'request image and binary mask share dimensions and every latent cell is uniform',
    () {
      final image = img.decodePng(prepared.job.image)!;
      final mask = img.decodePng(prepared.job.mask)!;
      expect((image.width, image.height), (832, 1216));
      expect((mask.width, mask.height), (832, 1216));
      expect(mask.getPixel(390, 380).r, 255);
      expect(mask.getPixel(8, 8).r, 0);
      String? mismatch;
      for (final pixel in mask) {
        final origin = mask.getPixel(pixel.x ~/ 8 * 8, pixel.y ~/ 8 * 8);
        if ((pixel.r != 0 && pixel.r != 255) ||
            pixel.r != pixel.g ||
            pixel.r != pixel.b ||
            pixel.r != origin.r ||
            pixel.a != 255) {
          mismatch ??= 'invalid latent cell at ${pixel.x},${pixel.y}';
        }
      }
      expect(mismatch, isNull);
    },
  );

  test(
    'composite changes only the source-space inner mask and preserves RGBA outside it',
    () async {
      final original = img.decodePng(source)!;
      final output = img.decodePng(
        await pasteFocusedInpaint(job: prepared.job, patch: generated),
      )!;
      expect((output.width, output.height), (256, 256));
      String? mismatch;
      for (final pixel in output) {
        final selected =
            pixel.x >= 64 && pixel.x < 72 && pixel.y >= 72 && pixel.y < 80;
        final expected = selected
            ? [0, 255, 0, 255]
            : _rgba(original.getPixel(pixel.x, pixel.y));
        final actual = _rgba(pixel);
        if (List.generate(4, (i) => actual[i] == expected[i]).contains(false)) {
          mismatch ??=
              'changed protected source pixel at ${pixel.x},${pixel.y}';
        }
      }
      expect(mismatch, isNull);
    },
  );

  test(
    'preview dimensions may differ but final response mismatch never becomes a saved crop',
    () async {
      final lowResolution = _png(64, 64);
      await expectLater(
        pasteFocusedInpaint(job: prepared.job, patch: lowResolution),
        throwsArgumentError,
      );
      final preview = img.decodePng(
        await pasteFocusedInpaint(
          job: prepared.job,
          patch: lowResolution,
          preview: true,
        ),
      )!;
      expect((preview.width, preview.height), (256, 256));
      expect(_rgba(preview.getPixel(68, 76)), [0, 255, 0, 255]);
      expect(
        _rgba(preview.getPixel(12, 28)),
        _rgba(img.decodePng(source)!.getPixel(12, 28)),
      );
    },
  );

  test(
    'transparent selected content uses returned alpha without a translucent seam',
    () async {
      final transparentResult = _png(
        prepared.width,
        prepared.height,
        alpha: 128,
      );
      final output = img.decodePng(
        await pasteFocusedInpaint(job: prepared.job, patch: transparentResult),
      )!;
      expect(_rgba(output.getPixel(64, 72)), [0, 255, 0, 128]);
      expect(_rgba(output.getPixel(71, 79)), [0, 255, 0, 128]);
      expect(
        _rgba(output.getPixel(63, 72)),
        _rgba(img.decodePng(source)!.getPixel(63, 72)),
      );
    },
  );

  test(
    'indexed PNGs expand to truecolor before resizing and pasting new colors',
    () async {
      final indexed = img.Image(
        width: 256,
        height: 256,
        withPalette: true,
        numChannels: 4,
      );
      indexed.palette!
        ..setRgba(0, 41, 71, 91, 0)
        ..setRgba(1, 91, 111, 131, 255);
      for (final pixel in indexed) {
        pixel.index = pixel.x < 16 ? 0 : 1;
      }
      final sourceBytes = Uint8List.fromList(img.encodePng(indexed));
      final sourceImage = img.decodePng(sourceBytes)!;
      expect(sourceImage.hasPalette, isTrue);
      final indexedJob = await prepareFocusedInpaint(
        original: sourceBytes,
        grid: raw,
        outer: outer,
        strength: .7,
      );
      expect(img.decodePng(indexedJob.job.image)!.hasPalette, isFalse);
      final indexedPatch = img.Image(
        width: indexedJob.width,
        height: indexedJob.height,
        withPalette: true,
        numChannels: 4,
      );
      indexedPatch.palette!.setRgba(0, 0, 255, 0, 255);
      final output = img.decodePng(
        await pasteFocusedInpaint(
          job: indexedJob.job,
          patch: Uint8List.fromList(img.encodePng(indexedPatch)),
        ),
      )!;
      expect(output.hasPalette, isFalse);
      expect(_rgba(output.getPixel(68, 76)), [0, 255, 0, 255]);
      expect(
        _rgba(output.getPixel(12, 28)),
        _rgba(sourceImage.getPixel(12, 28)),
      );
      expect(
        _rgba(output.getPixel(100, 100)),
        _rgba(sourceImage.getPixel(100, 100)),
      );
    },
  );

  test(
    'sixteen-bit source channels keep their values outside the mask',
    () async {
      final sixteen = img.Image(
        width: 256,
        height: 256,
        format: img.Format.uint16,
        numChannels: 4,
      );
      for (final pixel in sixteen) {
        pixel.setRgba(40001, 20003, 10007, 65535);
      }
      final prepared16 = await prepareFocusedInpaint(
        original: Uint8List.fromList(img.encodePng(sixteen)),
        grid: raw,
        outer: outer,
        strength: .7,
      );
      final output = img.decodePng(
        await pasteFocusedInpaint(job: prepared16.job, patch: generated),
      )!;
      expect(output.format, img.Format.uint16);
      expect(_rgba(output.getPixel(12, 28)), [40001, 20003, 10007, 65535]);
      expect(_rgba(output.getPixel(68, 76)), [0, 65535, 0, 65535]);
    },
  );

  for (final internationalText in [false, true]) {
    test(
      'exports new ${internationalText ? 'UTF-8 iTXt' : 'tEXt'} generation metadata at full canvas dimensions',
      () async {
        final oldImage = img.decodePng(source)!
          ..textData = {
            'Source': 'NovelAI Diffusion V4.5',
            'Comment': jsonEncode({
              'prompt': 'old prompt',
              'seed': 11,
              'width': 256,
              'height': 256,
            }),
            'OldNote': 'stale-private-note',
          };
        final preparedWithMeta = await prepareFocusedInpaint(
          original: Uint8List.fromList(img.encodePng(oldImage)),
          grid: raw,
          outer: outer,
          strength: .7,
        );
        final prompt = internationalText ? 'new prompt, 猫咪' : 'new prompt';
        final fields = {
          'prompt': prompt,
          'uc': 'bad hands',
          'seed': 123456,
          'width': prepared.width,
          'height': prepared.height,
        };
        final Uint8List patch;
        if (internationalText) {
          patch = await writeImageMetadataPng(
            generated,
            comment: fields,
            source: 'NovelAI Diffusion V4.5',
          );
        } else {
          final generatedImage = img.decodePng(generated)!
            ..textData = {
              'Source': 'NovelAI Diffusion V4.5',
              'Comment': jsonEncode(fields),
            };
          patch = Uint8List.fromList(img.encodePng(generatedImage));
        }
        final output = await pasteFocusedInpaint(
          job: preparedWithMeta.job,
          patch: patch,
        );
        final metadata = (await extractImageMetadata(output))!;
        expect(metadata.prompt, prompt);
        expect(metadata.negativePrompt, 'bad hands');
        expect(metadata.seed, '123456');
        expect((metadata.width, metadata.height), (256, 256));
        expect(
          latin1.decode(output).contains('stale-private-note'),
          isFalse,
          reason:
              'Source text chunks must not survive as new generation metadata',
        );
        expect(
          _rgba(img.decodePng(output)!.getPixel(12, 28)),
          _rgba(oldImage.getPixel(12, 28)),
          reason: 'Metadata replacement must not alter protected alpha LSBs',
        );
      },
    );
  }

  test(
    'preparation snapshots the grid before yielding and rejects mismatched source dimensions',
    () async {
      final grid = raw.copy();
      final encoded = grid.encode();
      final pending = prepareFocusedInpaint(
        original: source,
        grid: grid,
        outer: outer,
        strength: .4,
      );
      grid.clear();
      expect((await pending).job.grid, encoded);
      await expectLater(
        prepareFocusedInpaint(
          original: _png(128, 128),
          grid: raw,
          outer: outer,
          strength: .7,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'custom character coordinates map to the crop only in the request copy',
    () {
      final sourceState = GenerateState.initial().copyWith(
        inpaint: prepared.job,
        params: GenerateState.initial().params.copyWith(useCoords: true),
        characters: [
          const CharacterPrompt(
            id: 'a',
            name: 'a',
            positive: 'cat',
            position: '0.2500,0.5000',
          ),
          const CharacterPrompt(id: 'b', name: 'b', positive: 'bird'),
          const CharacterPrompt(
            id: 'c',
            name: 'c',
            positive: 'dog',
            position: '0.9900,0.0000',
          ),
          const CharacterPrompt(
            id: 'd',
            name: 'd',
            positive: 'fox',
            position: 'C3',
            enabled: false,
          ),
        ],
      );
      final request = focusedRequestState(sourceState);
      expect(request.characters.map((c) => c.id), ['a', 'b', 'c', 'd']);
      final first = resolveCharacterCenter(request.characters.first.position)!;
      expect(first.x, closeTo((64 - 8) / 128, .0001));
      expect(first.y, closeTo((128 - 16) / 192, .0001));
      expect(request.characters[1].position, isNull, reason: 'AUTO stays AUTO');
      expect(request.characters[2].position, '1.0000,0.0000');
      expect(request.characters[3].position, 'C3');
      expect(sourceState.characters.map((c) => c.position), [
        '0.2500,0.5000',
        null,
        '0.9900,0.0000',
        'C3',
      ]);
      expect(identical(request.inpaint, sourceState.inpaint), isTrue);
      final automatic = sourceState.copyWith(
        params: sourceState.params.copyWith(useCoords: false),
      );
      expect(identical(focusedRequestState(automatic), automatic), isTrue);
    },
  );
}
