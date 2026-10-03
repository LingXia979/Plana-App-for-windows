import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/inspiration_page.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

import 'support/desktop_capture.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  final capture = GlobalKey();
  final entries = [
    for (var i = 0; i < 8; i++)
      TagEntry(
        id: 'char$i',
        category: TagCategory.character,
        name: [
          '白发少女',
          '森林旅人',
          '暮色精灵',
          '午后访客',
          '海风与少年',
          '花园来信',
          '雪中旅人',
          '星夜猫娘',
        ][i],
        positive: [
          'white hair, blue eyes, 1girl',
          'traveler, green eyes, forest',
          'elf, purple hair, sunset',
          '1girl, brown hair, cafe',
          '1boy, ocean, white shirt',
          '1girl, garden, flowers',
          'snow, traveler, white hair',
          'cat girl, night, stars',
        ][i],
        aliases: ['别名$i'],
        tags: [if (i == 0) '白发'],
        createdAt: 10 - i,
      ),
    const TagEntry(
      id: 'scene0',
      category: TagCategory.scene,
      name: '樱花树下',
      positive: 'cherry blossoms',
    ),
  ];
  const publicEntry = TagEntry(
    id: 'pub_cat',
    category: TagCategory.character,
    name: '公共猫娘',
    positive: 'cat girl, white hair',
    publicId: 'cat',
    createdBy: '10001',
  );

  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_inspiration_layout_');
    File('${temp.path}/tag_library.json').writeAsStringSync(
      jsonEncode({'entries': entries.map((e) => e.toJson()).toList()}),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        publicTagsProvider.overrideWith(
          (ref, cat) async => cat == TagCategory.character ? [publicEntry] : [],
        ),
        tagAuthorNamesProvider.overrideWith((ref) async => {'10001': '示例作者'}),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    temp.deleteSync(recursive: true);
  });
  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
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
            home: const InspirationPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'desktop toolbar, responsive cards, filters and details preserve browsing state',
    (tester) async {
      await mount(tester);
      final search = key('tag-search-character');
      expect(tester.getSize(search).width, 300);
      expect(
        tester.getTopLeft(search).dy,
        closeTo(tester.getTopLeft(key('inspiration-category-character')).dy, 4),
      );
      expect(
        tester.getTopLeft(key('inspiration-card-char0')).dy,
        tester.getTopLeft(key('inspiration-card-char5')).dy,
      );
      expect(
        tester.getTopLeft(key('inspiration-card-char6')).dy,
        greaterThan(tester.getTopLeft(key('inspiration-card-char0')).dy),
      );
      await captureDesktop(tester, capture, 'windows16-inspiration-wide');

      await tester.tap(key('inspiration-detail-char0'));
      await tester.pumpAndSettle();
      expect(key('inspiration-detail-dialog'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getSize(key('inspiration-detail-dialog')).width,
        lessThanOrEqualTo(1500),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isFalse,
      );

      await tester.enterText(search, '别名0');
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsOneWidget);
      expect(key('inspiration-card-char1'), findsNothing);
      tester.view.physicalSize = const Size(740, 700);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, '别名0');
      expect(tester.takeException(), isNull);
      await tester.enterText(search, '');
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'windows16-inspiration-compact');
      await tester.tap(find.widgetWithText(ChoiceChip, '白发'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char1'), findsNothing);
      await tester.tap(key('inspiration-category-scene'));
      await tester.pumpAndSettle();
      expect(key('inspiration-scope-public'), findsNothing);
      expect(key('inspiration-card-scene0'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'new and edit actions open one dismissible editor; selection still imports to creation',
    (tester) async {
      await mount(tester);
      final create = tester
          .widget<FilledButton>(key('inspiration-new'))
          .onPressed!;
      create();
      create();
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭编辑器'));
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsNothing);
      await tester.tap(
        find.descendant(
          of: key('inspiration-card-char0'),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      expect(find.widgetWithText(TextField, '白发少女'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-select-char0'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isTrue,
      );
      await tester.tap(find.text('主提示词'));
      // Selection clears after the usage record is saved. Wait for that
      // observable completion, rather than assuming disk I/O takes <150 ms.
      for (
        var i = 0;
        i < 100 && key('desktop-inspiration-selection').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(container.read(generateProvider).prompt, contains('white hair'));
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isFalse,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'desktop right-click actions retain the selected group and cancellation preserves data',
    (tester) async {
      await mount(tester);
      await tester.tap(key('inspiration-select-char0'));
      await tester.tap(key('inspiration-select-char1'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(key('desktop-inspiration-selection')).height,
        lessThan(80),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(key('inspiration-card-char0')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 项'), findsOneWidget);
      expect(
        find.widgetWithText(PopupMenuItem<String>, '加入角色'),
        findsOneWidget,
      );
      await captureDesktop(
        tester,
        capture,
        'windows17-inspiration-context-menu',
      );
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '取消选择'));
      await tester.pumpAndSettle();
      expect(key('desktop-inspiration-selection'), findsNothing);
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char0')).value,
        isFalse,
      );
      expect(
        tester.widget<Checkbox>(key('inspiration-select-char1')).value,
        isFalse,
      );
      expect(
        container.read(tagLibraryProvider).value!.entries.length,
        entries.length,
      );

      await tester.tap(key('inspiration-select-char0'));
      await tester.tap(key('inspiration-select-char1'));
      await tester.pumpAndSettle();
      final unselected = await tester.startGesture(
        tester.getCenter(key('inspiration-card-char2')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await unselected.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        container.read(tagLibraryProvider).value!.entries.length,
        entries.length,
      );
      await tester.tap(key('inspiration-selection-menu'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(PopupMenuItem<String>, '主提示词'));
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(container.read(generateProvider).prompt, contains('purple hair'));
      expect(
        container.read(generateProvider).prompt,
        isNot(contains('white hair')),
      );
      for (
        var i = 0;
        i < 50 && key('desktop-inspiration-selection').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(key('desktop-inspiration-selection'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'public collection appears under My favorites and search survives scope changes',
    (tester) async {
      await mount(tester);
      await tester.tap(key('inspiration-scope-public'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-pub_cat'), findsOneWidget);
      await tester.enterText(key('tag-search-character'), '公共猫娘');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(
            of: key('inspiration-card-pub_cat'),
            matching: find.byTooltip('收藏'),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(find.byTooltip('已收藏'), findsOneWidget);
      await tester.tap(key('inspiration-scope-mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('tag-search-character')).controller!.text,
        '公共猫娘',
      );
      expect(find.text('公共猫娘'), findsWidgets);
      expect(
        container
            .read(tagLibraryProvider)
            .value!
            .entries
            .where((e) => e.publicId == 'cat')
            .length,
        1,
      );
      await finish(tester);
    },
  );
}
