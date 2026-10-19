import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/storage_lifecycle.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late AppLifecycleListener lifecycle;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_exit_');
    stores = await AppStores.open(rootOverride: root);
    lifecycle = createStorageLifecycleListener(stores);
    stores.workspace.schedule(
      GenerateState.initial().copyWith(prompt: 'old draft'),
      idSeq: 100,
    );
    await stores.flushForExit();
    await stores.workspace.load();
  });
  tearDown(() async {
    lifecycle.dispose();
    await root.delete(recursive: true);
  });

  Future<T> pumpFuture<T>(WidgetTester tester, Future<T> future) async {
    var done = false;
    late T value;
    unawaited(
      future.then((result) {
        value = result;
        done = true;
      }),
    );
    for (var i = 0; i < 500 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done, isTrue, reason: 'The persistence queue must finish');
    return value;
  }

  test(
    'normal desktop exit waits for workspace and preference writes',
    () async {
      stores.workspace.schedule(
        GenerateState.initial().copyWith(prompt: 'latest draft'),
        idSeq: 100,
      );
      final preferenceWrite = stores.prefs.write(
        key: 'exit_test',
        value: 'latest preference',
      );
      expect(await binding.handleRequestAppExit(), AppExitResponse.exit);
      final reopened = await AppStores.open(rootOverride: root);
      expect(reopened.workspace.initial!.prompt, 'latest draft');
      expect(reopened.prefs.get('exit_test'), 'latest preference');
      await preferenceWrite;
      await reopened.flushForExit();
    },
  );

  testWidgets('exit also commits a fullscreen editor with pending writeback', (
    tester,
  ) async {
    await tester.runAsync(
      () => stores.prefs.write(
        key: 'editor_settings',
        value: jsonEncode(
          const EditorSettings(
            enableCompletion: false,
            showTranslation: false,
          ).toJson(),
        ),
      ),
    );
    final container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const EditorPage(positive: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(AnnotatedField),
        matching: find.byType(TextField),
      );
      expect(input, findsOneWidget);
      await tester.enterText(input, 'newest editor draft');
      await tester.pump();
      expect(
        container.read(generateProvider).prompt,
        'old draft',
        reason: 'The 400ms editor writeback has not fired',
      );
      final response = await pumpFuture(tester, binding.handleRequestAppExit());
      expect(response, AppExitResponse.exit);
      expect(container.read(generateProvider).prompt, 'newest editor draft');
      final saved =
          jsonDecode(
                File('${root.path}/workspace/state.json').readAsStringSync(),
              )
              as Map;
      expect(saved['state']['prompt'], 'newest editor draft');
    } finally {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await pumpFuture(tester, stores.flushForExit());
    }
  });
}
