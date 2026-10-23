import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/setting_row.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/rules_page.dart';
import 'package:plana_app/features/assistant/widgets/settings_sheet.dart';

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

  Future<void> mount(WidgetTester tester, Widget page, double scale) async {
    tester.view.physicalSize = const Size(1000, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light().textTheme.apply(
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
