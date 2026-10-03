import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/inpaint/inpaint_ops.dart';
import 'package:plana_app/features/inpaint/inpaint_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Uint8List source;
  Finder key(String name) => find.byKey(ValueKey(name));

  setUp(() {
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    container.read(desktopLibraryProvider);
    source = Uint8List.fromList(
      img.encodePng(img.Image(width: 512, height: 768)),
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  dynamic painter(WidgetTester tester) =>
      tester.widget<CustomPaint>(key('inpaint-editor-canvas')).painter;
  List<Rect> mask(WidgetTester tester) =>
      List<Rect>.from(painter(tester).rects as List);
  double area(WidgetTester tester) =>
      mask(tester).fold(0.0, (sum, r) => sum + r.width * r.height);
  Offset point(WidgetTester tester, Offset pixel) {
    final p = painter(tester);
    return tester.getTopLeft(key('inpaint-editor-canvas')) +
        (p.offset as Offset) +
        pixel * (p.scale as double);
  }

  bool enabled(WidgetTester tester, String name) =>
      tester
          .widget<InkWell>(
            find.descendant(of: key(name), matching: find.byType(InkWell)),
          )
          .onTap !=
      null;
  Future<void> tap(WidgetTester tester, String name) async {
    await tester.tap(key(name));
    await tester.pumpAndSettle();
  }

  Future<void> draw(WidgetTester tester, Offset pixel) async {
    await tester.tapAt(point(tester, pixel), kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset delta) async {
    final gesture = await tester.startGesture(
      point(tester, from),
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pump();
    final scaled = delta * (painter(tester).scale as double);
    await gesture.moveBy(scaled / 2);
    await tester.pump();
    await gesture.moveBy(scaled / 2);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1100, 900),
    InpaintPrefs? prefs = const InpaintPrefs(assist: true, brush: 64),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (prefs != null) {
      await tester.runAsync(
        () => container.read(inpaintPrefsProvider.notifier).save(prefs),
      );
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: InpaintOverlay(
              session: InpaintSession(
                imageBytes: source,
                sourceId: 'test-original',
              ),
            ),
          ),
        ),
      ),
    );
    for (
      var i = 0;
      i < 100 && key('inpaint-editor-canvas').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(key('inpaint-editor-canvas'), findsOneWidget);
  }

  testWidgets(
    'desktop brush stays at pointer, circular strokes, fill and redo preserve edits',
    (tester) async {
      await mount(tester);
      expect(find.text('偏位'), findsNothing);
      await tap(tester, 'inpaint-tool-brush');
      await tap(tester, 'inpaint-tool-brush');
      expect(find.text('偏位'), findsNothing);
      await tap(tester, 'inpaint-brush-shape');
      expect(find.text('圆形刷'), findsOneWidget);
      await draw(tester, const Offset(256, 384));
      final circular = mask(tester);
      expect(area(tester), greaterThan(0));
      expect(area(tester), lessThan(64 * 64));
      expect(circular.any((r) => r.contains(const Offset(256, 384))), isTrue);
      await tap(tester, 'inpaint-tool-fill');
      expect(find.textContaining('点击图片涂满'), findsNothing);
      await draw(tester, const Offset(256, 384));
      expect(area(tester), 512 * 768);
      await tap(tester, 'inpaint-undo');
      expect(mask(tester), circular);
      await tap(tester, 'inpaint-redo');
      expect(area(tester), 512 * 768);
      await tap(tester, 'inpaint-tool-eraser');
      await draw(tester, const Offset(256, 384));
      expect(area(tester), lessThan(512 * 768));
      await tap(tester, 'inpaint-undo');
      expect(area(tester), 512 * 768);
      await tap(tester, 'inpaint-clear');
      expect(area(tester), 0);
      expect(enabled(tester, 'inpaint-redo'), isFalse);
      await tap(tester, 'inpaint-undo');
      expect(area(tester), 512 * 768);
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(
        container.read(inpaintPrefsProvider).brushShape,
        MaskBrushShape.circle,
      );
      await tester.pumpWidget(const SizedBox());
      await mount(tester, prefs: null);
      expect(find.text('圆形刷'), findsOneWidget);
      expect(painter(tester).brushShape, MaskBrushShape.circle);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'crop body moves without resizing, handles resize, painting keeps a manual crop fixed',
    (tester) async {
      await mount(tester);
      await tap(tester, 'inpaint-tool-crop');
      final initial = painter(tester).crop as IntRect;
      await tap(tester, 'inpaint-undo');
      expect(painter(tester).crop, isNull);
      await tap(tester, 'inpaint-redo');
      expect(painter(tester).crop, initial);
      final center = Offset(
        initial.x + initial.w / 2,
        initial.y + initial.h / 2,
      );
      await drag(tester, center, const Offset(128, 128));
      final moved = painter(tester).crop as IntRect;
      expect((moved.w, moved.h), (initial.w, initial.h));
      expect(moved.x, greaterThan(initial.x));
      expect(moved.y, greaterThan(initial.y));
      expect(mask(tester), isEmpty);
      await tap(tester, 'inpaint-undo');
      expect(painter(tester).crop, initial);
      await drag(tester, center, const Offset(2, 2));
      expect(painter(tester).crop, initial);
      expect(enabled(tester, 'inpaint-redo'), isTrue);
      await tap(tester, 'inpaint-redo');
      expect(painter(tester).crop, moved);
      await drag(
        tester,
        Offset(moved.x.toDouble(), moved.y.toDouble()),
        const Offset(-128, -128),
      );
      final resized = painter(tester).crop as IntRect;
      expect(resized.w, greaterThan(moved.w));
      expect(resized.h, greaterThan(moved.h));
      await tap(tester, 'inpaint-tool-brush');
      await draw(tester, const Offset(256, 384));
      expect(painter(tester).crop, resized);
      expect(mask(tester), isNotEmpty);
      final painted = mask(tester);
      await draw(tester, const Offset(8, 8));
      expect(painter(tester).crop, isNull);
      expect(mask(tester), painted);
      await tap(tester, 'inpaint-undo');
      expect(painter(tester).crop, resized);
      await tap(tester, 'inpaint-tool-crop');
      await drag(tester, const Offset(8, 512), const Offset(128, 128));
      final small = painter(tester).crop as IntRect;
      expect((small.w, small.h), (128, 128));
      await drag(
        tester,
        Offset(small.x + small.w.toDouble(), small.y + small.h.toDouble()),
        const Offset(64, 64),
      );
      final larger = painter(tester).crop as IntRect;
      expect((larger.w, larger.h), (192, 192));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outside clicks dismiss focus without painting, while context and resize grip retain it',
    (tester) async {
      await mount(tester);
      await draw(tester, const Offset(256, 384));
      final painted = mask(tester);
      await tap(tester, 'inpaint-tool-crop');
      final crop = painter(tester).crop as IntRect;
      expect(find.text('取消框选'), findsNothing);
      expect(find.textContaining('框内拖动移动'), findsNothing);
      await draw(tester, Offset(crop.x + 8, crop.y + crop.h / 2));
      expect(painter(tester).crop, crop);
      expect(enabled(tester, 'inpaint-redo'), isFalse);

      for (final tool in ['crop', 'brush', 'eraser', 'fill']) {
        await tap(tester, 'inpaint-tool-$tool');
        await draw(tester, const Offset(8, 8));
        expect(painter(tester).crop, isNull, reason: tool);
        expect(mask(tester), painted, reason: '$tool must not paint on cancel');
        expect(key('inpaint-focus-context'), findsNothing);
        await tap(tester, 'inpaint-undo');
        expect(painter(tester).crop, crop);
        expect(mask(tester), painted);
        expect(painter(tester).focusContext, 32);
      }

      await tap(tester, 'inpaint-tool-crop');
      // A canceled OS pointer is not a completed outside click.
      final canceled = await tester.startGesture(
        point(tester, const Offset(8, 8)),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await canceled.cancel();
      await tester.pumpAndSettle();
      expect(painter(tester).crop, crop);
      expect(mask(tester), painted);

      // The whole colored corner is a resize target, not a crop-body move.
      final inset = 17 / (painter(tester).scale as double);
      await drag(
        tester,
        Offset(crop.x + crop.w - inset, crop.y + crop.h - inset),
        const Offset(32, 32),
      );
      final resized = painter(tester).crop as IntRect;
      expect((resized.x, resized.y), (crop.x, crop.y));
      expect((resized.w, resized.h), (crop.w + 32, crop.h + 32));
      await tap(tester, 'inpaint-undo');
      expect(painter(tester).crop, crop);

      // Small pointer jitter still counts as a click outside the yellow frame.
      await drag(tester, const Offset(8, 8), const Offset(2, 2));
      expect(painter(tester).crop, isNull);
      expect(mask(tester), painted);
      await tap(tester, 'inpaint-undo');
      expect(painter(tester).crop, crop);
      await tester.tapAt(
        tester.getTopLeft(key('inpaint-editor-canvas')) + const Offset(4, 4),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(painter(tester).crop, isNull);
      expect(mask(tester), painted);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focused crop saves only the interior and preserves context and request resolution',
    (tester) async {
      container
          .read(generateProvider.notifier)
          .setInpaint(
            InpaintJob(
              image: source,
              mask: source,
              strength: .43,
              sourceId: 'test-original',
            ),
            width: 512,
            height: 768,
          );
      await mount(tester);
      expect(find.textContaining('强度'), findsNothing);
      await tap(tester, 'inpaint-tool-crop');
      final crop = painter(tester).crop as IntRect;
      await tester.tap(find.text('保存遮罩'));
      await tester.pump();
      for (
        var i = 0;
        i < 200 &&
            container.read(generateProvider).inpaint?.paste?.focus == null;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      final job = container.read(generateProvider).inpaint!;
      expect(job.strength, .43);
      expect(job.paste!.sendX, crop.x);
      expect(job.paste!.sendY, crop.y);
      final image = img.decodePng(job.mask)!;
      final sent = focusedSendSize(crop.w, crop.h);
      expect((image.width, image.height), (sent.width, sent.height));
      expect(image.getPixel(0, 0).r, 0);
      expect(image.getPixel(image.width - 1, image.height - 1).r, 0);
      expect(image.getPixel(image.width ~/ 2, image.height ~/ 2).r, 255);
      expect(job.paste!.focus!.context, 32);
      expect(
        (job.paste!.focus!.width, job.paste!.focus!.height),
        (crop.w, crop.h),
      );
      final grid = MaskGrid(512, 768)..decodeInto(job.grid!);
      expect(grid.isEmpty, isTrue);
      final selection = MaskGrid(512, 768)..decodeInto(job.paste!.focusMask!);
      expect(maskBounds(selection), focusedInnerRect(crop, 32));
      stores.flushNow();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop brush shape sits beside brush size and keeps the inline brush slider',
    (tester) async {
      await mount(tester);
      expect(find.textContaining('新图：'), findsNothing);
      expect(find.textContaining('强度'), findsNothing);
      final shape = tester.getRect(key('inpaint-brush-shape'));
      final brush = tester.getRect(find.text('笔刷 64'));
      expect(shape.center.dy, closeTo(brush.center.dy, .01));
      expect(shape.left, greaterThan(brush.right));
      expect(
        shape.top,
        greaterThan(tester.getBottomLeft(key('inpaint-tool-brush')).dy),
      );
      await tester.tap(find.text('笔刷 64'));
      await tester.pumpAndSettle();
      final brushRow = tester.getRect(key('inpaint-inline-slider'));
      expect(brushRow.width, lessThanOrEqualTo(640));
      expect(
        brushRow.top,
        greaterThan(tester.getBottomLeft(key('inpaint-tool-brush')).dy),
      );
      expect(
        brushRow.top,
        greaterThanOrEqualTo(
          tester.getBottomLeft(key('inpaint-editor-canvas')).dy,
        ),
      );
      expect(
        brushRow.bottom,
        lessThan(tester.getTopLeft(find.text('笔刷 64')).dy),
      );
      await draw(tester, const Offset(256, 384));
      expect(key('inpaint-inline-slider'), findsOneWidget);
      await tap(tester, 'inpaint-brush-shape');
      expect(find.text('圆形刷'), findsOneWidget);
      expect(find.text('笔刷大小'), findsOneWidget);
      expect(tester.getRect(key('inpaint-inline-slider')), brushRow);
      await tap(tester, 'inpaint-brush-shape');
      expect(find.text('方形刷'), findsOneWidget);
      tester.view.physicalSize = const Size(360, 700);
      await tester.pumpAndSettle();
      expect(key('inpaint-inline-slider').hitTestable(), findsOneWidget);
      expect(key('inpaint-brush-shape').hitTestable(), findsOneWidget);
      expect(tester.getSize(key('inpaint-inline-slider')).width, lessThan(360));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focused context changes inner area, leaves outer fixed and can undo or reject empty interior',
    (tester) async {
      await mount(tester);
      await tap(tester, 'inpaint-tool-crop');
      final outer = painter(tester).crop as IntRect;
      expect(painter(tester).focusContext, 32);
      final slider = key('inpaint-focus-context');
      final row = tester.getRect(key('inpaint-focus-controls'));
      expect(row.width, lessThanOrEqualTo(640));
      expect(row.height, 44);
      expect(
        row.top,
        greaterThan(tester.getBottomLeft(key('inpaint-tool-brush')).dy),
      );
      expect(row.bottom, lessThan(tester.getTopLeft(find.text('笔刷 64')).dy));
      await tester.drag(slider, const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(painter(tester).focusContext, 96);
      expect(painter(tester).crop, outer);
      await tap(tester, 'inpaint-undo');
      expect(painter(tester).focusContext, 32);
      expect(painter(tester).crop, outer);
      await tap(tester, 'inpaint-redo');
      expect(painter(tester).focusContext, 96);
      await drag(tester, const Offset(8, 608), const Offset(128, 128));
      expect((painter(tester).crop as IntRect).w, 128);
      final save = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('保存遮罩'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(save.onPressed, isNull);
      expect(find.textContaining('扩大选区'), findsOneWidget);
      tester.view.physicalSize = const Size(360, 700);
      await tester.pumpAndSettle();
      expect(key('inpaint-focus-context').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expansion increments accumulate, undo and redo restore margins, narrow tools fit',
    (tester) async {
      final originalJob = InpaintJob(
        image: source,
        mask: source,
        strength: .39,
        sourceId: 'test-original',
      );
      container
          .read(generateProvider.notifier)
          .setInpaint(originalJob, width: 512, height: 768);
      await mount(tester);
      await tester.tap(find.text('笔刷 64'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('扩图'));
      await tester.pumpAndSettle();
      expect(find.textContaining('强度'), findsNothing);
      expect(key('inpaint-inline-slider'), findsNothing);
      Future<void> expand(String side, String amount) async {
        await tester.tap(find.textContaining('尺寸 ').first);
        await tester.pumpAndSettle();
        await tester.enterText(key('expand-$side'), amount);
        await tester.pump();
        await tester.tap(key('expand-apply'));
        await tester.pumpAndSettle();
      }

      await expand('left', '1');
      expect(painter(tester).padL, 64);
      await expand('top', '65');
      expect((painter(tester).padL, painter(tester).padT), (64, 128));
      await tap(tester, 'inpaint-undo');
      expect((painter(tester).padL, painter(tester).padT), (64, 0));
      await tap(tester, 'inpaint-redo');
      expect((painter(tester).padL, painter(tester).padT), (64, 128));
      tester.view.physicalSize = const Size(360, 700);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('涂抹'));
      await tester.pumpAndSettle();
      expect(key('inpaint-tool-fill').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('扩图'));
      await tester.pumpAndSettle();
      expect((painter(tester).padL, painter(tester).padT), (64, 128));
      expect(find.textContaining('强度'), findsNothing);
      expect(key('inpaint-inline-slider'), findsNothing);
      await tester.tap(find.text('保存扩图'));
      await tester.pump();
      for (
        var i = 0;
        i < 200 &&
            identical(container.read(generateProvider).inpaint, originalJob);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      final expanded = container.read(generateProvider).inpaint!;
      expect(expanded, isNot(same(originalJob)));
      expect(expanded.strength, .39);
      stores.flushNow();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone keeps strength controls in paint and expand modes', (
    tester,
  ) async {
    container.updateOverrides([
      appStoresProvider.overrideWithValue(stores),
      desktopModeProvider.overrideWithValue(false),
    ]);
    await mount(
      tester,
      // Ahem gives every Latin digit the width of a CJK glyph. The unchanged
      // phone expansion row needs 365 px with that test font, plus its padding.
      // Use a normal 414 dp phone for this strength-control regression.
      size: const Size(414, 700),
      prefs: const InpaintPrefs(brush: 64, strength: .33),
    );
    expect(tester.takeException(), isNull);
    expect(key('inpaint-brush-shape'), findsNothing);
    await tester.tap(find.text('强度 0.33'));
    await tester.pumpAndSettle();
    expect(find.text('重绘强度'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('扩图'));
    await tester.pumpAndSettle();
    expect(find.text('强度 0.33'), findsOneWidget);
    expect(find.text('重绘强度'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('强度 0.33'));
    await tester.pumpAndSettle();
    expect(find.text('重绘强度'), findsOneWidget);
    stores.flushNow();
    expect(tester.takeException(), isNull);
  });
}
