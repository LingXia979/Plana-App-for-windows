import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/editor/widgets/editor_top_bar.dart';
import 'package:plana_app/features/editor/widgets/tag_panel.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';
import 'package:plana_app/features/inspiration/widgets/tag_card.dart';

void main() {
  late AppStores stores;
  late ProviderContainer container;
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
    container = ProviderContainer(
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
    container.dispose();
    stores.flushNow();
  });

  Finder key(String id) => find.byKey(ValueKey(id));
  Finder input(String id) =>
      find.descendant(of: key('$id-text'), matching: find.byType(TextField));
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            dialogTheme: const DialogThemeData(
              constraints: BoxConstraints(maxWidth: 760),
            ),
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 500, child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String id) async {
    await tester.ensureVisible(key(id));
    await tester.tap(key(id));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets(
    'character folding starts enabled and preserves the complete editor session',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.addCharacter();
      final id = container.read(generateProvider).characters.single.id;
      gen.updateCharacter(
        id,
        positive: 'traveler, white shirt',
        negative: 'hat',
      );
      await mount(tester, const CharacterCard());
      expect(input('desktop-character-$id'), findsOneWidget);
      await tap(tester, 'character-collapse-$id');
      expect(input('desktop-character-$id'), findsNothing);
      expect(find.byType(TagCardPreview), findsOneWidget);
      final libraryPosition = tester.getTopLeft(key('character-library-$id'));
      final avatarPosition = tester.getTopLeft(key('character-avatar-$id'));
      expect(libraryPosition.dx, lessThan(avatarPosition.dx));
      expect(find.text('traveler, white shirt'), findsOneWidget);
      await tap(tester, 'character-collapse-$id');
      expect(tester.getTopLeft(key('character-library-$id')), libraryPosition);
      expect(tester.getTopLeft(key('character-avatar-$id')), avatarPosition);
      expect(find.byType(TagCardPreview), findsOneWidget);
      expect(input('desktop-character-$id'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(
        find.text('hat'),
        findsNothing,
        reason: 'the summary row is removed when expanded',
      );
      final field = tester.widget<TextField>(input('desktop-character-$id'));
      await tester.enterText(
        input('desktop-character-$id'),
        'traveler, blue shirt',
      );
      await tap(tester, 'character-collapse-$id');
      expect(
        container.read(generateProvider).characters.single.positive,
        'traveler, blue shirt',
      );
      expect(input('desktop-character-$id'), findsNothing);
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(collapsiblePromptCards: false));
      await tester.pumpAndSettle();
      expect(key('character-collapse-$id'), findsNothing);
      expect(input('desktop-character-$id'), findsOneWidget);
      expect(
        tester.widget<TextField>(input('desktop-character-$id')).controller,
        same(field.controller),
      );
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(collapsiblePromptCards: true));
      await tester.pumpAndSettle();
      await tap(tester, 'character-collapse-$id');
      expect(
        tester.widget<TextField>(input('desktop-character-$id')).controller,
        same(field.controller),
      );
      expect(
        tester
            .widget<TextField>(input('desktop-character-$id'))
            .controller!
            .text,
        'traveler, blue shirt',
      );
      expect(
        container.read(generateProvider).characters.single.negative,
        'hat',
      );
      expect(find.byType(EditorPage), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets(
    'main and section cards collapse independently without losing edits',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.setPrompts(positive: 'solo', negative: 'lowres');
      gen.addSection();
      final id = container.read(generateProvider).sections.last.id;
      gen.applyCanvas(
        CanvasPrompts.of(
          container
              .read(generateProvider)
              .copyWith(
                sections: [
                  for (final s in container.read(generateProvider).sections)
                    s.id == id
                        ? s.copyWith(positive: 'ocean', negative: 'indoors')
                        : s,
                ],
              ),
        ),
        force: true,
      );
      await mount(tester, const PromptCard());
      await tester.enterText(input('desktop-section-$id'), 'ocean, blue sky');
      final controller = tester
          .widget<TextField>(input('desktop-section-$id'))
          .controller;
      await tap(tester, 'prompt-section-collapse-$id');
      expect(input('desktop-section-$id'), findsNothing);
      expect(input('desktop-prompt'), findsOneWidget);
      expect(
        container.read(generateProvider).sections.last.positive,
        'ocean, blue sky',
      );
      await tap(tester, 'prompt-section-collapse-main');
      expect(input('desktop-prompt'), findsNothing);
      await tap(tester, 'prompt-section-collapse-$id');
      expect(input('desktop-prompt'), findsNothing);
      expect(
        tester.widget<TextField>(input('desktop-section-$id')).controller,
        same(controller),
      );
      expect(container.read(generateProvider).negativePrompt, 'lowres');
      expect(
        container.read(generateProvider).sections.last.negative,
        'indoors',
      );
      await tap(tester, 'prompt-section-collapse-$id');
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(collapsiblePromptCards: false));
      await tester.pumpAndSettle();
      expect(input('desktop-prompt'), findsOneWidget);
      expect(input('desktop-section-$id'), findsOneWidget);
      expect(key('prompt-section-collapse-main'), findsNothing);
      expect(key('prompt-section-collapse-$id'), findsNothing);
      expect(
        tester.widget<TextField>(input('desktop-section-$id')).controller,
        same(controller),
      );
      await finish(tester);
    },
  );

  testWidgets('disabling folding keeps main and all section cards expanded', (
    tester,
  ) async {
    final gen = container.read(generateProvider.notifier);
    gen.setPrompts(positive: 'solo');
    gen.addSection();
    container
        .read(themeSettingsProvider.notifier)
        .patch((s) => s.copyWith(collapsiblePromptCards: false));
    await mount(tester, const PromptCard());
    expect(input('desktop-prompt'), findsOneWidget);
    expect(find.byType(EditorPage), findsNWidgets(2));
    expect(key('prompt-section-collapse-main'), findsNothing);
    final id = container.read(generateProvider).sections.last.id;
    expect(input('desktop-section-$id'), findsOneWidget);
    expect(key('prompt-section-collapse-$id'), findsNothing);
    await finish(tester);
  });
  testWidgets('turning folding off expands the main card and retains edits', (
    tester,
  ) async {
    final gen = container.read(generateProvider.notifier);
    gen.setPrompts(positive: 'solo', negative: 'lowres');
    container
        .read(themeSettingsProvider.notifier)
        .patch((s) => s.copyWith(collapsiblePromptCards: true));
    await mount(tester, const PromptCard());
    expect(input('desktop-prompt'), findsOneWidget);
    await tap(tester, 'prompt-section-collapse-main');
    expect(input('desktop-prompt'), findsNothing);
    expect(find.text('solo'), findsOneWidget);
    await tap(tester, 'prompt-section-collapse-main');
    await tester.enterText(input('desktop-prompt'), 'solo, rain');
    final controller = tester
        .widget<TextField>(input('desktop-prompt'))
        .controller;
    await tap(tester, 'prompt-section-collapse-main');
    expect(input('desktop-prompt'), findsNothing);
    expect(container.read(generateProvider).prompt, 'solo, rain');
    container
        .read(themeSettingsProvider.notifier)
        .patch((s) => s.copyWith(collapsiblePromptCards: false));
    await tester.pumpAndSettle();
    expect(key('prompt-section-collapse-main'), findsNothing);
    expect(input('desktop-prompt'), findsOneWidget);
    container
        .read(themeSettingsProvider.notifier)
        .patch((s) => s.copyWith(collapsiblePromptCards: true));
    await tester.pumpAndSettle();
    await tap(tester, 'prompt-section-collapse-main');
    expect(
      tester.widget<TextField>(input('desktop-prompt')).controller,
      same(controller),
    );
    expect(container.read(generateProvider).negativePrompt, 'lowres');
    await finish(tester);
  });
  testWidgets(
    'disabled sections remain expandable and editing does not enable them',
    (tester) async {
      final gen = container.read(generateProvider.notifier);
      gen.addSection();
      final id = container.read(generateProvider).sections.last.id;
      gen.updateSection(id, enabled: false);
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(collapsiblePromptCards: true));
      await mount(tester, const PromptCard());
      await tap(tester, 'prompt-section-collapse-$id');
      expect(input('desktop-section-$id'), findsNothing);
      await tap(tester, 'prompt-section-collapse-$id');
      expect(input('desktop-section-$id'), findsOneWidget);
      await tester.enterText(input('desktop-section-$id'), 'disabled draft');
      await tap(tester, 'prompt-section-collapse-$id');
      expect(
        container.read(generateProvider).sections.last.positive,
        'disabled draft',
      );
      expect(container.read(generateProvider).sections.last.enabled, isFalse);
      await finish(tester);
    },
  );
  for (final target in ['main', 'section', 'character']) {
    testWidgets('large editor saves $target and synchronizes the sidebar', (
      tester,
    ) async {
      final gen = container.read(generateProvider.notifier);
      gen.setPrompts(positive: 'solo', negative: 'lowres');
      String? id;
      if (target == 'character') {
        gen.addCharacter();
        id = container.read(generateProvider).characters.single.id;
        gen.updateCharacter(id, positive: 'traveler', negative: 'hat');
      } else if (target == 'section') {
        gen.addSection();
        id = container.read(generateProvider).sections.last.id;
      }
      await mount(
        tester,
        target == 'character' ? const CharacterCard() : const PromptCard(),
      );
      final prefix = target == 'character'
          ? 'desktop-character-$id'
          : target == 'section'
          ? 'desktop-section-$id'
          : 'desktop-prompt';
      await tester.enterText(input(prefix), 'fresh sidebar edit');
      await tap(
        tester,
        target == 'character'
            ? 'character-fullscreen-$id'
            : 'prompt-fullscreen-${id ?? 'main'}',
      );
      final dialog = find.byType(Dialog);
      expect(dialog, findsOneWidget);
      final largeEditor = find.byWidgetPredicate(
        (widget) => widget is EditorPage && widget.floatingPanels,
      );
      expect(
        tester.getSize(largeEditor).width,
        tester.view.physicalSize.width / tester.view.devicePixelRatio - 48,
      );
      final field = find
          .descendant(of: dialog, matching: find.byType(TextField))
          .first;
      expect(
        tester.widget<TextField>(field).controller!.text,
        'fresh sidebar edit',
      );
      await tester.enterText(field, 'large window edit');
      await tester.tap(find.byTooltip('保存并返回'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(
        tester.widget<TextField>(input(prefix)).controller!.text,
        'large window edit',
      );
      final state = container.read(generateProvider);
      if (target == 'character') {
        expect(state.characters.single.positive, 'large window edit');
        expect(state.characters.single.negative, 'hat');
        expect(state.prompt, 'solo');
      } else if (target == 'section') {
        expect(state.sections.last.positive, 'large window edit');
        expect(state.prompt, 'solo');
      } else {
        expect(state.prompt, 'large window edit');
      }
      expect(state.negativePrompt, 'lowres');
      await finish(tester);
    });
  }
  testWidgets('large editor fills and resizes with the desktop window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: 'solo', negative: 'lowres');
    await mount(tester, const PromptCard());
    await tap(tester, 'prompt-fullscreen-main');
    final largeEditor = find.byWidgetPredicate(
      (widget) => widget is EditorPage && widget.floatingPanels,
    );
    for (final size in [
      const Size(1600, 1000),
      const Size(1000, 800),
      const Size(700, 700),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(
        tester.getRect(largeEditor),
        Rect.fromLTWH(24, 24, size.width - 48, size.height - 48),
      );
      expect(tester.takeException(), isNull);
    }
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(container.read(generateProvider).prompt, 'solo');
    expect(container.read(generateProvider).negativePrompt, 'lowres');
    await finish(tester);
  });

  testWidgets('outside click closes the text dialog and retains fresh edits', (
    tester,
  ) async {
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: 'solo', negative: 'lowres');
    await mount(tester, const PromptCard());
    await tap(tester, 'prompt-fullscreen-main');
    final field = find
        .descendant(of: find.byType(Dialog), matching: find.byType(TextField))
        .first;
    await tester.enterText(field, 'fresh text edit');
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      tester.widget<TextField>(input('desktop-prompt')).controller!.text,
      'fresh text edit',
    );
    expect(container.read(generateProvider).negativePrompt, 'lowres');
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  for (final selectedCount in [0, 1, 2]) {
    testWidgets(
      'outside click saves chip input with $selectedCount selected tags',
      (tester) async {
        final gen = container.read(generateProvider.notifier);
        gen.setPrompts(positive: 'solo', negative: 'lowres');
        gen.addCharacter();
        final id = container.read(generateProvider).characters.single.id;
        gen.updateCharacter(
          id,
          positive: 'traveler, white shirt',
          negative: 'hat',
        );
        await container.read(editorSettingsProvider.future);
        unawaited(
          container
              .read(editorSettingsProvider.notifier)
              .patch((s) => s.copyWith(chipMode: true)),
        );
        await mount(tester, const CharacterCard());
        await tap(tester, 'character-fullscreen-$id');
        final dialog = find.byType(Dialog);
        final flow = find.descendant(
          of: dialog,
          matching: find.byType(ChipFlowView),
        );
        final chipState = tester.state<ChipFlowViewState>(flow);
        final bodyRect = tester.getRect(flow);
        final headerRect = tester.getRect(find.byType(EditorTopBar));
        for (var i = 0; i < selectedCount; i++) {
          await tester.tapAt(chipState.chipAnchor(i)!.center);
          await tester.pumpAndSettle();
        }
        if (selectedCount > 0) {
          expect(key('desktop-tag-popover'), findsOneWidget);
          expect(
            find.byType(selectedCount == 1 ? TagPanel : BatchPanel),
            findsOneWidget,
          );
          expect(tester.getRect(flow), bodyRect);
          expect(tester.getRect(find.byType(EditorTopBar)), headerRect);
        }
        final tail = find.descendant(
          of: flow,
          matching: find.byType(TextField),
        );
        await tester.enterText(tail, 'blue sky');
        expect(
          tester.widget<ChipFlowView>(flow).selection.length,
          selectedCount,
        );
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(key('desktop-tag-popover'), findsNothing);
        expect(
          container.read(generateProvider).characters.single.positive,
          'traveler, white shirt, blue sky',
        );
        expect(
          container.read(generateProvider).characters.single.negative,
          'hat',
        );
        expect(container.read(generateProvider).prompt, 'solo');
        await tap(tester, 'character-fullscreen-$id');
        final reopened = find.descendant(
          of: dialog,
          matching: find.byType(ChipFlowView),
        );
        expect(
          tester.widget<ChipFlowView>(reopened).controller.text,
          'traveler, white shirt, blue sky',
        );
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'chip names use the same smaller font in the sidebar and dialog',
    (tester) async {
      cacheTagMeta('ocean', trans: '海洋');
      container.read(generateProvider.notifier).setPrompts(positive: 'ocean');
      await container.read(editorSettingsProvider.future);
      unawaited(
        container
            .read(editorSettingsProvider.notifier)
            .patch(
              (s) => s.copyWith(
                chipMode: true,
                showTranslation: true,
                chipFontSize: 20,
              ),
            ),
      );
      await mount(tester, const PromptCard());
      Finder label(Finder flow, String value) =>
          find.descendant(of: flow, matching: find.text(value));
      void check(Finder flow) {
        expect(tester.widget<Text>(label(flow, 'ocean')).style!.fontSize, 16);
        expect(tester.widget<Text>(label(flow, '海洋')).style!.fontSize, 16);
      }

      check(find.byType(ChipFlowView));
      await tap(tester, 'prompt-fullscreen-main');
      check(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(ChipFlowView),
        ),
      );
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      unawaited(
        container
            .read(editorSettingsProvider.notifier)
            .patch((s) => s.copyWith(chipMode: false)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnnotatedField>(find.byType(AnnotatedField)).fontSize,
        16,
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
}
