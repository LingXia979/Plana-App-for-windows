import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/inpaint/expand_canvas_dialog.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';

class _Result {
  bool closed = false;
  ExpandMargins? margins;
}

Finder _key(String name) => find.byKey(ValueKey(name));

Future<_Result> _open(
  WidgetTester tester, {
  int width = 832,
  int height = 1216,
  Size window = const Size(1440, 900),
  ui.Image? image,
  ExpandMargins existing = (left: 0, top: 0, right: 0, bottom: 0),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = window;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result.margins = await showDialog<ExpandMargins>(
                context: context,
                builder: (_) => ExpandCanvasDialog(
                  width: width,
                  height: height,
                  image: image,
                  existing: existing,
                ),
              );
              result.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(_key('expand-canvas-dialog'), findsOneWidget);
  return result;
}

Future<void> _enter(WidgetTester tester, String side, String text) async {
  await tester.ensureVisible(_key('expand-$side'));
  await tester.enterText(_key('expand-$side'), text);
  await tester.pumpAndSettle();
}

bool _canApply(WidgetTester tester) =>
    tester.widget<FilledButton>(_key('expand-apply')).onPressed != null;

String _validation(WidgetTester tester) =>
    tester.widget<Text>(_key('expand-validation')).data!;

void main() {
  testWidgets('desktop places four inputs around a portrait canvas', (
    tester,
  ) async {
    await _open(tester);
    final preview = tester.getRect(_key('expand-preview'));
    final top = tester.getRect(_key('expand-top'));
    final bottom = tester.getRect(_key('expand-bottom'));
    final left = tester.getRect(_key('expand-left'));
    final right = tester.getRect(_key('expand-right'));
    expect(top.bottom, lessThan(preview.top));
    expect(bottom.top, greaterThan(preview.bottom));
    expect(left.right, lessThan(preview.left));
    expect(right.left, greaterThan(preview.right));
    expect(top.center.dx, closeTo(preview.center.dx, .1));
    expect(bottom.center.dx, closeTo(preview.center.dx, .1));
    expect(left.center.dy, closeTo(preview.center.dy, .1));
    expect(right.center.dy, closeTo(preview.center.dy, .1));
    expect(preview.width / preview.height, closeTo(832 / 1216, .001));
    expect(_canApply(tester), isFalse, reason: 'zero margins are not an edit');
  });

  testWidgets('landscape preview follows the resulting non-square dimensions', (
    tester,
  ) async {
    await _open(tester, width: 1216, height: 832);
    var preview = tester.getSize(_key('expand-preview'));
    expect(preview.width / preview.height, closeTo(1216 / 832, .001));
    await _enter(tester, 'left', '64');
    await _enter(tester, 'bottom', '128');
    preview = tester.getSize(_key('expand-preview'));
    expect(preview.width / preview.height, closeTo(1280 / 960, .001));
    expect(find.text('1216 × 832\n↓\n1280 × 960'), findsOneWidget);
  });

  testWidgets('returns independently rounded asymmetric margins', (
    tester,
  ) async {
    final result = await _open(tester);
    await _enter(tester, 'left', '1');
    await _enter(tester, 'top', '65');
    await _enter(tester, 'right', '129');
    await _enter(tester, 'bottom', '0');
    expect(find.text('832 × 1216\n↓\n1088 × 1344'), findsOneWidget);
    expect(_canApply(tester), isTrue);
    await tester.tap(_key('expand-apply'));
    await tester.pumpAndSettle();
    expect(result.closed, isTrue);
    expect(result.margins, (left: 64, top: 128, right: 192, bottom: 0));
    expect(_key('expand-canvas-dialog'), findsNothing);
  });

  testWidgets('cancel discards entered margins', (tester) async {
    final result = await _open(tester);
    await _enter(tester, 'left', '256');
    await _enter(tester, 'bottom', '64');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result.closed, isTrue);
    expect(result.margins, isNull);
  });

  testWidgets(
    'image preview preserves its proportions and both old and new offsets',
    (tester) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xFF336699), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final source = (await tester.runAsync(() => picture.toImage(64, 128)))!;
      picture.dispose();
      try {
        await _open(
          tester,
          width: 128,
          height: 256,
          image: source,
          existing: (left: 64, top: 128, right: 0, bottom: 0),
        );
        await _enter(tester, 'left', '1');
        await _enter(tester, 'top', '65');
        final preview = tester.getRect(_key('expand-preview'));
        final image = tester.getRect(find.byType(RawImage));
        final scale = preview.width / 192;
        expect(preview.width / preview.height, closeTo(192 / 384, .001));
        expect(image.width / image.height, closeTo(64 / 128, .001));
        expect(image.left - preview.left, closeTo(128 * scale, .1));
        expect(image.top - preview.top, closeTo(256 * scale, .1));
        expect(image.right, closeTo(preview.right, .1));
        expect(image.bottom, closeTo(preview.bottom, .1));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        source.dispose();
      }
    },
  );

  testWidgets('invalid input blocks apply until a valid margin is restored', (
    tester,
  ) async {
    await _open(tester);
    await _enter(tester, 'right', '64');
    expect(_canApply(tester), isTrue);
    for (final input in ['', '-1', '--']) {
      await _enter(tester, 'left', input);
      expect(_canApply(tester), isFalse, reason: input);
      expect(_validation(tester), '请输入非负整数');
      expect(tester.takeException(), isNull);
    }
    await _enter(tester, 'left', '0');
    expect(_canApply(tester), isTrue);
    expect(_validation(tester), contains('64'));
  });

  testWidgets('side and area limits disable confirmation with an explanation', (
    tester,
  ) async {
    await _open(tester, width: 512, height: 512);
    await _enter(tester, 'right', '3584');
    expect(_canApply(tester), isTrue, reason: '4096 × 512 is valid');
    await _enter(tester, 'right', '3585');
    expect(_canApply(tester), isFalse);
    expect(_validation(tester), contains('4096'));
    await _enter(tester, 'right', '1024');
    await _enter(tester, 'bottom', '1536');
    expect(_canApply(tester), isTrue, reason: '1536 × 2048 is exactly 3MP');
    await _enter(tester, 'bottom', '1537');
    expect(_canApply(tester), isFalse);
    expect(_validation(tester), contains('3,145,728'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid base dimensions cannot be confirmed', (tester) async {
    await _open(tester, width: 833, height: 1216);
    await _enter(tester, 'top', '64');
    expect(_canApply(tester), isFalse);
    expect(_validation(tester), contains('原图宽高需要为 64 的倍数'));
  });

  testWidgets('step buttons round the input and never reduce below zero', (
    tester,
  ) async {
    final result = await _open(tester);
    Finder down() => find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '上减少 64 像素',
    );
    Finder up() => find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '上增加 64 像素',
    );
    String value() =>
        tester.widget<TextField>(_key('expand-top')).controller!.text;
    expect(tester.widget<IconButton>(down()).onPressed, isNull);
    await tester.tap(up());
    await tester.pumpAndSettle();
    expect(value(), '64');
    await tester.tap(down());
    await tester.pumpAndSettle();
    expect(value(), '0');
    expect(tester.widget<IconButton>(down()).onPressed, isNull);
    await _enter(tester, 'top', '65');
    await tester.tap(up());
    await tester.pumpAndSettle();
    expect(value(), '192');
    await tester.tap(down());
    await tester.pumpAndSettle();
    expect(value(), '128');
    await tester.tap(_key('expand-apply'));
    await tester.pumpAndSettle();
    expect(result.margins, (left: 0, top: 128, right: 0, bottom: 0));
  });

  for (final window in [
    const Size(720, 700),
    const Size(500, 600),
    const Size(360, 600),
  ]) {
    testWidgets(
      'fields and fixed actions work at ${window.width.toInt()}px without overflow',
      (tester) async {
        final result = await _open(tester, window: window);
        final dialog = tester.getRect(find.byType(AlertDialog));
        expect(dialog.left, greaterThanOrEqualTo(0));
        expect(dialog.right, lessThanOrEqualTo(window.width));
        expect(dialog.top, greaterThanOrEqualTo(0));
        expect(dialog.bottom, lessThanOrEqualTo(window.height));
        for (final side in ['top', 'bottom', 'left', 'right']) {
          await _enter(tester, side, '64');
          expect(tester.takeException(), isNull, reason: side);
        }
        expect(_canApply(tester), isTrue);
        expect(_key('expand-apply').hitTestable(), findsOneWidget);
        await tester.tap(_key('expand-apply'));
        await tester.pumpAndSettle();
        expect(result.margins, (left: 64, top: 64, right: 64, bottom: 64));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
