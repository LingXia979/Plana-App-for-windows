// 透明背景(V5)的下游保护。
//
// 透明图一旦生成,后面每一步都可能把它拍平 —— 而拍平是**无声**的:图还在、
// 尺寸也对,只是透明区变成了黑色/白色。这几条就是那几步。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/image_ops.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/core/util/transparency.dart';

/// 左半透明、右半不透明的 PNG(方便按位置取样)。
Future<Uint8List> _halfTransparent(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = 200; // R
      rgba[i + 1] = 60;
      rgba[i + 2] = 60;
      rgba[i + 3] = x < w ~/ 2 ? 0 : 255;
    }
  }
  return encodePngFromRgba(rgba, w, h);
}

/// 不透明 PNG。[stego] = 模拟 NAI 的隐写位(alpha 254/255 混着),
/// 这正是「拿 `< 255` 判透明」会翻车的那种图。
Future<Uint8List> _opaque(int w, int h, {bool stego = true}) {
  final rgba = Uint8List(w * h * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = 30;
    rgba[i + 1] = 180;
    rgba[i + 2] = 90;
    rgba[i + 3] = stego && (i ~/ 4).isEven ? 254 : 255;
  }
  return encodePngFromRgba(rgba, w, h);
}

Future<Uint8List> _rgbaOf(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 透明**不是**开关,是提示词里带 `transparent background` 就触发。
  // 判据必须认 tag 不认子串 —— 认子串的话「transparent background overlay」
  // 会误命中,用户白等一张不该透明的图。
  group('promptHasTransparentBackground', () {
    test('逐条比,命中才算', () {
      expect(
        promptHasTransparentBackground('1girl, transparent background'),
        isTrue,
      );
      expect(promptHasTransparentBackground('transparent background'), isTrue);
      expect(promptHasTransparentBackground('1girl, smile'), isFalse);
    });

    test('不认子串', () {
      expect(
        promptHasTransparentBackground('transparent background overlay'),
        isFalse,
      );
      expect(
        promptHasTransparentBackground('semi transparent background'),
        isFalse,
      );
    });

    test('脱掉强调括号与数值权重', () {
      for (final p in [
        '{transparent background}',
        '[[transparent background]]',
        '1.3::transparent background::',
        '-1.2::transparent background::',
        '  Transparent Background  ',
      ]) {
        expect(promptHasTransparentBackground(p), isTrue, reason: p);
      }
    });

    test('全角逗号 / 竖线 / 换行都算分隔', () {
      expect(
        promptHasTransparentBackground('1girl,transparent background'),
        isTrue,
      );
      expect(
        promptHasTransparentBackground('a|transparent background'),
        isTrue,
      );
      expect(
        promptHasTransparentBackground('a\ntransparent background'),
        isTrue,
      );
    });

    test('角色词里带也算', () {
      expect(
        anyPromptHasTransparentBackground('1girl', ['transparent background']),
        isTrue,
      );
      expect(anyPromptHasTransparentBackground('1girl', ['smile']), isFalse);
      expect(anyPromptHasTransparentBackground(null), isFalse);
    });
  });

  group('clearAlphaLsb:抹掉隐写但不拍实', () {
    test('两端吸到端点,中间清最低位', () {
      final rgba = Uint8List.fromList([
        0, 0, 0, 255, // 全不透明
        0, 0, 0, 254, // 隐写位写过的「不透明」
        0, 0, 0, 0, //   全透明
        0, 0, 0, 1, //   隐写位写过的「全透明」
        0, 0, 0, 128, // 抗锯齿边缘
        0, 0, 0, 129,
      ]);
      clearAlphaLsb(rgba);
      expect(
        [for (var i = 3; i < rgba.length; i += 4) rgba[i]],
        [255, 255, 0, 0, 128, 128],
      );
    });

    // 对本来就不透明的图,这条规则要退化成旧行为(254/255 都变 255),
    // 否则等于顺手改了每一张存量图。
    test('不透明图的结果与「alpha 全推 255」完全一致', () {
      final rgba = Uint8List.fromList([
        0,
        0,
        0,
        254,
        0,
        0,
        0,
        255,
        0,
        0,
        0,
        254,
      ]);
      clearAlphaLsb(rgba);
      expect(
        [for (var i = 3; i < rgba.length; i += 4) rgba[i]],
        [255, 255, 255],
      );
    });
  });

  // 阈值卡 254 而不是 255:NAI 把隐写写在 alpha 最低位,
  // 拿 `< 255` 判会把**每一张** NAI 图都当成透明图。
  group('rgbaHasAlpha:254 这个下限是必须的', () {
    test('254/255 混着的不透明图不算透明', () {
      expect(
        rgbaHasAlpha(Uint8List.fromList([0, 0, 0, 254, 0, 0, 0, 255])),
        isFalse,
      );
    });

    test('真有半透/全透才算', () {
      expect(rgbaHasAlpha(Uint8List.fromList([0, 0, 0, 253])), isTrue);
      expect(rgbaHasAlpha(Uint8List.fromList([0, 0, 0, 0])), isTrue);
    });
  });

  group('pngHasAlpha', () {
    test('透明图 true / 不透明图 false', () async {
      expect(await pngHasAlpha(await _halfTransparent(128, 128)), isTrue);
      expect(await pngHasAlpha(await _opaque(128, 128)), isFalse);
    });

    test('解不开的字节当不透明,不抛', () async {
      expect(await pngHasAlpha(Uint8List.fromList([1, 2, 3])), isFalse);
    });
  });

  // 存图时「清除元数据 / 覆写元数据」两条路以前都会把 alpha 全推成 255,
  // 于是用户存下来的透明 PNG 变成实心 —— 这是这批修复的正题。
  group('存图不再把透明图拍实', () {
    test('清除元数据:透明区照样透明', () async {
      final src = await _halfTransparent(96, 96);
      final out = await cleanImagePng(src);
      expect(await pngHasAlpha(out), isTrue);
    });

    test('覆写元数据:透明区照样透明,且元数据能读回来', () async {
      final src = await _halfTransparent(96, 96);
      final out = await writeCustomMetadataPng(
        src,
        '1girl, transparent background',
      );
      expect(await pngHasAlpha(out), isTrue);
      final rgba = await _rgbaOf(out);
      expect(rgba[3], 0); // 左上角仍是全透明
    });

    test('不透明图走这两条路的结果不变(alpha 恒 255)', () async {
      final src = await _opaque(128, 128);
      for (final out in [
        await cleanImagePng(src),
        await writeCustomMetadataPng(src, 'x'),
      ]) {
        expect(await pngHasAlpha(out), isFalse);
      }
    });
  });

  // 黑底本来只是 cover 的边缘保险(cover 铺满画布,底色看不见),
  // 但它会透过 alpha 显出来 —— 缩略图变黑方块、图生图底图变黑底。
  group('coverResizePng:keepAlpha', () {
    test('默认垫黑底(旧行为不变)', () async {
      final out = await coverResizePng(
        await _halfTransparent(128, 128),
        64,
        64,
      );
      final rgba = await _rgbaOf(out);
      expect(rgba[3], 255); // 左上角被黑底填实
      expect(rgba[0], 0);
    });

    test('keepAlpha:透明区原样带过去', () async {
      final out = await coverResizePng(
        await _halfTransparent(128, 128),
        64,
        64,
        keepAlpha: true,
      );
      expect(await pngHasAlpha(out), isTrue);
      expect((await _rgbaOf(out))[3], 0);
    });

    // 注意用的是**纯 255** 的图:带隐写位(254)的图两条路会差一丝 ——
    // 垫了黑底的那条会把 254 合成成 255、RGB 也被黑底拉暗 1/255。
    // 对缩略图无所谓,但拿它做等价断言就不成立了。
    test('全不透明图加不加 keepAlpha 都一样', () async {
      final src = await _opaque(128, 128, stego: false);
      final a = await _rgbaOf(await coverResizePng(src, 64, 64));
      final b = await _rgbaOf(
        await coverResizePng(src, 64, 64, keepAlpha: true),
      );
      expect(a, b);
    });
  });

  group('makeThumb', () {
    test('带隐写位的不透明图编 JPEG,按短边等比缩', () async {
      final t = await makeThumb(await _opaque(1024, 1536));
      expect(t.jpeg, isTrue);
      expect(t.bytes.sublist(0, 2), [0xFF, 0xD8]);
      expect(await decodeImageSize(t.bytes), (kThumbShortSide, 768));
    });

    test('有真透明的编 PNG,透明区带过去,小图不放大', () async {
      final t = await makeThumb(await _halfTransparent(128, 128));
      expect(t.jpeg, isFalse);
      expect(await decodeImageSize(t.bytes), (128, 128));
      expect((await _rgbaOf(t.bytes))[3], 0);
    });
  });
}
