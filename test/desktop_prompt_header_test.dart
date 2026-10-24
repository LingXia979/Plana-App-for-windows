import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/editor/widgets/chip_flow_view.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';

import 'support/character_avatar_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CharacterAvatarFixture fixture;
  GenerateNotifier gen() => fixture.container.read(generateProvider.notifier);
  GenerateState state() => fixture.container.read(generateProvider);
  List<String> order() => state().sections.map((s) => s.id).toList();
  Finder key(String id) => find.byKey(ValueKey(id));
  Finder header(String id) => key('prompt-section-header-$id');
  Finder name(String id) => key('prompt-section-name-$id');
  Finder nameInput(String id) => key('prompt-section-name-$id-editor');
  Finder input(String id) => find.descendant(
    of: key(id == 'main' ? 'desktop-prompt-text' : 'desktop-section-$id-text'),
    matching: find.byType(TextField),
  );
  Offset emptyHeader(WidgetTester tester, String id) =>
      tester.getRect(header(id)).centerRight - const Offset(18, 0);
  bool inList(String id) => find
      .ancestor(of: header(id), matching: find.byType(ReorderableListView))
      .evaluate()
      .isNotEmpty;

  setUp(() async {
    fixture = CharacterAvatarFixture();
    await fixture.initialize();
    gen().setPrompts(positive: 'forest', negative: 'lowres');
    gen().applyCanvas(
      CanvasPrompts.of(
        state().copyWith(
          sections: const [
            PromptSection.main(),
            PromptSection(
              id: 's1',
              name: '分区一',
              positive: 'blue sky',
              negative: 'rain',
              positiveRaw: 'blue sky, ~hat~',
            ),
            PromptSection(
              id: 's2',
              name: '分区二',
              positive: 'lake',
              negative: 'fog',
            ),
          ],
        ),
      ),
      force: true,
    );
  });
  tearDown(() async {
    await fixture.dispose();
  });

  Future<void> mount(WidgetTester tester) async =>
      fixture.mount(tester, child: const PromptCard(), width: 520);
  Future<void> clickHeader(WidgetTester tester, String id) async {
    await tester.ensureVisible(header(id));
    await tester.tapAt(emptyHeader(tester, id), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  Future<void> collapseAll(WidgetTester tester) async {
    for (final id in order()) {
      await clickHeader(tester, id);
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    tester.view.reset();
  }

  Future<void> dragToEnd(
    WidgetTester tester,
    String id, {
    bool fromName = false,
    bool hover = false,
  }) async {
    final start = fromName
        ? tester.getCenter(name(id))
        : emptyHeader(tester, id);
    final last = order().last;
    final wasExpanded = input(id).evaluate().isNotEmpty;
    final grabOffset = start.dy - tester.getTopLeft(key('sec$id')).dy;
    final end = Offset(
      start.dx,
      tester.getBottomLeft(key('sec$last')).dy + grabOffset + 8,
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    if (hover) {
      // Previous mouse clicks already registered this device.
      await gesture.moveTo(start);
      await tester.pump(const Duration(seconds: 1));
    }
    await gesture.down(start);
    await gesture.moveBy(const Offset(0, 4));
    await tester.pump(); // No elapsed long-press time.
    expect(
      inList(id),
      isFalse,
      reason: 'Moving immediately must create a drag proxy',
    );
    expect(
      input(id).evaluate().isNotEmpty,
      wasExpanded,
      reason: 'Moving to the drag overlay must preserve folding',
    );
    for (var step = 1; step <= 6; step++) {
      await gesture.moveTo(Offset.lerp(start, end, step / 6)!);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await gesture.removePointer();
  }

  for (final standalone in [false, true]) {
    desktopTest(
      '${standalone ? 'standalone' : 'section'} header click collapses once and folding setting disables it',
      (tester) async {
        if (standalone) {
          gen().applyCanvas(
            CanvasPrompts.of(state().copyWith(sections: [])),
            force: true,
          );
        }
        await mount(tester);
        final id = standalone ? 'main' : 's1';
        expect(find.byIcon(Icons.drag_indicator), findsNothing);
        expect(key('prompt-section-collapse-$id'), findsNothing);
        await clickHeader(tester, id);
        expect(input(id), findsNothing);
        await clickHeader(tester, id);
        expect(input(id), findsOneWidget);
        fixture.container
            .read(themeSettingsProvider.notifier)
            .patch((s) => s.copyWith(collapsiblePromptCards: false));
        await tester.pumpAndSettle();
        await clickHeader(tester, id);
        expect(input(id), findsOneWidget);
        if (!standalone) {
          // Folding is optional, sorting is not disabled by this setting.
          final start = emptyHeader(tester, 's1');
          final gesture = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          await gesture.moveBy(const Offset(0, 4));
          await tester.pump();
          expect(inList('s1'), isFalse);
          await gesture.cancel();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  desktopTest(
    'tiny movement remains a click and a stationary hold never enters multi-select',
    (tester) async {
      await mount(tester);
      final start = emptyHeader(tester, 's1');
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, .2));
      await tester.pump(const Duration(seconds: 1));
      expect(inList('s1'), isTrue);
      expect(input('s1'), findsOneWidget);
      expect(find.byTooltip('退出多选'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(input('s1'), findsNothing);
      expect(order(), ['main', 's1', 's2']);
      await finish(tester);
    },
  );

  for (final button in [kSecondaryButton, kMiddleMouseButton]) {
    desktopTest('button $button neither collapses nor sorts headers or names', (
      tester,
    ) async {
      await mount(tester);
      for (final start in [
        emptyHeader(tester, 's1'),
        tester.getCenter(name('s1')),
      ]) {
        await tester.tapAt(
          start,
          kind: PointerDeviceKind.mouse,
          buttons: button,
        );
        final gesture = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
          buttons: button,
        );
        await gesture.moveBy(const Offset(0, 70));
        await gesture.up();
        await tester.pumpAndSettle();
      }
      expect(order(), ['main', 's1', 's2']);
      expect(input('s1'), findsOneWidget);
      expect(nameInput('s1'), findsNothing);
      await finish(tester);
    });
  }

  for (final fromName in [false, true]) {
    desktopTest(
      'immediate drag from ${fromName ? 'name' : 'hovered empty header'} sorts without renaming or expanding',
      (tester) async {
        await mount(tester);
        await collapseAll(tester);
        await dragToEnd(tester, 's1', fromName: fromName, hover: !fromName);
        expect(order(), ['main', 's2', 's1']);
        expect(input('s1'), findsNothing);
        expect(nameInput('s1'), findsNothing);
        expect(state().sections.last.positiveRaw, 'blue sky, ~hat~');
        expect(state().sections.last.negative, 'rain');
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  desktopTest(
    'main row sorts from its header while a click on a name only renames',
    (tester) async {
      await mount(tester);
      await collapseAll(tester);
      await tester.tap(name('s1'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(nameInput('s1'), findsOneWidget);
      expect(input('s1'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await dragToEnd(tester, 'main');
      expect(order(), ['s1', 's2', 'main']);
      expect(state().prompt, 'forest');
      expect(state().negativePrompt, 'lowres');
      await finish(tester);
    },
  );

  for (final action in ['fullscreen', 'toggle', 'delete']) {
    desktopTest(
      'dragging the $action button does not sort, fold or activate it',
      (tester) async {
        await mount(tester);
        await collapseAll(tester);
        final target = action == 'fullscreen'
            ? key('prompt-fullscreen-s1')
            : find.descendant(
                of: key('secs1'),
                matching: find.byTooltip(action == 'toggle' ? '停用分区' : '删除分区'),
              );
        final gesture = await tester.startGesture(
          tester.getCenter(target),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(0, 100));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(order(), ['main', 's1', 's2']);
        expect(input('s1'), findsNothing);
        expect(state().sections[1].enabled, isTrue);
        expect(find.byType(Dialog), findsNothing);
        await finish(tester);
      },
    );
  }

  for (final editingName in [false, true]) {
    desktopTest(
      'dragging inside ${editingName ? 'name' : 'prompt'} text selects text without sorting',
      (tester) async {
        await mount(tester);
        if (editingName) {
          await tester.tap(name('s1'));
          await tester.pumpAndSettle();
        }
        final field = editingName ? nameInput('s1') : input('s1');
        await tester.enterText(
          field,
          'long enough words to select with a mouse',
        );
        final box = tester.getRect(field);
        final start = box.centerLeft + const Offset(15, 0);
        final gesture = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(100, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(order(), ['main', 's1', 's2']);
        expect(inList('s1'), isTrue);
        expect(
          tester.widget<TextField>(field).controller!.selection.isCollapsed,
          isFalse,
        );
        expect(input('s1'), findsOneWidget);
        if (editingName) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        await finish(tester);
      },
    );
  }

  desktopTest(
    'multi-select header and name toggle selection; sorting preserves selected IDs',
    (tester) async {
      await mount(tester);
      await tester.tap(key('prompt-section-select'));
      await tester.pumpAndSettle();
      await clickHeader(tester, 's1');
      await tester.tap(name('s2'));
      await tester.pumpAndSettle();
      for (final id in ['main', 's1', 's2']) {
        expect(
          tester.widget<Checkbox>(key('prompt-section-pick-$id')).value,
          isTrue,
        );
      }
      await dragToEnd(tester, 's1', fromName: true);
      expect(order(), ['main', 's2', 's1']);
      for (final id in ['main', 's1', 's2']) {
        expect(
          tester.widget<Checkbox>(key('prompt-section-pick-$id')).value,
          isTrue,
        );
        expect(nameInput(id), findsNothing);
      }
      await finish(tester);
    },
  );

  desktopTest(
    'keyboard activation can still fold the header without a separate icon',
    (tester) async {
      await mount(tester);
      final content = find
          .descendant(of: header('main'), matching: find.byType(ConstrainedBox))
          .first;
      Focus.of(tester.element(content)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(input('main'), findsNothing);
      await finish(tester);
    },
  );

  for (final effort in [NaiEffort.medium, NaiEffort.high]) {
    desktopTest('sorting retains disabled drafts, editor and undo in $effort', (
      tester,
    ) async {
      gen().setModel('NAI 5.0 Full');
      gen().setNaiEffort(effort);
      gen().updateSection('s1', enabled: false);
      await mount(tester);
      await clickHeader(tester, 'main');
      await clickHeader(tester, 's2');
      final controller = tester.widget<TextField>(input('s1')).controller!;
      const draft = '1.3::blue sky::, ~hat~, sunshine';
      await tester.enterText(input('s1'), draft);
      await clickHeader(tester, 's1');
      await dragToEnd(tester, 's1');
      expect(order(), ['main', 's2', 's1']);
      expect(input('s1'), findsNothing);
      await clickHeader(tester, 's1');
      expect(
        tester.widget<TextField>(input('s1')).controller,
        same(controller),
      );
      expect(controller.text, draft);
      expect(state().sections.last.positiveRaw, draft);
      expect(state().sections.last.negative, 'rain');
      expect(state().sections.last.enabled, isFalse);
      expect(
        key('desktop-section-s1-negative-tab'),
        effort == NaiEffort.medium ? findsNothing : findsOneWidget,
      );
      await tester.tap(key('desktop-section-s1-undo'));
      await tester.pumpAndSettle();
      expect(controller.text, 'blue sky, ~hat~');

      // Medium hides negative editing, without replacing its saved High draft.
      gen().setNaiEffort(NaiEffort.high);
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-section-s1-negative-tab'));
      await tester.pumpAndSettle();
      expect(controller.text, 'rain');
      await tester.enterText(input('s1'), 'snow, ~fog~');
      await clickHeader(tester, 's1');
      await clickHeader(tester, 's1');
      expect(controller.text, 'snow, ~fog~');
      await tester.tap(key('desktop-section-s1-undo'));
      await tester.pumpAndSettle();
      expect(controller.text, 'rain');
      expect(state().sections.last.enabled, isFalse);
      expect(state().negativePrompt, 'lowres');
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }

  desktopTest('dragging flushes pending chip input and preserves its undo', (
    tester,
  ) async {
    await pumpUntilComplete(
      tester,
      fixture.container.read(editorSettingsProvider.future),
    );
    await pumpUntilComplete(
      tester,
      fixture.container
          .read(editorSettingsProvider.notifier)
          .patch((s) => s.copyWith(chipMode: true)),
    );
    await mount(tester);
    await clickHeader(tester, 'main');
    await clickHeader(tester, 's2');
    final flow = find.descendant(
      of: key('secs1'),
      matching: find.byType(ChipFlowView),
    );
    final controller = tester.widget<ChipFlowView>(flow).controller;
    final tail = find.descendant(of: flow, matching: find.byType(TextField));
    await tester.enterText(tail, 'sunshine');
    expect(state().sections[1].positive.contains('sunshine'), isFalse);
    await dragToEnd(tester, 's1');
    expect(order(), ['main', 's2', 's1']);
    expect(state().sections.last.positive, contains('sunshine'));
    expect(state().sections.last.positiveRaw, contains('~hat~'));
    expect(state().sections.last.negative, 'rain');
    expect(tester.widget<ChipFlowView>(flow).controller, same(controller));
    // ChipFlowView keeps a zero-width sentinel for backspace at the start.
    expect(
      tester.widget<TextField>(tail).controller!.text.replaceAll('\u200b', ''),
      isEmpty,
    );
    await clickHeader(tester, 's1');
    await clickHeader(tester, 's1');
    await tester.tap(key('desktop-section-s1-undo'));
    await tester.pumpAndSettle();
    expect(controller.text, 'blue sky, ~hat~');
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}

void desktopTest(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
