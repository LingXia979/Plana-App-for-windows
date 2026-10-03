/// PNG 元数据写入端(移植自 web `processImageForSave`):
/// 清除 = 重编码 + 抹掉 alpha 最低位(LSB 隐写连同 tEXt 一并消失,
/// 但透明区照样透明 —— 见 [clearAlphaLsb]);
/// 覆写 = 清除后按 NAI 官方格式把自定义提示词 gzip 压缩写回 alpha LSB
/// (stealth_pngcomp;位序与读取端 `_LsbExtractor` 镜像:列优先、字节高位在前)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'transparency.dart';

Future<(Uint8List, int, int)> _decodeRgba(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final img = (await codec.getNextFrame()).image;
    try {
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) throw StateError('图片解码失败');
      return (bd.buffer.asUint8List(), img.width, img.height);
    } finally {
      img.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// RGBA → PNG(测试也用它造样张)。
Future<Uint8List> encodePngFromRgba(Uint8List rgba, int w, int h) async {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  final img = await c.future;
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  if (data == null) throw StateError('PNG 编码失败');
  return data.buffer.asUint8List();
}

/// 清除元数据:抹掉 alpha 最低位的隐写载荷后重编码(见 [clearAlphaLsb])。
Future<Uint8List> cleanImagePng(Uint8List bytes) async {
  final (rgba, w, h) = await _decodeRgba(bytes);
  clearAlphaLsb(rgba);
  return encodePngFromRgba(rgba, w, h);
}

/// Write editable generation parameters as standard UTF-8 PNG iTXt. Removing
/// the old alpha payload first prevents stale hidden prompts from surviving.
/// Unlike steganography, text chunks also work with small preview images.
Future<Uint8List> writeImageMetadataPng(
  Uint8List bytes, {
  required Map<String, dynamic> comment,
  String source = 'Plana',
}) async {
  final (rgba, width, height) = await _decodeRgba(bytes);
  clearAlphaLsb(rgba);
  final png = await encodePngFromRgba(rgba, width, height);
  final fields = {...comment, 'width': width, 'height': height};
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(png, 0, png.length - 12));
  for (final entry in {
    'Software': 'Plana',
    'Source': source,
    'Comment': jsonEncode(fields),
  }.entries) {
    // keyword NUL, uncompressed flag/method, empty language/translated keyword.
    final data = [
      ...ascii.encode(entry.key),
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode(entry.value),
    ];
    final typeAndData = Uint8List.fromList([...ascii.encode('iTXt'), ...data]);
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(typeAndData)
      ..add(
        (ByteData(4)..setUint32(0, getCrc32(typeAndData))).buffer.asUint8List(),
      );
  }
  out.add(Uint8List.sublistView(png, png.length - 12));
  return out.takeBytes();
}

class _LsbWriter {
  _LsbWriter(this.data, this.width, this.height);

  final Uint8List data; // RGBA
  final int width;
  final int height;
  int _row = 0;
  int _col = 0;

  void _writeBit(int bit) {
    if (_col >= width) throw StateError('图片太小,放不下元数据');
    final index = (_row * width + _col) * 4 + 3; // alpha
    data[index] = (data[index] & 0xFE) | bit;
    _row++;
    if (_row == height) {
      _row = 0;
      _col++;
    }
  }

  void writeByte(int b) {
    for (var i = 7; i >= 0; i--) {
      _writeBit((b >> i) & 1);
    }
  }

  void writeBytes(List<int> bs) {
    for (final b in bs) {
      writeByte(b);
    }
  }

  void writeUint32(int v) {
    writeByte((v >> 24) & 0xFF);
    writeByte((v >> 16) & 0xFF);
    writeByte((v >> 8) & 0xFF);
    writeByte(v & 0xFF);
  }
}

/// NAI 官方 Comment 骨架(与 web `writeCustomMetadataToImage` 字段一致)。
Map<String, dynamic> _naiComment(String prompt, int w, int h) => {
  'prompt': prompt,
  'steps': 28,
  'height': h,
  'width': w,
  'scale': 5.0,
  'uncond_scale': 0.0,
  'cfg_rescale': 0.0,
  'seed': 0,
  'n_samples': 1,
  'noise_schedule': 'karras',
  'legacy_v3_extend': false,
  'reference_information_extracted_multiple': <Object>[],
  'reference_strength_multiple': <Object>[],
  'v4_prompt': {
    'caption': {'base_caption': prompt, 'char_captions': <Object>[]},
    'use_coords': true,
    'use_order': true,
    'legacy_uc': false,
  },
  'v4_negative_prompt': {
    'caption': {'base_caption': '', 'char_captions': <Object>[]},
    'use_coords': false,
    'use_order': false,
    'legacy_uc': false,
  },
  'sampler': 'k_euler_ancestral',
  'controlnet_strength': 1.0,
  'controlnet_model': null,
  'dynamic_thresholding': false,
  'dynamic_thresholding_percentile': 0.999,
  'dynamic_thresholding_mimic_scale': 10.0,
  'sm': false,
  'sm_dyn': false,
  'skip_cfg_above_sigma': null,
  'skip_cfg_below_sigma': 0.0,
  'lora_unet_weights': null,
  'lora_clip_weights': null,
  'deliberate_euler_ancestral_bug': false,
  'prefer_brownian': true,
  'cfg_sched_eligibility': 'enable_for_post_summer_samplers',
  'explike_fine_detail': false,
  'minimize_sigma_inf': false,
  'uncond_per_vibe': true,
  'wonky_vibe_correlation': true,
  'stream': 'none',
  'version': 1,
  'uc': '',
  'request_type': 'PromptGenerateRequest',
};

/// 覆写元数据:抹掉旧数据后,把 [customPrompt] 按 NAI 格式写入 alpha LSB。
Future<Uint8List> writeCustomMetadataPng(
  Uint8List bytes,
  String customPrompt,
) async {
  final (rgba, w, h) = await _decodeRgba(bytes);
  clearAlphaLsb(rgba);

  final metadata = {
    'Description': customPrompt,
    'Software': 'NovelAI',
    'Source': 'NovelAI',
    'Generation time': '0.0',
    'Comment': jsonEncode(_naiComment(customPrompt, w, h)),
  };
  final compressed = GZipEncoder().encode(utf8.encode(jsonEncode(metadata)));

  const magic = 'stealth_pngcomp';
  if ((magic.length + 4 + compressed.length) * 8 > w * h) {
    throw StateError('图片太小,放不下元数据');
  }
  final writer = _LsbWriter(rgba, w, h)
    ..writeBytes(utf8.encode(magic))
    ..writeUint32(compressed.length * 8)
    ..writeBytes(compressed);
  return encodePngFromRgba(writer.data, w, h);
}
