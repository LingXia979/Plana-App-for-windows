import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_completion.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/widgets/completion_bar.dart';
import 'package:plana_app/features/editor/widgets/completion_panel.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';

class _Completion extends Fake implements TagCompletion {
  @override
  Future<SuggestResult> query(String raw) async => const SuggestResult(
    tags: [Suggestion(text: 'blue sky', kind: SuggestionKind.tag)],
  );

  @override
  Future<List<String>> relatedOf(String name) async => const [];
}

void main() {
  late AppStores stores;
  late ProviderContainer container;

  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Future<void> mount(WidgetTester tester, bool chips) async {
    stores = AppStores.ephemeral();
    await tester.runAsync(
      () => stores.prefs.write(
        key: 'editor_settings',
        value: jsonEncode(
          EditorSettings(chipMode: chips, showTranslation: false).toJson(),
        ),
      ),
    );
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        tagCompletionProvider.overrideWithValue(_Completion()),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: 'solo', negative: 'lowres');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 450, child: DesktopPromptCard()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> mouseClick(WidgetTester tester, Finder finder) async {
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.down(tester.getCenter(finder));
    // A real mouse press and release can straddle a layout frame.
    await tester.pump(const Duration(milliseconds: 50));
    await pointer.up();
    await tester.pumpAndSettle();
    await pointer.removePointer();
  }

  for (final negative in [false, true]) {
    for (final chips in [false, true]) {
      testWidgets(
        'mouse completion inserts in ${negative ? 'negative' : 'positive'} sidebar ${chips ? 'chips' : 'text'}',
        (tester) async {
          await mount(tester, chips);
          if (negative) {
            await tester.tap(
              find.byKey(const ValueKey('desktop-prompt-negative-tab')),
            );
            await tester.pumpAndSettle();
          }
          final host = find.byType(DesktopPromptCard);
          final field = find
              .descendant(of: host, matching: find.byType(TextField))
              .first;
          await tester.enterText(
            field,
            chips ? 'bl' : '${negative ? 'lowres' : 'solo'}, bl',
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(find.byType(CompletionBar), findsOneWidget);
          final suggestion = find.descendant(
            of: find.byType(CompletionBar),
            matching: find.text('blue sky'),
          );
          await mouseClick(tester, suggestion);
          expect(
            negative
                ? container.read(generateProvider).negativePrompt
                : container.read(generateProvider).prompt,
            contains('blue sky'),
          );
          expect(
            negative
                ? container.read(generateProvider).prompt
                : container.read(generateProvider).negativePrompt,
            negative ? 'solo' : 'lowres',
          );
          expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
          if (chips) {
            expect(
              chipInputBody(tester.widget<TextField>(field).controller!.text),
              isEmpty,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 5));
        },
      );

      testWidgets(
        'expanded completion keeps the query in ${negative ? 'negative' : 'positive'} sidebar ${chips ? 'chips' : 'text'}',
        (tester) async {
          await mount(tester, chips);
          if (negative) {
            await tester.tap(
              find.byKey(const ValueKey('desktop-prompt-negative-tab')),
            );
            await tester.pumpAndSettle();
          }
          final host = find.byType(DesktopPromptCard);
          final field = find
              .descendant(of: host, matching: find.byType(TextField))
              .first;
          await tester.enterText(
            field,
            chips ? 'bl' : '${negative ? 'lowres' : 'solo'}, bl',
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          await mouseClick(tester, find.byType(CompletionGrip));
          expect(find.byType(CompletionPanel), findsOneWidget);
          final suggestion = find.descendant(
            of: find.byType(CompletionPanel),
            matching: find.text('blue sky'),
          );
          expect(suggestion, findsOneWidget);
          await mouseClick(tester, suggestion);
          expect(
            negative
                ? container.read(generateProvider).negativePrompt
                : container.read(generateProvider).prompt,
            contains('blue sky'),
          );
          expect(find.byType(CompletionPanel), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 5));
        },
      );
    }
  }
}
