import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/shell/app_shell.dart';

import 'support/pump_until.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a lingering retry toast is harmless after its shell is removed',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('plana_removed_shell_');
      final stores = (await tester.runAsync(
        () => AppStores.open(rootOverride: root),
      ))!;
      final showShell = ValueNotifier(true);
      final container = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(true),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: ValueListenableBuilder<bool>(
                valueListenable: showShell,
                builder: (context, visible, child) =>
                    visible ? const AppShell() : const Scaffold(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        stores.reportSaveError('Synthetic failure');
        await tester.pumpAndSettle();
        showShell.value = false;
        await tester.pumpAndSettle();
        expect(find.byType(AppShell), findsNothing);
        expect(find.text('重试'), findsOneWidget);
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        showShell.dispose();
        await pumpUntilComplete(tester, stores.flushForExit());
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('an idle save failure requests a frame and can be retried', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('plana_idle_save_');
    final stores = (await tester.runAsync(
      () => AppStores.open(rootOverride: root),
    ))!;
    final container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    Directory? blocker;
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      await pumpUntilComplete(tester, stores.flushForExit());
      await tester.pumpAndSettle();
      expect(binding.hasScheduledFrame, isFalse);

      blocker = Directory('${root.path}/workspace/state.json.tmp')
        ..createSync(recursive: true);
      await tester.runAsync(() async {
        stores.workspace.schedule(
          GenerateState.initial().copyWith(prompt: 'retry this idle draft'),
          idSeq: 101,
        );
        stores.workspace.flush();
        await expectLater(
          stores.workspace.idle,
          throwsA(isA<FileSystemException>()),
        );
      });
      expect(
        binding.hasScheduledFrame,
        isTrue,
        reason: 'The asynchronous failure must wake an otherwise idle UI',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('工作台保存失败'), findsOneWidget);

      blocker.deleteSync();
      await tester.tap(find.text('重试'));
      await pumpUntil(tester, () => find.text('已保存').evaluate().isNotEmpty);
      final saved =
          jsonDecode(
                File('${root.path}/workspace/state.json').readAsStringSync(),
              )
              as Map;
      expect(saved['state']['prompt'], 'retry this idle draft');
    } finally {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      if (blocker?.existsSync() ?? false) blocker!.deleteSync();
      await pumpUntilComplete(tester, stores.flushForExit());
      root.deleteSync(recursive: true);
    }
  });
}
