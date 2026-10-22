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
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';
import 'package:plana_app/features/inspiration/inspiration_page.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/shell/shell_state.dart';

class _MemoryPresets extends PromptPresetsNotifier {
  @override
  Future<PromptPresetsState> build() async =>
      const PromptPresetsState(presets: kDefaultPromptPresets);

  @override
  Future<void> setActive(String id) async {
    ref.read(generateProvider.notifier).setPromptPreset(id);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const entries = [
    TagEntry(
      id: 'traveler',
      category: TagCategory.character,
      name: '林间旅人',
      positive: 'forest, new light',
      negative: 'rain, unwanted blur',
      createdAt: 2,
    ),
    TagEntry(
      id: 'cat',
      category: TagCategory.character,
      name: '夜色猫娘',
      positive: 'cat ears, moonlight',
      negative: 'bad paws, bad tail',
      createdAt: 1,
    ),
  ];
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  late GenerateNotifier gen;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_fold_import_ui_');
    File('${temp.path}/tag_library.json').writeAsStringSync(
      jsonEncode({'entries': entries.map((e) => e.toJson()).toList()}),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          chipMode: true,
          enableCompletion: false,
          showTranslation: false,
        ).toJson(),
      ),
    );
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        promptPresetsProvider.overrideWith(_MemoryPresets.new),
        publicTagsProvider.overrideWith((ref, category) async => []),
        tagAuthorNamesProvider.overrideWith((ref) async => {}),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    gen = container.read(generateProvider.notifier);
    gen.setModel('NAI 4.5 Full');
    container.read(shellIndexProvider.notifier).select(kTabInspiration);
  });

  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    expect(temp.parent.absolute.path, Directory.systemTemp.absolute.path);
    temp.deleteSync(recursive: true);
  });

  Finder key(String name) => find.byKey(ValueKey(name));
  Finder flowIn(String prefix) => find.descendant(
    of: key('$prefix-tags'),
    matching: find.byType(ChipFlowView),
  );
  CharacterPrompt character(String id) =>
      gen.state.characters.singleWhere((c) => c.id == id);

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: Consumer(
            builder: (context, ref, _) => IndexedStack(
              index: ref.watch(shellIndexProvider) == kTabCreate ? 0 : 1,
              children: [
                Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 380,
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            const DesktopPromptCard(),
                            for (final c
                                in ref.watch(generateProvider).characters)
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: DesktopPromptCard(
                                  key: ValueKey(c.id),
                                  charId: c.id,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const InspirationPage(),
              ],
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

  Future<void> importEntries(
    WidgetTester tester,
    List<String> ids, {
    bool asCharacters = false,
  }) async {
    for (final id in ids) {
      await tap(tester, key('inspiration-select-$id'));
    }
    await tap(
      tester,
      asCharacters
          ? find.widgetWithText(FilledButton, '加入角色')
          : key('inspiration-selection-prompt'),
    );
    // Import records usage on disk before navigating back to creation.
    for (
      var i = 0;
      i < 100 && container.read(shellIndexProvider) != kTabCreate;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(container.read(shellIndexProvider), kTabCreate);
    expect(key('desktop-prompt-tags'), findsOneWidget);
  }

  Future<void> deleteFold(
    WidgetTester tester,
    String prefix,
    String name,
  ) async {
    final finder = flowIn(prefix);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    final view = tester.widget<ChipFlowView>(finder);
    final units = topLevelUnits(view.controller.text, view.foldBodies);
    final index = units.indexWhere((unit) => unit.fold?.name == name);
    expect(
      index,
      isNonNegative,
      reason: 'The imported side must be a fold chip',
    );
    await tester.tapAt(
      tester.state<ChipFlowViewState>(finder).chipAnchor(index)!.center,
    );
    await tester.pumpAndSettle();
    await tap(
      tester,
      find.descendant(
        of: key('desktop-tag-popover'),
        matching: find.text('删除'),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'real main import links both folds and either-side delete and undo preserve unrelated words',
    (tester) async {
      gen.setPrompts(
        positive: 'sunrise, forest',
        negative: 'rain, manual exclusion',
      );
      await mount(tester);
      await importEntries(tester, ['traveler', 'cat']);
      final imported = gen.state;
      expect(parseFolds(imported.promptRaw), hasLength(2));
      expect(parseFolds(imported.negativePromptRaw), hasLength(2));
      expect(imported.promptFoldLinks, hasLength(2));
      final traveler = imported.promptFoldLinks.singleWhere(
        (link) => link.positiveName == '林间旅人',
      );
      final cat = imported.promptFoldLinks.singleWhere(
        (link) => link.positiveName == '夜色猫娘',
      );
      expect(traveler.positiveBody, 'new light');
      expect(traveler.negativeBody, 'unwanted blur');

      await tap(tester, key('desktop-prompt-preset'));
      await tap(tester, key('prompt-preset-card-none'));
      await tap(tester, key('prompt-preset-manager-close'));
      expect(container.read(activePromptPresetIdProvider), 'none');
      expect(gen.state.promptFoldLinks, imported.promptFoldLinks);

      for (final positive in [true, false]) {
        await tap(
          tester,
          key('desktop-prompt-${positive ? 'positive' : 'negative'}-tab'),
        );
        await deleteFold(
          tester,
          'desktop-prompt',
          positive ? traveler.positiveName : traveler.negativeName,
        );
        expect(gen.state.prompt, 'sunrise, forest, cat ears, moonlight');
        expect(
          gen.state.negativePrompt,
          'rain, manual exclusion, bad paws, bad tail',
        );
        expect(gen.state.promptFoldLinks.map((link) => link.id), [cat.id]);
        await tap(tester, key('desktop-prompt-undo'));
        expect(gen.state.prompt, imported.prompt);
        expect(gen.state.negativePrompt, imported.negativePrompt);
        expect(gen.state.promptRaw, imported.promptRaw);
        expect(gen.state.negativePromptRaw, imported.negativePromptRaw);
        expect(gen.state.promptFoldLinks, imported.promptFoldLinks);
      }
      await finish(tester);
    },
  );

  testWidgets(
    'real character import retains paired raw drafts and deletes only the target character pair',
    (tester) async {
      gen.setPrompts(positive: 'main untouched', negative: 'main exclusion');
      gen.addNamedCharactersFrom([
        (
          avatar: null,
          name: '已有角色',
          positive: 'original words',
          negative: 'original negative',
        ),
      ]);
      final existing = gen.state.characters.single;
      await mount(tester);
      await importEntries(tester, ['traveler', 'cat'], asCharacters: true);
      expect(gen.state.characters, hasLength(3));
      final imported = gen.state.characters.singleWhere(
        (c) => c.name == '林间旅人',
      );
      final other = gen.state.characters.singleWhere((c) => c.name == '夜色猫娘');
      for (final c in [imported, other]) {
        expect(parseFolds(c.positiveRaw), hasLength(1));
        expect(parseFolds(c.negativeRaw), hasLength(1));
        expect(c.foldLinks, hasLength(1));
      }
      final prefix = 'desktop-character-${imported.id}';
      final pair = imported.foldLinks.single;
      await tap(tester, key('$prefix-negative-tab'));
      await deleteFold(tester, prefix, pair.negativeName);
      expect(character(imported.id).positive, isEmpty);
      expect(character(imported.id).negative, isEmpty);
      expect(character(imported.id).foldLinks, isEmpty);
      expect(character(existing.id), same(existing));
      expect(character(other.id), same(other));
      expect(gen.state.prompt, 'main untouched');
      expect(gen.state.negativePrompt, 'main exclusion');

      await tap(tester, key('$prefix-undo'));
      final restored = character(imported.id);
      expect(restored.positive, imported.positive);
      expect(restored.negative, imported.negative);
      expect(restored.positiveRaw, imported.positiveRaw);
      expect(restored.negativeRaw, imported.negativeRaw);
      expect(restored.foldLinks, imported.foldLinks);
      await finish(tester);
    },
  );

  testWidgets(
    'mounted editor reloads sidecar-only unlink before deleting an imported fold',
    (tester) async {
      gen.setPrompts(positive: 'forest', negative: 'rain');
      await mount(tester);
      await importEntries(tester, ['traveler']);
      final imported = gen.state;
      final pair = imported.promptFoldLinks.single;
      final mountedEditor = tester.state<ChipFlowViewState>(
        flowIn('desktop-prompt'),
      );
      gen.setPrompts(promptFoldLinks: []);
      await tester.pumpAndSettle();
      expect(gen.state.promptRaw, imported.promptRaw);
      expect(gen.state.negativePromptRaw, imported.negativePromptRaw);
      expect(
        tester.state<ChipFlowViewState>(flowIn('desktop-prompt')),
        same(mountedEditor),
      );
      await deleteFold(tester, 'desktop-prompt', pair.positiveName);
      expect(gen.state.prompt, 'forest');
      expect(gen.state.negativePrompt, imported.negativePrompt);
      expect(gen.state.promptFoldLinks, isEmpty);

      await tap(tester, key('desktop-prompt-undo'));
      expect(gen.state.prompt, imported.prompt);
      expect(gen.state.negativePrompt, imported.negativePrompt);
      expect(gen.state.promptFoldLinks, isEmpty);
      await finish(tester);
    },
  );
}
