import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/desktop_image_save.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/gallery/widgets/result_canvas.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

class _FolderPicker extends FilePicker {
  String? directory;
  int calls = 0;
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
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  late _FolderPicker picker;
  late ResultImage result;
  Finder key(String value) => find.byKey(ValueKey(value));

  setUp(() {
    temp = Directory.systemTemp.createTempSync('plana_manual_save_');
    stores = AppStores.ephemeral();
    picker = _FolderPicker()..directory = temp.path;
    FilePicker.platform = picker;
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        prefsStoreProvider.overrideWithValue(PrefsStore.emptyForTest(temp)),
      ],
    );
    result = ResultImage(
      id: 'gen24',
      width: 32,
      height: 48,
      seed: 123,
      bytes: Uint8List.fromList(
        img.encodePng(img.Image(width: 32, height: 48)),
      ),
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    temp.deleteSync(recursive: true);
  });

  test(
    'repeated and concurrent manual saves keep every file, preserve bytes and honor format',
    () async {
      final files = await Future.wait([
        for (var i = 0; i < 3; i++)
          saveDesktopImage(
            directory: temp.path,
            image: result,
            bytes: result.bytes!,
            settings: const SaveSettings(),
          ),
      ]);
      expect(files.map((f) => f.path).toSet().length, 3);
      for (final file in files) {
        expect(await file.readAsBytes(), result.bytes);
      }
      final jpg = await saveDesktopImage(
        directory: temp.path,
        image: result,
        bytes: result.bytes!,
        settings: const SaveSettings(format: SaveFormat.jpg),
      );
      expect(jpg.path.endsWith('.jpg'), isTrue);
      expect(img.decodeJpg(await jpg.readAsBytes()), isNotNull);
      expect(temp.listSync().any((f) => f.path.endsWith('.part')), isFalse);
      await expectLater(
        saveDesktopImage(
          directory: '${temp.path}/missing',
          image: result,
          bytes: result.bytes!,
          settings: const SaveSettings(),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  Future<void> mount(WidgetTester tester, {bool empty = false}) async {
    tester.view.physicalSize = const Size(360, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                ResultActions(
                  result: empty ? null : result,
                  canvasBar: CanvasActionBar.top,
                ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(
                        key: ValueKey('test-canvas'),
                        color: Colors.white,
                      ),
                      if (!empty && result.hasInpaintComparison)
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: ResultActions(
                            result: result,
                            canvasBar: CanvasActionBar.comparison,
                          ),
                        ),
                    ],
                  ),
                ),
                ResultActions(
                  result: empty ? null : result,
                  canvasBar: CanvasActionBar.bottom,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    stores.flushNow();
  }

  Future<void> drain(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'top and bottom actions fit the minimum canvas width; a remembered folder saves without another picker',
    (tester) async {
      await mount(tester);
      expect(tester.takeException(), isNull);
      final toolArea = tester.getRect(key('canvas-primary-tools'));
      expect(toolArea.center.dx, closeTo(180, .01));
      expect(key('canvas-use-base'), findsOneWidget);
      expect(key('canvas-use-base').hitTestable(), findsOneWidget);
      expect(
        tester.getRect(key('canvas-top-actions')).bottom,
        lessThanOrEqualTo(tester.getRect(key('test-canvas')).top),
      );
      expect(
        tester.getRect(key('canvas-bottom-actions')).top,
        greaterThanOrEqualTo(tester.getRect(key('test-canvas')).bottom),
      );
      await tester.tap(key('canvas-save-folder'));
      await drain(
        tester,
        () => container.read(desktopSaveDirectoryProvider) == temp.path,
      );
      expect(picker.calls, 1);
      for (var i = 1; i <= 2; i++) {
        await tester.tap(key('canvas-save'));
        await drain(
          tester,
          () =>
              temp.listSync().where((f) => f.path.endsWith('.png')).length ==
                  i &&
              tester.widget<OutlinedButton>(key('canvas-save')).onPressed !=
                  null,
        );
      }
      expect(picker.calls, 1);
      final prefs = await tester.runAsync(
        () => PrefsStore.open(temp, legacyRead: (_) async => null),
      );
      expect(prefs!.get(DesktopSaveDirectory.preferenceKey), temp.path);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'canceling the first folder selection saves nothing and empty canvas disables image actions',
    (tester) async {
      picker.directory = null;
      await mount(tester);
      await tester.tap(key('canvas-save'));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(container.read(desktopSaveDirectoryProvider), isNull);
      expect(temp.listSync(), isEmpty);
      await mount(tester, empty: true);
      expect(
        tester.widget<TextButton>(key('canvas-inpaint')).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextButton>(key('canvas-use-base')).onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(key('canvas-regenerate')).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextButton>(key('canvas-save-folder')).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  Future<void> comparisonResult(
    WidgetTester tester, {
    String id = 'gen25',
  }) async {
    final mask = MaskGrid(32, 48)..paintDot(12, 12, 8);
    final png = await tester.runAsync(() => maskToPng(mask));
    result = ResultImage(
      id: id,
      width: 32,
      height: 48,
      seed: 123,
      badge: ResultBadge.inpaint,
      bytes: result.bytes,
      input: GenerateState.initial().copyWith(
        inpaint: InpaintJob(
          image: result.bytes!,
          mask: png!,
          strength: .7,
          grid: mask.encode(),
        ),
      ),
    );
  }

  testWidgets(
    'old result button holds with mouse or keyboard and survives minimum width',
    (tester) async {
      await comparisonResult(tester);
      await mount(tester);
      expect(find.text('旧的'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final oldButton = tester.getRect(key('canvas-compare-old'));
      final canvas = tester.getRect(key('test-canvas'));
      expect(oldButton.right, closeTo(canvas.right - 12, .01));
      expect(oldButton.bottom, closeTo(canvas.bottom - 12, .01));
      expect(
        oldButton.bottom,
        lessThan(tester.getRect(key('canvas-regenerate')).top),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(key('canvas-compare-old')),
        kind: ui.PointerDeviceKind.mouse,
      );
      await drain(tester, () => container.read(comparePreviewProvider) != null);
      expect(container.read(comparePreviewProvider)?.resultId, 'gen25');
      await gesture.up();
      await tester.pump();
      expect(container.read(comparePreviewProvider), isNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await drain(tester, () => container.read(comparePreviewProvider) != null);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(container.read(comparePreviewProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'released or navigated comparison cannot appear after asynchronous loading',
    (tester) async {
      await comparisonResult(tester);
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(key('canvas-compare-old')),
      );
      await gesture.up();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pumpAndSettle();
      expect(container.read(comparePreviewProvider), isNull);

      final held = await tester.startGesture(
        tester.getCenter(key('canvas-compare-old')),
      );
      await drain(tester, () => container.read(comparePreviewProvider) != null);
      await comparisonResult(tester, id: 'gen26');
      await mount(tester);
      expect(container.read(comparePreviewProvider), isNull);
      await held.up();
      await tester.pump();
      expect(container.read(comparePreviewProvider), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
