/// 剪贴板图片层的单元测试:回包怎么读、DIB 怎么补头、什么情况下不抢文本粘贴。
///
/// 原生那半截(Swift / C++)不在这里测 —— macOS 的通道由打包冒烟验
/// (见 CI 的 clipboard smoke),Windows 的 C++ 没有人能在这台机器上跑。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/clipboard_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Map<String, Object?>? response;

  final png = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 8, height: 4)..clear(img.ColorRgb8(10, 200, 30)),
    ),
  );

  setUp(() {
    calls = [];
    response = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, (call) async {
      calls.add(call);
      if (call.method == 'write') return true;
      return response;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, null);
  });

  for (final stripText in [false, true]) {
    test(
      'macOS smoke verifies Finder PNG bytes (stripText=$stripText)',
      () async {
        Uint8List? written;
        List<String> copied = [];
        final fixturePaths = <String>[];
        messenger.setMockMethodCallHandler(DesktopClipboard.channel, (
          call,
        ) async {
          if (call.method == 'write') {
            written = (call.arguments as Map)['image'] as Uint8List;
            copied = [];
            return true;
          }
          if (call.method == 'smokeCopyFiles') {
            copied = (call.arguments as List).cast<String>();
            fixturePaths.addAll(copied);
            return true;
          }
          if (call.method == 'read' && copied.isEmpty) {
            return {'image': written, 'format': 'png'};
          }
          final images = <Map<String, Object?>>[];
          for (final path in copied) {
            final bytes = await File(path).readAsBytes();
            img.Image? image;
            try {
              image = img.decodeImage(bytes);
            } catch (_) {
              return {'fromFile': true, 'error': 'invalid_image'};
            }
          if (image == null) {
            return {'fromFile': true, 'error': 'invalid_image'};
          }
            images.add({
              'name': File(path).uri.pathSegments.last,
              'image': path.endsWith('.png') && !stripText
                  ? bytes
                  : Uint8List.fromList(img.encodePng(image..textData = null)),
            });
          }
          return {'fromFile': true, 'images': images};
        });
        if (stripText) {
          await expectLater(
            runMacOsClipboardSmokeTest(),
            throwsA(isA<StateError>()),
          );
        } else {
          await runMacOsClipboardSmokeTest();
        }
        expect(fixturePaths, isNotEmpty);
        for (final path in fixturePaths) {
          expect(
            await File(path).exists(),
            isFalse,
            reason: 'Smoke fixtures must be cleaned',
          );
        }
      },
    );
  }

  group('读剪贴板', () {
    test('只有图时取图,文件名跟着一起回来', () async {
      response = {'image': png, 'format': 'png', 'name': 'shot.png'};
      final content = await DesktopClipboard.read();
      expect(content.hasImage, isTrue);
      expect(content.hasText, isFalse);
      expect(content.name, 'shot.png');

      final image = await DesktopClipboard.readImage();
      expect(image?.bytes, png);
      expect(image?.name, 'shot.png');
    });

    test('图和文本同时有:默认不抢文本,明确要图时才给', () async {
      response = {'image': png, 'format': 'png', 'text': '一段复制来的文字'};

      expect(await DesktopClipboard.readImage(), isNull);
      expect((await DesktopClipboard.readImage(preferImage: true))?.bytes, png);
    });

    test('空白文本不算文本:图照取', () async {
      response = {'image': png, 'format': 'png', 'text': '  \n '};
      expect((await DesktopClipboard.readImage())?.bytes, png);
    });

    test('从文件管理器复制的图:剪贴板里的文件名不挡道', () async {
      response = {
        'image': png,
        'format': 'file',
        'text': 'cat.png',
        'fromFile': true,
        'name': 'cat.png',
      };
      final content = await DesktopClipboard.read();
      expect(content.fromFile, isTrue);
      expect(content.hasText, isTrue);
      expect((await DesktopClipboard.readImage())?.bytes, png);
    });

    test('Finder 解码的多张图片一次返回且保留各自文件名', () async {
      response = {
        'images': [
          {'image': png, 'name': 'first.heic'},
          {'image': png, 'name': 'second.png'},
        ],
        'text': 'first.heic',
        'fromFile': true,
      };
      final images = await DesktopClipboard.readImages();
      expect(images.map((image) => image.name), ['first.heic', 'second.png']);
      expect(images.map((image) => image.bytes), [png, png]);
    });

    test('资源管理器复制多张文件时按顺序读入', () async {
      final dir = await Directory.systemTemp.createTemp('clipboard_files_');
      addTearDown(() => dir.delete(recursive: true));
      final first = File('${dir.path}/first.png')..writeAsBytesSync(png);
      final second = File('${dir.path}/second.png')..writeAsBytesSync(png);
      response = {
        'paths': [first.path, second.path],
        'text': 'first.png',
        'fromFile': true,
      };
      final images = await DesktopClipboard.readImages();
      expect(images.map((image) => image.name), ['first.png', 'second.png']);
      expect(images.map((image) => image.bytes), [png, png]);
    });

    test('原生报告文件过大时显式粘贴显示错误', () async {
      response = {'error': 'too_large', 'fromFile': true};
      expect(
        () => DesktopClipboard.readImages(preferImage: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('剪贴板里没图、通道没注册,都只是「没有」,不抛', () async {
      response = {'text': '只有文字'};
      var content = await DesktopClipboard.read();
      expect(content.hasImage, isFalse);
      expect(content.hasText, isTrue);
      expect(await DesktopClipboard.readImage(), isNull);

      messenger.setMockMethodCallHandler(DesktopClipboard.channel, null);
      content = await DesktopClipboard.read();
      expect(content.hasImage, isFalse);
      expect(await DesktopClipboard.readImage(), isNull);
    });
  });

  group('写剪贴板', () {
    test('统一交 PNG;macOS 不额外带 DIB', () async {
      expect(await DesktopClipboard.writeImage(png), isTrue);
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(args['image'], png); // 本来就是 PNG:原样交出去,不重新编码
      expect(args.containsKey('dib'), isFalse);
    });

    test('Windows 多带一份 DIB:补上文件头能解回同一张图', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(await DesktopClipboard.writeImage(png), isTrue);

      final args = (calls.single.arguments as Map).cast<String, Object?>();
      final dib = args['dib']! as Uint8List;
      expect(dib.sublist(0, 2), isNot(equals([0x42, 0x4D]))); // 裸 DIB,没有 BM
      final header = ByteData.sublistView(dib);
      expect(header.getUint32(0, Endian.little), 40);
      expect(header.getUint16(14, Endian.little), 24);
      expect(header.getUint32(16, Endian.little), 0); // BI_RGB

      final decoded = img.decodeImage(wrapDibAsBmp(dib));
      expect(decoded, isNotNull);
      expect((decoded!.width, decoded.height), (8, 4));
      expect(decoded.getPixel(0, 0).r, 10);
      expect(decoded.getPixel(0, 0).g, 200);
      expect(decoded.getPixel(0, 0).b, 30);
    });

    test('Windows DIB 保留四角像素方向和颜色', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final source = img.Image(width: 2, height: 2)
        ..setPixelRgb(0, 0, 255, 0, 0)
        ..setPixelRgb(1, 0, 0, 255, 0)
        ..setPixelRgb(0, 1, 0, 0, 255)
        ..setPixelRgb(1, 1, 255, 255, 0);
      expect(
        await DesktopClipboard.writeImage(
          Uint8List.fromList(img.encodePng(source)),
        ),
        isTrue,
      );
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      final decoded = img.decodeImage(wrapDibAsBmp(args['dib']! as Uint8List))!;
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          final expected = source.getPixel(x, y);
          final actual = decoded.getPixel(x, y);
          expect(
            (actual.r, actual.g, actual.b),
            (expected.r, expected.g, expected.b),
          );
        }
      }
    });

    test('JPEG 之类不是 PNG 的字节先转码再交 —— 不能贴着 PNG 标签发出去', () async {
      final jpg = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 6, height: 6)),
      );
      expect(await DesktopClipboard.writeImage(jpg), isTrue);
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      final image = args['image']! as Uint8List;
      expect(image.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('原生说写不进去时如实回 false,不假装成功', () async {
      messenger.setMockMethodCallHandler(DesktopClipboard.channel, (
        call,
      ) async {
        calls.add(call);
        return false;
      });
      expect(await DesktopClipboard.writeImage(png), isFalse);
    });
  });

  group('DIB 补文件头', () {
    /// 造一个 2×2 的 24 位裸 DIB(自下而上,行按 4 字节对齐)。
    Uint8List dib({
      int headerSize = 40,
      int compression = 0,
      int bitCount = 24,
      int colorsUsed = 0,
    }) {
      const rowStride = 8; // 2 像素 × 3 字节,补到 4 的倍数
      final pixels = rowStride * 2;
      final palette =
          (colorsUsed != 0
              ? colorsUsed
              : bitCount <= 8
              ? 1 << bitCount
              : 0) *
          4;
      final masks = headerSize == 40 && compression != 0
          ? compression == 6
                ? 16
                : 12
          : 0;
      final out = Uint8List(headerSize + masks + palette + pixels);
      final header = ByteData.sublistView(out);
      header
        ..setUint32(0, headerSize, Endian.little)
        ..setInt32(4, 2, Endian.little) // 宽
        ..setInt32(8, 2, Endian.little) // 高
        ..setUint16(12, 1, Endian.little) // planes
        ..setUint16(14, bitCount, Endian.little)
        ..setUint32(16, compression, Endian.little)
        ..setUint32(20, pixels, Endian.little)
        ..setUint32(32, colorsUsed, Endian.little); // biClrUsed
      var at = headerSize + masks + palette;
      for (var row = 0; row < 2; row++) {
        for (var x = 0; x < 2; x++) {
          out[at++] = 30; // B
          out[at++] = 200; // G
          out[at++] = 10; // R
        }
        at += 2; // 行对齐
      }
      return out;
    }

    test('24 位无压缩:偏移落在像素数据上', () {
      final bmp = wrapDibAsBmp(dib());
      expect(bmp.sublist(0, 2), [0x42, 0x4D]);
      expect(ByteData.sublistView(bmp).getUint32(10, Endian.little), 14 + 40);
      final decoded = img.decodeImage(bmp)!;
      expect((decoded.width, decoded.height), (2, 2));
      expect(decoded.getPixel(0, 0).g, 200);
    });

    test('40 字节头 + BI_BITFIELDS:三个掩码也要算进偏移', () {
      final bmp = wrapDibAsBmp(dib(compression: 3, bitCount: 32));
      expect(
        ByteData.sublistView(bmp).getUint32(10, Endian.little),
        14 + 40 + 12,
      );
    });

    test('BI_ALPHABITFIELDS 的第四个掩码和高色深色表也计入偏移', () {
      final alpha = wrapDibAsBmp(dib(compression: 6, bitCount: 32));
      expect(
        ByteData.sublistView(alpha).getUint32(10, Endian.little),
        14 + 40 + 16,
      );
      final palette = wrapDibAsBmp(dib(colorsUsed: 2));
      expect(
        ByteData.sublistView(palette).getUint32(10, Endian.little),
        14 + 40 + 8,
      );
    });

    test('负高度可读，极值和缺失的像素数据须拒绝', () {
      final topDown = dib();
      ByteData.sublistView(topDown).setInt32(8, -2, Endian.little);
      expect(wrapDibAsBmp(topDown).length, topDown.length + 14);
      ByteData.sublistView(topDown).setInt32(8, -0x80000000, Endian.little);
      expect(() => wrapDibAsBmp(topDown), throwsFormatException);
      final truncated = Uint8List.sublistView(dib(), 0, 40 + 8);
      expect(() => wrapDibAsBmp(truncated), throwsFormatException);
    });

    test('调色板图的偏移按调色板条数走', () {
      final bmp = wrapDibAsBmp(dib(bitCount: 8));
      expect(
        ByteData.sublistView(bmp).getUint32(10, Endian.little),
        14 + 40 + 256 * 4,
      );
    });

    test('已经是 BMP 的原样返回,头不完整的直接报错', () {
      final bmp = Uint8List.fromList([0x42, 0x4D, 0, 0, 0, 0]);
      expect(wrapDibAsBmp(bmp), same(bmp));
      expect(
        () => wrapDibAsBmp(Uint8List(20)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
