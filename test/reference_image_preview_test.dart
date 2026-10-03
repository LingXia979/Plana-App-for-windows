import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/char_ref_card.dart';
import 'package:plana_app/features/generate/widgets/common.dart';
import 'package:plana_app/features/generate/widgets/reference_image_preview.dart';
import 'package:plana_app/features/generate/widgets/reference_strip.dart';
import 'package:plana_app/features/generate/widgets/vibe_card.dart';

class _MemoryGenerate extends GenerateNotifier {
  _MemoryGenerate(this.initial);
  final GenerateState initial;

  @override
  GenerateState build() => initial;
}

void main() {
  final png = File('assets/app_icon.png').readAsBytesSync();
  final other = Uint8List.fromList(png);
  final preview = find.byKey(const ValueKey('reference-image-preview'));
  final previewImage = find.byKey(const ValueKey('reference-preview-image'));

  Future<void> doubleClick(WidgetTester tester, Finder finder) async {
    final center = tester.getCenter(finder);
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool desktop = true,
    ProviderContainer? container,
    Size size = const Size(1000, 760),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: child),
    );
    await tester.pumpWidget(
      container == null
          ? ProviderScope(
              overrides: [desktopModeProvider.overrideWithValue(desktop)],
              child: app,
            )
          : UncontrolledProviderScope(container: container, child: app),
    );
    await tester.pumpAndSettle();
  }

  for (final vibe in [true, false]) {
    testWidgets(
      '${vibe ? 'Vibe' : 'character'} double-click previews original disabled image without altering generation',
      (tester) async {
        final stores = AppStores.ephemeral();
        final initial = GenerateState.initial().copyWith(
          vibes: [
            VibeItem(id: 'v1', image: png, name: 'one'),
            VibeItem(id: 'v2', image: other, name: 'two', enabled: false),
          ],
          charRefs: [
            CharRefItem(id: 'c1', image: png, name: 'one'),
            CharRefItem(id: 'c2', image: other, name: 'two', enabled: false),
          ],
          openPanels: {Panel.vibe, Panel.charRef},
        );
        final container = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            desktopModeProvider.overrideWithValue(true),
            generateProvider.overrideWith(() => _MemoryGenerate(initial)),
          ],
        );
        addTearDown(container.dispose);
        await mount(
          tester,
          SingleChildScrollView(
            child: SizedBox(
              width: 430,
              child: vibe ? const VibeCard() : const CharRefCard(),
            ),
          ),
          container: container,
        );
        final second = find.byType(RefThumb).at(1);
        await tester.tap(second, kind: PointerDeviceKind.mouse);
        // Selection must update on the first frame, before the double-click
        // window expires. Waiting here would hide the mouse latency bug.
        await tester.pump();
        expect(tester.widget<RefThumb>(second).selected, isTrue);
        expect(preview, findsNothing);
        await tester.pump(kDoubleTapTimeout);
        await doubleClick(tester, second);
        expect(preview, findsOneWidget);
        expect(find.text('${vibe ? 'Vibe 参考图' : '角色参考图'} · 2'), findsOneWidget);
        final image = tester.widget<Image>(previewImage);
        expect(image.image, isA<MemoryImage>());
        expect((image.image as MemoryImage).bytes, same(other));
        expect(image.fit, BoxFit.contain);
        expect(
          find.descendant(
            of: preview,
            matching: find.byIcon(Icons.visibility_off),
          ),
          findsNothing,
        );
        expect(container.read(generateProvider), same(initial));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(preview, findsNothing);
        expect(container.read(generateProvider), same(initial));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'preview zooms, pans, resets and closes without changing references',
    (tester) async {
      final selections = <String>[];
      await mount(
        tester,
        ReferenceStrip(
          items: [(id: 'image', image: png, enabled: true)],
          selectedId: 'image',
          onSelect: selections.add,
          onReorder: (_, _) => fail('Preview must not reorder'),
        ),
      );
      await doubleClick(tester, find.byType(RefThumb));
      final viewer = find.descendant(
        of: preview,
        matching: find.byType(InteractiveViewer),
      );
      final transform = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(viewer),
          scrollDelta: const Offset(0, -160),
        ),
      );
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
      final beforePan = transform.value.clone();
      await tester.drag(
        viewer,
        const Offset(50, 30),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(transform.value, isNot(beforePan));
      await tester.tap(find.byTooltip('适应窗口'));
      await tester.pumpAndSettle();
      expect(transform.value, Matrix4.identity());
      await doubleClick(tester, viewer);
      expect(transform.value.getMaxScaleOnAxis(), 2.5);
      await doubleClick(tester, viewer);
      expect(transform.value, Matrix4.identity());
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();
      expect(preview, findsNothing);
      expect(selections, ['image']);
      await doubleClick(tester, find.byType(RefThumb));
      expect(preview, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '100 ms mouse hold still reorders real images without opening a preview',
    (tester) async {
      var items = [
        (id: 'one', image: png as Uint8List?, enabled: true),
        (id: 'two', image: other as Uint8List?, enabled: false),
        (id: 'three', image: png as Uint8List?, enabled: true),
      ];
      var selected = 'one';
      var reorders = 0;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 280,
            child: ReferenceStrip(
              items: items,
              selectedId: selected,
              onSelect: (id) => setState(() => selected = id),
              onReorder: (from, to) => setState(() {
                final next = [...items];
                next.insert(to, next.removeAt(from));
                items = next;
                reorders++;
              }),
            ),
          ),
        ),
      );
      final second = find.byKey(const ValueKey('two'));
      final drag = await tester.startGesture(
        tester.getCenter(second),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 110));
      for (var i = 0; i < 7; i++) {
        await drag.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 250));
      await drag.up();
      await tester.pumpAndSettle();
      expect(reorders, 1);
      expect(preview, findsNothing);
      expect(items.last.id, 'two');
      await doubleClick(tester, find.byKey(const ValueKey('two')));
      expect(
        (tester.widget<Image>(previewImage).image as MemoryImage).bytes,
        same(other),
      );
      expect(find.text('参考图预览 · 3'), findsOneWidget);
      expect(reorders, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('encoded-only Vibe remains selectable without an empty preview', (
    tester,
  ) async {
    var selected = '';
    await mount(
      tester,
      ReferenceStrip(
        items: const [(id: 'encoded', image: null, enabled: true)],
        selectedId: null,
        onSelect: (id) => selected = id,
        onReorder: (_, _) {},
      ),
    );
    await doubleClick(tester, find.byType(RefThumb));
    expect(selected, 'encoded');
    expect(preview, findsNothing);
  });

  testWidgets(
    'rapid clicks select each image immediately; only same-image repeat previews',
    (tester) async {
      var selected = 'one';
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) => ReferenceStrip(
            items: [
              (id: 'one', image: png, enabled: true),
              (id: 'two', image: other, enabled: false),
            ],
            selectedId: selected,
            onSelect: (id) => setState(() => selected = id),
            onReorder: (_, _) => fail('Click must not reorder'),
          ),
        ),
      );
      for (final id in ['one', 'two', 'one']) {
        await tester.tap(
          find.byKey(ValueKey(id)),
          kind: PointerDeviceKind.mouse,
        );
        expect(
          selected,
          id,
          reason: 'Selection must complete on pointer release',
        );
        await tester.pump();
        expect(preview, findsNothing);
        final thumb = find.descendant(
          of: find.byKey(ValueKey(id)),
          matching: find.byType(RefThumb),
        );
        expect(tester.widget<RefThumb>(thumb).selected, isTrue);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(
        find.byKey(const ValueKey('one')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(preview, findsOneWidget);
      expect(
        (tester.widget<Image>(previewImage).image as MemoryImage).bytes,
        same(png),
      );
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'timeout, wheel, keyboard, cancel and secondary click break the preview sequence',
    (tester) async {
      for (final interruption in [
        'timeout',
        'wheel',
        'keyboard',
        'other-key',
        'focus',
        'cancel',
        'secondary',
      ]) {
        var selected = 'one';
        await mount(
          tester,
          StatefulBuilder(
            builder: (context, setState) => ReferenceStrip(
              items: [
                (id: 'one', image: png, enabled: true),
                (id: 'two', image: other, enabled: true),
              ],
              selectedId: selected,
              onSelect: (id) => setState(() => selected = id),
              onReorder: (_, _) => fail('This sequence must not reorder'),
            ),
          ),
        );
        final second = find.byKey(const ValueKey('two'));
        await tester.tap(second, kind: PointerDeviceKind.mouse);
        expect(selected, 'two');
        await tester.pump(const Duration(milliseconds: 50));
        switch (interruption) {
          case 'timeout':
            await tester.pump(kDoubleTapTimeout);
          case 'wheel':
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: tester.getCenter(second),
                scrollDelta: const Offset(0, 30),
              ),
            );
          case 'keyboard':
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          case 'other-key':
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          case 'focus':
            FocusManager.instance.primaryFocus?.unfocus();
          case 'cancel':
            final press = await tester.startGesture(
              tester.getCenter(second),
              kind: PointerDeviceKind.mouse,
            );
            await press.cancel();
          case 'secondary':
            final press = await tester.startGesture(
              tester.getCenter(second),
              kind: PointerDeviceKind.mouse,
              buttons: kSecondaryButton,
            );
            await press.up();
        }
        await tester.pump();
        await tester.tap(second, kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(preview, findsNothing, reason: interruption);
        expect(selected, 'two');
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(second, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(preview, findsOneWidget, reason: interruption);
        await tester.tap(find.byTooltip('关闭预览'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'replacing image bytes resets the pending preview and opens the new original',
    (tester) async {
      final images = ValueNotifier<List<ReferencePreview>>([
        (id: 'one', image: png, enabled: true),
      ]);
      addTearDown(images.dispose);
      await mount(
        tester,
        ValueListenableBuilder(
          valueListenable: images,
          builder: (context, items, _) => ReferenceStrip(
            items: items,
            selectedId: 'one',
            onSelect: (_) {},
            onReorder: (_, _) {},
          ),
        ),
      );
      final thumb = find.byType(RefThumb);
      await tester.tap(thumb, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      images.value = [(id: 'one', image: other, enabled: true)];
      await tester.pump();
      await tester.tap(thumb, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(preview, findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(thumb, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(preview, findsOneWidget);
      expect(
        (tester.widget<Image>(previewImage).image as MemoryImage).bytes,
        same(other),
      );
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'accessibility activation selects without becoming a double-click',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var selections = 0;
        await mount(
          tester,
          ReferenceStrip(
            items: [(id: 'one', image: png, enabled: true)],
            selectedId: 'one',
            onSelect: (_) => selections++,
            onReorder: (_, _) {},
          ),
        );
        for (var tap = 0; tap < 2; tap++) {
          final node = tester.getSemantics(find.byType(RefThumb));
          node.owner!.performAction(node.id, SemanticsAction.tap);
          await tester.pump(const Duration(milliseconds: 50));
          expect(selections, tap + 1);
          expect(preview, findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('small window and large text keep preview controls visible', (
    tester,
  ) async {
    await mount(
      tester,
      ReferenceStrip(
        items: [(id: 'one', image: png, enabled: true)],
        selectedId: 'one',
        onSelect: (_) {},
        onReorder: (_, _) {},
      ),
      size: const Size(340, 420),
      textScale: 1.8,
    );
    await doubleClick(tester, find.byType(RefThumb));
    final rect = tester.getRect(preview);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(340));
    expect(rect.bottom, lessThanOrEqualTo(420));
    expect(tester.getSize(previewImage).height, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(preview, findsNothing);
  });

  testWidgets('mobile reference tap behavior stays unchanged', (tester) async {
    var selections = 0;
    await mount(
      tester,
      ReferenceStrip(
        items: [(id: 'one', image: png, enabled: true)],
        selectedId: 'one',
        onSelect: (_) => selections++,
        onReorder: (_, _) {},
      ),
      desktop: false,
    );
    await tester.tap(find.byType(RefThumb));
    await tester.pump();
    expect(selections, 1);
    expect(preview, findsNothing);
    expect(tester.widget<RefThumb>(find.byType(RefThumb)).onTapUp, isNull);
  });

  testWidgets('unreadable preview has a dismissible error state', (
    tester,
  ) async {
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showReferenceImagePreview(
            context,
            image: Uint8List.fromList([1, 2, 3]),
            title: '参考图',
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('这张参考图暂时无法读取'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(preview, findsNothing);
  });
}
