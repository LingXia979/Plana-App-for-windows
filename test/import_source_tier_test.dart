// 导入面板顶栏显示的那行「来源模型」。
//
// V5 的 Source 串里**不写档次**,只有一串权重 hash —— 不显式补上,顶栏就只有
// 光秃秃一个「NovelAI V5」,而 V4/V4.5 那边有指纹表、一直是带 Full/Curated 的。
// 用户就是这么发现的,所以这条钉在真实解析路径上(造 PNG → extractImageMetadata),
// 而不是只测那个判据函数。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/import/image_metadata.dart';

/// 往 PNG 的 IHDR 之后插一批 tEXt 块(keyword\0value),返回新字节。
Uint8List _withText(Uint8List png, Map<String, String> entries) {
  // 8 签名 + IHDR(4 长度 + 4 类型 + 13 数据 + 4 CRC)= 33
  const afterIhdr = 8 + 4 + 4 + 13 + 4;
  final out = BytesBuilder()..add(png.sublist(0, afterIhdr));
  for (final e in entries.entries) {
    final data = <int>[...latin1.encode(e.key), 0, ...utf8.encode(e.value)];
    final type = latin1.encode('tEXt');
    final len = ByteData(4)..setUint32(0, data.length, Endian.big);
    final crc = ByteData(4)
      ..setUint32(0, getCrc32([...type, ...data]), Endian.big);
    out
      ..add(len.buffer.asUint8List())
      ..add(type)
      ..add(data)
      ..add(crc.buffer.asUint8List());
  }
  out.add(png.sublist(afterIhdr));
  return out.toBytes();
}

Future<Uint8List> _blankPng(int w, int h) {
  final rnd = Random(7);
  final rgba = Uint8List(w * h * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = rnd.nextInt(256);
    rgba[i + 1] = rnd.nextInt(256);
    rgba[i + 2] = rnd.nextInt(256);
    rgba[i + 3] = 255;
  }
  return encodePngFromRgba(rgba, w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<String?> sourceOf(String rawSource) async {
    final png = _withText(await _blankPng(64, 64), {
      'Source': rawSource,
      'Comment': jsonEncode({
        'prompt': '1girl',
        'uc': '',
        'width': 64,
        'height': 64,
        'seed': 1,
      }),
    });
    return (await extractImageMetadata(png))?.source;
  }

  group('顶栏来源模型:档次要写出来', () {
    test('V5 Medium 官方指纹保留 Full 和 Medium 档位', () async {
      for (final hash in ['93F4BD30', '70AB5786']) {
        expect(
          await sourceOf('NovelAI Diffusion V5 $hash'),
          'NovelAI V5 Full Medium',
        );
      }
    });
    test('V5 白名单指纹 → Full', () async {
      expect(
        await sourceOf('NovelAI Diffusion V5 657484A5'),
        'NovelAI V5 Full',
      );
      expect(
        await sourceOf('NovelAI Diffusion V5 0ADF9AB7'),
        'NovelAI V5 Full',
      );
    });

    test('其余 V5 指纹 → Curated(官方那边就是 default 分支)', () async {
      expect(
        await sourceOf('NovelAI Diffusion V5 12345678'),
        'NovelAI V5 Curated',
      );
    });

    test('V4.5 的已知指纹走指纹表,照样带档次', () async {
      expect(
        await sourceOf('NovelAI Diffusion V4.5 4BDE2A90'),
        'NovelAI V4.5 Full',
      );
      expect(
        await sourceOf('NovelAI Diffusion V4.5 C02D4F98'),
        'NovelAI V4.5 Curated',
      );
    });

    // 没见过的 V4.5 指纹是**真的不知道**档次 —— 那时宁可不写,
    // 也别硬挂一个 Full(V5 那边能写是因为规则是白名单,不是猜的)。
    test('没见过的 V4.5 指纹 → 不硬猜档次', () async {
      expect(await sourceOf('NovelAI Diffusion V4.5 DEADBEEF'), 'NovelAI V4.5');
    });
  });
}
