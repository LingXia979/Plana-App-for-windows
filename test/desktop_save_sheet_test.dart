import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/desktop_image_save.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/import/image_metadata.dart';

import 'support/pump_until.dart';

class _FolderPicker extends FilePicker {
  String? directory;
  var calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls++;
    return directory;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late AppStores stores;
  late ProviderContainer container;
  late _FolderPicker picker;
  late ResultImage image;
  final galCalls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final platforms = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
  });

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('plana_save_sheet_');
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    picker = _FolderPicker()..directory = folder.path;
    FilePicker.platform = picker;
    galCalls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('gal'), (
      call,
    ) async {
      galCalls.add(call.method);
      return call.method == 'hasAccess' || call.method == 'requestAccess'
          ? true
          : null;
    });
    final png = img.Image(width: 128, height: 128, numChannels: 3)
      ..textData = {
        'Source': 'NovelAI Diffusion V4.5',
        'Comment': jsonEncode({
          'prompt': 'old prompt',
          'width': 128,
          'height': 128,
          'seed': 123,
        }),
      };
    for (final pixel in png) {
      pixel.setRgb(pixel.x * 2, pixel.y * 2, (pixel.x + pixel.y) % 256);
    }
    image = ResultImage(
      id: 'gen1',
      width: 128,
      height: 128,
      seed: 123,
      bytes: Uint8List.fromList(img.encodePng(png)),
    );
    await container.read(saveSettingsProvider.future);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(const MethodChannel('gal'), null);
    container.dispose();
    stores.flushNow();
    await folder.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ResultActions(
                result: image,
                canvasBar: CanvasActionBar.bottom,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.byKey(const ValueKey('canvas-save')));
    await tester.pumpAndSettle();
  }

  Future<void> finishSave(WidgetTester tester, String filename) async {
    await pumpUntil(
      tester,
      () => find.text('单次保存').evaluate().isEmpty,
      reason: 'Image save must finish before dismissing its sheet',
    );
    await tester.pumpAndSettle();
    expect(find.text('单次保存'), findsNothing);
    expect(find.text('已保存到 ${folder.path}/$filename'), findsOneWidget);
    expect(galCalls, isEmpty);
    expect(
      folder.listSync().whereType<File>().map((f) => f.uri.pathSegments.last),
      [filename],
    );
  }

  testWidgets(
    'one-off PNG uses the selected folder and its metadata choice',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(desktopSaveDirectoryProvider.notifier)
            .select(folder.path),
      );
      await open(tester);
      expect(find.text('plana_gen1_123.png'), findsOneWidget);
      await tester.tap(find.text('清除生成信息'));
      await tester.pump();
      await tester.tap(find.text('单次保存'));
      await finishSave(tester, 'plana_gen1_123.png');
      final bytes = await tester.runAsync(
        () => File('${folder.path}/plana_gen1_123.png').readAsBytes(),
      );
      expect(await tester.runAsync(() => extractImageMetadata(bytes!)), isNull);
      expect(picker.calls, 0);
      expect(container.read(saveSettingsProvider).value, const SaveSettings());
      await tester.pumpWidget(const SizedBox());
    },
    variant: platforms,
  );

  testWidgets(
    'one-off JPG chooses a folder and uses the selected quality',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('JPG 有损'));
      await tester.pump();
      tester.widget<Slider>(find.byType(Slider)).onChanged!(40);
      await tester.pump();
      await tester.tap(find.text('单次保存'));
      await finishSave(tester, 'plana_gen1_123.jpg');
      expect(picker.calls, 1);
      expect(container.read(desktopSaveDirectoryProvider), folder.path);
      final bytes = await tester.runAsync(
        () => File('${folder.path}/plana_gen1_123.jpg').readAsBytes(),
      );
      final expected = img.encodeJpg(img.decodePng(image.bytes!)!, quality: 40);
      expect(bytes, expected);
      expect(img.decodeJpg(bytes!)!.width, 128);
      expect(container.read(saveSettingsProvider).value, const SaveSettings());
      await tester.pumpWidget(const SizedBox());
    },
    variant: platforms,
  );

  testWidgets(
    'cancelled folder selection keeps the sheet available for retry',
    (tester) async {
      picker.directory = null;
      await open(tester);
      await tester.tap(find.text('单次保存'));
      await tester.pumpAndSettle();
      expect(folder.listSync(), isEmpty);
      expect(galCalls, isEmpty);
      expect(find.text('单次保存'), findsOneWidget);
      expect(container.read(desktopSaveDirectoryProvider), isNull);
      picker.directory = folder.path;
      await tester.tap(find.text('单次保存'));
      await finishSave(tester, 'plana_gen1_123.png');
      expect(picker.calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
