import 'dart:typed_data';
import 'dart:ui' as ui;

import '../generate/models.dart';
import 'inpaint_ops.dart';

/// Replaces only the painted part of a result with its saved source and a
/// translucent white mask. The generation snapshot already persists both
/// images, the mask and crop coordinates, so each history entry stays distinct.
Future<Uint8List> buildInpaintComparison({
  required Uint8List result,
  required InpaintJob job,
}) async {
  final decoded = <ui.Image>[];
  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final image = (await codec.getNextFrame()).image;
      decoded.add(image);
      return image;
    } finally {
      codec.dispose();
    }
  }

  ui.Picture? picture;
  try {
    final output = await decode(result);
    final paste = job.paste;
    // A failed paste is saved as a crop-sized result. It must be compared with
    // the sent crop, rather than stretching the full source into that crop.
    final pasted =
        paste != null &&
        output.width == paste.outW &&
        output.height == paste.outH;
    final source = await decode(pasted ? paste.original : job.image);
    if (source.width != output.width || source.height != output.height) {
      throw StateError('重绘前后尺寸不一致');
    }
    final bounds = ui.Rect.fromLTWH(
      0,
      0,
      output.width.toDouble(),
      output.height.toDouble(),
    );
    final clip = pasted
        ? ui.Rect.fromLTWH(
            paste.tightX.toDouble(),
            paste.tightY.toDouble(),
            paste.tightW.toDouble(),
            paste.tightH.toDouble(),
          ).intersect(bounds)
        : bounds;
    final grid = MaskGrid(output.width, output.height);
    final gridBytes = pasted && paste.focus != null
        ? paste.focusMask
        : job.grid;
    final useGrid = gridBytes != null && grid.decodeInto(gridBytes);
    if (pasted && paste.focus != null && !useGrid) {
      throw StateError('缺少框选重绘的有效内区蒙版');
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, bounds);
    canvas.drawImage(output, ui.Offset.zero, ui.Paint());
    canvas.save();
    canvas.clipRect(clip, doAntiAlias: false);
    if (useGrid) {
      final path = ui.Path();
      for (final rect in grid.displayRects()) {
        path.addRect(rect);
      }
      canvas.clipPath(path, doAntiAlias: false);
      canvas.drawImage(source, ui.Offset.zero, ui.Paint());
      canvas.drawRect(bounds, ui.Paint()..color = const ui.Color(0x59FFFFFF));
    } else {
      final mask = await decode(job.mask);
      final maskAt = ui.Offset(
        pasted ? paste.sendX.toDouble() : 0,
        pasted ? paste.sendY.toDouble() : 0,
      );
      canvas.clipRect(
        maskAt & ui.Size(mask.width.toDouble(), mask.height.toDouble()),
        doAntiAlias: false,
      );
      canvas.saveLayer(bounds, ui.Paint());
      canvas.drawImage(source, ui.Offset.zero, ui.Paint());
      canvas.drawRect(bounds, ui.Paint()..color = const ui.Color(0x59FFFFFF));
      // The API mask is opaque black/white. Convert its red channel to alpha
      // before applying dstIn; ordinary alpha would select the entire image.
      canvas.drawImage(
        mask,
        maskAt,
        ui.Paint()
          ..blendMode = ui.BlendMode.dstIn
          ..colorFilter = const ui.ColorFilter.matrix([
            0,
            0,
            0,
            0,
            255,
            0,
            0,
            0,
            0,
            255,
            0,
            0,
            0,
            0,
            255,
            1,
            0,
            0,
            0,
            0,
          ]),
      );
      canvas.restore();
    }
    canvas.restore();
    picture = recorder.endRecording();
    final preview = await picture.toImage(output.width, output.height);
    decoded.add(preview);
    final png = await preview.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('无法生成重绘对比');
    return png.buffer.asUint8List();
  } finally {
    picture?.dispose();
    for (final image in decoded) {
      image.dispose();
    }
  }
}
