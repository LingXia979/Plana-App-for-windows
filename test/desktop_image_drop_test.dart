import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/ui/image_drop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bytes = Uint8List.fromList(
    img.encodePng(img.Image(width: 12, height: 18)),
  );
  final payload = ImageDropPayload.image(
    name: 'sample.png',
    load: () async => bytes,
  );
  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> native(
    WidgetTester tester,
    String method,
    Offset point,
    List<String> paths,
  ) async {
    final scale = tester.view.devicePixelRatio;
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        DesktopImageDropHost.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, {
            'x': point.dx * scale,
            'y': point.dy * scale,
            'paths': paths,
          }),
        ),
        (_) {},
      );
    });
    await tester.pump();
  }

  Future<void> settleDrop(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  testWidgets(
    'native drop uses deepest visible receiver and never imports on hover or leave',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('plana_drop_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = File('${dir.path}/中文图片.png')..writeAsBytesSync(bytes);
      var inner = 0, outer = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: ImageDropRegion(
              label: '全局导入',
              onDrop: (_, _) async => outer++,
              child: Center(
                child: ImageDropRegion(
                  label: '加入参考',
                  onDrop: (images, _) async {
                    expect(images.single.name, '中文图片.png');
                    expect(images.single.bytes, bytes);
                    inner++;
                  },
                  child: const SizedBox(
                    key: ValueKey('target'),
                    width: 200,
                    height: 120,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final point = tester.getCenter(key('target'));
      await native(tester, 'over', point, [path.path]);
      expect(find.text('松开以加入参考'), findsOneWidget);
      expect(inner + outer, 0);
      await native(tester, 'leave', point, []);
      expect(find.text('松开以加入参考'), findsNothing);
      expect(inner + outer, 0);
      await native(tester, 'drop', point, [path.path]);
      await settleDrop(tester);
      expect(inner, 1);
      expect(outer, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('modal barrier blocks underlying native target', (tester) async {
    var imports = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => DesktopImageDropHost(child: child!),
        home: Scaffold(
          body: ImageDropRegion(
            label: '导入',
            onDrop: (_, _) async => imports++,
            child: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => const AlertDialog(title: Text('dialog')),
                    );
                  },
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
    await native(tester, 'over', const Offset(20, 20), ['missing.png']);
    await native(tester, 'drop', const Offset(20, 20), ['missing.png']);
    await settleDrop(tester);
    expect(imports, 0);
    expect(find.text('松开以导入'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'invalid batch and multiple files at a single-image target leave state untouched',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('plana_drop_invalid_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final valid = File('${dir.path}/a.png')..writeAsBytesSync(bytes);
      final invalid = File('${dir.path}/b.png')
        ..writeAsStringSync('not an image');
      var calls = 0;
      var multiple = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return ImageDropRegion(
                  label: '导入',
                  multiple: multiple,
                  onDrop: (_, _) async => calls++,
                  child: const SizedBox.expand(key: ValueKey('target')),
                );
              },
            ),
          ),
        ),
      );
      final point = tester.getCenter(key('target'));
      await native(tester, 'drop', point, [valid.path, invalid.path]);
      await settleDrop(tester);
      expect(calls, 0);
      expect(find.text('无法读取图片：b.png'), findsOneWidget);
      update(() => multiple = false);
      await tester.pump();
      await native(tester, 'drop', point, [valid.path, valid.path]);
      await settleDrop(tester);
      expect(calls, 0);
      update(() => multiple = true);
      await tester.pump();
      await native(tester, 'drop', point, [valid.path, valid.path]);
      await settleDrop(tester);
      expect(calls, 1);
    },
  );

  for (final delta in [
    const Offset(30, 0),
    const Offset(-30, 0),
    const Offset(0, 30),
    const Offset(0, -30),
    const Offset(-25, 25),
  ]) {
    testWidgets(
      'mouse image drag can start $delta and change direction into a receiver',
      (tester) async {
        var imports = 0, taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: Center(
                      child: DesktopImageDraggable(
                        data: payload,
                        feedback: const SizedBox(width: 20, height: 20),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => taps++,
                          child: const SizedBox(
                            key: ValueKey('source'),
                            width: 100,
                            height: 100,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ImageDropRegion(
                      label: '导入',
                      onDrop: (_, _) async => imports++,
                      child: const SizedBox.expand(key: ValueKey('target')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(key('source')),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(delta);
        await tester.pump();
        await gesture.moveTo(tester.getCenter(key('target')));
        await tester.pump();
        expect(find.text('松开以导入'), findsOneWidget);
        await gesture.up();
        await settleDrop(tester);
        expect(imports, 1);
        expect(taps, 0);
      },
    );
  }

  testWidgets(
    'short mouse click and touch keep child behavior; an outside drop cancels',
    (tester) async {
      var started = 0, taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: DesktopImageDraggable(
                data: payload,
                onDragStarted: () => started++,
                feedback: const SizedBox(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox(
                    key: ValueKey('source'),
                    width: 100,
                    height: 100,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      var gesture = await tester.startGesture(
        tester.getCenter(key('source')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(1, 1));
      await gesture.up();
      await tester.pump();
      expect(taps, 1);
      expect(started, 0);
      gesture = await tester.startGesture(
        tester.getCenter(key('source')),
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(40, 30));
      await gesture.up();
      await tester.pump();
      expect(started, 0);
      gesture = await tester.startGesture(
        tester.getCenter(key('source')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, -50));
      await gesture.moveTo(const Offset(-10, -10));
      await gesture.up();
      await tester.pump();
      expect(started, 1);
      expect(taps, 1);
    },
  );
}
