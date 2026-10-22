import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';

import 'support/desktop_capture.dart';

void main() {
  late AppStores stores;
  late ProviderContainer c;
  setUpAll(loadDesktopCaptureFonts);
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
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });
  Finder key(String id) => find.byKey(ValueKey(id));
  for (final scale in [1.0, 1.4]) {
    testWidgets(
      'section editors keep Medium negatives hidden and fit at $scale text',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gen = c.read(generateProvider.notifier);
        gen.setModel('NAI 5.0 Full');
        gen.setNaiEffort(NaiEffort.medium);
        gen.setPrompts(
          positive: 'forest, soft light',
          negative: 'saved high negative',
        );
        gen.addSection();
        final id = c.read(generateProvider).sections.last.id;
        gen.updateSection(id, name: '画风与光影');
        final capture = GlobalKey();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: RepaintBoundary(
              key: capture,
              child: MaterialApp(
                theme: AppTheme.light().copyWith(
                  textTheme: AppTheme.light().textTheme.apply(
                    fontFamily: 'Microsoft YaHei',
                  ),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(width: 500, child: const PromptCard()),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(key('desktop-prompt-negative-tab'), findsNothing);
        expect(key('desktop-section-$id-negative-tab'), findsNothing);
        expect(c.read(generateProvider).negativePrompt, 'saved high negative');
        expect(tester.takeException(), isNull);
        await captureDesktop(
          tester,
          capture,
          'windows52-sections-${(scale * 100).round()}',
        );
        await tester.ensureVisible(key('prompt-fullscreen-$id'));
        await tester.tap(key('prompt-fullscreen-$id'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('排除'), findsNothing);
        await captureDesktop(
          tester,
          capture,
          'windows52-section-fullscreen-${(scale * 100).round()}',
        );
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(Dialog))).pop();
        await tester.pumpAndSettle();
        gen.setNaiEffort(NaiEffort.high);
        await tester.pumpAndSettle();
        expect(key('desktop-prompt-negative-tab'), findsOneWidget);
        expect(key('desktop-section-$id-negative-tab'), findsOneWidget);
        expect(c.read(generateProvider).negativePrompt, 'saved high negative');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      },
    );
  }
}
