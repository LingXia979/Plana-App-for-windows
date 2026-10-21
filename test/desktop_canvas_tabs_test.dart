import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/desktop_canvas_tabs.dart';
import 'package:plana_app/main.dart';

import 'support/pump_until.dart';

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late List<String> ids;
  var disposed = false;

  setUp(() {
    disposed = false;
    FlutterSecureStorage.setMockInitialValues({});
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    final canvases = container.read(canvasWorkspaceProvider.notifier);
    final generate = container.read(generateProvider.notifier);
    ids = [container.read(canvasWorkspaceProvider).defaultId];
    generate.setPrompts(positive: 'default draft');
    for (var i = 1; i <= 8; i++) {
      ids.add(canvases.create());
      generate.setPrompts(positive: 'draft $i');
    }
    canvases.select(ids.first);
  });

  void disposeContainer() {
    if (disposed) return;
    container.dispose();
    disposed = true;
  }

  tearDown(disposeContainer);

  Finder key(String name) => find.byKey(ValueKey(name));
  Finder tab(String id) => key('desktop-canvas-$id');
  Finder label(String name) => find.widgetWithText(TextButton, name);

  Future<void> mount(
    WidgetTester tester, {
    double width = 310,
    bool fullWorkspace = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      disposeContainer();
      await pumpUntilComplete(tester, stores.flushForExit());
      stores.desktopOutput.root.parent.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: fullWorkspace
            ? const PlanaApp()
            : MaterialApp(
                theme: AppTheme.light(),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: const DesktopCanvasTabs(),
                    ),
                  ),
                ),
              ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    disposeContainer();
    await pumpUntilComplete(tester, stores.flushForExit());
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'overflow menu selects hidden canvases and preserves each draft',
    (tester) async {
      await mount(tester);
      expect(label('画布 8').hitTestable(), findsNothing);
      await tester.tap(key('desktop-canvas-picker'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '画布 8'),
      );
      await tester.pumpAndSettle();
      expect(container.read(canvasWorkspaceProvider).activeId, ids.last);
      expect(container.read(generateProvider).prompt, 'draft 8');
      expect(label('画布 8').hitTestable(), findsOneWidget);
      final list = find.byType(Scrollable).first;
      expect(
        tester.getRect(tab(ids.last)).right,
        lessThanOrEqualTo(tester.getRect(list).right + .01),
      );

      await tester.tap(key('desktop-canvas-actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建画布'));
      await tester.pumpAndSettle();
      expect(label('画布 9').hitTestable(), findsOneWidget);
      expect(container.read(generateProvider).prompt, isEmpty);

      await tester.tap(key('desktop-canvas-picker'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '默认画布'),
      );
      await tester.pumpAndSettle();
      expect(label('默认画布').hitTestable(), findsOneWidget);
      expect(container.read(generateProvider).prompt, 'default draft');
      expect(
        container.read(canvasWorkspaceProvider).find(ids.last)!.prompts.prompt,
        'draft 8',
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'wheel and mouse label drags browse without selecting or sorting',
    (tester) async {
      await mount(tester);
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      final scroll = list.scrollController!;
      final point = tester.getCenter(find.byType(Scrollable).first);
      Future<void> wheel(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: point, scrollDelta: delta),
        );
        await tester.pumpAndSettle();
      }

      await wheel(const Offset(0, 60));
      expect(scroll.offset, closeTo(60, .01));
      await wheel(const Offset(50, 0));
      expect(scroll.offset, closeTo(110, .01));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await wheel(const Offset(0, -40));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(scroll.offset, closeTo(70, .01));
      await wheel(const Offset(-1000, 0));
      expect(scroll.offset, 0);
      await tester.drag(
        label('画布 1'),
        const Offset(-100, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(container.read(canvasWorkspaceProvider).activeId, ids.first);
      expect(
        container
            .read(canvasWorkspaceProvider)
            .canvases
            .map((canvas) => canvas.id),
        ids,
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'hovered drag handle works in the complete workspace after scrolling',
    (tester) async {
      await tester.runAsync(() async {
        await stores.prefs.write(
          key: 'editor_settings',
          value: '{"enableCompletion":false}',
        );
        await stores.prefs.write(
          key: 'assistant_settings',
          value: '{"introVersion":$kAssistantIntroVersion}',
        );
      });
      container.read(canvasWorkspaceProvider.notifier).select(ids.last);
      await mount(tester, fullWorkspace: true);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (final scale in [1.0, 1.4]) {
        container
            .read(themeSettingsProvider.notifier)
            .patch((settings) => settings.copyWith(textScale: scale));
        for (final size in [const Size(900, 760), const Size(1400, 900)]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          final handle = find.descendant(
            of: tab(ids.last),
            matching: find.byType(ReorderableDragStartListener),
          );
          expect(handle.hitTestable(), findsOneWidget);
          await mouse.moveTo(tester.getCenter(handle));
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('拖动画布排序'), findsOneWidget);
          await mouse.down(tester.getCenter(handle));
          await mouse.moveBy(const Offset(-15, 10));
          await tester.pump(const Duration(milliseconds: 300));
          expect(key('desktop-canvas-drag-preview'), findsOneWidget);
          expect(find.text('拖动画布排序'), findsNothing);
          expect(tester.takeException(), isNull, reason: '$scale at $size');
          await mouse.up();
          await tester.pumpAndSettle();
          await mouse.moveTo(Offset.zero);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$scale at $size');
        }
      }
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
      expect(container.read(canvasWorkspaceProvider).activeId, ids.last);
      expect(container.read(generateProvider).prompt, 'draft 8');
      await finish(tester);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'drag handles still sort while keeping the default and active canvas',
    (tester) async {
      container.read(canvasWorkspaceProvider.notifier).select(ids[1]);
      await mount(tester, width: 1200);
      final handle = find.descendant(
        of: tab(ids[1]),
        matching: find.byType(ReorderableDragStartListener),
      );
      final next = tester.getRect(tab(ids[2]));
      final gesture = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump(const Duration(milliseconds: 250));
      await gesture.moveTo(Offset(next.center.dx + 20, next.center.dy));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      final workspace = container.read(canvasWorkspaceProvider);
      expect(workspace.canvases.map((canvas) => canvas.id), [
        ids[0],
        ids[2],
        ids[1],
        ...ids.skip(3),
      ]);
      expect(workspace.activeId, ids[1]);
      expect(container.read(generateProvider).prompt, 'draft 1');
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
}
