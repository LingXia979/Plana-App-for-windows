import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/widgets/inline_editor_chrome.dart';
import 'package:plana_app/features/editor/widgets/prompt_preset_menu_button.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/preset_manage_page.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';

class _MemoryPresets extends PromptPresetsNotifier {
  int activations = 0;
  int adds = 0;
  int updates = 0;
  int removes = 0;
  int imports = 0;
  List<PromptPreset> extra = const [];
  PromptPresetsState get current => state.requireValue;

  @override
  Future<PromptPresetsState> build() async => PromptPresetsState(
    presets: [
      ...kDefaultPromptPresets,
      const PromptPreset(
        id: 'custom',
        name: '我的预设',
        positive: 'custom style',
        negative: 'custom exclusion',
      ),
      const PromptPreset(
        id: 'custom-v5',
        name: 'V5 预设',
        positive: 'v5 style',
        negative: '',
        scope: 'v5',
      ),
      ...extra,
    ],
    activeId: 'heavy',
  );

  @override
  Future<void> setActive(String id) async {
    activations++;
    state = AsyncData(
      PromptPresetsState(presets: current.presets, activeId: id),
    );
  }

  @override
  Future<void> add({
    required String name,
    String positive = '',
    String negative = '',
    bool suffixPositive = false,
  }) async {
    adds++;
    state = AsyncData(
      PromptPresetsState(
        presets: [
          ...current.presets,
          PromptPreset(
            id: 'created-$adds',
            name: name,
            positive: positive,
            negative: negative,
            suffixPositive: suffixPositive,
          ),
        ],
        activeId: current.activeId,
      ),
    );
  }

  @override
  Future<void> updatePreset(
    String id, {
    String? name,
    String? positive,
    String? negative,
    bool? suffixPositive,
  }) async {
    updates++;
    state = AsyncData(
      PromptPresetsState(
        presets: [
          for (final p in current.presets)
            p.id == id
                ? p.copyWith(
                    name: name,
                    positive: positive,
                    negative: negative,
                    suffixPositive: suffixPositive,
                  )
                : p,
        ],
        activeId: current.activeId,
      ),
    );
  }

  @override
  Future<void> remove(String id) async {
    removes++;
    state = AsyncData(
      PromptPresetsState(
        presets: current.presets.where((p) => p.id != id).toList(),
        activeId: current.activeId == id ? 'none' : current.activeId,
      ),
    );
  }

  @override
  Future<int> importPresets(
    List<PromptPreset> incoming, {
    String? activeId,
  }) async {
    imports++;
    state = AsyncData(
      PromptPresetsState(
        presets: [...current.presets, ...incoming],
        activeId: current.activeId,
      ),
    );
    return incoming.length;
  }
}

class _Picker extends FilePicker {
  String? text;
  int calls = 0;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    expect(type, FileType.custom);
    expect(allowedExtensions, ['json']);
    expect(withData, isTrue);
    if (text == null) return null;
    final bytes = Uint8List.fromList(utf8.encode(text!));
    return FilePickerResult([
      PlatformFile(name: 'presets.json', size: bytes.length, bytes: bytes),
    ]);
  }
}

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late GenerateNotifier gen;
  late _MemoryPresets presets;
  late _Picker picker;
  late FilePicker originalPicker;

  setUpAll(() => FilePicker.platform = _Picker());

  setUp(() async {
    stores = AppStores.ephemeral();
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          enableCompletion: false,
          showTranslation: false,
        ).toJson(),
      ),
    );
    presets = _MemoryPresets();
    originalPicker = FilePicker.platform;
    picker = _Picker();
    FilePicker.platform = picker;
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        promptPresetsProvider.overrideWith(() => presets),
      ],
    );
    gen = container.read(generateProvider.notifier);
  });

  tearDown(() {
    FilePicker.platform = originalPicker;
    container.dispose();
    stores.flushNow();
  });

  Finder key(String name) => find.byKey(ValueKey(name));
  Finder presetItem(String id) => key('prompt-preset-card-$id');
  Finder textInput() => find.descendant(
    of: key('desktop-prompt-text'),
    matching: find.byType(TextField),
  );

  ProviderContainer editorContainer(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(InlineEditorChrome).first),
        listen: false,
      );

  Future<void> mount(
    WidgetTester tester, {
    double width = 310,
    double textScale = 1,
    Size window = const Size(1000, 800),
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  child: Consumer(
                    builder: (_, ref, _) => Column(
                      children: [
                        const DesktopPromptCard(),
                        for (final c in ref.watch(generateProvider).characters)
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
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) =>
      tap(tester, key('desktop-prompt-preset'));

  Future<void> close(WidgetTester tester) =>
      tap(tester, key('prompt-preset-manager-close'));

  Future<void> reveal(WidgetTester tester, String id) async {
    final scrollable = find
        .descendant(
          of: find.byType(ReorderableListView),
          matching: find.byType(Scrollable),
        )
        .first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      presetItem(id),
      180,
      scrollable: scrollable,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String id) async {
    await reveal(tester, id);
    await tap(tester, presetItem(id));
    expect(key('prompt-preset-manager-dialog'), findsOneWidget);
    expect(
      find.descendant(
        of: presetItem(id),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
  }

  Finder detailFields() => find.descendant(
    of: key('prompt-preset-editor-dialog'),
    matching: find.byType(TextField),
  );

  Rect dialogRect(WidgetTester tester, String name) =>
      tester.getRect(find.byWidget(tester.widget<Dialog>(key(name)).child!));

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  for (final size in [(310.0, 1.0), (220.0, 1.4)]) {
    testWidgets(
      'main-only shortcut stays next to mode at width ${size.$1}, scale ${size.$2}',
      (tester) async {
        gen.addCharacter();
        final charId = gen.state.characters.single.id;
        await mount(tester, width: size.$1, textScale: size.$2);
        expect(find.byType(PromptPresetMenuButton), findsOneWidget);
        expect(find.byTooltip('切换预设'), findsOneWidget);
        expect(key('desktop-character-$charId-mode'), findsOneWidget);
        final mode = tester.getRect(key('desktop-prompt-mode'));
        final preset = tester.getRect(key('desktop-prompt-preset'));
        expect(preset.left, closeTo(mode.right, .01));
        expect(preset.center.dy, closeTo(mode.center.dy, .01));
        expect(preset.right, lessThanOrEqualTo(size.$1 - 12));
        expect(tester.takeException(), isNull);
        await open(tester);
        expect(
          tester
              .widget<PromptPresetManagePage>(
                find.byType(PromptPresetManagePage),
              )
              .compact,
          isTrue,
        );
        expect(
          dialogRect(tester, 'prompt-preset-manager-dialog').size,
          const Size(740, 640),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(presets.activations, 0);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'shared manager shows all scopes and selection never changes the generation model',
    (tester) async {
      gen.setModel('NAI 5.0 Full');
      gen.setPrompts(positive: 'sunrise', negative: 'rain');
      await mount(tester);
      final before = gen.state;
      await open(tester);
      expect(
        find.descendant(
          of: presetItem('heavy'),
          matching: find.byIcon(Icons.radio_button_checked),
        ),
        findsOneWidget,
      );
      expect(presets.current.activeId, 'heavy');
      expect(presets.activations, 0);
      for (final id in [
        'heavy',
        'light',
        'v5-standard',
        'v5-light',
        'none',
        'custom',
        'custom-v5',
      ]) {
        await reveal(tester, id);
        expect(presetItem(id), findsOneWidget);
      }
      expect(
        find.descendant(of: presetItem('custom-v5'), matching: find.text('V5')),
        findsOneWidget,
      );
      await select(tester, 'v5-light');
      expect(gen.state, same(before));
      gen.setModel('NAI 4.5 Full');
      await tester.pumpAndSettle();
      await select(tester, 'custom-v5');
      expect(presets.current.activeId, 'custom-v5');
      expect(gen.state.params.model, 'NAI 4.5 Full');
      await close(tester);
      expect(presets.current.activeId, 'custom-v5');
      await finish(tester);
    },
  );

  testWidgets(
    'selecting custom or none preserves drafts, caret, tabs and undo',
    (tester) async {
      gen.setPrompts(positive: 'sunrise', negative: 'rain');
      await mount(tester);
      await tester.enterText(textInput(), 'sunrise, mist ');
      await tester.pumpAndSettle();
      await tap(tester, key('desktop-prompt-negative-tab'));
      final editor = editorContainer(tester);
      // A distinct undo step avoids the editor's 700 ms typing coalescence.
      editor
          .read(editorProvider.notifier)
          .editActive('rain, snow ', structural: true);
      editor
          .read(editorProvider.notifier)
          .registerFold('saved style', 'soft light');
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(textInput()).controller!;
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pumpAndSettle();
      final editing = editor.read(editorProvider);
      final generation = gen.state;
      final selection = controller.selection;
      expect(editing.activePositive, isFalse);
      expect(editing.canUndo, isTrue);

      await open(tester);
      for (final id in ['custom', 'none']) {
        await select(tester, id);
        expect(presets.current.activeId, id);
        expect(editor.read(editorProvider), same(editing));
        expect(gen.state, same(generation));
        expect(controller.text, 'rain, snow ');
        expect(controller.selection, selection);
        expect(editing.positiveText, 'sunrise, mist ');
        expect(editing.foldBodies['saved style'], 'soft light');
      }
      expect(presets.activations, 2);
      await close(tester);
      await tap(tester, key('desktop-prompt-undo'));
      expect(gen.state.negativePrompt, 'rain');
      expect(gen.state.prompt, 'sunrise, mist');
      await finish(tester);
    },
  );

  testWidgets('preset selection retains uncommitted chip input and selection', (
    tester,
  ) async {
    gen.setPrompts(positive: 'sunrise, mist', negative: 'rain');
    await mount(tester);
    await tap(tester, key('desktop-prompt-mode'));
    final flowFinder = find.byType(ChipFlowView);
    final flow = tester.state<ChipFlowViewState>(flowFinder);
    await tester.tapAt(flow.chipAnchor(0)!.center);
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: flowFinder,
      matching: find.byType(TextField),
    );
    await tester.enterText(input, 'unfinished words');
    await tester.pumpAndSettle();
    final before = tester.widget<ChipFlowView>(flowFinder);
    final editor = editorContainer(tester);
    final editing = editor.read(editorProvider);
    final generation = gen.state;
    final draft = before.input.value;
    final selected = Set<int>.of(before.selection);
    await open(tester);
    await select(tester, 'none');
    await close(tester);
    final after = tester.widget<ChipFlowView>(flowFinder);
    expect(after.input.value, draft);
    expect(chipInputBody(after.input.text), 'unfinished words');
    expect(after.selection, selected);
    expect(editor.read(editorProvider), same(editing));
    expect(gen.state, same(generation));
    expect(key('desktop-prompt-tags'), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
    'repeated opening and dismissal never change the preset or editor',
    (tester) async {
      gen.setPrompts(positive: 'sunrise', negative: 'rain');
      await mount(tester);
      final before = gen.state;
      final openButton = tester.widget<IconButton>(
        key('desktop-prompt-preset'),
      );
      openButton.onPressed!();
      openButton.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(PromptPresetManagePage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('prompt-preset-manager-dialog'), findsNothing);
      await open(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(key('prompt-preset-manager-dialog'), findsNothing);
      expect(presets.current.activeId, 'heavy');
      expect(presets.activations, 0);
      expect(gen.state, same(before));
      await finish(tester);
    },
  );

  testWidgets(
    '340px window with large text keeps long lists and readonly details scrollable',
    (tester) async {
      presets.extra = [
        for (var i = 0; i < 30; i++)
          PromptPreset(
            id: 'extra-$i',
            name: '第 $i 个名字很长的自定义预设，保持菜单宽度和滚动',
            positive: 'extra $i',
            negative: '',
          ),
      ];
      await mount(
        tester,
        width: 220,
        textScale: 1.8,
        window: const Size(340, 600),
      );
      await open(tester);
      expect(
        dialogRect(tester, 'prompt-preset-manager-dialog').size,
        const Size(308, 568),
      );
      await select(tester, 'extra-29');
      expect(presets.current.activeId, 'extra-29');
      expect(presets.activations, 1);
      await reveal(tester, 'heavy');
      await tap(tester, key('prompt-preset-edit-heavy'));
      final detail = dialogRect(tester, 'prompt-preset-editor-dialog');
      expect(detail.width, lessThanOrEqualTo(308));
      expect(detail.height, lessThanOrEqualTo(568));
      expect(
        tester.widgetList<TextField>(detailFields()).every((f) => f.readOnly),
        isTrue,
      );
      expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
      await tap(tester, find.widgetWithText(TextButton, '关闭'));
      expect(key('prompt-preset-manager-dialog'), findsOneWidget);
      expect(presets.current.activeId, 'extra-29');
      expect(presets.updates, 0);
      expect(key('prompt-preset-delete-heavy'), findsNothing);
      await close(tester);
      await finish(tester);
    },
  );

  testWidgets(
    'compact custom editing supports cancel, one creation, save and confirmed delete',
    (tester) async {
      await mount(tester);
      await open(tester);
      await reveal(tester, 'custom');
      final before = presets.current;
      await tap(tester, key('prompt-preset-edit-custom'));
      await tester.enterText(detailFields().at(0), 'discard this edit');
      await tap(tester, find.widgetWithText(TextButton, '取消'));
      expect(presets.current, same(before));
      expect(presets.updates, 0);

      final create = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('新建预设'),
          matching: find.byType(IconButton),
        ),
      );
      create.onPressed!();
      create.onPressed!();
      await tester.pumpAndSettle();
      expect(key('prompt-preset-editor-dialog'), findsOneWidget);
      await tester.enterText(detailFields().at(0), 'New preset');
      await tester.enterText(detailFields().at(1), 'soft light');
      await tester.enterText(detailFields().at(2), 'blur');
      await tap(tester, find.text('末尾'));
      await tap(tester, find.widgetWithText(FilledButton, '保存'));
      expect(presets.adds, 1);
      var created = presets.current.presets.singleWhere(
        (p) => p.id == 'created-1',
      );
      expect(
        (
          created.name,
          created.positive,
          created.negative,
          created.suffixPositive,
        ),
        ('New preset', 'soft light', 'blur', true),
      );
      expect(presets.current.activeId, 'heavy');

      await reveal(tester, created.id);
      await tap(tester, key('prompt-preset-edit-${created.id}'));
      await tester.enterText(detailFields().at(0), 'Renamed');
      await tap(tester, find.widgetWithText(FilledButton, '保存'));
      expect(presets.updates, 1);
      created = presets.current.presets.singleWhere((p) => p.id == 'created-1');
      expect(created.name, 'Renamed');
      await select(tester, created.id);
      await tap(tester, key('prompt-preset-delete-${created.id}'));
      await tap(tester, find.widgetWithText(TextButton, '取消'));
      expect(presets.removes, 0);
      await tap(tester, key('prompt-preset-delete-${created.id}'));
      await tap(tester, find.widgetWithText(FilledButton, '删除'));
      expect(presets.removes, 1);
      expect(presets.current.activeId, 'none');
      expect(presets.current.presets.any((p) => p.id == created.id), isFalse);
      expect(key('prompt-preset-manager-dialog'), findsOneWidget);
      await close(tester);
      await finish(tester);
    },
  );

  testWidgets(
    'compact JSON import preserves state on cancel or invalid data and shows imported scope',
    (tester) async {
      await mount(tester);
      await open(tester);
      final before = presets.current;
      await tap(tester, find.byTooltip('导入预设（JSON）'));
      expect(presets.current, same(before));
      expect(presets.imports, 0);
      picker.text = '[{"positive":"valid"},{"positive":12}]';
      await tap(tester, find.byTooltip('导入预设（JSON）'));
      expect(presets.current, same(before));
      expect(presets.imports, 0);
      expect(find.textContaining('导入失败'), findsOneWidget);
      expect(
        tester.getRect(find.byType(SnackBar)).bottom,
        lessThanOrEqualTo(
          dialogRect(tester, 'prompt-preset-manager-dialog').bottom,
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      picker.text = jsonEncode([
        {
          'id': 'imported',
          'name': 'Imported scoped preset',
          'positive': 'quality',
          'negative': 'error',
          'scope': 'legacy',
          'positivePlacement': 'suffix',
        },
      ]);
      await tap(tester, find.byTooltip('导入预设（JSON）'));
      expect(presets.imports, 1);
      expect(presets.current.activeId, before.activeId);
      final imported = presets.current.presets.last;
      expect((imported.scope, imported.suffixPositive), ('legacy', true));
      await reveal(tester, 'imported');
      expect(
        find.descendant(
          of: presetItem('imported'),
          matching: find.text('4.5 及更早'),
        ),
        findsOneWidget,
      );
      expect(picker.calls, 3);
      await close(tester);
      await finish(tester);
    },
  );
}
