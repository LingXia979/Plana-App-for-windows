import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/import/image_metadata.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/tools/metadata_tool_page.dart';

class _Picker extends FilePicker {
  late Uint8List bytes;
  String? directory;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(name: 'sample.png', size: bytes.length, bytes: bytes),
  ]);
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => directory;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late FilePicker original;
  late _Picker picker;
  late Directory temp;
  late AppStores stores;
  setUpAll(() async {
    FilePicker.platform = _Picker();
    if (Platform.isWindows) {
      await (FontLoader('MaterialIcons')..addFont(
            File(
              r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader('Microsoft YaHei')..addFont(
            File(
              r'C:\Windows\Fonts\msyh.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  setUp(() async {
    original = FilePicker.platform;
    picker = _Picker();
    picker.bytes = await writeCustomMetadataPng(
      await File('assets/app_icon.png').readAsBytes(),
      '1girl, white hair, cherry blossoms',
    );
    FilePicker.platform = picker;
    temp = Directory.systemTemp.createTempSync('plana_metadata_ui_');
    stores = AppStores.ephemeral();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      (_) async =>
          throw StateError('Desktop export must not use the phone gallery'),
    );
  });
  tearDown(() async {
    stores.flushNow();
    FilePicker.platform = original;
    // FileImage decodes finish off-thread; Windows may briefly retain a read
    // handle after the last thumbnail unmounts. Only retry that sharing error.
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 32 || attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('gal'),
      null,
    );
  });

  final capture = GlobalKey();
  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1120, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopModeProvider.overrideWithValue(true),
          appStoresProvider.overrideWithValue(stores),
        ],
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                key: PageStorageKey('desktop-tools-scroll'),
                padding: EdgeInsets.all(24),
                child: MetadataToolView(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> tapIO(WidgetTester tester, Finder target, {File? output}) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(target);
      if (output != null) {
        for (
          var i = 0;
          i < 100 && (!output.existsSync() || output.lengthSync() == 0);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    await tester.ensureVisible(find.text('单张处理'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'build/windows-validation/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'batch strip leaves vertical wheel to the page and supports Shift wheel, drag and arrows',
    (tester) async {
      final input = Directory('${temp.path}/strip')..createSync();
      for (var i = 0; i < 20; i++) {
        File(
          '${input.path}/image${i.toString().padLeft(2, '0')}.png',
        ).writeAsBytesSync(picker.bytes);
      }
      await mount(tester);
      // Load fixture thumbnails outside FakeAsync before scrolling exposes
      // them, so file reads can finish even if a card immediately unmounts.
      await tester.runAsync(() async {
        final context = tester.element(find.byType(MetadataToolView));
        for (final file in input.listSync().whereType<File>()) {
          if (!context.mounted) return;
          await precacheImage(
            ResizeImage(FileImage(file), width: 240),
            context,
          );
        }
      });
      await tester.tap(find.text('批量处理'));
      await tester.pumpAndSettle();
      picker.directory = input.path;
      await tapIO(tester, key('metadata-browse-input'));
      final scrollbar = key('metadata-preview-scrollbar');
      final controller = tester.widget<Scrollbar>(scrollbar).controller!;
      expect(controller.offset, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.offset, 148);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一张（→）'));
      await tester.pumpAndSettle();
      expect(controller.offset, 148);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.offset, 296);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(controller.offset, 148);

      controller.jumpTo(0);
      await tester.pumpAndSettle();
      final rect = tester.getRect(scrollbar);
      final thumb = await tester.startGesture(
        Offset(rect.left + 30, rect.bottom - 4),
        kind: ui.PointerDeviceKind.mouse,
      );
      await thumb.moveBy(const Offset(200, 0));
      await tester.pump();
      await thumb.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(300));

      controller.jumpTo(0);
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(
        rect.center,
        kind: ui.PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(-20, 0));
      await tester.pump();
      await drag.moveBy(const Offset(-180, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await drag.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(100));
      expect(find.byType(Dialog), findsNothing);
      final beforeWheel = controller.offset;
      final page = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const PageStorageKey('desktop-tools-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final beforePageWheel = page.pixels;
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: rect.center,
          scrollDelta: const Offset(0, 80),
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, beforeWheel);
      expect(page.pixels, greaterThan(beforePageWheel));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final pageBeforeShift = page.pixels;
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(scrollbar),
          scrollDelta: const Offset(0, 80),
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(beforeWheel + 80, .1));
      expect(page.pixels, pageBeforeShift);
      expect(find.text('图片预览 · 20 张 · 已选 20'), findsOneWidget);

      await tester.tap(key('metadata-input-directory'));
      await tester.pumpAndSettle();
      final beforeEditing = controller.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(controller.offset, beforeEditing);
      await screenshot(tester, 'windows17-metadata-strip');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // Images exposed by scrolling may still be finishing their file reads.
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 50 && PaintingBinding.instance.imageCache.pendingImageCount > 0;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
    },
  );

  testWidgets('advanced parameters survive reopening and resizing', (
    tester,
  ) async {
    await mount(tester);
    final advanced = find.text('更多参数');
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final schedule = key('metadata-field-noise_schedule');
    await tester.ensureVisible(schedule);
    await tester.enterText(schedule, 'karras');
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<TextField>(schedule).controller!.text, 'karras');
    expect(tester.getSize(schedule).height, lessThan(80));
    tester.view.physicalSize = const Size(540, 650);
    await tester.pumpAndSettle();
    await tester.ensureVisible(schedule);
    expect(tester.widget<TextField>(schedule).controller!.text, 'karras');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'single image reads hidden parameters, retains edits across tabs and exports a copy to the chosen folder',
    (tester) async {
      await mount(tester);
      await tapIO(tester, key('metadata-select-image'));
      expect(find.text('完整信息与导入'), findsOneWidget);
      expect(
        tester.widget<TextField>(key('metadata-field-prompt')).controller!.text,
        '1girl, white hair, cherry blossoms',
      );
      await tester.enterText(key('metadata-field-prompt'), '樱花, 猫娘');
      await tester.enterText(key('metadata-field-uc'), 'bad quality');
      await tester.ensureVisible(key('metadata-field-seed'));
      await tester.enterText(key('metadata-field-seed'), '4294967295');
      await tester.ensureVisible(find.text('批量处理'));
      await tester.tap(find.text('批量处理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单张处理'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('metadata-field-prompt')).controller!.text,
        '樱花, 猫娘',
      );
      await tapIO(tester, key('metadata-write-single'));
      expect(temp.listSync(), isEmpty);
      picker.directory = temp.path;
      await tapIO(tester, key('metadata-browse-output'));
      final output = File('${temp.path}/sample_custom.png');
      await tapIO(tester, key('metadata-write-single'), output: output);
      expect(find.text('已导出 1 张'), findsOneWidget);
      expect(find.text('打开输出文件夹'), findsOneWidget);
      await tester.runAsync(() async {
        final result = (await extractImageMetadata(
          await output.readAsBytes(),
        ))!;
        expect(result.prompt, '樱花, 猫娘');
        expect(result.negativePrompt, 'bad quality');
        expect(result.seed, '4294967295');
        expect(
          (await extractImageMetadata(picker.bytes))!.prompt,
          '1girl, white hair, cherry blossoms',
        );
      });
      await screenshot(tester, 'windows14-metadata-single');
      tester.view.physicalSize = const Size(540, 650);
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('metadata-write-single'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'batch previews sit below input and above output, and exports use current single form values',
    (tester) async {
      final input = Directory('${temp.path}/input')..createSync();
      final output = Directory('${temp.path}/output')..createSync();
      final a = File('${input.path}/a.png')..writeAsBytesSync(picker.bytes);
      File('${input.path}/b.png').writeAsBytesSync(picker.bytes);
      await mount(tester);
      await tester.enterText(key('metadata-field-prompt'), 'batch prompt');
      await tester.enterText(key('metadata-field-uc'), 'batch negative');
      await tester.ensureVisible(find.text('批量处理'));
      await tester.tap(find.text('批量处理'));
      await tester.pumpAndSettle();
      picker.directory = input.path;
      await tapIO(tester, key('metadata-browse-input'));
      expect(key('metadata-thumbnail-a.png'), findsOneWidget);
      expect(key('metadata-thumbnail-b.png'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RawImage>(
              find.descendant(
                of: key('metadata-thumbnail-a.png'),
                matching: find.byType(RawImage),
              ),
            )
            .image,
        isNotNull,
      );
      expect(
        tester.getRect(key('metadata-input-directory')).bottom,
        lessThan(tester.getRect(key('metadata-batch-previews')).top),
      );
      expect(
        tester.getRect(key('metadata-batch-previews')).bottom,
        lessThan(tester.getRect(key('metadata-output-directory')).top),
      );
      expect(find.textContaining('metadata_stripped'), findsOneWidget);
      picker.directory = output.path;
      await tapIO(tester, key('metadata-browse-output'));
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.textContaining('metadata_edited'), findsOneWidget);
      await screenshot(tester, 'windows14-metadata-batch');
      final exported = File('${output.path}/metadata_edited/b_custom.png');
      await tapIO(tester, key('metadata-start-batch'), output: exported);
      expect(find.text('已导出 2 张'), findsOneWidget);
      await tester.runAsync(() async {
        final meta = (await extractImageMetadata(
          await exported.readAsBytes(),
        ))!;
        expect(meta.prompt, 'batch prompt');
        expect(meta.negativePrompt, 'batch negative');
        expect(await a.readAsBytes(), picker.bytes);
      });
      tester.view.physicalSize = const Size(540, 650);
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('metadata-batch-previews'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'history picker reads a single image and appends deduplicated batches without changing the gallery',
    (tester) async {
      final memoryImage = ResultImage(
        id: 'gen101',
        width: 512,
        height: 512,
        seed: 1,
        bytes: picker.bytes,
      );
      const diskImage = ResultImage(
        id: 'gen102',
        width: 512,
        height: 512,
        seed: 2,
      );
      stores.gallery.initialResults = [memoryImage, diskImage];
      stores.gallery.initialSelectedId = diskImage.id;
      final source = stores.gallery.imageFileForPreview(diskImage.id);
      source.parent.createSync(recursive: true);
      source.writeAsBytesSync(picker.bytes);
      await mount(tester);
      await tapIO(tester, key('metadata-history-single'));
      expect(key('history-image-picker'), findsOneWidget);
      await tapIO(tester, key('history-image-gen101'));
      expect(
        tester.widget<TextField>(key('metadata-field-prompt')).controller!.text,
        '1girl, white hair, cherry blossoms',
      );
      expect(find.text('gen101.png'), findsOneWidget);
      await tester.tap(find.text('批量处理'));
      await tester.pumpAndSettle();
      await tapIO(tester, key('metadata-history-batch'));
      await tester.tap(key('history-image-gen101'));
      await tester.tap(key('history-image-gen102'));
      await tester.pumpAndSettle();
      await tapIO(tester, key('history-confirm-selection'));
      expect(key('metadata-thumbnail-gen101.png'), findsOneWidget);
      expect(key('metadata-thumbnail-gen102.png'), findsOneWidget);
      expect(find.text('图片预览 · 2 张 · 已选 2'), findsOneWidget);
      await tapIO(tester, key('metadata-history-batch'));
      await tester.tap(key('history-image-gen101'));
      await tester.pumpAndSettle();
      await tapIO(tester, key('history-confirm-selection'));
      expect(find.text('图片预览 · 2 张 · 已选 2'), findsOneWidget);
      // History-only batches must ask where to export; cancel keeps the selection.
      picker.directory = null;
      await tapIO(tester, key('metadata-start-batch'));
      expect(find.text('已导出 2 张'), findsNothing);
      expect(find.text('图片预览 · 2 张 · 已选 2'), findsOneWidget);
      picker.directory = temp.path;
      final output = File('${temp.path}/metadata_stripped/gen102_clean.png');
      await tapIO(tester, key('metadata-start-batch'), output: output);
      expect(find.text('已导出 2 张'), findsOneWidget);
      await tester.runAsync(() async {
        expect(await extractImageMetadata(await output.readAsBytes()), isNull);
        expect(await source.readAsBytes(), picker.bytes);
        expect(
          await stores.gallery.imageFileForPreview(memoryImage.id).exists(),
          isFalse,
        );
        expect(
          await File(
            '${temp.path}/metadata_stripped/gen101_clean.png',
          ).exists(),
          isTrue,
        );
      });
      // Folder scans and refreshes keep the images appended from history.
      final folder = Directory('${temp.path}/input')..createSync();
      File('${folder.path}/folder.png').writeAsBytesSync(picker.bytes);
      picker.directory = folder.path;
      await tapIO(tester, key('metadata-browse-input'));
      expect(find.text('图片预览 · 3 张 · 已选 3'), findsOneWidget);
      expect(
        ProviderScope.containerOf(
          tester.element(key('desktop-metadata-tool')),
          listen: false,
        ).read(galleryProvider).selectedId,
        diskImage.id,
      );
      await screenshot(tester, 'windows15-metadata-history-batch');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
