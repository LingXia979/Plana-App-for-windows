import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/ui_prefs.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_editor_page.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/widgets/category_sheets.dart';
import 'package:plana_app/features/inspiration/widgets/char_pick_sheet.dart';
import 'package:plana_app/features/inspiration/widgets/tag_card.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final capture = GlobalKey();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late TagCategoryDef custom;
  Finder key(String name) => find.byKey(ValueKey(name));

  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('plana_category_desktop_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => root.path,
    );
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        publicTagsProvider.overrideWith((ref, cat) async => []),
      ],
    );
    await container.read(tagLibraryProvider.future);
    custom = await container
        .read(tagLibraryProvider.notifier)
        .addCategory(
          label: '服装',
          iconName: 'Shirt',
          layout: TagCardLayout.portrait,
        );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    syncCustomTagCategories(const []);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    root.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {bool dark = false}) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              platform: TargetPlatform.windows,
              textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () => showCategoryManagerSheet(context),
                      child: const Text('管理类别'),
                    ),
                    TextButton(
                      onPressed: () => showTagEditor(
                        context,
                        cat: TagCategory.character,
                        categories: [
                          TagCategory.character,
                          custom.key,
                          TagCategory.other,
                        ],
                        lastPageKey: 'sectionSave',
                        draft: (
                          name: '测试条目',
                          positive: 'blue dress, ribbon',
                          negative: 'bad hands',
                          tags: ['常用'],
                        ),
                      ),
                      child: const Text('编辑条目'),
                    ),
                    TextButton(
                      onPressed: () => showCharPickSheet(context),
                      child: const Text('选择角色'),
                    ),
                  ],
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
    await pumpUntilComplete(
      tester,
      container.read(tagLibraryProvider.notifier).settled,
    );
    await pumpUntilComplete(tester, stores.flushForExit());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'category manager creates a text category and protects builtin rows',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('管理类别'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('删除'), findsNWidgets(3)); // scene, other and custom
      await tester.tap(find.text('新建类别'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '动作');
      await tester.pumpAndSettle();
      await tester.tap(find.text('无图'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await pumpUntil(
        tester,
        () => container.read(tagLibraryProvider).value!.customDefs.length == 2,
      );
      await tester.pumpAndSettle();
      expect(
        container.read(tagLibraryProvider).value!.customDefs.last.hasPreview,
        isFalse,
      );
      await captureDesktop(tester, capture, 'batch9-category-manager');
      await finish(tester);
    },
  );

  testWidgets(
    'category switch keeps one desktop dialog, draft, tags and dropped preview',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('编辑条目'));
      await tester.pumpAndSettle();
      final bytes = Uint8List.fromList(
        img.encodePng(
          img.fill(
            img.Image(width: 24, height: 32, numChannels: 4),
            color: img.ColorRgba8(60, 120, 210, 255),
          ),
        ),
      );
      final region = tester.widget<ImageDropRegion>(
        key('tag-preview-image-drop'),
      );
      await region.onDrop([
        PickedImage('cover.png', bytes),
      ], ImageDropPayload.image(name: 'cover.png', load: () async => bytes));
      await tester.pumpAndSettle();
      await tester.tap(key('tag-editor-category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('服装'));
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      expect(find.text('新建服装'), findsOneWidget);
      expect(find.widgetWithText(TextField, '测试条目'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'blue dress, ribbon'),
        findsOneWidget,
      );
      expect(find.byType(Image), findsWidgets);
      await captureDesktop(tester, capture, 'batch9-category-editor');
      tester.view.physicalSize = const Size(520, 760);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesktop(tester, capture, 'batch9-category-editor-narrow');
      tester.view.physicalSize = const Size(1100, 850);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await pumpUntil(
        tester,
        () => container.read(tagLibraryProvider).value!.entries.isNotEmpty,
      );
      await pumpUntil(
        tester,
        () => key('tag-editor-dialog').evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      final saved = container.read(tagLibraryProvider).value!.entries.single;
      expect(saved.category, custom.key);
      expect(saved.negative, 'bad hands');
      expect(saved.tags, ['常用']);
      expect(File(saved.previews.single).readAsBytesSync(), bytes);
      expect(
        container.read(uiPrefsProvider).lastPages['sectionSave'],
        custom.webId,
      );
      expect(key('tag-editor-dialog'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'character picker includes custom categories and remembers its page',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(tagLibraryProvider.notifier)
            .upsert(
              TagEntry(
                id: 'outfit',
                category: custom.key,
                name: '衣服条目',
                positive: 'dress',
              ),
            ),
      );
      await mount(tester, dark: true);
      await tester.tap(find.text('选择角色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('服装'));
      await tester.pumpAndSettle();
      expect(key('outfit'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择角色'));
      await tester.pumpAndSettle();
      expect(key('outfit'), findsOneWidget);
      expect(
        container.read(uiPrefsProvider).lastPages['charPick'],
        custom.webId,
      );
      await captureDesktop(tester, capture, 'batch9-category-picker-dark');
      await finish(tester);
    },
  );

  testWidgets(
    'text-only categories render prompts instead of image placeholders',
    (tester) async {
      final def = TagCategoryDef.custom(
        id: 'c_text',
        label: '动作',
        iconName: 'Hand',
        layout: TagCardLayout.none,
      );
      syncCustomTagCategories([def]);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 200,
            child: TagCard(
              entry: TagEntry(
                id: 'a',
                category: def.key,
                name: '招手',
                positive: 'waving, smile',
              ),
              selected: false,
              isPublic: false,
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      );
      expect(find.byType(TagCardPreview), findsNothing);
      expect(find.text('waving, smile'), findsOneWidget);
      await finish(tester);
    },
  );
}
