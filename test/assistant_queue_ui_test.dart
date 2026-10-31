import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_page.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/assistant/preset_rules.dart';

import 'support/desktop_capture.dart';

class _Assistant extends AssistantNotifier {
  void running() => state = state.copyWith(running: true);
}

class _Settings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async =>
      const AssistantSettings(introVersion: kAssistantIntroVersion);
}

class _Rules extends RulesLibraryNotifier {
  @override
  Future<RulesLibrary> build() async => const RulesLibrary();
}

void main() {
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  late AppStores stores;
  late ProviderContainer c;
  late _Assistant n;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        assistantProvider.overrideWith(_Assistant.new),
        assistantSettingsProvider.overrideWith(_Settings.new),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        desktopModeProvider.overrideWithValue(true),
        assistantEndpointProvider.overrideWithValue(null),
        rulesLibraryProvider.overrideWith(_Rules.new),
        agentModelsProvider.overrideWith((_) async => const AgentModelList()),
      ],
    );
    await c.read(assistantSettingsProvider.future);
    n = c.read(assistantProvider.notifier) as _Assistant;
    n.running();
  });
  tearDown(() async {
    c.dispose();
    stores.flushNow();
    await stores.assistant.idle;
  });
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(920, 850);
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
              ),
            ),
            home: const Scaffold(body: AssistantPage(embedded: true)),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> tick(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets(
    'Enter enqueues while running; Shift+Enter and IME stay editable',
    (tester) async {
      await mount(tester);
      final input = find.byType(TextField);
      await tester.enterText(input, '排队的一句');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tick(tester);
      expect(c.read(assistantProvider).queue.single.text, '排队的一句');
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(find.text('排队中'), findsOneWidget);
      expect(find.byTooltip('停止'), findsOneWidget);
      await tester.enterText(input, 'next');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(tester.widget<TextField>(input).controller!.text, 'next\n');
      tester
          .widget<TextField>(input)
          .controller!
          .value = const TextEditingValue(
        text: '拼音',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(c.read(assistantProvider).queue, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'queued right-click edit restores all images without replacing draft',
    (tester) async {
      final images = [
        for (var i = 1; i <= 2; i++)
          Uint8List.fromList(img.encodePng(img.Image(width: i + 2, height: 4))),
      ];
      await n.submit('queued', images: images);
      final id = c.read(assistantProvider).queue.single.id;
      await mount(tester);
      expect(
        find.byKey(ValueKey('assistant-queued-image-$id-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('assistant-queued-image-$id-1')),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.tap(
        find.byKey(ValueKey('assistant-message-$id')),
        buttons: kSecondaryMouseButton,
      );
      await tick(tester);
      expect(find.byType(BottomSheet), findsNothing);
      await captureDesktop(tester, capture, 'batch8-queued-menu');
      await tester.tap(find.text('编辑该信息'));
      await tick(tester);
      expect(c.read(assistantProvider).queue, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'queued\ndraft',
      );
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      await captureDesktop(tester, capture, 'batch8-queued-edit');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('queued menu cancellation preserves active request and draft', (
    tester,
  ) async {
    await n.submit('cancel this');
    final id = c.read(assistantProvider).queue.single.id;
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'keep draft');
    await tester.tap(find.byKey(ValueKey('assistant-message-menu-$id')));
    await tick(tester);
    await tester.tap(find.text('取消发送'));
    await tick(tester);
    expect(c.read(assistantProvider).queue, isEmpty);
    expect(c.read(assistantProvider).running, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'keep draft',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
