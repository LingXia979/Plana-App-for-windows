import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

const kAssistantMaxAttachments = 64;

/// The legacy bot endpoint accepts one image. Preserve every original in the
/// session, and send an ordered contact sheet instead of dropping attachments.
/// Decode, resize and encode away from the UI isolate; never crop a reference.
Future<Uint8List> prepareAssistantReferenceSheet(List<Uint8List> images) {
  if (images.isEmpty) throw ArgumentError('没有图片附件');
  if (images.length == 1) return Future.value(images.single);
  return compute(_referenceSheet, List<Uint8List>.of(images));
}

Uint8List _referenceSheet(List<Uint8List> images) {
  // Bound the sheet's allocation while keeping all accepted references. The
  // desktop receiver already limits one drop to 64 images.
  if (images.length > kAssistantMaxAttachments) {
    throw StateError('一条消息最多添加 $kAssistantMaxAttachments 张图片');
  }
  final columns = math.sqrt(images.length).ceil();
  final rows = (images.length / columns).ceil();
  const gap = 16;
  const labelHeight = 40;
  final cell = math.min(1024, (4096 - gap * (columns + 1)) ~/ columns);
  final sheet = img.Image(
    width: columns * (cell + gap) + gap,
    height: rows * (cell + gap) + gap,
    numChannels: 3,
  );
  img.fill(sheet, color: img.ColorRgb8(245, 245, 245));
  for (var i = 0; i < images.length; i++) {
    final decoded = img.decodeImage(images[i], frame: 0);
    if (decoded == null) throw StateError('第 ${i + 1} 张图片无法读取，未发送本轮附件。');
    final source = img.bakeOrientation(decoded);
    final scale = math.min(
      cell / source.width,
      (cell - labelHeight) / source.height,
    );
    final width = math.max(1, (source.width * math.min(1.0, scale)).round());
    final height = math.max(1, (source.height * math.min(1.0, scale)).round());
    final resized = width == source.width && height == source.height
        ? source
        : img.copyResize(
            source,
            width: width,
            height: height,
            interpolation: img.Interpolation.average,
          );
    final x = gap + (i % columns) * (cell + gap);
    final y = gap + (i ~/ columns) * (cell + gap);
    img.fillRect(
      sheet,
      x1: x,
      y1: y,
      x2: x + cell - 1,
      y2: y + cell - 1,
      color: img.ColorRgb8(255, 255, 255),
    );
    img.drawString(
      sheet,
      '#${i + 1}',
      font: img.arial24,
      x: x + 8,
      y: y + 6,
      color: img.ColorRgb8(25, 25, 25),
    );
    img.compositeImage(
      sheet,
      resized,
      dstX: x + (cell - width) ~/ 2,
      dstY: y + labelHeight + (cell - labelHeight - height) ~/ 2,
    );
  }
  return Uint8List.fromList(img.encodeJpg(sheet, quality: 90));
}

String assistantReferenceSheetPrompt(String text, int imageCount) =>
    '$text${text.isEmpty ? '' : '\n\n'}'
    '[本轮共有 $imageCount 张参考图片，合并在附件中。'
    '每张图以 #1 至 #$imageCount 编号，按从左到右、从上到下排列；'
    '请分别参考全部图片，编号条和留白不是原图内容。]';
