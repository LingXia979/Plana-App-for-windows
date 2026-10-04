import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 12, height: 18, numChannels: 4)
        ..clear(img.ColorRgba8(230, 90, 120, 120)),
    ),
  );
  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> paste(
    WidgetTester tester,
    Offset point, {
    Uint8List? bytes,
    bool bitmap = false,
    List<String> paths = const [],
    String error = '',
  }) async {
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        DesktopImageDropHost.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('paste', {
            'x': point.dx * tester.view.devicePixelRatio,
            'y': point.dy * tester.view.devicePixelRatio,
            'bytes': bytes ?? png,
            'bitmap': bitmap,
            'paths': paths,
            'error': error,
          }),
        ),
        (_) {},
      );
    });
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  testWidgets(
    'pointer recipient wins over focus; repeated pastes append original PNG',
    (tester) async {
      final reference = <PickedImage>[], assistant = <PickedImage>[];
      var generic = 0;
      final text = TextEditingController();
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: ImageDropRegion(
              label: '普通导入',
              pasteFallback: true,
              acceptInternal: false,
              onDrop: (_, _) async => generic++,
              child: Row(
                children: [
                  Expanded(
                    child: ImageDropRegion(
                      label: '参考',
                      multiple: true,
                      onDrop: (images, _) async => reference.addAll(images),
                      child: Center(
                        child: TextField(
                          key: const ValueKey('reference'),
                          controller: text,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ImageDropRegion(
                      label: '助手',
                      multiple: true,
                      onDrop: (images, payload) async {
                        expect(payload.source, 'clipboard');
                        assistant.addAll(images);
                      },
                      child: const SizedBox.expand(key: ValueKey('assistant')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(key('reference'));
      await paste(tester, tester.getCenter(key('assistant')));
      await paste(tester, tester.getCenter(key('assistant')));
      expect(assistant.map((image) => image.bytes), [png, png]);
      expect(reference, isEmpty);
      expect(generic, 0);
      expect(text.text, isEmpty);
      await paste(tester, tester.getCenter(key('reference')));
      expect(reference.single.bytes, png);
    },
  );

  testWidgets(
    'active assistant page owns header paste; hidden page cannot receive',
    (tester) async {
      var assistant = 0, generic = 0, index = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: ImageDropRegion(
              label: '普通导入',
              pasteFallback: true,
              acceptInternal: false,
              onDrop: (_, _) async => generic++,
              child: Column(
                children: [
                  const SizedBox(
                    height: 60,
                    width: double.infinity,
                    key: ValueKey('header'),
                  ),
                  Expanded(
                    child: StatefulBuilder(
                      builder: (_, setState) {
                        update = setState;
                        return IndexedStack(
                          index: index,
                          children: [
                            ImageDropRegion(
                              label: '助手',
                              pasteDefault: true,
                              onDrop: (_, _) async => assistant++,
                              child: const SizedBox.expand(),
                            ),
                            const SizedBox.expand(),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await paste(tester, tester.getCenter(key('header')));
      expect(assistant, 1);
      expect(generic, 0);
      update(() => index = 1);
      await tester.pump();
      await paste(tester, tester.getCenter(key('header')));
      expect(generic, 1);
      expect(assistant, 1);
    },
  );

  testWidgets('pane header proxy and disabled receiver do not fall through', (
    tester,
  ) async {
    final target = GlobalKey();
    var assistant = 0, generic = 0, enabled = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => DesktopImageDropHost(child: child!),
        home: Scaffold(
          body: ImageDropRegion(
            label: '普通导入',
            pasteFallback: true,
            onDrop: (_, _) async => generic++,
            child: Column(
              children: [
                ImagePasteProxy(
                  target: target,
                  child: const SizedBox(
                    width: double.infinity,
                    height: 60,
                    key: ValueKey('header'),
                  ),
                ),
                Expanded(
                  child: StatefulBuilder(
                    builder: (_, setState) {
                      update = setState;
                      return ImageDropRegion(
                        key: target,
                        label: '助手',
                        enabled: enabled,
                        onDrop: (_, _) async => assistant++,
                        child: const SizedBox.expand(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await paste(tester, tester.getCenter(key('header')));
    expect(assistant, 1);
    update(() => enabled = false);
    await tester.pump();
    await paste(tester, tester.getCenter(key('header')));
    expect(assistant, 1);
    expect(generic, 0);
  });

  testWidgets('modal blocks hover, focus and page fallbacks', (tester) async {
    var imports = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => DesktopImageDropHost(child: child!),
        home: Scaffold(
          body: ImageDropRegion(
            label: '助手',
            pasteDefault: true,
            onDrop: (_, _) async => imports++,
            child: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(title: Text('dialog')),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await paste(tester, const Offset(20, 20));
    await paste(tester, const Offset(-100, -100));
    expect(imports, 0);
  });

  testWidgets(
    'bitmap becomes PNG; clipboard errors and invalid batches preserve state',
    (tester) async {
      final received = <PickedImage>[];
      final directory = Directory.systemTemp.createTempSync(
        'plana_clipboard_test_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final first = File('${directory.path}/one.png')..writeAsBytesSync(png);
      final second = File('${directory.path}/two.png')..writeAsBytesSync(png);
      final invalid = File('${directory.path}/invalid.png')
        ..writeAsStringSync('invalid');
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: ImageDropRegion(
              label: '助手',
              multiple: true,
              onDrop: (images, _) async => received.addAll(images),
              child: const SizedBox.expand(key: ValueKey('target')),
            ),
          ),
        ),
      );
      final point = tester.getCenter(key('target'));
      await paste(
        tester,
        point,
        bitmap: true,
        bytes: Uint8List.fromList(
          img.encodeBmp(img.Image(width: 8, height: 6)),
        ),
      );
      expect(img.decodePng(received.single.bytes)?.width, 8);
      expect(received.single.name, 'clipboard.png');
      await paste(tester, point, paths: [first.path, second.path]);
      expect(received.length, 3);
      await paste(tester, point, paths: [first.path, invalid.path]);
      expect(received.length, 3);
      await paste(tester, point, error: 'clipboard_busy');
      expect(received.length, 3);
      expect(find.byType(SnackBar), findsOneWidget);
    },
  );

  testWidgets(
    'partly scrolled reference accepts paste at its visible portion',
    (tester) async {
      var imports = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: SizedBox(
              height: 150,
              child: SingleChildScrollView(
                child: ImageDropRegion(
                  label: '参考',
                  onDrop: (_, _) async => imports++,
                  child: const SizedBox(height: 1000, width: 500),
                ),
              ),
            ),
          ),
        ),
      );
      await paste(tester, const Offset(50, 50));
      expect(imports, 1);
    },
  );

  testWidgets('plain text Ctrl+V retains normal TextField behavior', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': '普通提示词'} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => DesktopImageDropHost(child: child!),
        home: Scaffold(body: TextField(controller: controller)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.text, '普通提示词');
  });
}
