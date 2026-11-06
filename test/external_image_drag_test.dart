import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/clipboard_image.dart';
import 'package:plana_app/core/platform/image_transfer.dart';
import 'package:plana_app/core/ui/external_image_drag.dart';
import 'package:plana_app/core/ui/image_drop.dart';

class _Prepared extends PreparedImageTransfer {
  _Prepared() : super(bytes: Uint8List(0), name: 'processed.jpg');
  int writes = 0;
  @override
  Future<File> file({Directory? temporaryDirectory}) async {
    writes++;
    return File('C:/synthetic-processed-export/processed.jpg');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void windowsTest(String name, WidgetTesterCallback body) => testWidgets(
    name,
    body,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final pixels = Uint8List.fromList(
    img.encodePng(img.Image(width: 16, height: 16)),
  );
  late _Prepared export;
  late Future<PreparedImageTransfer> Function() prepare;
  late List<MethodCall> calls;
  late List<ImageDropPayload> drops;
  late Completer<String> nativeDone;
  var starts = 0, ends = 0, preparations = 0;
  final payload = ImageDropPayload.image(
    name: 'original.png',
    imageId: 'original-result',
    source: 'history',
    load: () async => pixels,
  );

  setUp(() {
    export = _Prepared();
    prepare = () async => export;
    calls = [];
    drops = [];
    starts = ends = preparations = 0;
    nativeDone = Completer<String>();
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, (call) async {
      calls.add(call);
      return call.method == 'startDrag' ? nativeDone.future : null;
    });
  });
  tearDown(() {
    if (!nativeDone.isCompleted) nativeDone.complete('cancelled');
    messenger.setMockMethodCallHandler(DesktopClipboard.channel, null);
  });

  Future<void> mount(WidgetTester tester, {bool rejectInternal = false}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => DesktopImageDropHost(child: child!),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 20,
                top: 100,
                child: ExternalImageDrag(
                  data: payload,
                  prepare: () {
                    preparations++;
                    return prepare();
                  },
                  onStart: () => starts++,
                  onEnd: () => ends++,
                  feedback: const Material(child: Text('拖图')),
                  child: const SizedBox(
                    key: ValueKey('source'),
                    width: 120,
                    height: 120,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
              Positioned(
                left: 350,
                top: 100,
                child: ImageDropRegion(
                  label: '测试目标',
                  acceptInternal: !rejectInternal,
                  onDrop: (images, received) async {
                    expect(images.single.bytes, pixels);
                    drops.add(received);
                  },
                  child: const SizedBox(
                    key: ValueKey('target'),
                    width: 150,
                    height: 200,
                    child: ColoredBox(color: Colors.grey),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<TestGesture> start(
    WidgetTester tester, {
    int buttons = kPrimaryMouseButton,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('source'))),
      kind: PointerDeviceKind.mouse,
      buttons: buttons,
    );
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    return gesture;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  Future<void> nativeDrop(WidgetTester tester, String token) async {
    final point = tester.getCenter(find.byKey(const ValueKey('target'))) * 1.5;
    await tester.runAsync(() async {
      await messenger.handlePlatformMessage(
        DesktopImageDropHost.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('drop', {
            'x': point.dx,
            'y': point.dy,
            'paths': ['C:/synthetic-processed-export/processed.jpg'],
            'internalToken': token,
          }),
        ),
        (_) {},
      );
    });
    await settle(tester);
  }

  windowsTest(
    'internal drag retains original identity and creates no export file',
    (tester) async {
      await mount(tester);
      final gesture = await start(tester);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('target'))),
      );
      await gesture.up();
      await settle(tester);
      expect(drops.single, same(payload));
      expect(export.writes, 0);
      expect(calls, isEmpty);
      expect((starts, ends), (1, 1));
    },
  );

  windowsTest(
    'crossing the window boundary hands off once, with processed file and token',
    (tester) async {
      await mount(tester);
      final gesture = await start(tester);
      await gesture.moveTo(const Offset(805, 200));
      await settle(tester);
      expect(calls.map((c) => c.method), ['startDrag']);
      final args = calls.single.arguments as Map;
      expect(args['filePath'], endsWith('processed.jpg'));
      expect(
        NativeImageDragRegistry.lookup(args['internalToken'] as String),
        same(payload),
      );
      expect(export.writes, 1);
      expect(
        (starts, ends),
        (1, 1),
        reason: 'Flutter drag ends before OLE takes over',
      );
      nativeDone.complete('copied');
      await tester.pump();
      await gesture.up();
      expect(tester.takeException(), isNull);
    },
  );

  windowsTest(
    'returning native drop uses original data, including after OLE completion',
    (tester) async {
      await mount(tester);
      final gesture = await start(tester);
      await gesture.moveTo(const Offset(-5, 200));
      await settle(tester);
      final token = (calls.single.arguments as Map)['internalToken'] as String;
      nativeDone.complete('copied');
      await tester.pump();
      await nativeDrop(tester, token);
      expect(drops.single, same(payload));
      await gesture.up();
    },
  );

  windowsTest(
    'returned internal drag respects regions which reject internal images',
    (tester) async {
      await mount(tester, rejectInternal: true);
      final gesture = await start(tester);
      await gesture.moveTo(const Offset(-5, 200));
      await settle(tester);
      await nativeDrop(
        tester,
        (calls.single.arguments as Map)['internalToken'] as String,
      );
      expect(drops, isEmpty);
      nativeDone.complete('cancelled');
      await gesture.up();
    },
  );

  for (final cancel in ['release', 'escape', 'dispose']) {
    windowsTest('slow preparation after $cancel cannot start a native drag', (
      tester,
    ) async {
      final pending = Completer<PreparedImageTransfer>();
      prepare = () => pending.future;
      await mount(tester);
      final gesture = await start(tester);
      await gesture.moveTo(const Offset(805, 200));
      await tester.pump();
      if (cancel == 'release') {
        await gesture.up();
      } else if (cancel == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      pending.complete(export);
      await settle(tester);
      expect(calls, isEmpty);
      expect(export.writes, 0);
      if (cancel != 'release') await gesture.up();
    });
  }

  windowsTest(
    'returning inside while preparing retains an ordinary internal drag',
    (tester) async {
      final pending = Completer<PreparedImageTransfer>();
      prepare = () => pending.future;
      await mount(tester);
      final gesture = await start(tester);
      await gesture.moveTo(const Offset(805, 200));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('target'))),
      );
      pending.complete(export);
      await tester.pump();
      await gesture.up();
      await settle(tester);
      expect(drops.single, same(payload));
      expect(calls, isEmpty);
      expect(export.writes, 0);
    },
  );

  windowsTest('failed processing never hands an original to native drag', (
    tester,
  ) async {
    prepare = () => Future.error(const FormatException('failed'));
    await mount(tester);
    final gesture = await start(tester);
    await gesture.moveTo(const Offset(805, 200));
    await settle(tester);
    expect(calls, isEmpty);
    expect(find.textContaining('无法拖出'), findsOneWidget);
    await gesture.up();
  });

  for (final buttons in [kSecondaryMouseButton, kMiddleMouseButton]) {
    windowsTest('mouse button $buttons does not start image export', (
      tester,
    ) async {
      await mount(tester);
      final gesture = await start(tester, buttons: buttons);
      await gesture.moveTo(const Offset(805, 200));
      await gesture.up();
      await tester.pump();
      expect(preparations, 0);
      expect(calls, isEmpty);
    });
  }
}
