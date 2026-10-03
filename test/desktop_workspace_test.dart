import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/features/inpaint/inpaint_overlay.dart';
import 'package:plana_app/main.dart';

class _ChatRecorder extends AssistantNotifier {
  final sent = <String>[];
  @override
  AssistantState build() => const AssistantState();
  @override
  Future<void> send(
    String text, {
    Uint8List? image,
    List<Uint8List> images = const [],
    bool withCanvas = false,
    void Function()? onAccepted,
  }) async {
    sent.add(text);
    onAccepted?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.isWindows) {
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
        if (await file.exists()) {
          await (FontLoader(
            entry.$1,
          )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
        }
      }
    }
  });
  late AppStores stores;
  late ProviderContainer c;
  var disposed = false;
  final capture = GlobalKey();
  setUp(() async {
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: '{"enableCompletion":false}',
    );
    disposed = false;
    for (final key in [
      'hint_grid_longpress',
      'hint_save_longpress',
      'hint_strip_swipe',
    ]) {
      await stores.prefs.write(key: key, value: '1');
    }
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    c.read(desktopLibraryProvider);
  });
  tearDown(() {
    if (!disposed) c.dispose();
    stores.flushNow();
  });
  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(key: capture, child: const PlanaApp()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();
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

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> resizePane(WidgetTester tester, String side, double dx) async {
    final gesture = await tester.startGesture(
      tester.getCenter(key('desktop-$side-divider')),
      kind: ui.PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> drainWrites(WidgetTester tester) async {
    stores.flushNow();
    var done = false;
    unawaited(
      Future.wait([
        stores.gallery.idle,
        stores.albums.idle,
      ]).then((_) => done = true),
    );
    for (var i = 0; i < 100 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done, isTrue, reason: 'Pending gallery writes must finish');
    c.dispose();
    disposed = true;
  }

  testWidgets('步数引导摘要定位设置，种子快捷清空，比例仍使用浮窗', (tester) async {
    await tester.runAsync(
      () => stores.prefs.write(
        key: 'desktop_generation_settings_expanded',
        value: '0',
      ),
    );
    final gen = c.read(generateProvider.notifier);
    gen.applyParams(
      c
          .read(generateProvider)
          .params
          .withActiveSteps(27)
          .copyWith(cfg: 5.5, seed: '12345678'),
    );
    await mount(tester, const Size(1440, 900));
    expect(key('desktop-steps'), findsNothing);
    final viewport = find.byKey(
      const PageStorageKey('desktop-controls-scroll'),
    );
    for (final pair in [
      ('steps', 'desktop-steps'),
      ('guidance', 'desktop-guidance'),
    ]) {
      await tester.tap(key('desktop-summary-${pair.$1}'));
      await tester.pumpAndSettle();
      final target = tester.getRect(key(pair.$2));
      final view = tester.getRect(viewport);
      expect(target.top, greaterThanOrEqualTo(view.top));
      expect(target.bottom, lessThanOrEqualTo(view.bottom));
    }
    expect(c.read(generateProvider).params.seed, '12345678');
    final scroll = tester.widget<SingleChildScrollView>(viewport).controller!;
    final beforeClear = scroll.offset;
    await tester.tap(key('desktop-summary-seed'));
    await tester.pumpAndSettle();
    expect(c.read(generateProvider).params.seed, isEmpty);
    expect(
      tester.widget<TextField>(key('desktop-seed')).controller!.text,
      isEmpty,
    );
    expect(scroll.offset, beforeClear);
    expect(
      find.descendant(
        of: key('desktop-summary-seed'),
        matching: find.text('随机'),
      ),
      findsOneWidget,
    );
    await screenshot(tester, 'windows17-generation-summary');
    await tester.tap(key('desktop-summary-resolution'));
    await tester.pumpAndSettle();
    expect(find.text('自定义'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('自定义'), findsNothing);
    tester.view.physicalSize = const Size(1024, 700);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await drainWrites(tester);
  });

  testWidgets('分隔线支持鼠标调整两侧宽度、边界限制及双击恢复', (tester) async {
    c.dispose();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantProvider.overrideWith(_ChatRecorder.new),
        assistantEndpointProvider.overrideWithValue(
          const CustomEndpoint(
            id: 'test',
            name: '本地测试接口',
            format: AgentApiFormat.openai,
            baseUrl: 'http://127.0.0.1:1',
            apiKey: 'local-test-only',
            model: 'test',
          ),
        ),
        assistantModelProvider.overrideWithValue(
          const AgentModelChoice(key: 'test', name: '本地测试接口'),
        ),
      ],
    );
    c
        .read(generateProvider.notifier)
        .setPrompts(
          positive:
              'mountain landscape, 1.5::sunrise, golden clouds::, 0.7::mist::',
        );
    await mount(tester, const Size(1440, 900));
    final input = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '想画什么、想改哪里…',
    );
    await tester.enterText(input, '调整宽度时保留的草稿');
    double width(String id) => tester.getSize(key(id)).width;
    final left = width('desktop-controls');
    final right = width('desktop-dock');
    final canvas = width('desktop-canvas');

    await resizePane(tester, 'left', 110);
    expect(width('desktop-controls'), closeTo(left + 110, .01));
    expect(width('desktop-dock'), closeTo(right, .01));
    expect(width('desktop-canvas'), closeTo(canvas - 110, .01));
    await resizePane(tester, 'right', -85);
    expect(width('desktop-dock'), closeTo(right + 85, .01));
    expect(width('desktop-controls'), closeTo(left + 110, .01));
    expect(width('desktop-canvas'), closeTo(canvas - 195, .01));
    expect(tester.widget<TextField>(input).controller!.text, '调整宽度时保留的草稿');
    expect(
      double.parse(stores.prefs.get('desktop_left_pane_width')!),
      closeTo(left + 110, .01),
    );
    expect(
      double.parse(stores.prefs.get('desktop_right_pane_width')!),
      closeTo(right + 85, .01),
    );
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'resizable-sidebars');

    await resizePane(tester, 'left', -2000);
    expect(width('desktop-controls'), closeTo(300, .01));
    await resizePane(tester, 'right', 2000);
    expect(width('desktop-dock'), closeTo(330, .01));
    await resizePane(tester, 'left', 2000);
    expect(width('desktop-canvas'), closeTo(360, .01));
    await resizePane(tester, 'left', -2000);
    await resizePane(tester, 'right', -2000);
    expect(width('desktop-canvas'), closeTo(360, .01));
    expect(tester.takeException(), isNull);

    for (final side in ['left', 'right']) {
      await tester.tap(key('desktop-$side-divider'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(key('desktop-$side-divider'));
      await tester.pumpAndSettle();
      expect(stores.prefs.get('desktop_${side}_pane_width'), isNull);
    }
    expect(width('desktop-controls'), closeTo(left, .01));
    expect(width('desktop-dock'), closeTo(right, .01));
    expect(width('desktop-canvas'), closeTo(canvas, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('侧栏宽度随窗口收缩并在恢复窗口和重新打开后保留', (tester) async {
    await mount(tester, const Size(1440, 900));
    await resizePane(tester, 'left', 120);
    await resizePane(tester, 'right', -100);
    final left = tester.getSize(key('desktop-controls')).width;
    final right = tester.getSize(key('desktop-dock')).width;
    final savedLeft = stores.prefs.get('desktop_left_pane_width');
    final savedRight = stores.prefs.get('desktop_right_pane_width');

    tester.view.physicalSize = const Size(1100, 768);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(key('desktop-controls')).width,
      greaterThanOrEqualTo(300),
    );
    expect(
      tester.getSize(key('desktop-dock')).width,
      greaterThanOrEqualTo(330),
    );
    expect(tester.getSize(key('desktop-canvas')).width, closeTo(360, .01));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(880, 640);
    await tester.pumpAndSettle();
    expect(key('desktop-right-divider'), findsNothing);
    expect(
      tester.getSize(key('desktop-canvas')).width,
      greaterThanOrEqualTo(360),
    );
    await tester.tap(key('desktop-ai-tab'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'resizable-sidebars-compact');
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(tester.getSize(key('desktop-controls')).width, closeTo(left, .01));
    expect(tester.getSize(key('desktop-dock')).width, closeTo(right, .01));
    expect(stores.prefs.get('desktop_left_pane_width'), savedLeft);
    expect(stores.prefs.get('desktop_right_pane_width'), savedRight);

    // A fresh workspace reads the original choice, not the temporarily fitted
    // widths from the smaller window.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await mount(tester, const Size(1440, 900));
    expect(tester.getSize(key('desktop-controls')).width, closeTo(left, .01));
    expect(tester.getSize(key('desktop-dock')).width, closeTo(right, .01));
    tester.view.physicalSize = const Size(880, 640);
    await tester.pumpAndSettle();
    await resizePane(tester, 'left', -40);
    expect(
      tester.getSize(key('desktop-controls')).width,
      closeTo(left - 40, .01),
    );
    expect(
      tester.getSize(key('desktop-canvas')).width,
      greaterThanOrEqualTo(360),
    );
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(key('desktop-controls')).width,
      closeTo(left - 40, .01),
    );
    expect(tester.getSize(key('desktop-dock')).width, closeTo(right, .01));
    expect(
      double.parse(stores.prefs.get('desktop_left_pane_width')!),
      closeTo(left - 40, .01),
    );
    expect(stores.prefs.get('desktop_right_pane_width'), savedRight);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('窗口收窄后拖动分隔线时另一侧不跳动', (tester) async {
    await mount(tester, const Size(1440, 900));
    await resizePane(tester, 'left', 120);
    await resizePane(tester, 'right', -100);
    tester.view.physicalSize = const Size(1100, 768);
    await tester.pumpAndSettle();
    final left = tester.getSize(key('desktop-controls')).width;
    final right = tester.getSize(key('desktop-dock')).width;
    await resizePane(tester, 'left', -30);
    expect(
      tester.getSize(key('desktop-controls')).width,
      closeTo(left - 30, .01),
    );
    expect(tester.getSize(key('desktop-dock')).width, closeTo(right, .01));
    expect(tester.getSize(key('desktop-canvas')).width, closeTo(390, .01));
    await resizePane(tester, 'right', 25);
    expect(
      tester.getSize(key('desktop-controls')).width,
      closeTo(left - 30, .01),
    );
    expect(tester.getSize(key('desktop-dock')).width, closeTo(right - 25, .01));
    expect(tester.getSize(key('desktop-canvas')).width, closeTo(415, .01));
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(key('desktop-controls')).width,
      closeTo(left - 30, .01),
    );
    expect(tester.getSize(key('desktop-dock')).width, closeTo(right - 25, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('画布到最小宽度后两侧栏可互相挤压并保存', (tester) async {
    await mount(tester, const Size(1440, 900));
    double width(String name) => tester.getSize(key(name)).width;
    await resizePane(tester, 'left', 180);
    final initialLeft = width('desktop-controls');
    final room = width('desktop-canvas') - 360;
    final initialRight = width('desktop-dock');
    await resizePane(tester, 'right', -(room + 90));
    expect(width('desktop-canvas'), closeTo(360, .01));
    expect(width('desktop-controls'), closeTo(initialLeft - 90, .01));
    expect(width('desktop-dock'), closeTo(initialRight + room + 90, .01));
    final right = width('desktop-dock');
    await resizePane(tester, 'left', 100);
    expect(width('desktop-canvas'), closeTo(360, .01));
    expect(width('desktop-controls'), closeTo(initialLeft + 10, .01));
    expect(width('desktop-dock'), closeTo(right - 100, .01));
    final savedLeft = width('desktop-controls');
    final savedRight = width('desktop-dock');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await mount(tester, const Size(1440, 900));
    expect(width('desktop-controls'), closeTo(savedLeft, .01));
    expect(width('desktop-dock'), closeTo(savedRight, .01));
    await resizePane(tester, 'right', -2000);
    expect(width('desktop-controls'), closeTo(300, .01));
    expect(width('desktop-canvas'), closeTo(360, .01));
    await resizePane(tester, 'left', 2000);
    expect(width('desktop-dock'), closeTo(330, .01));
    expect(width('desktop-canvas'), closeTo(360, .01));
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'sidebar-pressure');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('AI 侧栏输入与快捷键在窄窗可用，不触发图片生成', (tester) async {
    c.dispose();
    final chat = _ChatRecorder();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantProvider.overrideWith(() => chat),
        assistantEndpointProvider.overrideWithValue(
          const CustomEndpoint(
            id: 'test',
            name: '本地测试接口',
            format: AgentApiFormat.openai,
            baseUrl: 'http://127.0.0.1:1',
            apiKey: 'local-test-only',
            model: 'test',
          ),
        ),
        assistantModelProvider.overrideWithValue(
          const AgentModelChoice(key: 'test', name: '本地测试接口'),
        ),
      ],
    );
    await mount(tester, const Size(1280, 800));
    final input = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '想画什么、想改哪里…',
    );
    await tester.enterText(input, '帮我整理提示词');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chat.sent, ['帮我整理提示词']);
    await tester.enterText(input, '第一行');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(chat.sent.length, 1);
    expect(tester.widget<TextField>(input).controller!.text, '第一行\n');
    tester.widget<TextField>(input).controller!.value = const TextEditingValue(
      text: '中文候选',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 0, end: 4),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(chat.sent.length, 1, reason: '输入法确认候选不能发送');
    tester.widget<TextField>(input).controller!.clearComposing();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chat.sent, ['帮我整理提示词', '中文候选']);
    expect(find.text('请先在「我的」页设置 NovelAI API Token'), findsNothing);
    tester.view.physicalSize = const Size(880, 640);
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-ai-tab'));
    await tester.pumpAndSettle();
    expect(input, findsOneWidget);
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'assistant');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets(
    '长提示词的侧栏滚动条按鼠标距离稳定移动',
    (tester) async {
      c
          .read(generateProvider.notifier)
          .setPrompts(
            positive: List.generate(
              180,
              (i) => 'mountain $i, 1.2::golden clouds::',
            ).join(', '),
          );
      await mount(tester, const Size(1440, 900));
      final scrollbar = key('desktop-controls-scrollbar');
      final position = tester.widget<Scrollbar>(scrollbar).controller!.position;
      final extent = position.maxScrollExtent;
      expect(extent, greaterThan(5000));
      final rect = tester.getRect(scrollbar);
      final drag = await tester.startGesture(
        Offset(rect.right - 5, rect.top + 12),
        kind: ui.PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 30));
      await tester.pumpAndSettle();
      final first = position.pixels;
      expect(first, greaterThan(0));
      expect(first / extent, lessThan(.1));
      expect(position.maxScrollExtent, closeTo(extent, .01));
      await drag.moveBy(const Offset(0, 30));
      await tester.pumpAndSettle();
      expect(position.pixels - first, closeTo(first, .1));
      expect(position.maxScrollExtent, closeTo(extent, .01));
      await drag.moveBy(const Offset(0, -30));
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(first, .1));
      await drag.up();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await drainWrites(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('生成设置折叠在滚动离开和重建工作台后保留', (tester) async {
    await mount(tester, const Size(1440, 900));
    final position = tester
        .widget<Scrollbar>(key('desktop-controls-scrollbar'))
        .controller!
        .position;
    await tester.ensureVisible(key('desktop-generation-settings'));
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-generation-settings'));
    await tester.pumpAndSettle();
    expect(key('desktop-rescale'), findsNothing);
    expect(stores.prefs.get('desktop_generation_settings_expanded'), '0');
    position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('desktop-generation-settings'));
    await tester.pumpAndSettle();
    expect(key('desktop-rescale'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await mount(tester, const Size(1440, 900));
    expect(key('desktop-rescale'), findsNothing);
    await tester.ensureVisible(key('desktop-generation-settings'));
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-generation-settings'));
    await tester.pumpAndSettle();
    expect(key('desktop-rescale'), findsOneWidget);
    expect(stores.prefs.get('desktop_generation_settings_expanded'), '1');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('标签悬浮面板在调整侧栏和窄窗时跟随选择', (tester) async {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    c
        .read(generateProvider.notifier)
        .setPrompts(
          positive:
              'sunrise, mist, rain, mountain landscape, golden clouds, soft lighting',
        );
    await mount(tester, const Size(1440, 900));
    await tester.tap(key('desktop-prompt-mode'));
    await tester.pumpAndSettle();
    final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
    await tester.tapAt(flow.chipAnchor(0)!.center);
    await tester.pumpAndSettle();
    await screenshot(tester, 'floating-single-tag');
    await tester.tapAt(flow.chipAnchor(1)!.center);
    await tester.pumpAndSettle();
    await screenshot(tester, 'floating-multiple-tags');
    tester.view.physicalSize = const Size(880, 640);
    await tester.pumpAndSettle();
    final rect = tester.getRect(key('desktop-tag-popover'));
    expect(rect.left, greaterThanOrEqualTo(8));
    expect(rect.right, lessThanOrEqualTo(872));
    expect(rect.top, closeTo(flow.chipAnchor(1)!.bottom + 8, .01));
    await screenshot(tester, 'floating-tags-compact');
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(key('desktop-tag-popover')).top,
      closeTo(flow.chipAnchor(1)!.bottom + 8, .01),
    );
    expect(tester.widget<ChipFlowView>(find.byType(ChipFlowView)).selection, {
      0,
      1,
    });
    debugDisableShadows = true;
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('桌面宽窄窗口、设置折叠和固定工具栏', (tester) async {
    c
        .read(generateProvider.notifier)
        .setPrompts(
          positive:
              'mountain landscape, 1.2::soft lighting::, 1.6::sunrise::, 2::golden clouds::, 0.7::mist::, 0.3::rain::, 0::city::',
        );
    await mount(tester, const Size(1440, 900));
    expect(key('desktop-controls'), findsOneWidget);
    expect(key('desktop-dock'), findsOneWidget);
    await screenshot(tester, 'creation');
    await tester.ensureVisible(find.byTooltip('添加角色'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加角色'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    final character = c.read(generateProvider).characters.single;
    final characterInput = find.descendant(
      of: key('desktop-character-${character.id}-text'),
      matching: find.byType(TextField),
    );
    await tester.ensureVisible(characterInput);
    await tester.enterText(characterInput, 'white hair, blue eyes');
    expect(
      c.read(generateProvider).characters.single.positive,
      'white hair, blue eyes',
    );
    await tester.ensureVisible(find.byTooltip('添加角色'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加角色'));
    await tester.pumpAndSettle();
    expect(c.read(generateProvider).characters.length, 2);
    expect(find.byTooltip('拖动角色排序'), findsWidgets);
    await screenshot(tester, 'character-inline');
    expect(find.byType(Dialog), findsNothing);
    await tester.tap(key('desktop-inspiration-tab'));
    await tester.pumpAndSettle();
    expect(find.text('公共库'), findsOneWidget);
    expect(find.text('我的 · 0'), findsOneWidget);
    await screenshot(tester, 'inspiration');
    for (final size in [
      const Size(1280, 800),
      const Size(1024, 768),
      const Size(880, 640),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
      await tester.tap(key('desktop-ai-tab'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-inspiration-tab'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'tools $size');
    }
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      key('desktop-generation-settings'),
      160,
      scrollable: find
          .descendant(
            of: key('desktop-controls'),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-generation-settings'));
    await tester.pumpAndSettle();
    expect(key('desktop-rescale'), findsNothing);
    await tester.tap(key('desktop-generation-settings'));
    await tester.pumpAndSettle();
    expect(key('desktop-rescale'), findsOneWidget);
    expect(find.text('高级设置'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('多标签拖动显示落点预览与按原顺序排列的浮层', (tester) async {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    final gen = c.read(generateProvider.notifier);
    gen.setPrompts(
      positive:
          'sunrise, mist, rain, mountain landscape, golden clouds, soft lighting',
    );
    await mount(tester, const Size(1440, 900));
    await tester.tap(key('desktop-prompt-mode'));
    await tester.pumpAndSettle();
    final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
    for (final i in [1, 0]) {
      await tester.tapAt(flow.chipAnchor(i)!.center);
      await tester.pumpAndSettle();
    }
    final drag = await tester.startGesture(
      flow.chipAnchor(0)!.center,
      kind: ui.PointerDeviceKind.mouse,
    );
    await drag.moveTo(flow.chipAnchor(5)!.center);
    await tester.pump();
    expect(key('desktop-chip-drag-feedback'), findsOneWidget);
    expect(key('desktop-tag-popover'), findsNothing);
    final a = tester.getRect(key('desktop-chip-drop-preview-0'));
    final b = tester.getRect(key('desktop-chip-drop-preview-1'));
    expect(a.top < b.top || a.left < b.left, isTrue);
    await screenshot(tester, 'chip-drag-preview');
    await drag.up();
    await tester.pumpAndSettle();
    expect(
      gen.state.prompt,
      'rain, mountain landscape, golden clouds, soft lighting, sunrise, mist',
    );
    await screenshot(tester, 'chip-drag-result');
    debugDisableShadows = true;
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('参考图及图生图在窄侧栏直接显示并可调整', (tester) async {
    final bytes = (await tester.runAsync(
      () => File('assets/app_icon.png').readAsBytes(),
    ))!;
    final n = c.read(generateProvider.notifier);
    n.addVibe(image: bytes, name: '侧栏 Vibe 参考图片');
    await mount(tester, const Size(1280, 800));
    await tester.ensureVisible(key('desktop-module-vibe'));
    await tester.pumpAndSettle();
    expect(find.text('Strength 参考强度'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'vibe-inline');
    n.addCharRef(image: bytes, name: '侧栏角色参考图片');
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('desktop-module-charRef'));
    await tester.pumpAndSettle();
    expect(find.text('Fidelity 保真度'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(880, 640);
    await tester.pumpAndSettle();
    await screenshot(tester, 'reference-inline');
    expect(tester.takeException(), isNull);
    n.setImg2ImgImage(image: bytes, width: 832, height: 1216);
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('desktop-module-img2img'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
    await screenshot(tester, 'img2img-inline');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('图库列表、库内图片、大图详情独立浏览且保持创作选择', (tester) async {
    final a = (await tester.runAsync(
      () => c.read(albumsProvider.notifier).create('猫猫图库'),
    ))!;
    final b = (await tester.runAsync(
      () => c.read(albumsProvider.notifier).create('风景图库'),
    ))!;
    c.read(desktopLibraryProvider.notifier).choose(a);
    final bytes = await tester.runAsync(
      () => File('assets/app_icon.png').readAsBytes(),
    );
    final result = await tester.runAsync(
      () => c
          .read(galleryProvider.notifier)
          .addResultToGallery(
            bytes: bytes!,
            width: 256,
            height: 256,
            seed: 123,
            input: c
                .read(generateProvider)
                .copyWith(
                  prompt: '1girl, white hair, blue eyes, soft lighting',
                ),
            target: c.read(gallerySaveTargetProvider),
          ),
    );
    await mount(tester, const Size(1440, 900));
    await tester.tap(key('desktop-nav-1'));
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-library-card-$a'));
    await tester.pumpAndSettle();
    expect(c.read(shellIndexProvider), kTabGallery);
    expect(key('desktop-gallery-grid'), findsOneWidget);
    expect(key('desktop-gallery-back'), findsNothing);
    expect(find.text('分组'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(find.text('多选'), findsNothing);
    expect(key('desktop-library-dialog'), findsNothing);
    await screenshot(tester, 'gallery');
    final selectedBefore = c.read(galleryProvider).selectedId;
    await tester.tap(key('desktop-image-${result!.id}'));
    // The viewer now waits for native decoding before committing the frame.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      if (key('desktop-viewer-image').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(key('desktop-image-viewer'), findsOneWidget);
    expect(c.read(shellIndexProvider), kTabGallery);
    expect(c.read(galleryProvider).selectedId, selectedBefore);
    expect(find.text('作品信息'), findsOneWidget);
    expect(find.text('重绘'), findsOneWidget);
    expect(find.text('图生图放大'), findsOneWidget);
    expect(find.text('超分辨率'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(key('desktop-image-import'), findsOneWidget);
    expect(find.text('重新生成'), findsNothing);
    await screenshot(tester, 'image-details');
    tester.view.physicalSize = const Size(880, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(key('desktop-image-close'));
    await tester.pumpAndSettle();
    // 背景工作台仍有重绘会话时，图库详情也能独立打开和关闭。
    c
        .read(inpaintSessionProvider.notifier)
        .open(imageBytes: bytes!, sourceId: result.id);
    await tester.pump();
    // 原生图片解码和异步存档读取需要真实事件循环，不能只推进假时钟。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-image-${result.id}'));
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-image-close'));
    await tester.pumpAndSettle();
    expect(key('desktop-image-viewer'), findsNothing);
    c.read(inpaintSessionProvider.notifier).close();
    await tester.pumpAndSettle();

    expect(key('desktop-gallery-grid'), findsOneWidget);
    await tester.tap(key('desktop-nav-1'));
    await tester.pumpAndSettle();
    expect(key('desktop-gallery-libraries'), findsOneWidget);
    expect(key('desktop-library-card-$a'), findsOneWidget);
    expect(key('desktop-library-card-$b'), findsOneWidget);
    expect(find.text('分组'), findsNothing);
    expect(
      find.descendant(
        of: key('desktop-gallery-libraries'),
        matching: find.text('切换图库'),
      ),
      findsNothing,
    );
    await tester.enterText(key('desktop-gallery-search'), '猫猫');
    await tester.pumpAndSettle();
    expect(key('desktop-library-card-$a'), findsOneWidget);
    expect(key('desktop-library-card-$b'), findsNothing);
    await tester.enterText(key('desktop-gallery-search'), '');
    await tester.pumpAndSettle();
    await screenshot(tester, 'libraries');
    await tester.tap(key('desktop-library-card-$b'));
    await tester.pumpAndSettle();
    expect(c.read(gallerySaveTargetProvider).albumId, b);
    expect(c.read(galleryBrowseAlbumProvider), b);
    expect(c.read(shellIndexProvider), kTabGallery);
    expect(key('desktop-gallery-grid'), findsOneWidget);
    await tester.tap(key('desktop-nav-0'));
    await tester.pumpAndSettle();
    expect(c.read(shellIndexProvider), kTabCreate);
    expect(key('desktop-library-dialog'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });

  testWidgets('桌面提示词直接编辑真实生成状态，切页保留', (tester) async {
    await mount(tester, const Size(1280, 800));
    await tester.enterText(
      find.descendant(
        of: key('desktop-prompt-text'),
        matching: find.byType(TextField),
      ),
      '1girl, cat ears, cherry blossoms',
    );
    expect(c.read(generateProvider).prompt, '1girl, cat ears, cherry blossoms');
    await tester.tap(key('desktop-nav-1'));
    await tester.pumpAndSettle();
    await tester.tap(key('desktop-nav-0'));
    await tester.pumpAndSettle();
    expect(find.text('1girl, cat ears, cherry blossoms'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await drainWrites(tester);
  });
}
