import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/shell/app_shell.dart';

class _Recorder extends AssistantNotifier {
  final sent = <String>[];

  @override
  AssistantState build() => const AssistantState();

  @override
  Future<void> send(
    String text, {
    Uint8List? image,
    List<Uint8List> images = const [],
    bool withCanvas = false,
    void Function()? onAccepted,
  }) async {
    expect(ref.read(assistantSettingsProvider).value!.introDone, isTrue);
    sent.add(text);
    onAccepted?.call();
  }
}

void main() {
  late AppStores stores;
  late ProviderContainer container;
  late _Recorder recorder;
  var disposed = false;

  setUp(() async {
    disposed = false;
    stores = AppStores.ephemeral();
    recorder = _Recorder();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        agentModelsProvider.overrideWith((ref) async => const AgentModelList()),
        assistantProvider.overrideWith(() => recorder),
      ],
    );
    await container.read(assistantSettingsProvider.future);
  });
  tearDown(() {
    if (!disposed) container.dispose();
    stores.flushNow();
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  final dialogs = find.byType(AlertDialog, skipOffstage: false);

  Future<void> mount(WidgetTester tester, {double width = 1400}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    expect(dialogs, findsNothing);
  }

  Future<void> completeIntro(WidgetTester tester) async {
    expect(dialogs, findsOneWidget);
    await tester.tap(find.text('不使用').hitTestable());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('下一步').hitTestable());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('自动写入创作页').hitTestable());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('开始使用').hitTestable());
    for (var i = 0; i < 100 && dialogs.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(dialogs, findsNothing);
    await tester.pumpAndSettle();
    final settings = container.read(assistantSettingsProvider).value!;
    expect(settings.introDone, isTrue);
    expect(settings.libraryScope, LibraryScope.none);
    expect(settings.autoImport, isTrue);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    stores.flushNow();
    await tester.pump();
    container.dispose();
    disposed = true;
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'full AI page shows one intro and retains the selected settings',
    (tester) async {
      await mount(tester);
      await tester.tap(key('desktop-nav-2'));
      await tester.pumpAndSettle();
      await completeIntro(tester);
      await tester.tap(key('desktop-nav-0'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-ai-tab'));
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-nav-2'));
      await tester.pumpAndSettle();
      expect(dialogs, findsNothing);
      expect(
        container.read(assistantSettingsProvider).value!.libraryScope,
        LibraryScope.none,
      );
      await finish(tester);
    },
  );

  for (final width in [1400.0, 950.0]) {
    testWidgets('sidebar introduces first use at window width $width', (
      tester,
    ) async {
      await mount(tester, width: width);
      await tester.tap(key('desktop-inspiration-tab'));
      await tester.pumpAndSettle();
      expect(dialogs, findsNothing);
      if (width < 1100) {
        await tester.tap(key('desktop-canvas-tab'));
        await tester.pumpAndSettle();
        expect(dialogs, findsNothing);
      }
      await tester.tap(key('desktop-ai-tab'));
      await tester.pumpAndSettle();
      await completeIntro(tester);
      await tester.tap(key('desktop-nav-2'));
      await tester.pumpAndSettle();
      expect(dialogs, findsNothing);
      await finish(tester);
    });
  }

  testWidgets('sidebar waits for intro confirmation before its first send', (
    tester,
  ) async {
    await mount(tester);
    final composer = find
        .byWidgetPredicate(
          (widget) => widget is TextField && widget.maxLines == 5,
        )
        .hitTestable();
    expect(composer, findsOneWidget);
    await tester.enterText(composer, '画一只猫');
    await tester.pump();
    await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(recorder.sent, isEmpty);
    await completeIntro(tester);
    expect(recorder.sent, ['画一只猫']);
    await finish(tester);
  });
}
