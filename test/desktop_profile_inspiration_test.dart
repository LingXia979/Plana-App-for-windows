import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/desktop/desktop_profile_page.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/inspiration/tag_editor_page.dart';
import 'package:plana_app/features/inspiration/inspiration_page.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/widgets/tag_sheets.dart';
import 'package:plana_app/features/inspiration/widgets/tag_filter_sheet.dart';
import 'package:plana_app/features/profile/account_page.dart';
import 'package:plana_app/features/profile/token_manage_page.dart';
import 'package:plana_app/features/shell/shell_state.dart';
import 'package:plana_app/features/tools/tools_page.dart';
import 'package:plana_app/features/tools/metadata_tool_page.dart';

void main() {
  late ProviderContainer c;
  late AppStores stores;
  final capture = GlobalKey();
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    if (!Platform.isWindows) return;
    for (final font in [
      ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ('monospace', r'C:\Windows\Fonts\consola.ttf'),
      (
        'MaterialIcons',
        r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      ),
    ]) {
      final file = File(font.$2);
      if (await file.exists()) {
        await (FontLoader(
          font.$1,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('plana_layout_test_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        publicTagsProvider.overrideWith((ref, category) async => const []),
        tagAuthorNamesProvider.overrideWith((ref) async => const {}),
      ],
    );
  });
  tearDown(() async {
    c.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
  });

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(1280, 850),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Start file IO outside FakeAsync before the real inspiration page watches it.
    await tester.runAsync(() => c.read(tagLibraryProvider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
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
            home: Scaffold(body: page),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await c.read(tagLibraryProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    final disabled = debugDisableShadows;
    try {
      debugDisableShadows = false;
      for (final render in tester.allRenderObjects) {
        render.markNeedsPaint();
      }
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/windows-validation/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = disabled;
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  Future<void> section(WidgetTester tester, String name) async {
    await tester.ensureVisible(key('profile-section-$name'));
    await tester.tap(key('profile-section-$name'));
    await tester.pumpAndSettle();
  }

  Widget library() => Align(
    alignment: Alignment.topRight,
    child: SizedBox(
      width: 400,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 850)),
        child: Consumer(
          builder: (context, ref, _) => Column(
            children: [
              const SizedBox(height: 100),
              Row(
                children: [
                  const Spacer(),
                  IconButton(
                    tooltip: '数据备份',
                    onPressed: () => showTagBackupSheet(context, ref),
                    icon: const Icon(Icons.cloud_outlined),
                  ),
                  Builder(
                    builder: (anchor) => IconButton(
                      tooltip: '标签池管理',
                      onPressed: () =>
                          showTagPoolSheet(anchor, ref, TagCategory.character),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ),
                ],
              ),
              FilledButton(
                onPressed: () =>
                    showTagEditor(context, cat: TagCategory.character),
                child: const Text('创建角色'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'profile keeps its sidebar, nested routes and tool drafts across categories and resize',
    (tester) async {
      c.read(shellIndexProvider.notifier).select(kTabProfile);
      await mount(tester, const DesktopProfilePage());
      expect(find.byType(AccountPage), findsOneWidget);
      expect(
        tester.getRect(key('profile-sidebar')).right,
        lessThan(tester.getRect(key('profile-content')).left),
      );
      await tester.tap(find.text('管理令牌'));
      await tester.pumpAndSettle();
      expect(find.byType(TokenManagePage), findsOneWidget);
      expect(key('profile-sidebar'), findsOneWidget);
      await section(tester, 'tools');
      final input = find
          .descendant(
            of: find.byType(ToolsPage),
            matching: find.byType(TextField),
          )
          .first;
      await tester.enterText(input, '(cat ears:1.2), solo');
      // Offscreen tool tabs must remain mounted after the whole pane scrolls.
      await tester.tap(find.text('图片元数据'));
      tester.view.physicalSize = const Size(640, 500);
      await tester.pumpAndSettle();
      final toolsScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const PageStorageKey('desktop-tools-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      toolsScroll.position.jumpTo(toolsScroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      toolsScroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('权重转换'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '(cat ears:1.2), solo',
      );
      tester.view.physicalSize = const Size(1280, 850);
      await tester.pumpAndSettle();
      await section(tester, 'appearance');
      expect(find.text('深浅模式'), findsOneWidget);
      await screenshot(tester, 'windows12-profile-appearance');
      await section(tester, 'tools');
      expect(
        tester.widget<TextField>(input).controller!.text,
        '(cat ears:1.2), solo',
      );
      await tester.tap(find.text('转换'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('导入提示词'));
      await tester.tap(find.text('导入提示词'));
      await tester.pumpAndSettle();
      expect(c.read(shellIndexProvider), kTabCreate);
      expect(c.read(generateProvider).prompt, contains('cat ears'));
      expect(find.byType(ToolsPage), findsOneWidget);
      c.read(shellIndexProvider.notifier).select(kTabProfile);
      await tester.pumpAndSettle();
      // A back event in a root pane must leave hidden panes' routes intact.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await section(tester, 'account');
      expect(find.byType(TokenManagePage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AccountPage), findsOneWidget);
      await section(tester, 'about');
      await tester.pump(const Duration(seconds: 3));
      await screenshot(tester, 'windows12-profile-about');
      tester.view.physicalSize = const Size(640, 700);
      await tester.pumpAndSettle();
      await tester.tap(key('profile-section-menu'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('工具箱'),
          matching: find.byWidgetPredicate(
            (widget) => widget is CheckedPopupMenuItem,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '(cat ears:1.2), solo',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'settings title and cards share the same scroll while sidebar stays put',
    (tester) async {
      await mount(
        tester,
        const DesktopProfilePage(),
        size: const Size(1280, 580),
      );
      final heading = key('settings-scrolling-heading');
      final token = find.text('NovelAI Token');
      final headingY = tester.getTopLeft(heading).dy;
      final tokenY = tester.getTopLeft(token).dy;
      final sidebar = tester.getRect(key('profile-sidebar'));
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(AccountPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(24);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(heading).dy, lessThan(headingY));
      expect(
        tester.getTopLeft(heading).dy - headingY,
        closeTo(tester.getTopLeft(token).dy - tokenY, 1),
      );
      expect(tester.getRect(key('profile-sidebar')), sidebar);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(heading.hitTestable(), findsNothing);
      await screenshot(tester, 'windows13-settings-scroll');
      await finish(tester);
    },
  );

  testWidgets(
    'filter anchors to the button and preserves the other dimension and dismissal',
    (tester) async {
      TagFilters current = (author: null, model: 'v5');
      TagFilters? returned;
      await mount(
        tester,
        Align(
          alignment: Alignment.topRight,
          child: Builder(
            builder: (anchor) => IconButton(
              tooltip: '筛选测试',
              icon: const Icon(Icons.filter_alt_outlined),
              onPressed: () async {
                returned = await showTagFilterSheet(
                  anchor,
                  desktop: true,
                  authors: const [
                    TagAuthor(id: '11', nickname: '樱花', count: 7),
                    TagAuthor(id: '22', nickname: '星空', count: 2),
                  ],
                  current: current,
                  hasModels: true,
                );
                if (returned != null) current = returned!;
              },
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.byTooltip('筛选测试'));
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.byType(BottomSheet), findsNothing);
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.width, 380);
      expect(
        panel.top,
        greaterThanOrEqualTo(tester.getRect(find.byTooltip('筛选测试')).bottom),
      );
      await tester.tap(find.text('作者'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '樱花');
      await tester.tap(find.text('樱花').last);
      await tester.pumpAndSettle();
      expect(current, (author: '11', model: 'v5'));
      await open();
      await screenshot(tester, 'windows13-filter');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(returned, isNull);
      expect(current.author, '11');
      await open();
      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      expect(current, (author: null, model: null));
      await finish(tester);
    },
  );

  testWidgets(
    'tag pool anchors to its gear, updates tags and closes with Escape',
    (tester) async {
      await mount(tester, library());
      final button = find.widgetWithIcon(IconButton, Icons.settings_outlined);
      final anchor = tester.getRect(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.width, 380);
      expect(panel.right, lessThanOrEqualTo(1268));
      expect(panel.top, closeTo(anchor.bottom + 8, 1));
      expect(find.byType(BottomSheet), findsNothing);
      await tester.enterText(find.byType(TextField), '喜欢的角色');
      await tester.runAsync(() async {
        await tester.tap(find.text('添加'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(
        c.read(tagLibraryProvider).value!.poolOf(TagCategory.character),
        contains('喜欢的角色'),
      );
      expect(find.text('喜欢的角色'), findsOneWidget);
      await screenshot(tester, 'windows12-tag-pool');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('desktop-popover'), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('喜欢的角色'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(key('desktop-popover'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'backup is a compact centered dialog and scrolls within a small window',
    (tester) async {
      await mount(tester, library());
      await tester.tap(find.byTooltip('数据备份'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      final panel = tester.getRect(
        find
            .descendant(
              of: key('tag-backup-dialog'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(panel.width, 540);
      expect(panel.height, lessThanOrEqualTo(620));
      expect(panel.center, const Offset(640, 425));
      expect(find.text('云端暂无备份'), findsOneWidget);
      await screenshot(tester, 'windows12-tag-backup');
      tester.view.physicalSize = const Size(720, 480);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('其他'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('tag-backup-dialog'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'character dialog keeps a portrait preview, borderless actions and draft on resize',
    (tester) async {
      await mount(tester, library());
      await tester.tap(find.text('创建角色'));
      await tester.pumpAndSettle();
      final rect = tester.getRect(key('tag-editor-form'));
      expect(rect.width, 888);
      expect(rect.center.dx, 640);
      expect(find.byType(Dialog), findsOneWidget);
      final portrait = tester.getRect(key('tag-editor-portrait'));
      expect(portrait.width / portrait.height, closeTo(832 / 1216, .001));
      expect(
        tester.widget<Material>(key('tag-editor-save-actions')).color,
        Colors.transparent,
      );
      expect(
        tester.getRect(find.text('上传')).bottom,
        greaterThan(portrait.bottom),
      );
      expect(
        tester.getRect(key('tag-editor-preview')).right,
        lessThan(tester.getRect(key('tag-editor-details')).left),
      );
      expect(find.text('名称 *'), findsOneWidget);
      expect(find.text('提示词 *'), findsOneWidget);
      final name = find.byType(TextField).first;
      await tester.enterText(name, '樱花猫娘');
      await screenshot(tester, 'windows14-character-editor');
      tester.view.physicalSize = const Size(700, 520);
      await tester.pumpAndSettle();
      expect(tester.getRect(key('tag-editor-form')).width, 620);
      await tester.scrollUntilVisible(
        find.widgetWithText(TextField, '给角色起个名字'),
        180,
        scrollable: find
            .descendant(
              of: key('tag-editor-details'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.widget<TextField>(name).controller!.text, '樱花猫娘');
      expect(find.byTooltip('关闭编辑器'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('创建角色'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'new entry opens from the real embedded toolbar after metadata and cannot stack barriers',
    (tester) async {
      var page = 0;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              TextButton(
                onPressed: () => setState(() => page = 1),
                child: const Text('回到创作'),
              ),
              Expanded(
                child: IndexedStack(
                  index: page,
                  children: [
                    const SingleChildScrollView(
                      key: PageStorageKey('desktop-tools-scroll'),
                      child: MetadataToolView(),
                    ),
                    const Align(
                      alignment: Alignment.topRight,
                      child: SizedBox(
                        width: 400,
                        child: MediaQuery(
                          data: MediaQueryData(size: Size(400, 800)),
                          child: InspirationPage(embedded: true),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      await tester.ensureVisible(find.text('更多参数'));
      await tester.tap(find.text('更多参数'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('回到创作'));
      await tester.pumpAndSettle();
      final create = find.byTooltip('新建');
      // Two invocations in one frame should produce one modal, one Escape closes it.
      final callback = tester
          .widget<IconButton>(
            find.ancestor(of: create, matching: find.byType(IconButton)),
          )
          .onPressed!;
      callback();
      callback();
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      expect(find.text('新建角色'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '给角色起个名字'), '可编辑');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsNothing);
      for (final category in ['画风', '场景', '提示词', '角色']) {
        await tester.tap(find.widgetWithText(TextButton, category));
        await tester.pumpAndSettle();
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(key('tag-editor-dialog'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭编辑器'));
        await tester.pumpAndSettle();
        expect(key('tag-editor-dialog'), findsNothing);
      }
      await finish(tester);
    },
  );
}
