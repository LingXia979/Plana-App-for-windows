import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/setting_row.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/rules_page.dart';
import 'package:plana_app/features/assistant/widgets/settings_sheet.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:flutter/services.dart';

import 'support/desktop_capture.dart';

void main() {
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  setUp(() async {
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(false),
        assistantEndpointProvider.overrideWithValue(
          const CustomEndpoint(
            id: 'synthetic',
            name: '合成接口',
            baseUrl: 'https://example.test',
            apiKey: '',
            model: 'synthetic',
            format: AgentApiFormat.openai,
          ),
        ),
        defaultRulesProvider.overrideWith(
          (ref, family) async => const DefaultRules(
            name: '默认规则',
            author: '',
            version: 'test',
            rules: [PresetRule(name: 'role', content: 'synthetic')],
          ),
        ),
      ],
    );
    await c.read(assistantSettingsProvider.future);
    await c.read(rulesLibraryProvider.future);
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });

  Future<void> mount(
    WidgetTester tester,
    Widget page,
    double scale, {
    Size size = const Size(1000, 780),
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(
                fontFamily: 'Microsoft YaHei',
                fontFamilyFallback: const ['Microsoft YaHei'],
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: page,
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

  for (final (name, scale, size, dark) in [
    ('normal', 1.0, const Size(1000, 780), false),
    ('large-dark', 1.4, const Size(880, 540), true),
    ('narrow', 1.4, const Size(440, 640), false),
  ]) {
    testWidgets('desktop import dropdown applies all three modes: $name', (
      tester,
    ) async {
      stores.assistant.initialCurrent = const [
        AssistantMsg(
          id: 'import-reply',
          role: MsgRole.ai,
          text: '',
          at: 1,
          draw: DrawProposal(positive: 'new scene', negative: 'new negative'),
        ),
      ];
      final original = GenerateState.initial().copyWith(
        prompt: 'old scene',
        promptRaw: '<#scene: old scene#>',
        negativePrompt: 'old negative',
        sections: const [
          PromptSection.main(),
          PromptSection(id: 'style', name: '画风', positive: 'watercolor'),
        ],
      );
      c
          .read(generateProvider.notifier)
          .applyCanvas(CanvasPrompts.of(original), force: true);
      final before = PromptSnapshot.of(c.read(generateProvider));
      final assistant = c.read(assistantProvider.notifier);
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showAssistantSettings(context),
                child: const Text('助手设置'),
              ),
            ),
          ),
        ),
        scale,
        size: size,
        dark: dark,
      );
      await tester.tap(find.text('助手设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      final dropdown = find.byType(DropdownButton<SectionImport>);
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await captureDesktop(tester, capture, 'assistant-import-$name-menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        c.read(assistantSettingsProvider).value!.importTo,
        SectionImport.main,
      );
      expect(
        find.byKey(const ValueKey('desktop-assistant-settings')),
        findsOneWidget,
      );

      for (final mode in SectionImport.values) {
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(sectionImportLabel(mode)).last);
        await tester.pumpAndSettle();
        expect(c.read(assistantSettingsProvider).value!.importTo, mode);
        expect(
          tester.widget<DropdownButton<SectionImport>>(dropdown).value,
          mode,
        );
        expect(
          PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
          isTrue,
        );
        final preview = assistant.previewSendState('import-reply')!;
        expect(assistant.applyProposal('import-reply'), isTrue);
        final imported = c.read(generateProvider);
        expect(
          imported.prompt,
          mode == SectionImport.newSection ? 'old scene' : 'new scene',
        );
        expect(
          imported.negativePrompt,
          mode == SectionImport.newSection ? 'old negative' : 'new negative',
        );
        expect(imported.sections.length, switch (mode) {
          SectionImport.main => 2,
          SectionImport.newSection => 3,
          SectionImport.clear => 0,
        });
        if (mode != SectionImport.clear) {
          expect(imported.sections[1].positive, 'watercolor');
        }
        if (mode == SectionImport.newSection) {
          expect(imported.sections.last.positive, 'new scene');
          expect(imported.sections.last.name, 'AI');
        }
        expect(composeSections(imported).prompt, preview.prompt);
        expect(
          composeSections(imported).negativePrompt,
          preview.negativePrompt,
        );
        expect(assistant.undo('import-reply'), isTrue);
        expect(
          PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
          isTrue,
        );
      }

      await captureDesktop(tester, capture, 'assistant-import-$name-selected');
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      c.invalidate(assistantSettingsProvider);
      await tester.runAsync(() => c.read(assistantSettingsProvider.future));
      expect(
        c.read(assistantSettingsProvider).value!.importTo,
        SectionImport.clear,
      );
      await finish(tester);
    });
  }

  for (final scale in [1.0, 1.4]) {
    testWidgets('desktop OC and sidebar settings persist at scale $scale', (
      tester,
    ) async {
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showAssistantSettings(context),
                child: const Text('助手设置'),
              ),
            ),
          ),
        ),
        scale,
      );
      await tester.tap(find.text('助手设置'));
      await tester.pumpAndSettle();
      expect(
        c.read(assistantSettingsProvider).value!.showSidebarImagePicker,
        isTrue,
      );
      final images = find.widgetWithText(SettingRow, '添加图片');
      await tester.ensureVisible(images);
      await tester.tap(images);
      await tester.pumpAndSettle();
      final oc = find.widgetWithText(SettingRow, 'OC 使用占位符');
      await tester.ensureVisible(oc);
      await tester.tap(oc);
      await tester.pumpAndSettle();
      await captureDesktop(
        tester,
        capture,
        'windows53-assistant-${(scale * 100).round()}',
      );
      expect(c.read(assistantSettingsProvider).value!.ocPlaceholders, isTrue);
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      c.invalidate(assistantSettingsProvider);
      await tester.runAsync(() => c.read(assistantSettingsProvider.future));
      expect(
        c.read(assistantSettingsProvider).value!.showSidebarImagePicker,
        isFalse,
      );
      expect(
        c.read(assistantSettingsProvider).value!.showSidebarHistoryPicker,
        isTrue,
      );
      expect(c.read(assistantSettingsProvider).value!.ocPlaceholders, isTrue);
      await finish(tester);
    });

    testWidgets(
      'full rule editor rejects invalid YAML and saves in place at scale $scale',
      (tester) async {
        final n = c.read(rulesLibraryProvider.notifier);
        final id = await tester.runAsync(
          () => n.add(
            name: '合成规则',
            author: '',
            models: {RulesFamily.nai5},
            rules: const [PresetRule(name: 'role', content: 'old rule')],
          ),
        );
        await tester.runAsync(() => n.use(RulesFamily.nai5, id!));
        await mount(tester, const RulesPresetPage(), scale);
        await tester.tap(find.byTooltip('编辑').last);
        await tester.pumpAndSettle();
        final editor = find.byWidgetPredicate(
          (w) => w is TextField && w.expands,
        );
        await tester.enterText(
          editor,
          'sections:\n  - name: role\n    content: a: b\n',
        );
        await tester.tap(find.byTooltip('保存'));
        await tester.pumpAndSettle();
        expect(editor, findsOneWidget);
        expect(c.read(rulesLibraryProvider).value!.presets.single.name, '合成规则');
        final valid = encodeRulesFile(
          name: '合成规则 · 已编辑',
          author: '本地测试',
          models: {RulesFamily.nai5},
          rules: const [PresetRule(name: 'role', content: '保持角色设定，并使用自然的构图。')],
        );
        await tester.enterText(editor, valid);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await captureDesktop(
          tester,
          capture,
          'windows53-rules-${(scale * 100).round()}',
        );
        await tester.tap(find.byTooltip('保存'));
        for (
          var i = 0;
          i < 100 &&
              c.read(rulesLibraryProvider).value!.presets.single.name == '合成规则';
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        final library = c.read(rulesLibraryProvider).value!;
        expect(library.presets.single.id, id);
        expect(library.presets.single.name, '合成规则 · 已编辑');
        expect(library.active[RulesFamily.nai5], id);
        expect(editor, findsNothing);
        await finish(tester);
      },
    );
  }
}
