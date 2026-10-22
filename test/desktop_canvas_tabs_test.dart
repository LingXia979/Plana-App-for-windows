import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/main.dart';

import 'support/pump_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    for (final entry in [
      ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ('monospace', r'C:\Windows\Fonts\consola.ttf'),
      ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
      (
        'MaterialIcons',
        r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      ),
    ]) {
      final file = File(entry.$2);
      await (FontLoader(
        entry.$1,
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  late AppStores stores;
  late ProviderContainer container;
  late List<String> ids;
  var disposed = false;
  final capture = GlobalKey();

  setUp(() {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] == '1') {
      debugDisableShadows = false;
    }
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

  tearDown(() {
    debugDisableShadows = true;
    disposeContainer();
  });

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
        child: RepaintBoundary(
          key: capture,
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
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    disposeContainer();
    await pumpUntilComplete(tester, stores.flushForExit());
    debugDisableShadows = true;
    expect(tester.takeException(), isNull);
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/windows-validation/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
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

      await tester.tap(key('desktop-canvas-new'));
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

  testWidgets('wheel browses without selecting or sorting', (tester) async {
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
  });

  testWidgets(
    'hovered tab label drags in the complete workspace after scrolling',
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
          final handle = label('画布 8');
          expect(handle.hitTestable(), findsOneWidget);
          await mouse.moveTo(tester.getCenter(handle));
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('画布 8'), findsNWidgets(2));
          await mouse.down(tester.getCenter(handle));
          await mouse.moveBy(const Offset(-15, 10));
          await tester.pump(const Duration(milliseconds: 300));
          expect(key('desktop-canvas-drag-preview'), findsOneWidget);
          expect(find.byIcon(Icons.drag_indicator), findsNothing);
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
    'pressing and dragging the label sorts without a handle or long press',
    (tester) async {
      container.read(canvasWorkspaceProvider.notifier).select(ids[1]);
      await mount(tester, width: 1200);
      final handle = label('画布 1');
      final next = tester.getRect(tab(ids[2]));
      final start = tester.getCenter(handle);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      expect(key('desktop-canvas-drag-preview'), findsOneWidget);
      for (var step = 1; step <= 8; step++) {
        await gesture.moveTo(
          Offset(start.dx + 24 + (next.width - 24) * step / 8, next.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
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

  Future<void> rightClick(WidgetTester tester, String id) async {
    await tester.tap(
      tab(id),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  Future<void> shortcut(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
    bool shift = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  final editor = find.byKey(const ValueKey('desktop-canvas-name-editor'));

  Future<void> submitName(WidgetTester tester) async {
    // Desktop Enter reaches TextField through the platform text input action.
    // A raw test key event alone does not emulate that platform response.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
  }

  testWidgets(
    'close button confirms, cancels and restores the active canvas with its draft',
    (tester) async {
      container.read(canvasWorkspaceProvider.notifier).select(ids[1]);
      await mount(tester, width: 1200);
      expect(key('desktop-canvas-close-${ids.first}'), findsNothing);
      await tester.tap(key('desktop-canvas-close-${ids[1]}'));
      await tester.pumpAndSettle();
      expect(find.text('删除「画布 1」？'), findsOneWidget);
      expect(container.read(canvasWorkspaceProvider).find(ids[1]), isNotNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(container.read(generateProvider).prompt, 'draft 1');
      await shortcut(tester, LogicalKeyboardKey.f2);
      await tester.enterText(editor, '关闭前改名');
      await tester.tap(key('desktop-canvas-close-${ids[1]}'));
      await tester.pumpAndSettle();
      expect(find.text('删除「关闭前改名」？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(container.read(canvasWorkspaceProvider).find(ids[1]), isNull);
      expect(container.read(canvasWorkspaceProvider).activeId, ids[2]);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(container.read(canvasWorkspaceProvider).activeId, ids[1]);
      expect(container.read(canvasWorkspaceProvider).active.name, '关闭前改名');
      expect(container.read(generateProvider).prompt, 'draft 1');
      await finish(tester);
    },
  );

  testWidgets(
    'closing a background tab preserves current editing and its close button never reorders',
    (tester) async {
      container.read(canvasWorkspaceProvider.notifier).select(ids[1]);
      await mount(tester, width: 1200);
      final close = key('desktop-canvas-close-${ids[2]}');
      await tester.drag(
        close,
        const Offset(100, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        container.read(canvasWorkspaceProvider).canvases.map((c) => c.id),
        ids,
      );
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.text('删除「画布 2」？'), findsOneWidget);
      expect(container.read(canvasWorkspaceProvider).activeId, ids[1]);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(container.read(canvasWorkspaceProvider).find(ids[2]), isNull);
      expect(container.read(canvasWorkspaceProvider).activeId, ids[1]);
      expect(container.read(generateProvider).prompt, 'draft 1');
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(container.read(canvasWorkspaceProvider).activeId, ids[1]);
      expect(
        container.read(canvasWorkspaceProvider).find(ids[2])!.prompts.prompt,
        'draft 2',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'right click selects its canvas; menu F2 renames inline with all text selected',
    (tester) async {
      await mount(tester, width: 1200);
      await rightClick(tester, ids[2]);
      expect(container.read(canvasWorkspaceProvider).activeId, ids[2]);
      expect(container.read(generateProvider).prompt, 'draft 2');
      expect(find.widgetWithText(MenuItemButton, '复制当前画布'), findsOneWidget);
      await shortcut(tester, LogicalKeyboardKey.f2);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(MenuItemButton, '复制当前画布'), findsNothing);
      expect(editor, findsOneWidget);
      final field = tester.widget<TextField>(editor);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
        field.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      await tester.enterText(editor, '第二个草稿');
      await submitName(tester);
      expect(editor, findsNothing);
      expect(
        container.read(canvasWorkspaceProvider).find(ids[2])!.name,
        '第二个草稿',
      );
      expect(
        container.read(canvasWorkspaceProvider).find(ids[1])!.name,
        '画布 1',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'F2 after click cancels with Escape, saves on blur and keeps empty names unchanged',
    (tester) async {
      await mount(tester, width: 1200);
      await tester.tap(label('画布 1'));
      await shortcut(tester, LogicalKeyboardKey.f2);
      await tester.enterText(editor, '取消的名字');
      await shortcut(tester, LogicalKeyboardKey.escape);
      expect(
        container.read(canvasWorkspaceProvider).find(ids[1])!.name,
        '画布 1',
      );
      await shortcut(tester, LogicalKeyboardKey.f2);
      await tester.enterText(editor, '保留的名字');
      await tester.tap(label('画布 2'));
      await tester.pumpAndSettle();
      expect(
        container.read(canvasWorkspaceProvider).find(ids[1])!.name,
        '保留的名字',
      );
      expect(container.read(canvasWorkspaceProvider).activeId, ids[2]);
      await shortcut(tester, LogicalKeyboardKey.f2);
      await tester.enterText(editor, '   ');
      await submitName(tester);
      expect(
        container.read(canvasWorkspaceProvider).find(ids[2])!.name,
        '画布 2',
      );
      expect(container.read(generateProvider).prompt, 'draft 2');
      await finish(tester);
    },
  );

  testWidgets('menu rename and copy act on the right-clicked canvas', (
    tester,
  ) async {
    await mount(tester, width: 1200);
    await rightClick(tester, ids[3]);
    await tester.tap(find.widgetWithText(MenuItemButton, '重命名'));
    await tester.pumpAndSettle();
    expect(editor, findsOneWidget);
    await tester.enterText(editor, '右键草稿');
    await submitName(tester);
    await rightClick(tester, ids[3]);
    await tester.tap(find.widgetWithText(MenuItemButton, '复制当前画布'));
    await tester.pumpAndSettle();
    final workspace = container.read(canvasWorkspaceProvider);
    expect(workspace.canvases.length, ids.length + 1);
    expect(workspace.active.name, '右键草稿 · 副本');
    expect(container.read(generateProvider).prompt, 'draft 3');
    await finish(tester);
  });

  testWidgets(
    'Ctrl Shift N creates a blank canvas once; Ctrl D confirms and supports undo',
    (tester) async {
      await mount(tester, width: 1200);
      await tester.tap(label('画布 1'));
      await shortcut(
        tester,
        LogicalKeyboardKey.keyN,
        control: true,
        shift: true,
      );
      var workspace = container.read(canvasWorkspaceProvider);
      expect(workspace.canvases.length, ids.length + 1);
      final created = workspace.activeId;
      expect(container.read(generateProvider).prompt, isEmpty);
      await shortcut(tester, LogicalKeyboardKey.keyD, control: true);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(container.read(canvasWorkspaceProvider).find(created), isNotNull);
      await shortcut(tester, LogicalKeyboardKey.keyD, control: true);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(container.read(canvasWorkspaceProvider).find(created), isNull);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      workspace = container.read(canvasWorkspaceProvider);
      expect(workspace.activeId, created);
      expect(workspace.canvases.length, ids.length + 1);
      await finish(tester);
    },
  );

  testWidgets(
    'default canvas rejects rename and delete from menu and shortcuts',
    (tester) async {
      await mount(tester, width: 1200);
      await rightClick(tester, ids.first);
      expect(
        tester
            .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, '重命名'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<MenuItemButton>(
              find.widgetWithText(MenuItemButton, '删除当前画布'),
            )
            .onPressed,
        isNull,
      );
      await shortcut(tester, LogicalKeyboardKey.f2);
      expect(editor, findsNothing);
      await shortcut(tester, LogicalKeyboardKey.keyD, control: true);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        container.read(canvasWorkspaceProvider).canvases.length,
        ids.length,
      );
      expect(container.read(canvasWorkspaceProvider).active.name, '默认画布');
      expect(container.read(generateProvider).prompt, 'default draft');
      await finish(tester);
    },
  );

  testWidgets(
    'workspace shortcuts reach the canvas while editing and are inactive on other pages',
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
      await mount(tester, fullWorkspace: true);
      final input = find.byType(TextField).hitTestable().first;
      await tester.tap(input);
      await shortcut(
        tester,
        LogicalKeyboardKey.keyN,
        control: true,
        shift: true,
      );
      expect(
        container.read(canvasWorkspaceProvider).canvases.length,
        ids.length + 1,
      );
      await tester.tap(find.byType(TextField).hitTestable().first);
      await shortcut(tester, LogicalKeyboardKey.f2);
      expect(editor, findsOneWidget);
      await tester.enterText(editor, '工作台改名');
      await shortcut(tester, LogicalKeyboardKey.enter, control: true);
      expect(container.read(canvasWorkspaceProvider).active.name, '工作台改名');
      container.read(shellIndexProvider.notifier).select(kTabGallery);
      await tester.pumpAndSettle();
      await shortcut(
        tester,
        LogicalKeyboardKey.keyN,
        control: true,
        shift: true,
      );
      await shortcut(tester, LogicalKeyboardKey.keyD, control: true);
      expect(
        container.read(canvasWorkspaceProvider).canvases.length,
        ids.length + 1,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'held shortcuts run once and default tab cannot be dragged away',
    (tester) async {
      await mount(tester, width: 1200);
      await tester.drag(
        label('默认画布'),
        const Offset(170, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        container.read(canvasWorkspaceProvider).canvases.map((c) => c.id),
        ids,
      );
      await rightClick(tester, ids.first);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        container.read(canvasWorkspaceProvider).canvases.length,
        ids.length + 1,
      );
      expect(find.widgetWithText(MenuItemButton, '新建画布'), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await tester.enterText(editor, '按键草稿');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, '按键草稿');
      await submitName(tester);
      await finish(tester);
    },
  );

  testWidgets(
    'long inline names and context menus fit the workspace at normal and large text',
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
      final canvases = container.read(canvasWorkspaceProvider.notifier);
      canvases.rename(ids.last, '长名称画布 · 提示词与参数草稿');
      canvases.select(ids.last);
      await mount(tester, fullWorkspace: true);
      for (final scale in [1.0, 1.4]) {
        tester.view.physicalSize = scale == 1
            ? const Size(1400, 900)
            : const Size(900, 760);
        container
            .read(themeSettingsProvider.notifier)
            .patch((s) => s.copyWith(textScale: scale));
        await tester.pumpAndSettle();
        final viewport = find
            .descendant(
              of: key('desktop-canvas-tabs'),
              matching: find.byType(Scrollable),
            )
            .first;
        expect(
          tester.getRect(tab(ids.last)).right,
          lessThanOrEqualTo(tester.getRect(viewport).right + .01),
        );
        await rightClick(tester, ids.last);
        expect(find.widgetWithText(MenuItemButton, '重命名'), findsOneWidget);
        await screenshot(tester, 'windows51-menu-${(scale * 100).round()}');
        await shortcut(tester, LogicalKeyboardKey.f2);
        expect(editor.hitTestable(), findsOneWidget);
        final field = tester.widget<TextField>(editor);
        expect(
          field.controller!.selection,
          TextSelection(
            baseOffset: 0,
            extentOffset: field.controller!.text.length,
          ),
        );
        await screenshot(tester, 'windows51-rename-${(scale * 100).round()}');
        expect(tester.takeException(), isNull);
        await shortcut(tester, LogicalKeyboardKey.escape);
      }
      await finish(tester);
    },
  );
}
