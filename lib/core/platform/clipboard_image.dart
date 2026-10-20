import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, compute, defaultTargetPlatform, listEquals;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../util/log.dart';
import '../util/png_meta.dart' show writeImageMetadataPng;

/// 剪贴板这一趟拿回来的东西:一张图、一段文本,以及这张图是不是从文件管理器
/// 里「复制文件」来的。
///
/// **图和文本同时回来是有意的** —— 要不要贴图,取决于调用点看没看到可用的文本
/// (见 [DesktopClipboard.readImage]);分两次问剪贴板,中间可能被别的程序换掉,
/// 判据和结果就对不上了。
class ClipboardContent {
  const ClipboardContent({
    this.image,
    this.format,
    this.name,
    this.text,
    this.fromFile = false,
    this.paths = const [],
    this.images = const [],
    this.error,
  });

  static const empty = ClipboardContent();

  /// 图片原始字节,没图时 null。
  final Uint8List? image;

  /// 这张图**从哪儿来**的,没图时 null。
  ///
  /// - `png`:剪贴板里就放着 PNG 字节(macOS 侧一律转成 PNG 再交出来);
  /// - `dib`:Windows 的 CF_DIB(裸 DIB,没有 BMP 文件头),要补头才能解;
  /// - `file`:从一个图片文件里读来的(资源管理器 / 访达里「复制文件」)。
  ///
  /// 它是来源标记,**不是**「这些字节长什么样」—— 怎么处理一律按字节认,
  /// 见 [DesktopClipboard.ensurePng]。
  final String? format;

  /// 图的文件名(从文件管理器复制时系统会带过来),拿不到就没有。
  final String? name;

  /// 纯文本(PNG 之外的第二个用途)。
  final String? text;

  /// 图是从「复制文件」来的。这种时候哪怕剪贴板里带着文件名(资源管理器复制
  /// 文件时就会带),用户要的也是那张图,不是文件名的文本。
  final bool fromFile;

  /// Files copied from Finder or Explorer; read only after a recipient accepts.
  final List<String> paths;

  /// Native-decoded file images, used when a platform decoder supports more
  /// file formats than Flutter's image codec (for example Finder HEIC files).
  final List<ClipboardImageBytes> images;

  /// Native validation failure, retained so an explicit image paste can report it.
  final String? error;

  bool get hasImage =>
      (image != null && image!.isNotEmpty) ||
      paths.isNotEmpty ||
      images.isNotEmpty ||
      error != null;

  /// 有**能拿来用**的文本:空串和纯空白不算 —— 从某些程序里复制图片时,
  /// 剪贴板里会顺带躺着一个空文本块,那不是「用户想贴文字」。
  bool get hasText => text != null && text!.trim().isNotEmpty;
}

/// 桌面端剪贴板图片读写。
///
/// Flutter 自带的 [Clipboard] 只有文本,图片得问系统要:走原生通道
/// `plana/clipboard`(macOS:`NSPasteboard`,见 macos/Runner/ClipboardChannel.swift;
/// Windows:剪贴板 API,见 windows/runner/clipboard_channel.cpp)。
///
/// 非桌面平台、或者原生侧没注册上,一律当作「剪贴板里没图」返回 —— 调用点据此
/// 落回文本粘贴 / 选图,不会因为少一个原生实现就报错。
class DesktopClipboard {
  const DesktopClipboard._();

  static const channel = MethodChannel('plana/clipboard');

  /// 读剪贴板。原生侧没实现、读不到、被别的程序占着,一律返回
  /// [ClipboardContent.empty] —— 「剪贴板里没图」和「这台机器读不了剪贴板」
  /// 对调用点是一回事,都该落回文本粘贴。
  static Future<ClipboardContent> read() async {
    try {
      final map = await channel.invokeMapMethod<String, Object?>('read');
      if (map == null) return ClipboardContent.empty;
      final image = map['image'];
      final images = <ClipboardImageBytes>[];
      for (final entry in (map['images'] as List?) ?? const []) {
        if (entry is! Map) continue;
        final bytes = entry['image'];
        if (bytes is Uint8List && bytes.isNotEmpty) {
          images.add(
            ClipboardImageBytes(bytes: bytes, name: entry['name'] as String?),
          );
        }
      }
      return ClipboardContent(
        image: image is Uint8List ? image : null,
        format: map['format'] as String?,
        name: map['name'] as String?,
        text: map['text'] as String?,
        fromFile: map['fromFile'] == true,
        paths: (map['paths'] as List?)?.cast<String>() ?? const [],
        images: images,
        error: map['error'] as String?,
      );
    } catch (e) {
      // 剪贴板是「顺手就有」的东西:原生侧被别的程序占着、没实现,都不该
      // 让粘贴这个动作本身失败。
      logd('[clipboard] 读取剪贴板失败: $e');
      return ClipboardContent.empty;
    }
  }

  /// 把一张图写进系统剪贴板,成功返回 true。
  ///
  /// [bytes] 是任意格式的原图字节(库里的作品、参考图都行),原生侧需要的容器
  /// 格式在这里统一备好:PNG 各端都认,Windows 另外要一份 DIB —— 老程序
  /// (画图、Word)不认 PNG 格式,只认 CF_DIB。
  static Future<bool> writeImage(Uint8List bytes) async {
    if (bytes.isEmpty) return false;
    try {
      final png = await ensurePng(bytes);
      final args = <String, Object?>{
        'image': png,
        if (defaultTargetPlatform == TargetPlatform.windows)
          'dib': await _dibOf(png),
      };
      return await channel.invokeMethod<bool>('write', args) ?? false;
    } catch (e) {
      logd('[clipboard] 写入剪贴板失败: $e');
      return false;
    }
  }

  /// 从剪贴板取一张能直接用的图(PNG 字节 + 名字),没有就返回 null。
  ///
  /// [preferImage] 为 false 时,**剪贴板里同时有能用的文本就不取图** —— 焦点多半
  /// 在一个输入框里,用户按 Ctrl/⌘+V 想贴的是文字;要图的话有「从剪贴板粘贴」
  /// 这个明确入口。从文件管理器复制的文件例外(见 [ClipboardContent.fromFile])。
  static Future<ClipboardImageBytes?> readImage({
    bool preferImage = false,
  }) async {
    try {
      final images = await readImages(preferImage: preferImage);
      return images.firstOrNull;
    } catch (e) {
      // 剪贴板里躺着的可能是「一张图」之外的东西(某些程序把原始像素块塞进来),
      // 读不出来就当没有,别把异常抛给粘贴动作。
      logd('[clipboard] 剪贴板里的图读不出来: $e');
      return null;
    }
  }

  /// Read one clipboard snapshot, including all files copied from a file manager.
  static Future<List<ClipboardImageBytes>> readImages({
    bool preferImage = false,
  }) async {
    final content = await read();
    if (!content.hasImage ||
        (!preferImage && content.hasText && !content.fromFile)) {
      return const [];
    }
    if (content.error != null) {
      throw FormatException(switch (content.error) {
        'too_many_images' => '一次最多粘贴 64 张图片',
        'clipboard_busy' => '剪贴板暂时被占用，请重试粘贴',
        'too_large' => '图片过大：单张最多 64 MB，一次最多 256 MB',
        _ => '无法读取剪贴板图片，请重新复制',
      });
    }
    if (content.images.isNotEmpty) {
      if (content.images.length > 64) {
        throw const FormatException('一次最多粘贴 64 张图片');
      }
      var total = 0;
      for (final image in content.images) {
        total += image.bytes.length;
        if (image.bytes.length > 64 * 1024 * 1024 ||
            total > 256 * 1024 * 1024) {
          throw const FormatException('图片过大：单张最多 64 MB，一次最多 256 MB');
        }
      }
      return content.images;
    }
    if (content.paths.isEmpty) return [await imageFromContent(content)];
    if (content.paths.length > 64) {
      throw const FormatException('一次最多粘贴 64 张图片');
    }
    final images = <ClipboardImageBytes>[];
    var total = 0;
    for (final path in content.paths) {
      final file = File(path);
      final size = await file.length();
      total += size;
      if (size <= 0 || size > 64 * 1024 * 1024 || total > 256 * 1024 * 1024) {
        throw const FormatException('图片过大：单张最多 64 MB，一次最多 256 MB');
      }
      final png = await ensurePng(await file.readAsBytes());
      if (png.length > 64 * 1024 * 1024) {
        throw const FormatException('图片过大：单张最多 64 MB');
      }
      images.add(ClipboardImageBytes(name: p.basename(path), bytes: png));
    }
    return images;
  }

  /// Decode bytes from an already-read snapshot without querying the clipboard again.
  static Future<ClipboardImageBytes> imageFromContent(
    ClipboardContent content,
  ) async {
    if (content.error != null) {
      throw FormatException(switch (content.error) {
        'too_many_images' => '一次最多粘贴 64 张图片',
        'clipboard_busy' => '剪贴板暂时被占用，请重试粘贴',
        'too_large' => '图片过大：单张最多 64 MB，一次最多 256 MB',
        _ => '无法读取剪贴板图片，请重新复制',
      });
    }
    final bytes = content.image;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('剪贴板中没有可读取的图片');
    }
    final png = await ensurePng(bytes, format: content.format);
    if (png.length > 64 * 1024 * 1024) {
      throw const FormatException('图片过大：单张最多 64 MB');
    }
    return ClipboardImageBytes(name: content.name, bytes: png);
  }

  /// 把 [bytes] 统一成 PNG:已经是 PNG 的原样返回(库里的作品都是 PNG,这条
  /// 路径不该有多余的解码开销),其余按**字节**判断后解码重编码。
  ///
  /// 为什么不照 [format] 走:那个字段是「图是从哪儿来的」(png / dib / file),
  /// 不是「这些字节长什么样」。原样信它、把 JPEG 的字节贴在「png」标签上交出去,
  /// 接收方会照着标签解,解出来是花的 —— 这里只认字节。
  static Future<Uint8List> ensurePng(Uint8List bytes, {String? format}) async {
    if (_isBmpHeader(bytes)) {
      // BMP 那份要先补上文件头才好解(裸 DIB 没有 BM 那 14 字节)。
      return compute(_toPng, wrapDibAsBmp(bytes));
    }
    if (_isPng(bytes)) return bytes;
    return compute(_toPng, bytes);
  }

  /// PNG → 裸 DIB(Windows 的 CF_DIB:去掉了 BMP 那 14 字节文件头)。
  static Future<Uint8List> _dibOf(Uint8List png) => compute(_toDib, png);
}

/// [DesktopClipboard.readImage] 的结果:PNG 字节 + 能拿到的原始文件名。
class ClipboardImageBytes {
  const ClipboardImageBytes({required this.bytes, this.name});

  final Uint8List bytes;
  final String? name;
}

/// [DesktopClipboard.readImage] 的默认返回名。
const kClipboardImageName = '剪贴板图片.png';

/// 打包冒烟用的开关,见 [runMacOsClipboardSmokeTest]。
const kMacOsClipboardSmokeTestEnvironment = 'PLANA_MACOS_CLIPBOARD_SMOKE_TEST';

/// 把一个几像素的 PNG 写进系统剪贴板再读回来,对不上就抛。
///
/// 只在 CI 的 macOS 打包校验里跑(`PLANA_MACOS_CLIPBOARD_SMOKE_TEST=1`)。
/// 验的不是 Dart 逻辑(那有单元测试),而是**原生通道真的在这个包里注册上了**:
/// Swift 文件没进 Xcode 工程、方法名对不上这类事,构建和启动都看不出问题,
/// 要等用户按 ⌘V 才发现 —— 那时候已经发出去了。会覆盖剪贴板内容,故只在 CI 跑。
Future<void> runMacOsClipboardSmokeTest() async {
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
  if (!await DesktopClipboard.writeImage(png)) {
    throw StateError('写入剪贴板失败(原生通道未注册?)');
  }
  final content = await DesktopClipboard.read();
  if (!content.hasImage) {
    throw StateError('刚写进去的图读不回来(原生通道未注册?)');
  }
  if (content.format != 'png') {
    throw StateError('剪贴板回包的格式不对: ${content.format}');
  }
  final decoded = img.decodeImage(content.image!);
  if (decoded == null || decoded.width != 2 || decoded.height != 2) {
    throw StateError('读回来的图不是写进去那张: ${decoded?.width}x${decoded?.height}');
  }
  final folder = await Directory.systemTemp.createTemp(
    'plana_clipboard_smoke_',
  );
  try {
    final textPng = Uint8List.fromList(
      img.encodePng(
        img.Image(width: 2, height: 2)
          ..textData = {
            'parameters': 'clipboard metadata\nSteps: 28, Seed: 123, Size: 2x2',
          },
      ),
    );
    final utf8Png = await writeImageMetadataPng(
      png,
      comment: {'prompt': '剪贴板元数据', 'seed': 123},
    );
    final files = [
      await File('${folder.path}/text.png').writeAsBytes(textPng),
      await File('${folder.path}/utf8.png').writeAsBytes(utf8Png),
      await File(
        '${folder.path}/image.jpg',
      ).writeAsBytes(img.encodeJpg(decoded)),
    ];
    Future<void> copyFiles(List<File> sources) async {
      final copied = await DesktopClipboard.channel.invokeMethod<bool>(
        'smokeCopyFiles',
        [for (final file in sources) file.path],
      );
      if (copied != true) throw StateError('无法创建 Finder 文件剪贴板样本');
    }

    await copyFiles(files);
    final images = await DesktopClipboard.readImages(preferImage: true);
    if (images.length != 3 ||
        images[0].name != 'text.png' ||
        images[1].name != 'utf8.png' ||
        !listEquals(images[0].bytes, textPng) ||
        !listEquals(images[1].bytes, utf8Png)) {
      throw StateError('Finder PNG 粘贴改变了原始字节或丢失生成元数据');
    }
    final converted = img.decodePng(images[2].bytes);
    if (converted == null || converted.width != 2 || converted.height != 2) {
      throw StateError('Finder JPG 粘贴没有正确转换为 PNG');
    }
    final invalid = await File(
      '${folder.path}/invalid.png',
    ).writeAsBytes([137, 80, 78, 71]);
    await copyFiles([files.first, invalid]);
    try {
      await DesktopClipboard.readImages(preferImage: true);
      throw StateError('Finder 粘贴接受了损坏 PNG');
    } on FormatException {
      // A bad file rejects the entire batch, without partial attachments.
    }
  } finally {
    await folder.delete(recursive: true);
  }
}

bool _isPng(Uint8List bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

bool _isBmpHeader(Uint8List bytes) =>
    bytes.length > 2 && bytes[0] == 0x42 && bytes[1] == 0x4D;

Uint8List _toPng(Uint8List bytes) {
  final decoded = img.decodeImage(bytes, frame: 0);
  if (decoded == null) throw const FormatException('剪贴板里的图片无法解码');
  return Uint8List.fromList(img.encodePng(decoded));
}

Uint8List _toDib(Uint8List png) {
  final decoded = img.decodeImage(png, frame: 0);
  if (decoded == null) throw const FormatException('剪贴板里的图片无法解码');
  // image.encodeBmp writes a V5/BI_BITFIELDS header even for 24-bit pixels.
  // Publish those pixels with a conventional 40-byte BI_RGB DIB instead.
  final bmp = img.encodeBmp(decoded.convert(numChannels: 3));
  final pixelOffset = ByteData.sublistView(bmp).getUint32(10, Endian.little);
  final pixels = Uint8List.sublistView(bmp, pixelOffset);
  final dib = Uint8List(40 + pixels.length);
  final header = ByteData.sublistView(dib);
  header
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, decoded.width, Endian.little)
    ..setInt32(8, decoded.height, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 24, Endian.little)
    ..setUint32(20, pixels.length, Endian.little);
  dib.setRange(40, dib.length, pixels);
  return dib;
}

/// 给裸 DIB 补一个 BMP 文件头,好交给 `image` 包解码。
///
/// Windows 剪贴板里给的是 CF_DIB —— 从 BITMAPINFOHEADER 开始,**没有** BMP 文件
/// 开头那 14 字节。补的时候 bfOffBits 不能照抄「14 + 头大小」:调色板(≤8 位色)
/// 和 40 字节头后面挂的三色掩码(BI_BITFIELDS)都得算进去,少了这块,像素数据
/// 的起点就会偏,解出来整张图是错位的。
///
/// 已经带 "BM" 文件头的原样返回。
Uint8List wrapDibAsBmp(Uint8List dib) {
  if (_isBmpHeader(dib)) return dib;
  if (dib.length < 12 || dib.length > 64 * 1024 * 1024) {
    throw const FormatException('DIB 头不完整或图片过大');
  }
  final headerSize = _u32(dib, 0);
  if (![12, 40, 52, 56, 108, 124].contains(headerSize) ||
      headerSize > dib.length) {
    throw const FormatException('不支持或不完整的 DIB 头');
  }
  final core = headerSize == 12;
  final width = core ? _u16(dib, 4) : _i32(dib, 4);
  final signedHeight = core ? _u16(dib, 6) : _i32(dib, 8);
  final height = signedHeight.abs();
  final planes = _u16(dib, core ? 8 : 12);
  final bitCount = _u16(dib, core ? 10 : 14);
  final compression = core ? 0 : _u32(dib, 16);
  if (width <= 0 ||
      height <= 0 ||
      width > 32768 ||
      height > 32768 ||
      planes != 1 ||
      ![1, 4, 8, 16, 24, 32].contains(bitCount) ||
      ![0, 3, 6].contains(compression) ||
      (compression != 0 && bitCount != 16 && bitCount != 32)) {
    throw const FormatException('DIB 尺寸或格式无效');
  }
  final colorsUsed = core ? 0 : _u32(dib, 32);
  final paletteEntries = colorsUsed != 0
      ? colorsUsed
      : bitCount <= 8
      ? 1 << bitCount
      : 0;
  if (paletteEntries > 256 ||
      (bitCount <= 8 && paletteEntries > 1 << bitCount)) {
    throw const FormatException('DIB 调色板无效');
  }
  final masks = headerSize == 40 && compression != 0
      ? (compression == 6 ? 16 : 12)
      : 0;
  final pixelOffset = headerSize + paletteEntries * (core ? 3 : 4) + masks;
  final stride = ((width * bitCount + 31) ~/ 32) * 4;
  if (pixelOffset + stride * height > dib.length) {
    throw const FormatException('DIB 像素数据不完整');
  }
  final offset = 14 + pixelOffset;
  final out = Uint8List(14 + dib.length);
  final header = ByteData.sublistView(out);
  header
    ..setUint8(0, 0x42) // 'B'
    ..setUint8(1, 0x4D) // 'M'
    ..setUint32(2, out.length, Endian.little)
    ..setUint32(10, offset, Endian.little);
  out.setRange(14, out.length, dib);
  return out;
}

int _u16(Uint8List bytes, int at) =>
    ByteData.sublistView(bytes).getUint16(at, Endian.little);

int _u32(Uint8List bytes, int at) =>
    ByteData.sublistView(bytes).getUint32(at, Endian.little);

int _i32(Uint8List bytes, int at) =>
    ByteData.sublistView(bytes).getInt32(at, Endian.little);
