import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

const _none = (left: 0, top: 0, right: 0, bottom: 0);
const _asymmetric = (left: 64, top: 128, right: 192, bottom: 64);

Uint8List _patternPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, x % 256, y % 256, (x + y) % 256, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

int _cell(MaskGrid grid, int x, int y) => grid.cells[y * grid.gw + x];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('desktop mask brushes', () {
    test('round brush keeps its centre and omits square corners', () {
      final square = MaskGrid(256, 256)..paintDot(128, 128, 48);
      final circle = MaskGrid(256, 256)
        ..paintDot(128, 128, 48, shape: MaskBrushShape.circle);

      expect(_cell(square, 13, 13), 1);
      expect(_cell(circle, 13, 13), 0);
      expect(_cell(circle, 18, 18), 0);
      expect(_cell(circle, 16, 16), 1);
      expect(_cell(circle, 15, 13), 1);
      expect(maskBounds(circle), maskBounds(square));
      expect(
        circle.cells.where((cell) => cell != 0).length,
        lessThan(square.cells.where((cell) => cell != 0).length),
      );
    });

    test('small circular brushes still paint one cell at image edges', () {
      for (final diameter in [4.0, 8.0]) {
        final grid = MaskGrid(64, 64)
          ..paintDot(0, 0, diameter, shape: MaskBrushShape.circle)
          ..paintDot(63, 63, diameter, shape: MaskBrushShape.circle);
        expect(_cell(grid, 0, 0), 1);
        expect(_cell(grid, 7, 7), 1);
        expect(grid.cells.where((cell) => cell != 0).length, 2);
      }
    });

    test(
      'fast circular strokes have no gaps and can be erased identically',
      () {
        final grid = MaskGrid(256, 256);
        const start = ui.Offset(16, 16);
        const end = ui.Offset(232, 232);
        grid.paintLine(start, end, 24, shape: MaskBrushShape.circle);
        for (var cell = 2; cell <= 29; cell++) {
          expect(_cell(grid, cell, cell), 1, reason: 'gap at cell $cell');
        }
        expect(_cell(grid, 2, 28), 0);
        grid.paintLine(
          start,
          end,
          24,
          erase: true,
          shape: MaskBrushShape.circle,
        );
        expect(grid.isEmpty, isTrue);
      },
    );

    test('circular eraser retains the corners left by a square brush', () {
      final grid = MaskGrid(256, 256)
        ..paintDot(128, 128, 48)
        ..paintDot(128, 128, 48, erase: true, shape: MaskBrushShape.circle);
      expect(_cell(grid, 16, 16), 0);
      expect(_cell(grid, 13, 13), 1);
      expect(_cell(grid, 18, 18), 1);
      expect(_cell(grid, 12, 12), 0);
    });

    test('whole-image fill includes partial edge cells and stays erasable', () {
      final grid = MaskGrid(65, 73)..fill();
      expect(grid.cells, everyElement(1));
      expect(maskBounds(grid), (x: 0, y: 0, w: 65, h: 73));
      grid.paintDot(64, 72, 8, erase: true, shape: MaskBrushShape.circle);
      expect(grid.cells.last, 0);
      expect(grid.cells.first, 1);
      grid.clear();
      expect(grid.isEmpty, isTrue);
    });
  });

  group('moving crop selection', () {
    test('moves both axes along the grid while preserving dimensions', () {
      const rect = (x: 64, y: 128, w: 448, h: 768);
      expect(moveCropRect(rect, const ui.Offset(130, -65), 832, 1216), (
        x: 192,
        y: 64,
        w: 448,
        h: 768,
      ));
      expect(moveCropRect(rect, const ui.Offset(20, 20), 832, 1216), rect);
    });

    test('clamps all four edges without shrinking the selection', () {
      const rect = (x: 64, y: 128, w: 448, h: 768);
      for (final delta in [
        const ui.Offset(-10000, -10000),
        const ui.Offset(10000, 10000),
        const ui.Offset(-10000, 10000),
        const ui.Offset(10000, -10000),
      ]) {
        final moved = moveCropRect(rect, delta, 832, 1216);
        expect(moved.w, rect.w);
        expect(moved.h, rect.h);
        expect(moved.x, delta.dx < 0 ? 0 : 384);
        expect(moved.y, delta.dy < 0 ? 0 : 448);
      }
    });

    test('nonaligned image bounds never push a snapped selection outside', () {
      const rect = (x: 0, y: 0, w: 256, h: 256);
      final moved = moveCropRect(rect, const ui.Offset(999, 999), 601, 799);
      expect(moved, (x: 320, y: 512, w: 256, h: 256));
      expect(moved.x + moved.w, lessThanOrEqualTo(601));
      expect(moved.y + moved.h, lessThanOrEqualTo(799));
      expect(moveCropRect(rect, const ui.Offset(999, -999), 256, 256), rect);
    });
  });

  group('expansion limits', () {
    test('each positive margin rounds upward independently to 64 pixels', () {
      final cases = {-1: 0, 0: 0, 1: 64, 63: 64, 64: 64, 65: 128, 129: 192};
      for (final entry in cases.entries) {
        expect(alignExpandMargin(entry.key), entry.value);
      }
      final margins = (
        left: alignExpandMargin(1),
        top: alignExpandMargin(65),
        right: alignExpandMargin(129),
        bottom: alignExpandMargin(0),
      );
      expect(margins, (left: 64, top: 128, right: 192, bottom: 0));
      expect(expansionError(832, 1216, margins), isNull);
    });

    test('permits exactly 4096 on either axis but rejects the next step', () {
      expect(
        expansionError(512, 512, (left: 0, top: 0, right: 3584, bottom: 0)),
        isNull,
      );
      expect(
        expansionError(512, 512, (left: 0, top: 3584, right: 0, bottom: 0)),
        isNull,
      );
      expect(
        expansionError(512, 512, (left: 0, top: 0, right: 3648, bottom: 0)),
        contains('4096'),
      );
      expect(
        expansionError(512, 512, (left: 0, top: 0, right: 0, bottom: 3648)),
        contains('4096'),
      );
    });

    test(
      'permits exactly 3MP but rejects one 64-pixel expansion beyond it',
      () {
        expect(expansionError(1536, 2048, _none), isNull);
        expect(
          expansionError(1536, 2048, (left: 0, top: 0, right: 64, bottom: 0)),
          contains('3,145,728'),
        );
        expect(expansionError(4096, 768, _none), isNull);
        expect(
          expansionError(4096, 768, (left: 0, top: 64, right: 0, bottom: 0)),
          contains('3,145,728'),
        );
      },
    );

    test(
      'validates base dimensions and rejects unaligned or negative margins',
      () {
        for (final dimensions in [(0, 64), (64, -64), (65, 128), (128, 127)]) {
          expect(
            expansionError(dimensions.$1, dimensions.$2, _none),
            isNotNull,
          );
        }
        for (final margins in [
          (left: -64, top: 0, right: 0, bottom: 0),
          (left: 0, top: 1, right: 0, bottom: 0),
          (left: 0, top: 0, right: 65, bottom: 0),
          (left: 0, top: 0, right: 0, bottom: -1),
        ]) {
          expect(expansionError(64, 64, margins), isNotNull);
        }
      },
    );
  });

  group('expanded PNG pixels', () {
    test(
      'asymmetric padding preserves all source pixels at the new offset',
      () async {
        final source = _patternPng(64, 128);
        final bytes = await buildExpandImage(
          source,
          padL: _asymmetric.left,
          padT: _asymmetric.top,
          padR: _asymmetric.right,
          padB: _asymmetric.bottom,
        );
        final expanded = img.decodePng(bytes)!;
        expect((expanded.width, expanded.height), (320, 320));
        String? mismatch;
        for (var y = 0; y < expanded.height; y++) {
          for (var x = 0; x < expanded.width; x++) {
            final sx = x - 64, sy = y - 128;
            final inside = sx >= 0 && sx < 64 && sy >= 0 && sy < 128;
            final pixel = expanded.getPixel(x, y);
            final r = inside ? sx : 255;
            final g = inside ? sy : 255;
            final b = inside ? sx + sy : 255;
            if (pixel.r != r ||
                pixel.g != g ||
                pixel.b != b ||
                pixel.a != 255) {
              mismatch ??= 'wrong source position or padding at ($x, $y)';
            }
          }
        }
        expect(mismatch, isNull);
      },
    );

    test(
      'new margins and old painted cells coexist in the shifted mask',
      () async {
        final grid = MaskGrid(64, 128)
          ..paintDot(16, 40, 8)
          ..paintDot(60, 124, 8);
        final originalCells = Uint8List.fromList(grid.cells);
        final bytes = await buildExpandMask(
          imgW: 64,
          imgH: 128,
          padL: _asymmetric.left,
          padT: _asymmetric.top,
          padR: _asymmetric.right,
          padB: _asymmetric.bottom,
          grid: grid,
        );
        final expanded = img.decodePng(bytes)!;
        expect((expanded.width, expanded.height), (320, 320));
        String? mismatch;
        for (var y = 0; y < expanded.height; y++) {
          for (var x = 0; x < expanded.width; x++) {
            final sx = x - 64, sy = y - 128;
            final inside = sx >= 0 && sx < 64 && sy >= 0 && sy < 128;
            final painted =
                (sx >= 16 && sx < 24 && sy >= 40 && sy < 48) ||
                (sx >= 56 && sx < 64 && sy >= 120 && sy < 128);
            final expected = !inside || painted ? 255 : 0;
            final pixel = expanded.getPixel(x, y);
            if (pixel.r != expected ||
                pixel.g != expected ||
                pixel.b != expected ||
                pixel.a != 255) {
              mismatch ??= 'wrong mask at ($x, $y), expected $expected';
            }
          }
        }
        expect(mismatch, isNull);
        expect(
          grid.cells,
          originalCells,
          reason: 'expansion must not mutate the saved source mask',
        );
      },
    );

    test(
      'an omitted source mask keeps the original image unselected',
      () async {
        final bytes = await buildExpandMask(
          imgW: 64,
          imgH: 128,
          padL: 64,
          padT: 0,
          padR: 0,
          padB: 64,
        );
        final mask = img.decodePng(bytes)!;
        expect((mask.width, mask.height), (128, 192));
        expect(mask.getPixel(63, 64).r, 255);
        expect(mask.getPixel(64, 64).r, 0);
        expect(mask.getPixel(127, 127).r, 0);
        expect(mask.getPixel(127, 128).r, 255);
      },
    );

    test(
      'image and mask exports enforce alignment and limits before rasterizing',
      () async {
        final source = _patternPng(64, 128);
        for (final margins in [
          (left: 1, top: 0, right: 0, bottom: 0),
          (left: -64, top: 0, right: 0, bottom: 0),
          (left: 0, top: 0, right: 4096, bottom: 0),
          (left: 1472, top: 0, right: 0, bottom: 1984),
        ]) {
          await expectLater(
            buildExpandImage(
              source,
              padL: margins.left,
              padT: margins.top,
              padR: margins.right,
              padB: margins.bottom,
            ),
            throwsArgumentError,
          );
          await expectLater(
            buildExpandMask(
              imgW: 64,
              imgH: 128,
              padL: margins.left,
              padT: margins.top,
              padR: margins.right,
              padB: margins.bottom,
            ),
            throwsArgumentError,
          );
        }
        await expectLater(
          buildExpandImage(
            _patternPng(65, 128),
            padL: 0,
            padT: 0,
            padR: 64,
            padB: 0,
          ),
          throwsArgumentError,
        );
        await expectLater(
          buildExpandMask(
            imgW: 65,
            imgH: 128,
            padL: 0,
            padT: 0,
            padR: 64,
            padB: 0,
          ),
          throwsArgumentError,
        );
      },
    );
  });
}
