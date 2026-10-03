import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_page.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';
import 'package:plana_app/features/assistant/widgets/proposal_actions.dart';
import 'package:plana_app/features/assistant/widgets/proposal_sheet.dart';
import 'package:plana_app/features/assistant/widgets/result_strip.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/generate/widgets/anlas_panel.dart';

class _FixtureAssistant extends AssistantNotifier {
  void seed(AssistantState initial) => state = initial;
}

class _FixedAnlas extends AnlasNotifier {
  int refreshes = 0;
  @override
  Future<NaiSubscription?> build() async => (
    anlas: 35738,
    fixedAnlas: 0,
    purchasedAnlas: 35738,
    isOpus: true,
    tier: 3,
    usage: (
      percent: 100.0,
      isNegative: false,
      secondsToNextPct: 6000,
      accounts: 1,
    ),
  );
  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

class _NoQuota extends NaiQuotaNotifier {
  @override
  Future<NaiQuota?> build() async => null;
  @override
  Future<void> refresh() async {}
}

const _current = [
  AssistantMsg(id: 'ask', role: MsgRole.user, text: '画一个站在樱花树下的猫娘', at: 1),
  AssistantMsg(
    id: 'reply',
    role: MsgRole.ai,
    text: '樱花树下,微风吹起花瓣。',
    at: 2,
    draw: DrawProposal(
      positive:
          '1girl, cat ears, white hair, red eyes, cherry blossoms, falling petals, outdoors, spring, sunlight',
    ),
  ),
];

ArchivedSession _session(int id, String title) => ArchivedSession(
  id: id,
  at: id,
  msgs: [
    AssistantMsg(id: 'ask-$id', role: MsgRole.user, text: title, at: id),
    AssistantMsg(
      id: 'reply-$id',
      role: MsgRole.ai,
      text: '已经为你整理好了提示词。',
      at: id + 1,
    ),
  ],
);

void main() {
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  setUpAll(() async {
    if (!Platform.isWindows) return;
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
  });
  setUp(() {
    for (final entry in const {
      '1girl': '单人女性',
      'cat ears': '猫耳',
      'white hair': '白发',
      'red eyes': '红瞳',
      'cherry blossoms': '樱花',
      'falling petals': '落花',
      'outdoors': '户外',
      'spring': '春天',
      'sunlight': '阳光',
    }.entries) {
      cacheTagMeta(entry.key, trans: entry.value);
    }
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        assistantProvider.overrideWith(_FixtureAssistant.new),
        anlasProvider.overrideWith(_FixedAnlas.new),
        naiQuotaProvider.overrideWith(_NoQuota.new),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
        defaultRulesProvider.overrideWith(
          (ref, family) async => const DefaultRules(
            name: 'Test',
            author: '',
            version: '1',
            rules: [],
          ),
        ),
        agentModelsProvider.overrideWith(
          (ref) async => const AgentModelList(
            active: 'one',
            choices: [
              AgentModelChoice(key: 'one', name: 'DeepSeek v4.1 Flash'),
              AgentModelChoice(key: 'two', name: 'Model Two'),
            ],
          ),
        ),
      ],
    );
    (c.read(assistantProvider.notifier) as _FixtureAssistant).seed(
      AssistantState(
        msgs: _current,
        sessions: [
          _session(100, '森林中的小屋'),
          _session(200, '雨天的咖啡馆'),
          _session(300, '星空下的旅行'),
        ],
      ),
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    bool embedded = false,
    Widget? body,
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
              platform: TargetPlatform.windows,
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
                fontFamilyFallback: const ['Segoe UI'],
              ),
            ),
            home: Scaffold(
              body:
                  body ??
                  (embedded
                      ? Align(
                          alignment: Alignment.topRight,
                          child: SizedBox(
                            width: 400,
                            child: MediaQuery(
                              data: MediaQueryData(
                                size: Size(400, size.height),
                              ),
                              child: const AssistantPage(embedded: true),
                            ),
                          ),
                        )
                      : const AssistantPage()),
            ),
          ),
        ),
      ),
    );
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

  testWidgets(
    'main assistant keeps history at left and model inside the composer',
    (tester) async {
      await mount(tester);
      final sidebar = key('assistant-history-sidebar');
      expect(sidebar, findsOneWidget);
      expect(tester.getRect(sidebar).left, 0);
      final composer = find.widgetWithText(TextField, '想画什么、想改哪里…');
      final model = key('assistant-composer-model');
      final box = tester.getRect(key('assistant-composer'));
      expect(box.contains(tester.getRect(model).topLeft), isTrue);
      expect(box.contains(tester.getRect(model).bottomRight), isTrue);
      expect(box.contains(tester.getRect(composer).center), isTrue);
      final longModel = tester.getRect(key('assistant-model-button'));
      final send = tester.getRect(
        find.byTooltip('发送 (Enter) · Shift + Enter 换行'),
      );
      expect(longModel.width, lessThan(220));
      expect(send.left - longModel.right, closeTo(8, 1));
      await tester.enterText(composer, '还没发送的草稿');
      await tester.enterText(key('assistant-history-search'), '森林');
      await tester.pumpAndSettle();
      expect(key('assistant-session-100'), findsOneWidget);
      expect(key('assistant-session-200'), findsNothing);
      await tester.enterText(key('assistant-history-search'), '');
      await tester.tap(key('assistant-session-100'));
      await tester.pumpAndSettle();
      expect(c.read(assistantProvider).msgs.first.text, '森林中的小屋');
      expect(
        c.read(assistantProvider).sessions.any((s) => s.msgs.first.id == 'ask'),
        isTrue,
      );
      expect(tester.widget<TextField>(composer).controller!.text, '还没发送的草稿');
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('DeepSeek v4.1 Flash'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(key('assistant-model-two')).bottom,
        lessThanOrEqualTo(800),
      );
      await tester.tap(key('assistant-model-two'));
      await tester.pumpAndSettle();
      expect(c.read(assistantModelProvider)?.key, 'two');
      final shortModel = tester.getRect(key('assistant-model-button'));
      expect(shortModel.width, lessThan(longModel.width));
      expect(shortModel.right, longModel.right);
      await screenshot(tester, 'windows13-assistant-model');
      await tester.tap(find.widgetWithText(FilledButton, '新对话'));
      await tester.pumpAndSettle();
      expect(c.read(assistantProvider).msgs, isEmpty);
      expect(
        c.read(assistantProvider).sessions.any((s) => s.title == '森林中的小屋'),
        isTrue,
      );
      await finish(tester);
    },
  );

  testWidgets('main proposal expands inside its message and survives resize', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(ResultStrip),
        matching: find.byType(ProposalDetails),
      ),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(ProposalActions), findsOneWidget);
    await screenshot(tester, 'assistant-main-inline-windows12');
    tester.view.physicalSize = const Size(820, 640);
    await tester.pumpAndSettle();
    expect(key('assistant-history-sidebar'), findsOneWidget);
    expect(key('assistant-inline-proposal'), findsOneWidget);
    await screenshot(tester, 'assistant-main-compact-windows12');
    await tester.ensureVisible(find.text('收起'));
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.byType(ProposalDetails), findsNothing);
    tester.view.physicalSize = const Size(650, 540);
    await tester.pumpAndSettle();
    expect(key('assistant-history-sidebar'), findsNothing);
    expect(find.byTooltip('历史会话'), findsOneWidget);
    expect(key('assistant-composer-model'), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
    'embedded history opens by its button in global window coordinates',
    (tester) async {
      await mount(tester, embedded: true);
      expect(key('assistant-history-sidebar'), findsNothing);
      expect(key('assistant-composer-model'), findsNothing);
      final button = find.widgetWithIcon(IconButton, Icons.history);
      final anchor = tester.getRect(button);
      final composer = find.widgetWithText(TextField, '想画什么、想改哪里…');
      await tester.enterText(composer, '保留这段草稿');
      await tester.tap(button);
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.width, 380);
      expect(panel.top, closeTo(anchor.bottom + 8, 1));
      expect(panel.right, closeTo(anchor.right, 1));
      expect(panel.height, lessThan(460));
      expect(find.byType(BottomSheet), findsNothing);
      await screenshot(tester, 'assistant-history-popover-windows11');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('desktop-popover'), findsNothing);
      expect(tester.widget<TextField>(composer).controller!.text, '保留这段草稿');
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(key('assistant-session-200'));
      await tester.pumpAndSettle();
      expect(c.read(assistantProvider).msgs.first.text, '雨天的咖啡馆');
      expect(key('desktop-popover'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'quota is a small anchored panel with refresh and outside dismissal',
    (tester) async {
      await mount(
        tester,
        body: const Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(200, 60, 0, 0),
            child: AnlasChip(),
          ),
        ),
      );
      final chip = find.byType(AnlasChip);
      final anchor = tester.getRect(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.width, 370);
      expect(panel.top, closeTo(anchor.bottom + 8, 1));
      expect(panel.left, greaterThanOrEqualTo(12));
      expect(panel.height, lessThan(460));
      expect(find.text('NAI 5 额度'), findsOneWidget);
      expect(find.text('0+35,738'), findsOneWidget);
      final notifier = c.read(anlasProvider.notifier) as _FixedAnlas;
      expect(notifier.refreshes, 1);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(notifier.refreshes, 2);
      await screenshot(tester, 'quota-popover-windows11');
      await tester.tapAt(const Offset(1000, 400));
      await tester.pumpAndSettle();
      expect(key('desktop-popover'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'quota flips above a low anchor and scrolls within a short window',
    (tester) async {
      await mount(
        tester,
        size: const Size(620, 330),
        body: const Align(
          alignment: Alignment.bottomRight,
          child: Padding(padding: EdgeInsets.all(20), child: AnlasChip()),
        ),
      );
      final anchor = tester.getRect(find.byType(AnlasChip));
      await tester.tap(find.byType(AnlasChip));
      await tester.pumpAndSettle();
      final panel = tester.getRect(key('desktop-popover'));
      expect(panel.bottom, lessThanOrEqualTo(anchor.top - 8));
      expect(panel.top, greaterThanOrEqualTo(12));
      expect(panel.right, lessThanOrEqualTo(608));
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      expect(find.text('已充满').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );
}
