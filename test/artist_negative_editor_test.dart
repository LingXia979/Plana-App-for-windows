import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/expand_body.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_editor_page.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

import 'support/desktop_capture.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const saved = TagEntry(
    id: 'artist-fixture',
    category: TagCategory.artist,
    name: '测试画风',
    positive: 'artist:test, soft color',
    negative: 'bad anatomy, worst quality',
    createdAt: 1,
  );
  late Directory temp;
  late File libraryFile;
  late AppStores stores;
  late ProviderContainer container;
  final capture = GlobalKey();

  setUpAll(loadDesktopCaptureFonts);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_artist_negative_');
    libraryFile = File('${temp.path}/tag_library.json')
      ..writeAsStringSync(jsonEncode({'entries': []}));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        publicTagsProvider.overrideWith((ref, cat) async => []),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    expect(temp.parent.absolute.path, Directory.systemTemp.absolute.path);
    temp.deleteSync(recursive: true);
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Finder field(String hint) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == hint,
  );
  Finder nameField() => field('给画风起个名字');
  Finder positiveField() => field('例如: wlop, rurudo');
  Finder negativeField() => field('例如: bad anatomy, worst quality');
  String textIn(WidgetTester tester, Finder input) =>
      tester.widget<TextField>(input).controller!.text;
  bool negativeOpen(WidgetTester tester) => tester
      .widget<ExpandBody>(
        find
            .ancestor(of: negativeField(), matching: find.byType(ExpandBody))
            .first,
      )
      .expanded;

  List<TagEntry> diskEntries() => [
    for (final raw
        in (jsonDecode(libraryFile.readAsStringSync()) as Map)['entries']
            as List)
      TagEntry.fromJson(Map<String, dynamic>.from(raw as Map))!,
  ];

  Future<void> mount(WidgetTester tester, {TagEntry? initial}) async {
    if (initial != null) {
      libraryFile.writeAsStringSync(
        jsonEncode({
          'entries': [initial.toJson()],
        }),
      );
    }
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const ValueKey('new-artist'),
                        onPressed: () =>
                            showTagEditor(context, cat: TagCategory.artist),
                        child: const Text('新建测试画风'),
                      ),
                      TextButton(
                        key: const ValueKey('edit-artist'),
                        onPressed: () => showTagEditor(
                          context,
                          cat: TagCategory.artist,
                          edit: container
                              .read(tagLibraryProvider)
                              .requireValue
                              .entries
                              .single,
                        ),
                        child: const Text('打开测试画风'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, Finder finder, String value) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.enterText(finder, value);
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, {bool create = false}) async {
    await tap(tester, key(create ? 'new-artist' : 'edit-artist'));
    expect(key('tag-editor-dialog'), findsOneWidget);
  }

  Future<void> save(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 100 && key('tag-editor-dialog').evaluate().isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 15));
    }
    await tester.pumpAndSettle();
    expect(key('tag-editor-dialog'), findsNothing);
  }

  Future<void> reloadLibrary(WidgetTester tester) async {
    container.invalidate(tagLibraryProvider);
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'new artist starts folded, saves entered negative, and reopens it expanded from disk',
    (tester) async {
      await mount(tester);
      await open(tester, create: true);
      expect(find.text('负面提示词'), findsOneWidget);
      expect(negativeOpen(tester), isFalse);
      await enter(tester, nameField(), '新画风');
      await enter(tester, positiveField(), 'artist:test, light colors');
      await tap(tester, find.text('负面提示词'));
      expect(negativeOpen(tester), isTrue);
      await enter(tester, negativeField(), '  bad hands, bad eyes  ');
      await tap(tester, find.text('负面提示词'));
      expect(negativeOpen(tester), isFalse);
      await tap(tester, find.text('负面提示词'));
      expect(textIn(tester, negativeField()), '  bad hands, bad eyes  ');
      await save(tester, '保存到本地');
      expect(diskEntries().single.negative, 'bad hands, bad eyes');
      expect(diskEntries().single.positive, 'artist:test, light colors');
      await reloadLibrary(tester);
      await open(tester);
      expect(negativeOpen(tester), isTrue);
      expect(textIn(tester, negativeField()), 'bad hands, bad eyes');
      await captureDesktop(
        tester,
        capture,
        'windows40-artist-negative-expanded',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'existing artist negative can be modified and then cleared persistently',
    (tester) async {
      await mount(tester, initial: saved);
      await open(tester);
      expect(negativeOpen(tester), isTrue);
      expect(textIn(tester, negativeField()), saved.negative);
      await enter(tester, negativeField(), '  edited exclusion  ');
      await save(tester, '保存修改');
      expect(diskEntries().single.negative, 'edited exclusion');
      expect(diskEntries().single.id, saved.id);
      await reloadLibrary(tester);
      await open(tester);
      expect(textIn(tester, negativeField()), 'edited exclusion');
      await enter(tester, negativeField(), '');
      await save(tester, '保存修改');
      expect(diskEntries().single.negative, isEmpty);
      expect(diskEntries().single.positive, saved.positive);
      await reloadLibrary(tester);
      await open(tester);
      expect(negativeOpen(tester), isFalse);
      expect(textIn(tester, negativeField()), isEmpty);
      await finish(tester);
    },
  );

  for (final create in [false, true]) {
    testWidgets(
      'cancelling ${create ? 'new' : 'existing'} artist discards negative edits without touching the library',
      (tester) async {
        await mount(tester, initial: saved);
        final before = libraryFile.readAsStringSync();
        await open(tester, create: create);
        if (create) {
          await enter(tester, nameField(), '未保存');
          await enter(tester, positiveField(), 'uncommitted positive');
          await tap(tester, find.text('负面提示词'));
        }
        await enter(tester, negativeField(), 'uncommitted exclusion');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(key('tag-editor-dialog'), findsNothing);
        expect(libraryFile.readAsStringSync(), before);
        expect(
          container
              .read(tagLibraryProvider)
              .requireValue
              .entries
              .single
              .negative,
          saved.negative,
        );
        await open(tester);
        expect(textIn(tester, negativeField()), saved.negative);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'importing main positive preserves the independently edited artist negative',
    (tester) async {
      container
          .read(generateProvider.notifier)
          .setPrompts(
            positive: 'imported artist, imported color',
            negative: 'global negative should not replace style',
          );
      await mount(tester, initial: saved);
      await open(tester);
      await tap(tester, find.text('导入主提示词'));
      expect(
        textIn(tester, positiveField()),
        'imported artist, imported color',
      );
      expect(textIn(tester, negativeField()), saved.negative);
      await enter(tester, negativeField(), 'my edited style negative');
      await tap(tester, find.text('导入主提示词'));
      expect(textIn(tester, negativeField()), 'my edited style negative');
      await save(tester, '保存修改');
      expect(diskEntries().single.negative, 'my edited style negative');
      expect(diskEntries().single.positive, 'imported artist, imported color');
      await finish(tester);
    },
  );

  testWidgets(
    'favorited public artist shows negative read-only and tag-only save preserves source text',
    (tester) async {
      final favorite = saved.copyWith(
        origin: TagOrigin.favorited,
        publicId: 'public-test',
      );
      container
          .read(generateProvider.notifier)
          .setPrompts(positive: 'available import', negative: 'other');
      await mount(tester, initial: favorite);
      await open(tester);
      expect(negativeOpen(tester), isTrue);
      expect(textIn(tester, negativeField()), saved.negative);
      expect(tester.widget<TextField>(negativeField()).readOnly, isTrue);
      expect(tester.widget<TextField>(positiveField()).readOnly, isTrue);
      expect(tester.widget<TextField>(nameField()).readOnly, isTrue);
      expect(find.text('导入主提示词'), findsNothing);
      expect(find.text('粘贴'), findsNothing);
      expect(find.text('保存修改'), findsNothing);
      expect(find.text('保存并发布'), findsNothing);
      await save(tester, '保存标签修改');
      final result = diskEntries().single;
      expect(result.negative, saved.negative);
      expect(result.positive, saved.positive);
      expect(result.origin, TagOrigin.favorited);
      expect(result.publicId, 'public-test');
      await finish(tester);
    },
  );
}
