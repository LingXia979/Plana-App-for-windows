import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadDesktopCaptureFonts() async {
  if (!Platform.isWindows ||
      Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') {
    return;
  }
  for (final font in [
    ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
    ('monospace', r'C:\Windows\Fonts\consola.ttf'),
    (
      'MaterialIcons',
      r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
    ),
  ]) {
    final file = File(font.$2);
    if (file.existsSync()) {
      await (FontLoader(
        font.$1,
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
  }
}

Future<void> captureDesktop(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
  final disabled = debugDisableShadows;
  debugDisableShadows = false;
  for (final render in tester.allRenderObjects) {
    render.markNeedsPaint();
  }
  try {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/windows-validation/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = disabled;
  }
}
