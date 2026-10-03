import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/editor_theme.dart';
import 'package:plana_app/features/editor/editor_page.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/annotated_field.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/editor/widgets/editor_settings_sheet.dart';
import 'package:plana_app/features/editor/widgets/tag_panel.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/desktop_prompt_card.dart';

void main() {
  late ProviderContainer container;
  late AppStores stores;
  late GenerateNotifier gen;
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
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
    gen = container.read(generateProvider.notifier);
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  Finder input(String prefix) => find.descendant(
    of: key('$prefix-text'),
    matching: find.byType(TextField),
  );
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 310,
                child: SingleChildScrollView(
                  child: Consumer(
                    builder: (context, ref, _) => Column(
                      children: [
                        const DesktopPromptCard(),
                        for (final c in ref.watch(generateProvider).characters)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: DesktopPromptCard(
                              key: ValueKey(c.id),
                              charId: c.id,
                            ),
                          ),
                      ],
                    ),
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

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> edit(WidgetTester tester, String prefix, String text) async {
    await tester.ensureVisible(input(prefix));
    await tester.enterText(input(prefix), text);
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String name) async {
    await tester.ensureVisible(key(name));
    await tester.pumpAndSettle();
    await tester.tap(key(name));
    await tester.pumpAndSettle();
  }

  test('weight backgrounds deepen to 2 and -1 and saturate there', () {
    for (final palette in [EditorPalette.light, EditorPalette.dark]) {
      expect(palette.weightWash(1), isNull);
      expect(palette.weightWash(1.2)!.a, lessThan(palette.weightWash(1.7)!.a));
      expect(palette.weightWash(1.7)!.a, lessThan(palette.weightWash(2)!.a));
      expect(palette.weightWash(2), palette.weightWash(5));
      expect(palette.weightWash(.7)!.a, lessThan(palette.weightWash(.3)!.a));
      expect(palette.weightWash(.3)!.a, lessThan(palette.weightWash(0)!.a));
      expect(palette.weightWash(0)!.a, lessThan(palette.weightWash(-1)!.a));
      expect(palette.weightWash(-1), palette.weightWash(-2));
      expect(
        palette.weightWash(1.2)!.r,
        greaterThan(palette.weightWash(1.2)!.b),
      );
      expect(palette.weightWash(.7)!.b, greaterThan(palette.weightWash(.7)!.r));
    }
  });

  testWidgets(
    'main and character sessions save immediately and isolate tabs, undo and imports',
    (tester) async {
      gen.setPrompts(positive: 'sunrise', negative: 'rain');
      gen.addCharacter();
      gen.addCharacter();
      final a = gen.state.characters[0].id;
      final b = gen.state.characters[1].id;
      gen.updateCharacter(a, positive: 'white hair', negative: 'hat');
      gen.updateCharacter(b, positive: 'blue hair', negative: 'glasses');
      await mount(tester);
      await edit(tester, 'desktop-prompt', '1.2::sunrise::, 0.7::mist:: ');
      expect(gen.state.prompt, '1.2::sunrise::, 0.7::mist::');
      expect(
        tester
            .widget<TextField>(input('desktop-prompt'))
            .controller!
            .text
            .endsWith(' '),
        isTrue,
        reason: 'Wire normalization must not reset the active draft or caret',
      );
      await tap(tester, 'desktop-character-$a-negative-tab');
      await edit(tester, 'desktop-character-$a', 'blurry');
      await edit(tester, 'desktop-character-$b', '1.5::silver hair::');
      expect(gen.state.characters[0].positive, 'white hair');
      expect(gen.state.characters[0].negative, 'blurry');
      expect(gen.state.characters[1].positive, '1.5::silver hair::');
      expect(gen.state.negativePrompt, 'rain');
      await tap(tester, 'desktop-character-$a-undo');
      expect(gen.state.characters[0].negative, 'hat');
      expect(gen.state.characters[1].positive, '1.5::silver hair::');
      gen.setPrompts(positive: 'external import');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input('desktop-prompt')).controller!.text,
        'external import',
      );
      gen.removeCharacter(a);
      await tester.pumpAndSettle();
      expect(gen.state.prompt, 'external import');
      expect(gen.state.characters.single.id, b);
      await finish(tester);
      expect(gen.state.characters.single.positive, '1.5::silver hair::');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long main and role prompts grow without a nested scroll viewport in both modes',
    (tester) async {
      final long = List.generate(
        80,
        (i) => '1.2::mountain $i::, 0.7::mist $i::',
      ).join(', ');
      gen.setPrompts(positive: long);
      gen.addCharacter();
      final id = gen.state.characters.single.id;
      gen.updateCharacter(id, positive: long);
      await mount(tester);
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        0,
        reason:
            'Loading an unfocused long prompt must not jump to its last line',
      );
      for (final prefix in ['desktop-prompt', 'desktop-character-$id']) {
        expect(tester.getSize(key('$prefix-text')).height, greaterThan(600));
        final field = tester.widget<TextField>(input(prefix));
        expect(field.maxLines, isNull);
        expect(field.controller!.text, long);
        for (final scroll in tester.stateList<ScrollableState>(
          find.descendant(
            of: key('$prefix-text'),
            matching: find.byType(Scrollable),
          ),
        )) {
          expect(scroll.position.maxScrollExtent, 0);
        }
      }
      await tap(tester, 'desktop-prompt-mode');
      expect(
        tester.getSize(key('desktop-prompt-tags')).height,
        greaterThan(600),
      );
      expect(
        find.descendant(
          of: key('desktop-prompt-tags'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      expect(gen.state.prompt, long);
      await finish(tester);
    },
  );

  testWidgets(
    'text actions anchor on selection and stay fixed when the prompt scrolls',
    (tester) async {
      gen.setPrompts(
        positive: List.generate(70, (i) => 'mountain $i').join(', '),
      );
      await mount(tester);
      final field = tester.state<AnnotatedFieldState>(
        find.byType(AnnotatedField),
      );
      final text = tester.widget<TextField>(input('desktop-prompt'));
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final extent = scroll.maxScrollExtent;
      final height = tester.getSize(key('desktop-prompt-text')).height;
      await tester.tapAt(
        tester.getTopLeft(input('desktop-prompt')) + const Offset(15, 15),
      );
      text.controller!.selection = const TextSelection.collapsed(offset: 5);
      await tester.pumpAndSettle();
      Rect panel() => tester.getRect(key('desktop-tag-popover'));
      expect(panel().top, closeTo(field.selectionAnchor()!.bottom + 8, .01));
      final first = panel();
      text.controller!.selection = const TextSelection.collapsed(offset: 8);
      await tester.pumpAndSettle();
      expect(panel().left, greaterThan(first.left));
      expect(scroll.maxScrollExtent, closeTo(extent, .01));
      expect(tester.getSize(key('desktop-prompt-text')).height, height);

      final beforeScroll = panel();
      scroll.jumpTo(20);
      await tester.pumpAndSettle();
      expect(panel(), beforeScroll);
      scroll.jumpTo(500);
      await tester.pumpAndSettle();
      expect(panel(), beforeScroll);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(key('desktop-tag-popover'), findsOneWidget);

      text.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 20,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BatchPanel), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: key('desktop-tag-popover'),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(key('desktop-tag-popover'), findsNothing);
      text.controller!.selection = const TextSelection.collapsed(offset: 8);
      await tester.pumpAndSettle();
      expect(key('desktop-tag-popover'), findsOneWidget);

      await tester.tapAt(const Offset(700, 550));
      await tester.pumpAndSettle();
      expect(key('desktop-tag-popover'), findsNothing);
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chip multi-selection actions anchor to the last click and keep the selection',
    (tester) async {
      gen.setPrompts(positive: 'sunrise, mist, rain');
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
      final before = tester.getSize(key('desktop-prompt-tags')).height;
      await tester.tapAt(flow.chipAnchor(0)!.center);
      await tester.pumpAndSettle();
      expect(find.byType(TagPanel), findsOneWidget);
      await tester.tapAt(flow.chipAnchor(1)!.center);
      await tester.pumpAndSettle();
      expect(find.byType(BatchPanel), findsOneWidget);
      final rect = tester.getRect(key('desktop-tag-popover'));
      expect(rect.left, closeTo(flow.chipAnchor(1)!.left, .01));
      expect(rect.top, closeTo(flow.chipAnchor(1)!.bottom + 8, .01));
      expect(tester.getSize(key('desktop-prompt-tags')).height, before);
      await tester.tap(
        find.descendant(
          of: key('desktop-tag-popover'),
          matching: find.byIcon(Icons.add),
        ),
      );
      await tester.pumpAndSettle();
      expect(gen.state.prompt, contains('1.1::'));
      expect(find.byType(BatchPanel), findsOneWidget);
      expect(tester.widget<ChipFlowView>(find.byType(ChipFlowView)).selection, {
        0,
        1,
      });
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(key('desktop-tag-popover'), findsNothing);
      expect(
        tester.widget<ChipFlowView>(find.byType(ChipFlowView)).selection,
        isEmpty,
      );
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Ctrl+A selects all tags only in the active prompt session', (
    tester,
  ) async {
    gen.setPrompts(positive: 'sunrise, mist, rain', negative: 'cloud, snow');
    gen.addCharacter();
    final id = gen.state.characters.single.id;
    gen.updateCharacter(id, positive: 'blue hair, green eyes');
    await mount(tester);
    await tap(tester, 'desktop-prompt-mode');
    Finder flowIn(String prefix) => find.descendant(
      of: key('$prefix-tags'),
      matching: find.byType(ChipFlowView),
    );
    Future<void> selectAll() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    final mainFlow = flowIn('desktop-prompt');
    final charFlow = flowIn('desktop-character-$id');
    await tester.tapAt(
      tester.state<ChipFlowViewState>(mainFlow).chipAnchor(0)!.center,
    );
    await tester.pumpAndSettle();
    await selectAll();
    expect(tester.widget<ChipFlowView>(mainFlow).selection, {0, 1, 2});
    expect(tester.widget<ChipFlowView>(charFlow).selection, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.ensureVisible(charFlow);
    await tester.tapAt(
      tester.state<ChipFlowViewState>(charFlow).chipAnchor(0)!.center,
    );
    await tester.pumpAndSettle();
    await selectAll();
    expect(tester.widget<ChipFlowView>(charFlow).selection, {0, 1});
    expect(tester.widget<ChipFlowView>(mainFlow).selection, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: charFlow,
      matching: find.byType(TextField),
    );
    await tester.enterText(input, 'draft words');
    await selectAll();
    expect(tester.widget<ChipFlowView>(charFlow).selection, isEmpty);
    final editing = tester.widget<TextField>(input).controller!;
    expect(editing.selection.textInside(editing.text), contains('draft words'));
    expect(gen.state.prompt, 'sunrise, mist, rain');
    await tester.enterText(input, '');
    await selectAll();
    expect(tester.widget<ChipFlowView>(charFlow).selection, {0, 1});
    await finish(tester);
  });

  for (final target in ['main', 'negative', 'character']) {
    testWidgets('pasting a tag batch commits all $target tags with one undo', (
      tester,
    ) async {
      const batch =
          'lowres, bad quality, -2::chibi, doll::, 1.5::blue sky::, last tag';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': batch};
          if (call.method == 'Clipboard.hasStrings') return {'value': true};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      gen.setPrompts(positive: 'sunrise', negative: 'rain');
      gen.addCharacter();
      final id = gen.state.characters.single.id;
      gen.updateCharacter(id, positive: 'green eyes');
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      if (target == 'negative') {
        await tap(tester, 'desktop-prompt-negative-tab');
      }
      final prefix = target == 'character'
          ? 'desktop-character-$id'
          : 'desktop-prompt';
      final flow = find.descendant(
        of: key('$prefix-tags'),
        matching: find.byType(ChipFlowView),
      );
      final tail = find.descendant(of: flow, matching: find.byType(TextField));
      await tester.ensureVisible(tail);
      await tester.tap(tail);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      String prompt() => target == 'character'
          ? gen.state.characters.single.positive
          : target == 'negative'
          ? gen.state.negativePrompt
          : gen.state.prompt;
      final original = target == 'character'
          ? 'green eyes'
          : target == 'negative'
          ? 'rain'
          : 'sunrise';
      expect(prompt(), '$original, $batch');
      expect(
        chipInputBody(tester.widget<TextField>(tail).controller!.text),
        isEmpty,
      );
      if (target != 'main') expect(gen.state.prompt, 'sunrise');
      await tap(tester, '$prefix-undo');
      expect(prompt(), original);
      await finish(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'context menu paste replaces the tail selection and submits, while typing stays a draft',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': 'blue sky, mist'};
          }
          if (call.method == 'Clipboard.hasStrings') return {'value': true};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      gen.setPrompts(positive: 'sunrise');
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      final tail = find.descendant(
        of: find.byType(ChipFlowView),
        matching: find.byType(TextField),
      );
      await tester.enterText(tail, 'draft');
      expect(gen.state.prompt, 'sunrise');
      final input = tester.widget<TextField>(tail).controller!;
      input.selection = TextSelection(
        baseOffset: kChipInputPad.length,
        extentOffset: input.text.length,
      );
      final editable = tester.state<EditableTextState>(
        find.descendant(of: tail, matching: find.byType(EditableText)),
      );
      editable.showToolbar();
      await tester.pumpAndSettle();
      final toolbar = tester.widget<AdaptiveTextSelectionToolbar>(
        find.byType(AdaptiveTextSelectionToolbar),
      );
      toolbar.buttonItems!
          .firstWhere((item) => item.type == ContextMenuButtonType.paste)
          .onPressed!();
      await tester.pumpAndSettle();
      expect(gen.state.prompt, 'sunrise, blue sky, mist');
      expect(chipInputBody(input.text), isEmpty);
      await finish(tester);
    },
  );

  testWidgets(
    'group chips and single tags share saturated effective weight colours',
    (tester) async {
      gen.setPrompts(
        positive:
            '2::single::, 5::group a, group b::, -1::low::, -2::blue a, blue b::, 0::zero::',
      );
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      Color? background(String name) => tester
          .element(find.text(name))
          .findAncestorWidgetOfExactType<Material>()!
          .color;
      expect(background('group a'), background('single'));
      expect(background('group b'), background('single'));
      expect(background('blue a'), background('low'));
      expect(background('blue b'), background('low'));
      expect(background('zero'), isNot(background('low')));
      await finish(tester);
    },
  );

  testWidgets(
    'mouse movement previews and drops a tag without waiting, with one undo',
    (tester) async {
      gen.setPrompts(positive: 'alpha, beta, gamma, delta');
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
      final drag = await tester.startGesture(
        flow.chipAnchor(0)!.center,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(3, 0));
      await tester.pump();
      expect(key('desktop-chip-drag-feedback'), findsNothing);
      await drag.moveBy(const Offset(2, 0));
      await tester.pump();
      expect(key('desktop-chip-drag-feedback'), findsOneWidget);
      expect(key('desktop-tag-popover'), findsNothing);
      final target = flow.chipAnchor(3)!;
      await drag.moveTo(Offset(target.right - 2, target.center.dy));
      await tester.pump();
      expect(key('desktop-chip-drop-preview-0'), findsOneWidget);
      expect(
        gen.state.prompt,
        'alpha, beta, gamma, delta',
        reason: 'Only mouse-up commits the preview',
      );
      await drag.up();
      await tester.pumpAndSettle();
      expect(parseToks(gen.state.prompt).map((t) => t.name), [
        'beta',
        'gamma',
        'delta',
        'alpha',
      ]);
      expect(key('desktop-chip-drag-feedback'), findsNothing);
      await tap(tester, 'desktop-prompt-undo');
      expect(gen.state.prompt, 'alpha, beta, gamma, delta');
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multi-tag dragging preserves prompt order instead of click order and can cancel',
    (tester) async {
      const original = 'alpha, beta, gamma, delta';
      gen.setPrompts(positive: original);
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
      for (final index in [3, 1]) {
        await tester.tapAt(flow.chipAnchor(index)!.center);
        await tester.pumpAndSettle();
      }
      expect(find.text('移动'), findsNothing);
      final drag = await tester.startGesture(
        flow.chipAnchor(1)!.center,
        kind: PointerDeviceKind.mouse,
      );
      final first = flow.chipAnchor(0)!;
      await drag.moveTo(Offset(first.left + 1, first.center.dy));
      await tester.pump();
      expect(key('desktop-chip-drop-preview-1'), findsOneWidget);
      expect(key('desktop-chip-drop-preview-3'), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
      expect(parseToks(gen.state.prompt).map((t) => t.name), [
        'beta',
        'delta',
        'alpha',
        'gamma',
      ]);
      final reordered = gen.state.prompt;
      final outside = await tester.startGesture(
        flow.chipAnchor(0)!.center,
        kind: PointerDeviceKind.mouse,
      );
      await outside.moveTo(const Offset(700, 400));
      await tester.pump();
      await outside.up();
      await tester.pumpAndSettle();
      expect(gen.state.prompt, reordered);
      final escape = await tester.startGesture(
        flow.chipAnchor(0)!.center,
        kind: PointerDeviceKind.mouse,
      );
      await escape.moveBy(const Offset(5, 0));
      await tester.pump();
      expect(key('desktop-chip-drag-feedback'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await escape.up();
      await tester.pumpAndSettle();
      expect(key('desktop-chip-drag-feedback'), findsNothing);
      expect(gen.state.prompt, reordered);
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragging a complete weight group keeps its encoding and group weight',
    (tester) async {
      gen.setPrompts(positive: '2::alpha, beta::, gamma, delta');
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
      for (final i in [1, 0]) {
        await tester.tapAt(flow.chipAnchor(i)!.center);
        await tester.pumpAndSettle();
      }
      final drag = await tester.startGesture(
        flow.chipAnchor(0)!.center,
        kind: PointerDeviceKind.mouse,
      );
      final last = flow.chipAnchor(3)!;
      await drag.moveTo(Offset(last.right - 1, last.center.dy));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      final tokens = parseToks(gen.state.prompt);
      expect(tokens.map((t) => t.name), ['gamma', 'delta', 'alpha', 'beta']);
      expect(tokens.map((t) => t.effMult), [1, 1, 2, 2]);
      expect(gen.state.prompt, contains('2::alpha, beta::'));
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragging at the viewport edge scrolls and cancellation leaves the prompt intact',
    (tester) async {
      final original = List.generate(60, (i) => 'mountain $i').join(', ');
      gen.setPrompts(positive: original);
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
      final short = await tester.startGesture(
        flow.chipAnchor(0)!.center,
        kind: PointerDeviceKind.mouse,
      );
      await short.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 250));
      expect(key('desktop-chip-drag-feedback'), findsNothing);
      await short.cancel();
      await tester.pumpAndSettle();
      final drag = await tester.startGesture(
        flow.chipAnchor(0)!.center,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(const Offset(150, 580));
      await tester.pump(const Duration(milliseconds: 240));
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(scroll.pixels, greaterThan(0));
      expect(gen.state.prompt, original);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await drag.up();
      await tester.pumpAndSettle();
      expect(gen.state.prompt, original);
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an external prompt replacement cancels a drag without restoring stale tags',
    (tester) async {
      gen.setPrompts(positive: 'alpha, beta, gamma');
      await mount(tester);
      await tap(tester, 'desktop-prompt-mode');
      final flow = tester.state<ChipFlowViewState>(find.byType(ChipFlowView));
      final drag = await tester.startGesture(
        flow.chipAnchor(0)!.center,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(5, 0));
      await tester.pump();
      expect(key('desktop-chip-drag-feedback'), findsOneWidget);
      gen.setPrompts(positive: 'external import');
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(gen.state.prompt, 'external import');
      expect(key('desktop-chip-drag-feedback'), findsNothing);
      await finish(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings live in main prompt, apply inline, and narrow tag tools fit',
    (tester) async {
      gen.setPrompts(positive: '1.2::sunrise::, 0.7::mist::');
      await mount(tester);
      expect(find.text('标签编辑器'), findsNothing);
      expect(
        tester.widget<EditorPage>(find.byType(EditorPage)).embedded,
        isTrue,
      );
      final controller = tester
          .widget<TextField>(input('desktop-prompt'))
          .controller!;
      await tester.tap(input('desktop-prompt'));
      controller.selection = const TextSelection.collapsed(offset: 7);
      await tester.pumpAndSettle();
      expect(find.byType(TagPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, 'desktop-editor-settings');
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(EditorSettingsSheet), findsOneWidget);
      unawaited(
        container
            .read(editorSettingsProvider.notifier)
            .patch(
              (s) => s.copyWith(showWeightWash: false, showTranslation: true),
            ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      final field = tester.widget<AnnotatedField>(
        find.descendant(
          of: key('desktop-prompt-text'),
          matching: find.byType(AnnotatedField),
        ),
      );
      expect(field.showWeightWash, isFalse);
      expect(field.showTrans, isTrue);
      expect(
        find.byType(EditorPage),
        findsOneWidget,
        reason: 'Settings must not push a second editor',
      );
      await finish(tester);
    },
  );
}
