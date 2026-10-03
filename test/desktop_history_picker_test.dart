import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_image_tile.dart';
import 'package:plana_app/features/gallery/widgets/history_image_picker.dart';

import 'support/desktop_capture.dart';

void main() {
  late AppStores stores;
  late ProviderContainer container;
  List<ResultImage>? picked;
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });
  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> mount(
    WidgetTester tester, {
    int count = 5,
    bool multiple = true,
    Set<String>? allowedIds,
    String title = '从历史选择',
  }) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = File('assets/app_icon.png').readAsBytesSync();
    stores = AppStores.ephemeral();
    stores.gallery.initialResults = [
      for (var i = 0; i < count; i++)
        ResultImage(
          id: 'gen$i',
          width: 832,
          height: 1216,
          seed: i,
          bytes: bytes,
        ),
    ];
    stores.gallery.initialSelectedId = 'gen4';
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryThumbProvider.overrideWith((ref, id) async => bytes),
      ],
    );
    picked = null;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              platform: TargetPlatform.windows,
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => picked = await showHistoryImagePicker(
                    context,
                    multiple: multiple,
                    allowedIds: allowedIds,
                    title: title,
                  ),
                  child: const Text('打开历史'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开历史'));
    await tester.pumpAndSettle();
  }

  bool checked(WidgetTester tester, int id) =>
      tester.widget<GalleryImageTile>(key('history-image-gen$id')).picked;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'batch history uses gallery tiles and click toggles without Ctrl or marquee',
    (tester) async {
      await mount(tester);
      expect(key('history-marquee-area'), findsNothing);
      expect(
        tester
            .widgetList<GalleryImageTile>(find.byType(GalleryImageTile))
            .every((tile) => tile.selecting),
        isTrue,
      );
      await tester.tap(key('history-image-gen0'));
      await tester.tap(key('history-image-gen1'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(key('history-image-gen2'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        [for (var i = 0; i < 5; i++) checked(tester, i)],
        [true, true, true, false, false],
      );
      await tester.tap(key('history-image-gen1'));
      await tester.pumpAndSettle();
      expect(
        [for (var i = 0; i < 5; i++) checked(tester, i)],
        [true, false, true, false, false],
      );
      expect(key('history-selection-rectangle'), findsNothing);
      await captureDesktop(tester, capture, 'windows27-history-selection');
      await tester.tap(key('history-confirm-selection'));
      await tester.pumpAndSettle();
      expect(picked!.map((e) => e.id), ['gen0', 'gen2']);
      expect(container.read(galleryProvider).selectedId, 'gen4');
      await finish(tester);
    },
  );

  testWidgets(
    'a vertical history drag scrolls without changing the selection',
    (tester) async {
      await mount(tester, count: 40);
      await tester.tap(key('history-image-gen0'));
      await tester.pumpAndSettle();
      expect(key('history-selection-rectangle'), findsNothing);
      final gridKey = find.byKey(const PageStorageKey('metadata-history-grid'));
      final grid = tester.widget<GridView>(gridKey);
      await tester.drag(gridKey, const Offset(0, -280));
      await tester.pumpAndSettle();
      expect(grid.controller!.offset, greaterThan(100));
      expect(find.text('添加（1 张）'), findsOneWidget);
      grid.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      expect(checked(tester, 0), isTrue);
      expect(checked(tester, 1), isFalse);
      await tester.tap(key('history-confirm-selection'));
      await tester.pumpAndSettle();
      expect(picked!.map((e) => e.id), ['gen0']);
      await finish(tester);
    },
  );

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      '${kind.name} history sweep adds or removes an ordered range and restores it when shrinking',
      (tester) async {
        await mount(tester);
        await tester.tap(key('history-image-gen4'));
        await tester.pumpAndSettle();
        Offset point(int id) => tester.getCenter(key('history-image-gen$id'));
        List<int> selected() => [
          for (var i = 0; i < 5; i++)
            if (checked(tester, i)) i,
        ];
        var press = await tester.startGesture(point(0), kind: kind);
        await press.moveTo(point(2));
        await tester.pump();
        expect(selected(), [0, 1, 2, 4]);
        // A sweep already owns the gesture; waiting through the 200ms hold
        // threshold cannot fire a second selection action.
        await tester.pump(const Duration(milliseconds: 250));
        expect(selected(), [0, 1, 2, 4]);
        await press.moveTo(point(4));
        await tester.pump();
        expect(selected(), [0, 1, 2, 3, 4]);
        await press.moveTo(point(1));
        await tester.pump();
        expect(selected(), [0, 1, 4]);
        await press.up();
        await tester.pumpAndSettle();
        expect(selected(), [0, 1, 4]);
        press = await tester.startGesture(point(1), kind: kind);
        await press.moveTo(point(2));
        await tester.pump();
        expect(selected(), [0, 4]);
        await press.moveTo(point(4));
        await tester.pump();
        expect(selected(), [0]);
        await press.moveTo(point(2));
        await tester.pump();
        expect(selected(), [0, 4]);
        await press.moveTo(point(0));
        await tester.pump();
        expect(selected(), [4]);
        await press.up();
        await tester.pumpAndSettle();
        expect(selected(), [4]);
        expect(key('history-selection-rectangle'), findsNothing);
        await captureDesktop(tester, capture, 'windows28-history-sweep');
        await tester.tap(key('history-confirm-selection'));
        await tester.pumpAndSettle();
        expect(picked!.map((e) => e.id), ['gen4']);
        expect(container.read(galleryProvider).selectedId, 'gen4');
        await finish(tester);
      },
    );
  }

  testWidgets(
    'history sweep auto-scrolls at the edge and selects every image in between',
    (tester) async {
      await mount(tester, count: 80);
      final gridKey = find.byKey(const PageStorageKey('metadata-history-grid'));
      final grid = tester.widget<GridView>(gridKey);
      final viewport = tester.getRect(gridKey);
      final endX = tester.getCenter(key('history-image-gen2')).dx;
      final mouse = await tester.startGesture(
        tester.getCenter(key('history-image-gen0')),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(tester.getCenter(key('history-image-gen2')));
      await tester.pump();
      await mouse.moveTo(Offset(endX, viewport.bottom - 2));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(grid.controller!.offset, greaterThan(400));
      await mouse.up();
      await tester.pumpAndSettle();
      final stopped = grid.controller!.offset;
      final summary = tester.widget<Text>(find.textContaining('添加（')).data;
      await tester.pump(const Duration(milliseconds: 400));
      expect(grid.controller!.offset, stopped);
      expect(find.text(summary!), findsOneWidget);
      await tester.tap(key('history-confirm-selection'));
      await tester.pumpAndSettle();
      expect(picked!.length, greaterThan(9));
      expect(picked!.map((image) => image.id), [
        for (var i = 0; i < picked!.length; i++) 'gen$i',
      ]);
      await finish(tester);
    },
  );

  testWidgets(
    'wheel scrolling cancels a pending history click or sweep at a boundary',
    (tester) async {
      await mount(tester, count: 2);
      final point = tester.getCenter(key('history-image-gen0'));
      final mouse = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 80));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: point,
          scrollDelta: const Offset(0, -80),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(checked(tester, 0), isFalse);
      expect(checked(tester, 1), isFalse);
      expect(find.text('添加（0 张）'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'history mouse drag selects immediately and release keeps it checked',
    (tester) async {
      await mount(tester);
      final mouse = await tester.startGesture(
        tester.getCenter(key('history-image-gen0')),
        kind: PointerDeviceKind.mouse,
      );
      expect(checked(tester, 0), isFalse);
      await mouse.moveBy(const Offset(5, 0));
      await tester.pump();
      expect(checked(tester, 0), isTrue);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(checked(tester, 0), isTrue);
      expect(picked, isNull);
      await tester.tap(key('history-select-all'));
      await tester.pumpAndSettle();
      expect(find.text('添加（5 张）'), findsOneWidget);
      await tester.tap(key('history-select-all'));
      await tester.pumpAndSettle();
      expect(find.text('添加（0 张）'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(key('history-confirm-selection')).onPressed,
        isNull,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'single history selection remains one click without multi-select',
    (tester) async {
      await mount(tester, multiple: false);
      expect(key('history-marquee-area'), findsNothing);
      expect(key('history-confirm-selection'), findsNothing);
      expect(
        tester.widget<GalleryImageTile>(key('history-image-gen2')).selecting,
        isFalse,
      );
      final mouse = await tester.startGesture(
        tester.getCenter(key('history-image-gen0')),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(tester.getCenter(key('history-image-gen2')));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(picked, isNull);
      await tester.tap(key('history-image-gen2'));
      await tester.pumpAndSettle();
      expect(picked!.map((e) => e.id), ['gen2']);
      expect(container.read(galleryProvider).selectedId, 'gen4');
      await finish(tester);
    },
  );

  testWidgets(
    'cover selection can restrict history to the supplied album IDs',
    (tester) async {
      await mount(
        tester,
        multiple: false,
        allowedIds: {'gen1', 'gen3'},
        title: '从这个图库里选择',
      );
      expect(find.text('从这个图库里选择'), findsOneWidget);
      expect(key('history-image-gen0'), findsNothing);
      expect(key('history-image-gen1'), findsOneWidget);
      expect(key('history-image-gen2'), findsNothing);
      expect(key('history-image-gen3'), findsOneWidget);
      await tester.tap(key('history-image-gen3'));
      await tester.pumpAndSettle();
      expect(picked!.map((e) => e.id), ['gen3']);
      await finish(tester);
    },
  );

  testWidgets('an empty album scope never falls back to all history', (
    tester,
  ) async {
    await mount(tester, allowedIds: {});
    expect(find.text('这个图库暂无图片'), findsOneWidget);
    expect(find.byType(GalleryImageTile), findsNothing);
    expect(
      tester.widget<FilledButton>(key('history-confirm-selection')).onPressed,
      isNull,
    );
    expect(
      tester.widget<TextButton>(key('history-select-all')).onPressed,
      isNull,
    );
    await finish(tester);
  });

  testWidgets(
    'narrow history keeps the shared selection grid and actions usable',
    (tester) async {
      await mount(tester);
      tester.view.physicalSize = const Size(480, 640);
      await tester.pumpAndSettle();
      expect(key('history-image-gen0').hitTestable(), findsOneWidget);
      await tester.tap(key('history-image-gen0'));
      await tester.pumpAndSettle();
      expect(key('history-select-all').hitTestable(), findsOneWidget);
      expect(key('history-confirm-selection').hitTestable(), findsOneWidget);
      await tester.tap(key('history-confirm-selection'));
      await tester.pumpAndSettle();
      expect(picked!.map((e) => e.id), ['gen0']);
      await finish(tester);
    },
  );
}
