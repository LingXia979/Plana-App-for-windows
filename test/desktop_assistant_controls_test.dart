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
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_mode.dart';
import 'package:plana_app/features/assistant/assistant_page.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/rules_page.dart';
import 'package:plana_app/features/assistant/widgets/model_sheet.dart';
import 'package:plana_app/features/assistant/widgets/settings_sheet.dart';
import 'package:plana_app/core/ui/setting_row.dart';

class _LoadingRules extends RulesLibraryNotifier {
  _LoadingRules(this.ready);
  final Completer<RulesLibrary> ready;
  @override
  Future<RulesLibrary> build() => ready.future;
}

void main() {
  late ProviderContainer c;
  late AppStores stores;
  final capture = GlobalKey();
  setUpAll(() async {
    if (Platform.isWindows) {
      for (final font in [
        ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
        ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
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
    }
  });
  setUp(() {
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        defaultRulesProvider.overrideWith(
          (ref, family) async => const DefaultRules(
            name: 'Default test rules',
            author: '',
            version: 'test',
            rules: [
              PresetRule(name: 'comic', content: 'comic', when: 'mode:comic'),
              PresetRule(
                name: 'natural',
                content: 'natural',
                when: 'mode:natural',
              ),
            ],
          ),
        ),
        agentModelsProvider.overrideWith(
          (ref) async => const AgentModelList(
            active: 'one',
            choices: [
              AgentModelChoice(
                key: 'one',
                name: 'Model One',
                recommended: true,
              ),
              AgentModelChoice(key: 'two', name: 'Model Two'),
            ],
          ),
        ),
      ],
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1100, 780),
    bool realAssistant = false,
  }) async {
    tester.view.physicalSize = size;
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
                fontFamilyFallback: const ['Segoe UI'],
              ),
              platform: TargetPlatform.windows,
            ),
            home: Scaffold(
              body: realAssistant
                  ? const AssistantPage(embedded: true)
                  : Align(
                      alignment: Alignment.topRight,
                      child: SizedBox(
                        width: 400,
                        child: Column(
                          children: [
                            Builder(
                              builder: (context) => Row(
                                children: [
                                  const Expanded(
                                    child: AssistantModelDropdown(),
                                  ),
                                  IconButton(
                                    key: const ValueKey('settings'),
                                    tooltip: '助手设置',
                                    onPressed: () =>
                                        showAssistantSettings(context),
                                    icon: const Icon(Icons.tune),
                                  ),
                                ],
                              ),
                            ),
                            const TextField(key: ValueKey('draft')),
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

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'build/windows-validation/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'model menu anchors below its button, selects and dismisses with Escape or outside click',
    (tester) async {
      debugDisableShadows = false;
      await mount(tester);
      final button = find.byKey(const ValueKey('assistant-model-button'));
      final buttonRect = tester.getRect(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final choice = find.byKey(const ValueKey('assistant-model-two'));
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.getRect(choice).top, greaterThan(buttonRect.bottom));
      await screenshot(tester, 'assistant-model-dropdown');
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(c.read(assistantModelPrefProvider).value, 'two');
      expect(find.byKey(const ValueKey('assistant-model-two')), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(choice, findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 500));
      await tester.pumpAndSettle();
      expect(choice, findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
      debugDisableShadows = true;
    },
  );

  testWidgets(
    'desktop settings slide in on the right, group controls, persist and preserve draft',
    (tester) async {
      debugDisableShadows = false;
      await mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('draft')),
        'unsent draft',
      );
      await tester.tap(find.byKey(const ValueKey('settings')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('desktop-assistant-settings'));
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.getRect(panel).right, 1084);
      expect(tester.getSize(panel).width, 440);
      await screenshot(tester, 'assistant-settings-conversation');
      final streamRow = find.widgetWithText(SettingRow, '流式输出');
      await tester.tap(streamRow);
      await tester.pumpAndSettle();
      expect(c.read(assistantSettingsProvider).value!.stream, false);
      await tester.tap(find.text('生成'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SettingRow, '纯文本格式'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SettingRow>(find.widgetWithText(SettingRow, '生成提示词后自动出图'))
            .enabled,
        false,
      );
      expect(c.read(assistantSettingsProvider).value!.autoGenerate, false);
      await screenshot(tester, 'assistant-settings-generation');
      await tester.tap(find.text('资料与规则'));
      await tester.pumpAndSettle();
      expect(find.text('资料库范围'), findsOneWidget);
      expect(find.text('规则预设'), findsOneWidget);
      await screenshot(tester, 'assistant-settings-resources');
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      expect(
        tester
                .widget<TextField>(find.byKey(const ValueKey('draft')))
                .controller
                ?.text ??
            tester
                .widget<EditableText>(find.byType(EditableText))
                .controller
                .text,
        'unsent draft',
      );
      c.invalidate(assistantSettingsProvider);
      await c.read(assistantSettingsProvider.future);
      expect(c.read(assistantSettingsProvider).value!.stream, false);
      expect(c.read(assistantSettingsProvider).value!.noDraw, true);
      await tester.tap(find.byKey(const ValueKey('settings')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
      debugDisableShadows = true;
    },
  );

  testWidgets(
    'empty model menu supports Escape before any interface is configured',
    (tester) async {
      c.dispose();
      c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(true),
          assistantBotAuthorizedProvider.overrideWithValue(false),
          agentModelsProvider.overrideWith(
            (ref) async => const AgentModelList(),
          ),
        ],
      );
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('assistant-model-button')));
      await tester.pumpAndSettle();
      expect(find.text('添加接口'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('添加接口'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets('settings keep all tabs usable in a short desktop window', (
    tester,
  ) async {
    await mount(tester, size: const Size(880, 540));
    await tester.tap(find.byKey(const ValueKey('settings')));
    await tester.pumpAndSettle();
    for (final tab in ['对话', '生成', '资料与规则']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    final panel = tester.getRect(
      find.byKey(const ValueKey('desktop-assistant-settings')),
    );
    expect(panel.top, greaterThanOrEqualTo(16));
    expect(panel.bottom, lessThanOrEqualTo(524));
    await tester.tapAt(const Offset(100, 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('desktop-assistant-settings')),
      findsNothing,
    );
    await finish(tester);
  });

  testWidgets(
    'preset navigation and repeated mode changes preserve the assistant and draft',
    (tester) async {
      await c.read(rulesLibraryProvider.future);
      final customId = await tester.runAsync(
        () => c
            .read(rulesLibraryProvider.notifier)
            .add(
              name: 'Test preset',
              author: '',
              models: {RulesFamily.nai45},
              rules: const [
                PresetRule(name: 'comic', content: 'comic', when: 'mode:comic'),
                PresetRule(
                  name: 'natural',
                  content: 'natural',
                  when: 'mode:natural',
                ),
              ],
            ),
      );
      await mount(tester, realAssistant: true);
      final input = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '想画什么、想改哪里…',
      );
      await tester.enterText(input, 'Unsent while changing presets');
      await tester.tap(find.byTooltip('助手设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料与规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('规则预设'));
      await tester.pumpAndSettle();
      expect(find.byType(RulesPresetPage), findsOneWidget);
      await tester.tap(find.text('Test preset'));
      await tester.pumpAndSettle();
      expect(
        c.read(rulesLibraryProvider).value!.activeFor(RulesFamily.nai45).id,
        customId,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-assistant-settings')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('关闭助手设置'));
      await tester.pumpAndSettle();
      for (final mode in [
        AssistantMode.comic,
        AssistantMode.natural,
        AssistantMode.normal,
      ]) {
        final current = c.read(assistantProvider).mode;
        await tester.tap(
          find.widgetWithText(
            FilterChip,
            current == AssistantMode.normal
                ? '模式'
                : assistantModeLabel(current),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        final menu = tester.getRect(
          find.byKey(const ValueKey('desktop-popover')),
        );
        final button = tester.getRect(
          find.widgetWithText(
            FilterChip,
            current == AssistantMode.normal
                ? '模式'
                : assistantModeLabel(current),
          ),
        );
        expect(menu.width, 280);
        expect((menu.bottom - button.top).abs(), closeTo(8, 1));
        await tester.tap(
          find.widgetWithText(ListTile, assistantModeLabel(mode)),
        );
        await tester.pumpAndSettle();
        expect(c.read(assistantProvider).mode, mode);
        expect(find.byType(AssistantPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Unsent while changing presets',
      );
      await finish(tester);
    },
  );

  testWidgets(
    'leaving the assistant while rules refresh is pending does not use a disposed ref',
    (tester) async {
      final ready = Completer<RulesLibrary>();
      c.dispose();
      c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          rulesLibraryProvider.overrideWith(() => _LoadingRules(ready)),
        ],
      );
      late Future<Set<AssistantMode>?> pending;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    pending = refreshAssistantModes(ref, RulesFamily.nai45),
                child: const Text('Refresh modes'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Refresh modes'));
      await tester.pumpWidget(const SizedBox());
      final result = expectLater(pending, completion(isNull));
      ready.complete(const RulesLibrary());
      await tester.pumpAndSettle();
      await result;
      expect(tester.takeException(), isNull);
    },
  );
}
