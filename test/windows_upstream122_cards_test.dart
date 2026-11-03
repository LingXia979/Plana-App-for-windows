import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/setting_row.dart';
import 'package:plana_app/core/util/nai_tokenizer.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/widgets/settings_sheet.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/widgets/advanced_sheet.dart';
import 'package:plana_app/features/generate/widgets/bottom_action_bar.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';
import 'package:plana_app/features/generate/widgets/common.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';
import 'package:plana_app/features/generate/widgets/prompt_token_counts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NaiT5Tokenizer tokenizer;
  late AppStores stores;
  late ProviderContainer c;
  setUpAll(() async {
    tokenizer = NaiT5Tokenizer.parse(
      await rootBundle.loadString('assets/t5_tokenizer.json'),
    );
  });
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
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(false),
        assistantEndpointProvider.overrideWithValue(null),
        naiTokenizerProvider.overrideWith((_) async => tokenizer),
        tagTranslationServiceProvider.overrideWith((ref) {
          final s = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(s.dispose);
          return s;
        }),
      ],
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });
  Finder key(String id) => find.byKey(ValueKey(id));
  Finder input(String id) =>
      find.descendant(of: key('$id-text'), matching: find.byType(TextField));
  Future<void> mount(
    WidgetTester tester,
    Widget body, {
    double width = 350,
    bool scroll = true,
  }) async {
    tester.view.physicalSize = const Size(1100, 980);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: scroll ? SingleChildScrollView(child: body) : body,
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
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets(
    'delete undo captures pending text, preserves raw negatives and restores only its canvas',
    (tester) async {
      final gen = c.read(generateProvider.notifier);
      gen.applyCanvas(
        CanvasPrompts.of(
          GenerateState.initial().copyWith(
            characters: const [
              CharacterPrompt(
                id: 'a',
                name: 'A',
                positive: 'blue hair',
                negative: 'red hair',
                negativeRaw: '<#bad: red hair#>',
              ),
              CharacterPrompt(id: 'b', name: 'B', positive: 'forest'),
            ],
          ),
        ),
        force: true,
      );
      gen.openPanel(Panel.characters);
      final source = c.read(canvasWorkspaceProvider).activeId;
      await mount(tester, const CharacterCard(), width: 500);
      await tester.enterText(input('desktop-character-a'), 'blue hair, tail');
      await tester.pump();
      final remove = find
          .byWidgetPredicate((w) => w is IconButton && w.tooltip == '删除角色')
          .first;
      await tester.ensureVisible(remove);
      await tester.pump();
      await tester.tap(remove);
      await tester.pump();
      expect(c.read(generateProvider).characters.map((e) => e.id), ['b']);
      final other = c.read(canvasWorkspaceProvider.notifier).create();
      gen.setPrompts(positive: 'untouched');
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(c.read(canvasWorkspaceProvider).activeId, other);
      expect(c.read(generateProvider).prompt, 'untouched');
      c.read(canvasWorkspaceProvider.notifier).select(source);
      await tester.pumpAndSettle();
      final chars = c.read(generateProvider).characters;
      expect(chars.map((e) => e.id), ['a', 'b']);
      expect(chars.first.positive, 'blue hair, tail');
      expect(chars.first.negativeRaw, '<#bad: red hair#>');
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'local counts survive collapse, narrow layouts and Medium without losing High negative',
    (tester) async {
      final gen = c.read(generateProvider.notifier);
      gen.applyCanvas(
        CanvasPrompts.of(
          GenerateState.initial().copyWith(
            params: const GenParams(model: 'NAI 5.0 Full'),
            characters: const [
              CharacterPrompt(
                id: 'a',
                name: '凉',
                positive: 'blue hair',
                negative: 'red hair',
              ),
            ],
          ),
        ),
        force: true,
      );
      gen.openPanel(Panel.characters);
      await mount(tester, const CharacterCard(), width: 310);
      PromptTokenCounts counts() =>
          tester.widget<PromptTokenCounts>(find.byType(PromptTokenCounts));
      final positive = totalPromptTokens(tokenizer, main: 'blue hair');
      final negative = totalPromptTokens(tokenizer, main: 'red hair');
      expect(counts().positive, positive);
      expect(counts().negative, negative);
      final header = key('character-header-a');
      final avatar = tester.getRect(key('character-avatar-a'));
      final fullscreen = tester.getRect(key('character-fullscreen-a'));
      final x = fullscreen.top > avatar.bottom
          ? tester.getRect(header).right - 18
          : fullscreen.left - 20;
      await tester.tapAt(Offset(x, avatar.center.dy));
      await tester.pumpAndSettle();
      expect(input('desktop-character-a'), findsNothing);
      expect(counts().positive, positive);
      expect(counts().negative, negative);
      gen.applyParams(
        c.read(generateProvider).params.copyWith(naiEffort: NaiEffort.medium),
      );
      await tester.pumpAndSettle();
      expect(counts().negative, isNull);
      expect(find.text('—'), findsOneWidget);
      expect(c.read(generateProvider).characters.single.negative, 'red hair');
      gen.applyParams(
        c.read(generateProvider).params.copyWith(naiEffort: NaiEffort.high),
      );
      await tester.pumpAndSettle();
      expect(counts().negative, negative);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'section positive and negative counts remain visible when collapsed',
    (tester) async {
      c
          .read(generateProvider.notifier)
          .applyCanvas(
            CanvasPrompts.of(
              GenerateState.initial().copyWith(
                prompt: 'forest',
                negativePrompt: 'lowres',
                sections: const [
                  PromptSection.main(),
                  PromptSection(
                    id: 's',
                    name: '风格',
                    positive: 'watercolor',
                    negative: 'blurry',
                  ),
                ],
              ),
            ),
            force: true,
          );
      await mount(tester, const PromptCard());
      final header = key('prompt-section-header-s');
      await tester.ensureVisible(header);
      await tester.tapAt(
        tester.getRect(header).centerRight - const Offset(18, 0),
      );
      await tester.pumpAndSettle();
      final pairs = tester
          .widgetList<PromptTokenCounts>(find.byType(PromptTokenCounts))
          .toList();
      expect(pairs.length, 2);
      expect(
        pairs.last.positive,
        totalPromptTokens(tokenizer, main: 'watercolor'),
      );
      expect(pairs.last.negative, totalPromptTokens(tokenizer, main: 'blurry'));
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'Medium explains actual fixed values and cannot change the saved High parameters',
    (tester) async {
      const original = GenParams(
        model: 'NAI 5.0 Full',
        naiEffort: NaiEffort.medium,
        steps: 40,
        sampler: 'Euler',
        noiseSchedule: 'exponential',
        cfgRescale: .7,
      );
      c.read(generateProvider.notifier).applyParams(original);
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAdvancedSheet(context),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      ParamSlider param(String label) => tester.widget<ParamSlider>(
        find.byWidgetPredicate((w) => w is ParamSlider && w.label == label),
      );
      expect(param('步数 Steps').value, 14);
      expect(param('CFG Rescale').value, 0);
      final steps = find.byWidgetPredicate(
        (w) => w is ParamSlider && w.label == '步数 Steps',
      );
      final slider = find.descendant(of: steps, matching: find.byType(Slider));
      await tester.dragFrom(tester.getCenter(slider), const Offset(90, 0));
      await tester.pumpAndSettle();
      expect(param('步数 Steps').value, 14);
      await tester.tapAt(tester.getCenter(slider));
      await tester.pumpAndSettle();
      expect(find.text('Medium 步数固定为 14'), findsWidgets);
      for (final field in tester.widgetList<EditableText>(
        find.descendant(of: steps, matching: find.byType(EditableText)),
      )) {
        expect(field.focusNode.canRequestFocus, isFalse);
      }
      expect(param('步数 Steps').value, 14);
      await tester.ensureVisible(find.text('Euler'));
      await tester.tapAt(tester.getCenter(find.text('Euler')));
      await tester.pumpAndSettle();
      expect(find.text('Medium 采样器固定为 Euler Ancestral'), findsWidgets);
      await tester.ensureVisible(find.text('exponential'));
      await tester.tapAt(tester.getCenter(find.text('exponential')));
      await tester.pumpAndSettle();
      expect(find.text('NAI 5 噪声调度固定为 karras'), findsWidgets);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      final saved = c.read(generateProvider).params;
      expect(saved.steps, 40);
      expect(saved.sampler, 'Euler');
      expect(saved.noiseSchedule, 'exponential');
      expect(saved.cfgRescale, .7);
      c
          .read(generateProvider.notifier)
          .applyParams(saved.copyWith(naiEffort: NaiEffort.high));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(param('步数 Steps').value, 40);
      await tester.scrollUntilVisible(
        find.text('CFG Rescale'),
        180,
        scrollable: find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(param('CFG Rescale').value, .7);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'desktop fixed step readout explains instead of opening an editor',
    (tester) async {
      c
          .read(generateProvider.notifier)
          .applyParams(
            const GenParams(model: 'NAI 5.0 Full', naiEffort: NaiEffort.medium),
          );
      var opened = false;
      await mount(
        tester,
        BottomActionBar(desktop: true, onSettingTap: (_) => opened = true),
        width: 480,
      );
      await tester.tap(find.byKey(const ValueKey('desktop-summary-steps')));
      await tester.pumpAndSettle();
      expect(opened, isFalse);
      expect(find.text('Medium 步数固定为 14'), findsWidgets);
      await finish(tester);
    },
  );

  testWidgets(
    'desktop import choice persists and is unavailable in text-only mode',
    (tester) async {
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAssistantSettings(context),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      final choice = find.byType(DropdownButton<SectionImport>);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text(sectionImportLabel(SectionImport.newSection)));
      await tester.pumpAndSettle();
      expect(
        c.read(assistantSettingsProvider).value!.importTo,
        SectionImport.newSection,
      );
      await tester.tap(find.widgetWithText(SettingRow, '纯文本格式'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButton<SectionImport>>(choice).onChanged,
        isNull,
      );
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      c.invalidate(assistantSettingsProvider);
      await tester.runAsync(() => c.read(assistantSettingsProvider.future));
      expect(
        c.read(assistantSettingsProvider).value!.importTo,
        SectionImport.newSection,
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
}
