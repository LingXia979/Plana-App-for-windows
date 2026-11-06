import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/platform/image_transfer.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/gallery/result_clipboard.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/import/image_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late Uint8List original;
  late List<MethodCall> calls;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('plana_transfer_test_');
    calls = [];
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, (call) async {
      calls.add(call);
      return call.method == 'write' ? true : null;
    });
    final pixels = img.Image(width: 128, height: 128, numChannels: 4);
    for (var y = 0; y < 128; y++) {
      for (var x = 0; x < 128; x++) {
        pixels.setPixelRgba(x, y, x * 2, y * 2, (x * y) % 256, 255);
      }
    }
    final hidden = await writeCustomMetadataPng(
      Uint8List.fromList(img.encodePng(pixels)),
      'original hidden prompt',
    );
    final image = img.decodePng(hidden)!;
    image.textData = {
      'Comment': jsonEncode({
        'prompt': 'original visible prompt',
        'uc': 'old negative',
      }),
    };
    original = Uint8List.fromList(img.encodePng(image));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, null);
    debugDefaultTargetPlatformOverride = null;
    temp.deleteSync(recursive: true);
  });

  Future<PreparedImageTransfer> prepare(SaveSettings options) =>
      prepareImageTransfer(
        load: () async => original,
        settings: Future.value(options),
        name: '猫猫_123',
      );

  for (final mode in SaveMeta.values) {
    test(
      'PNG ${mode.name}: file and image clipboard honor the same metadata policy',
      () async {
        final export = await prepare(
          SaveSettings(meta: mode, customPrompt: '公开的自定义提示词'),
        );
        final file = await export.file(temporaryDirectory: temp);
        expect(file.path, endsWith('猫猫_123.png'));
        expect(await file.readAsBytes(), export.bytes);
        expect(
          await DesktopClipboard.writeImage(export.bytes, filePath: file.path),
          isTrue,
        );
        final args = calls.last.arguments as Map;
        expect(args['filePath'], file.path);
        expect(args['image'], export.bytes);
        expect(
          img.decodeImage(wrapDibAsBmp(args['dib'] as Uint8List))!.width,
          128,
        );
        if (mode == SaveMeta.original) {
          expect(
            export.bytes,
            original,
            reason: 'PNG original must be byte-exact',
          );
        } else {
          final meta = await extractImageMetadata(export.bytes);
          if (mode == SaveMeta.clean) {
            expect(
              meta,
              isNull,
              reason: 'remove visible text AND alpha steganography',
            );
          } else {
            expect(meta!.prompt, '公开的自定义提示词');
            expect(meta.negativePrompt, isEmpty);
          }
          expect(
            utf8.decode(export.bytes, allowMalformed: true),
            isNot(contains('original visible')),
          );
        }
        expect(
          (await extractImageMetadata(original))!.prompt,
          'original visible prompt',
        );
      },
    );
  }

  test(
    'JPG quality applies to file; image/bitmap fallback derive from that JPG',
    () async {
      final low = await prepare(
        const SaveSettings(format: SaveFormat.jpg, quality: .1),
      );
      final high = await prepare(
        const SaveSettings(format: SaveFormat.jpg, quality: 1),
      );
      expect(low.bytes, isNot(high.bytes));
      expect(low.bytes.length, lessThan(high.bytes.length));
      final file = await low.file(temporaryDirectory: temp);
      expect(file.path, endsWith('.jpg'));
      expect(await file.readAsBytes(), low.bytes);
      expect(img.decodeJpg(low.bytes), isNotNull);
      expect(await extractImageMetadata(low.bytes), isNull);
      expect(
        await DesktopClipboard.writeImage(low.bytes, filePath: file.path),
        isTrue,
      );
      final args = calls.last.arguments as Map;
      final png = img.decodePng(args['image'] as Uint8List)!;
      final jpg = img.decodeJpg(low.bytes)!;
      final dib = img.decodeImage(wrapDibAsBmp(args['dib'] as Uint8List))!;
      expect(png.getBytes(), jpg.getBytes());
      expect(dib.getPixel(35, 45).r, jpg.getPixel(35, 45).r);
    },
  );

  test(
    'loading settings waits for persisted policy before reading/exporting',
    () async {
      final options = Completer<SaveSettings>();
      var reads = 0;
      final future = prepareImageTransfer(
        settings: options.future,
        load: () async {
          reads++;
          return original;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads, 0);
      options.complete(const SaveSettings(meta: SaveMeta.clean));
      expect(await extractImageMetadata((await future).bytes), isNull);
    },
  );

  test(
    'sequential and concurrent exports do not invalidate earlier files',
    () async {
      final exports = await Future.wait([
        prepare(const SaveSettings()),
        prepare(const SaveSettings()),
      ]);
      final files = await Future.wait([
        for (final export in exports) export.file(temporaryDirectory: temp),
      ]);
      expect(files[0].path, isNot(files[1].path));
      expect(await files[0].readAsBytes(), original);
      expect(await files[1].readAsBytes(), original);
      expect(
        (await exports[0].file(temporaryDirectory: temp)).path,
        files[0].path,
      );
    },
  );

  test(
    'a superseded clipboard write stops after asynchronous conversion',
    () async {
      var current = true;
      final write = DesktopClipboard.writeImage(
        original,
        stillCurrent: () => current,
      );
      current = false;
      expect(await write, isFalse);
      expect(calls.where((call) => call.method == 'write'), isEmpty);
    },
  );

  test(
    'failed export never falls back to source metadata or a source path',
    () async {
      await expectLater(
        prepareImageTransfer(
          load: () async => Uint8List.fromList([1, 2, 3]),
          settings: Future.value(const SaveSettings(meta: SaveMeta.clean)),
        ),
        throwsA(anything),
      );
      await expectLater(
        prepareImageTransfer(
          load: () async => null,
          settings: Future.value(const SaveSettings()),
        ),
        throwsFormatException,
      );
      expect(calls.where((call) => call.method == 'write'), isEmpty);
    },
  );

  test(
    'cache sweep preserves clipboard, fresh files and unrelated/nested folders',
    () async {
      final root = Directory('${temp.path}/cache')..createSync();
      File fixture(String folder) {
        final dir = Directory('${root.path}/$folder')..createSync();
        return File('${dir.path}/sample.png')..writeAsBytesSync(original);
      }

      final old = fixture('transfer_old');
      final clipboard = fixture('transfer_clipboard');
      final fresh = fixture('transfer_fresh');
      final unrelated = fixture('other_app');
      final nested = fixture('transfer_nested');
      Directory('${nested.parent.path}/subfolder').createSync();
      final future = DateTime.now().add(const Duration(days: 10));
      fresh.setLastModifiedSync(future);
      await sweepImageTransferCache(
        root,
        now: future,
        protectedPaths: [clipboard.path],
      );
      expect(old.existsSync(), isFalse);
      for (final file in [clipboard, fresh, unrelated, nested]) {
        expect(file.existsSync(), isTrue);
      }
    },
  );
}
