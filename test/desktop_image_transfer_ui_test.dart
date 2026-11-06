import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/features/gallery/image_transfer_button.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';
import 'package:plana_app/features/import/image_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  late ResultImage result;
  late List<MethodCall> calls;
  var selections = 0, opens = 0;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('plana_transfer_ui_');
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        prefsStoreProvider.overrideWithValue(PrefsStore.emptyForTest(temp)),
      ],
    );
    final image = img.Image(width: 128, height: 128, numChannels: 4)
      ..clear(img.ColorRgba8(20, 120, 180, 255))
      ..textData = {'Comment': '{"prompt":"private source prompt"}'};
    result = ResultImage(
      id: 'transfer',
      seed: 321,
      width: 128,
      height: 128,
      bytes: Uint8List.fromList(img.encodePng(image)),
    );
    selections = opens = 0;
    calls = [];
    messenger.setMockMethodCallHandler(paths, (_) async => temp.path);
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, (call) async {
      calls.add(call);
      if (call.method == 'write') return true;
      if (call.method == 'startDrag') return 'cancelled';
      return null;
    });
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, null);
    temp.deleteSync(recursive: true);
  });
  void windowsTest(String name, WidgetTesterCallback body) => testWidgets(
    name,
    body,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  Future<void> mount(
    WidgetTester tester, {
    Widget? child,
    SaveSettings settings = const SaveSettings(),
  }) async {
    await tester.runAsync(() async {
      await container.read(saveSettingsProvider.future);
      await container
          .read(saveSettingsProvider.notifier)
          .patch((_) => settings);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child:
                  child ??
                  SizedBox(
                    width: 200,
                    height: 240,
                    child: GalleryImageTile(
                      result: result,
                      onTap: () => opens++,
                      onLongPress: (_) => selections++,
                      onSecondaryTap: (_) {},
                      mouseDragSelect: true,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 5));
      if (i >= 3 &&
          calls.any(
            (call) => call.method == 'write' || call.method == 'startDrag',
          )) {
        break;
      }
    }
  }

  Finder getHandle() =>
      find.byKey(const ValueKey('gallery-image-transfer-transfer'));
  Future<TestGesture> hover(WidgetTester tester) async {
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(
      location: tester.getCenter(find.byType(GalleryImageTile)),
    );
    await tester.pump();
    return pointer;
  }

  windowsTest(
    'gallery hover copy applies persisted clean policy to file and PNG',
    (tester) async {
      await mount(tester, settings: const SaveSettings(meta: SaveMeta.clean));
      final pointer = await hover(tester);
      await tester.tap(getHandle());
      await settle(tester);
      final args =
          calls.singleWhere((c) => c.method == 'write').arguments as Map;
      await tester.runAsync(() async {
        final file = await File(args['filePath'] as String).readAsBytes();
        expect(file, args['image']);
        expect(await extractImageMetadata(file), isNull);
        expect(
          (await extractImageMetadata(result.bytes!))!.prompt,
          'private source prompt',
        );
      });
      expect((selections, opens), (0, 0));
      await pointer.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest(
    'gallery transfer handle exports JPG without starting range selection',
    (tester) async {
      await mount(
        tester,
        settings: const SaveSettings(format: SaveFormat.jpg, quality: .5),
      );
      final pointer = await hover(tester);
      await pointer.down(tester.getCenter(getHandle()));
      await pointer.moveBy(const Offset(20, 0));
      await tester.pump();
      await pointer.moveTo(const Offset(805, 240));
      await settle(tester);
      final args =
          calls.singleWhere((c) => c.method == 'startDrag').arguments as Map;
      await tester.runAsync(() async {
        final path = args['filePath'] as String;
        expect(path, endsWith('.jpg'));
        expect(img.decodeJpg(await File(path).readAsBytes()), isNotNull);
      });
      expect((selections, opens), (0, 0));
      await pointer.up();
      await pointer.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );

  windowsTest('copy snapshots settings while source is loading', (
    tester,
  ) async {
    final pending = Completer<Uint8List?>();
    await mount(
      tester,
      settings: const SaveSettings(meta: SaveMeta.clean),
      child: ImageTransferButton(load: () => pending.future),
    );
    await tester.tap(find.byKey(const ValueKey('preview-image-transfer')));
    await tester.pump();
    await tester.runAsync(
      () => container
          .read(saveSettingsProvider.notifier)
          .patch((_) => const SaveSettings()),
    );
    pending.complete(result.bytes);
    await settle(tester);
    final args = calls.singleWhere((c) => c.method == 'write').arguments as Map;
    await tester.runAsync(
      () async => expect(
        await extractImageMetadata(args['image'] as Uint8List),
        isNull,
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  windowsTest('a slower earlier copy cannot overwrite a newer copy', (
    tester,
  ) async {
    final pending = Completer<Uint8List?>();
    await mount(
      tester,
      child: Row(
        children: [
          ImageTransferButton(
            key: const ValueKey('slow'),
            load: () => pending.future,
          ),
          ImageTransferButton(
            key: const ValueKey('fast'),
            load: () async => result.bytes,
          ),
        ],
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('slow')),
        matching: find.byType(IconButton),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('fast')),
        matching: find.byType(IconButton),
      ),
    );
    await settle(tester);
    pending.complete(result.bytes);
    await settle(tester);
    expect(calls.where((c) => c.method == 'write'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
}
