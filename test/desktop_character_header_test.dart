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

import 'support/character_avatar_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CharacterAvatarFixture fixture;
  GenerateNotifier gen() => fixture.container.read(generateProvider.notifier);
  GenerateState state() => fixture.container.read(generateProvider);
  CharacterPrompt character(String id) =>
      state().characters.firstWhere((c) => c.id == id);
  List<String> order() => state().characters.map((c) => c.id).toList();
  Finder key(String id) => find.byKey(ValueKey(id));
  Finder header(String id) => key('character-header-$id');
  Finder name(String id) => key('character-name-$id');
  Finder nameInput(String id) => key('character-name-$id-editor');
  Finder input(String id) => find.descendant(
    of: key('desktop-character-$id-text'),
    matching: find.byType(TextField),
  );
  Finder action(String id, String type) => switch (type) {
    'toggle' || 'delete' => find.descendant(
      of: key('char$id'),
      matching: find.byTooltip(
        type == 'delete'
            ? '删除角色'
            : character(id).enabled
            ? '停用(保留配置)'
            : '启用',
      ),
    ),
    _ => key('character-$type-$id'),
  };
  Offset emptyHeader(WidgetTester tester, String id, {bool secondRow = false}) {
    final avatar = tester.getRect(action(id, 'avatar'));
    final fullscreen = tester.getRect(action(id, 'fullscreen'));
    final box = tester.getRect(header(id));
    if (fullscreen.top > avatar.bottom) {
      return secondRow
          ? Offset(box.left + 18, fullscreen.center.dy)
          : Offset(box.right - 18, avatar.center.dy);
    }
    return Offset(fullscreen.left - 20, avatar.center.dy);
  }

  bool inList(String id) => find
      .ancestor(of: header(id), matching: find.byType(ReorderableListView))
      .evaluate()
      .isNotEmpty;

  setUp(() async {
    fixture = CharacterAvatarFixture();
    await fixture.initialize();
    gen().applyCanvas(
      CanvasPrompts.of(
        state().copyWith(
          prompt: 'forest',
          negativePrompt: 'lowres',
          characters: [
            CharacterPrompt(
              id: 'c1',
              name: '角色甲',
              positive: 'traveler, blue sky',
              positiveRaw: 'traveler, ~hat~, blue sky',
              negative: 'rain',
              position: 'B2',
              avatar: fixture.local,
            ),
            const CharacterPrompt(
              id: 'c2',
              name: '角色乙',
              positive: 'ocean',
              negative: 'fog',
              position: 'D4',
            ),
            const CharacterPrompt(
              id: 'c3',
              name: '角色丙',
              positive: 'sunlight',
              negative: 'snow',
            ),
          ],
        ),
      ),
      force: true,
    );
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await fixture.dispose();
  });

  Future<void> mount(WidgetTester tester, {bool narrow = false}) async {
    await fixture.mount(
      tester,
      width: narrow ? 340 : 520,
      scale: narrow ? 1.4 : 1,
    );
    await waitForAvatarImage(tester, action('c1', 'avatar'));
  }

  Future<void> clickHeader(
    WidgetTester tester,
    String id, {
    bool secondRow = false,
  }) async {
    await tester.ensureVisible(header(id));
    await tester.tapAt(
      emptyHeader(tester, id, secondRow: secondRow),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  Future<void> collapseAll(WidgetTester tester) async {
    for (final id in order()) {
      await clickHeader(tester, id);
    }
    await tester.ensureVisible(header(order().first));
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(header(id));
    final start = fromName
        ? tester.getCenter(name(id))
        : emptyHeader(tester, id);
    final wasExpanded = input(id).evaluate().isNotEmpty;
    final grabOffset = start.dy - tester.getTopLeft(key('char$id')).dy;
    final end = Offset(
      start.dx,
      tester.getBottomLeft(key('char${order().last}')).dy + grabOffset + 8,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    if (hover) {
      await mouse.moveTo(start);
      await tester.pump(const Duration(seconds: 1));
    }
    await mouse.down(start);
    await mouse.moveBy(const Offset(0, 4));
    await tester.pump(); // No elapsed long-press time before the proxy appears.
    expect(inList(id), isFalse);
    expect(input(id).evaluate().isNotEmpty, wasExpanded);
    for (var step = 1; step <= 6; step++) {
      await mouse.moveTo(Offset.lerp(start, end, step / 6)!);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.removePointer();
  }

  for (final narrow in [false, true]) {
    final layout = narrow ? 'narrow' : 'wide';
    desktopTest(
      '$layout header click, small motion, hold, keyboard and folding setting',
      (tester) async {
        await mount(tester, narrow: narrow);
        expect(find.byIcon(Icons.drag_indicator), findsNothing);
        expect(key('character-collapse-c1'), findsNothing);
        final avatar = tester.getRect(action('c1', 'avatar'));
        expect(
          tester.getRect(action('c1', 'fullscreen')).top > avatar.bottom,
          narrow,
        );
        await clickHeader(tester, 'c1');
        expect(input('c1'), findsNothing);
        expect(input('c2'), findsOneWidget);
        await clickHeader(tester, 'c1', secondRow: narrow);
        expect(input('c1'), findsOneWidget);
        final mouse = await tester.startGesture(
          emptyHeader(tester, 'c1'),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(.2, 0));
        await tester.pump(const Duration(seconds: 1));
        expect(inList('c1'), isTrue);
        expect(input('c1'), findsOneWidget);
        await mouse.up();
        await tester.pumpAndSettle();
        expect(input('c1'), findsNothing);
        final content = find
            .descendant(of: header('c1'), matching: find.byType(ConstrainedBox))
            .first;
        Focus.of(tester.element(content)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(input('c1'), findsOneWidget);
        await clickHeader(tester, 'c1');
        fixture.container
            .read(themeSettingsProvider.notifier)
            .patch((s) => s.copyWith(collapsiblePromptCards: false));
        await tester.pumpAndSettle();
        await clickHeader(tester, 'c1');
        expect(input('c1'), findsOneWidget);
        final drag = await tester.startGesture(
          emptyHeader(tester, 'c1'),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(0, 4));
        await tester.pump();
        expect(inList('c1'), isFalse);
        await drag.cancel();
        await tester.pumpAndSettle();
        expect(order(), ['c1', 'c2', 'c3']);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );

    for (final fromName in [false, true]) {
      desktopTest(
        '$layout immediate ${fromName ? 'name' : 'hovered header'} dragging preserves roles and folding',
        (tester) async {
          gen().updateCharacter('c1', enabled: false);
          await mount(tester, narrow: narrow);
          await collapseAll(tester);
          final original = {for (final c in state().characters) c.id: c};
          await dragToEnd(tester, 'c1', fromName: fromName, hover: !fromName);
          expect(order(), ['c2', 'c3', 'c1']);
          expect(input('c1'), findsNothing);
          expect(nameInput('c1'), findsNothing);
          await dragToEnd(tester, 'c2', fromName: fromName);
          expect(order(), ['c3', 'c1', 'c2']);
          for (final c in state().characters) {
            expect(c, same(original[c.id]));
          }
          await tester.tap(name('c1'), kind: PointerDeviceKind.mouse);
          await tester.pumpAndSettle();
          final field = tester.widget<TextField>(nameInput('c1'));
          expect(
            field.controller!.selection,
            const TextSelection(baseOffset: 0, extentOffset: 3),
          );
          expect(input('c1'), findsNothing);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await finish(tester);
        },
      );
    }

    desktopTest(
      '$layout controls never sort or fold; clicks and avatar preview remain independent',
      (tester) async {
        await mount(tester, narrow: narrow);
        await collapseAll(tester);
        for (final type in [
          'avatar',
          'toggle',
          'fullscreen',
          'position',
          'delete',
        ]) {
          final mouse = await tester.startGesture(
            tester.getCenter(action('c1', type)),
            kind: PointerDeviceKind.mouse,
          );
          await mouse.moveBy(const Offset(0, 110));
          await tester.pump();
          expect(inList('c1'), isTrue, reason: type);
          await mouse.up();
          await tester.pumpAndSettle();
          expect(order(), ['c1', 'c2', 'c3']);
          expect(character('c1').enabled, isTrue);
          expect(input('c1'), findsNothing);
          expect(find.byType(Dialog), findsNothing);
          expect(nameInput('c1'), findsNothing);
        }
        await tester.tap(
          action('c1', 'avatar'),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        final preview = key('reference-image-preview');
        expect(preview, findsOneWidget);
        await waitForAvatarImage(tester, preview);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(action('c1', 'avatar'), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(find.text('选择角色'), findsWidgets);
        await tester.tap(key('replacement'));
        await tester.pumpAndSettle();
        expect(character('c1').name, '新角色');
        expect(character('c1').position, 'B2');
        expect(character('c1').avatar, fixture.local);
        expect(input('c1'), findsNothing);
        await tester.tap(action('c1', 'toggle'));
        await tester.pumpAndSettle();
        expect(character('c1').enabled, isFalse);
        for (final type in ['fullscreen', 'position']) {
          await tester.tap(action('c1', type));
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsOneWidget);
          Navigator.of(tester.element(find.byType(Dialog))).pop();
          await tester.pumpAndSettle();
          expect(input('c1'), findsNothing);
        }
        await tester.tap(action('c1', 'delete'));
        await tester.pumpAndSettle();
        expect(order(), ['c2', 'c3']);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );

    desktopTest(
      '$layout editing name and prompt text can select without moving the role',
      (tester) async {
        await mount(tester, narrow: narrow);
        for (final editingName in [false, true]) {
          if (editingName) {
            await tester.tap(name('c1'));
            await tester.pumpAndSettle();
          }
          final field = editingName ? nameInput('c1') : input('c1');
          await tester.enterText(
            field,
            'long enough words to select with a mouse',
          );
          final start = tester.getRect(field).centerLeft + const Offset(15, 0);
          final mouse = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          await mouse.moveBy(const Offset(70, 0));
          await mouse.up();
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field).controller!.selection.isCollapsed,
            isFalse,
          );
          expect(order(), ['c1', 'c2', 'c3']);
          expect(input('c1'), findsOneWidget);
          if (editingName) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          }
        }
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  for (final button in [kSecondaryButton, kMiddleMouseButton]) {
    desktopTest('button $button never folds, renames or sorts a role', (
      tester,
    ) async {
      await mount(tester, narrow: true);
      for (final start in [
        emptyHeader(tester, 'c1'),
        tester.getCenter(name('c1')),
      ]) {
        await tester.tapAt(
          start,
          kind: PointerDeviceKind.mouse,
          buttons: button,
        );
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
          buttons: button,
        );
        await mouse.moveBy(const Offset(0, 100));
        await mouse.up();
        await tester.pumpAndSettle();
      }
      expect(order(), ['c1', 'c2', 'c3']);
      expect(input('c1'), findsOneWidget);
      expect(nameInput('c1'), findsNothing);
      await finish(tester);
    });
  }

  for (final effort in [NaiEffort.medium, NaiEffort.high]) {
    desktopTest(
      '$effort drafts, undo, avatar and position survive sorting and fullscreen',
      (tester) async {
        gen().setModel('NAI 5.0 Full');
        gen().setNaiEffort(effort);
        gen().updateCharacter('c1', enabled: false);
        await mount(tester);
        await clickHeader(tester, 'c2');
        await clickHeader(tester, 'c3');
        final controller = tester.widget<TextField>(input('c1')).controller!;
        const draft = '1.3::traveler::, ~hat~, sunshine';
        await tester.enterText(input('c1'), draft);
        await clickHeader(tester, 'c1');
        await dragToEnd(tester, 'c1');
        await clickHeader(tester, 'c1');
        expect(
          tester.widget<TextField>(input('c1')).controller,
          same(controller),
        );
        expect(controller.text, draft);
        expect(character('c1').positiveRaw, draft);
        expect(character('c1').negative, 'rain');
        expect(character('c1').enabled, isFalse);
        expect(character('c1').position, 'B2');
        expect(character('c1').avatar, fixture.local);
        expect(
          key('desktop-character-c1-negative-tab'),
          effort == NaiEffort.medium ? findsNothing : findsOneWidget,
        );
        await tester.tap(key('desktop-character-c1-undo'));
        await tester.pumpAndSettle();
        expect(controller.text, 'traveler, ~hat~, blue sky');
        await tester.tap(action('c1', 'fullscreen'));
        await tester.pumpAndSettle();
        final largeField = find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextField),
            )
            .first;
        await tester.enterText(largeField, 'large editor draft');
        await tester.tap(find.byTooltip('保存并返回'));
        await tester.pumpAndSettle();
        expect(controller.text, 'large editor draft');
        gen().setNaiEffort(NaiEffort.high);
        await tester.pumpAndSettle();
        await tester.tap(key('desktop-character-c1-negative-tab'));
        await tester.pumpAndSettle();
        expect(controller.text, 'rain');
        await tester.enterText(input('c1'), 'snow, ~fog~');
        await clickHeader(tester, 'c1');
        await clickHeader(tester, 'c1');
        expect(controller.text, 'snow, ~fog~');
        expect(character('c2').negative, 'fog');
        expect(state().negativePrompt, 'lowres');
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  desktopTest(
    'dragging commits pending chip input without losing undo or selection overlays',
    (tester) async {
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
      await clickHeader(tester, 'c2');
      await clickHeader(tester, 'c3');
      final flow = find.descendant(
        of: key('charc1'),
        matching: find.byType(ChipFlowView),
      );
      final controller = tester.widget<ChipFlowView>(flow).controller;
      final tail = find.descendant(of: flow, matching: find.byType(TextField));
      await tester.enterText(tail, 'sunshine');
      expect(character('c1').positive.contains('sunshine'), isFalse);
      await dragToEnd(tester, 'c1');
      expect(order(), ['c2', 'c3', 'c1']);
      expect(character('c1').positive, contains('sunshine'));
      expect(character('c1').positiveRaw, contains('~hat~'));
      expect(tester.widget<ChipFlowView>(flow).controller, same(controller));
      expect(
        tester
            .widget<TextField>(tail)
            .controller!
            .text
            .replaceAll('\u200b', ''),
        isEmpty,
      );
      await clickHeader(tester, 'c1');
      await clickHeader(tester, 'c1');
      await tester.tap(key('desktop-character-c1-undo'));
      await tester.pumpAndSettle();
      expect(controller.text, 'traveler, ~hat~, blue sky');
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  for (final immediate in [false, true]) {
    desktopTest(
      'canvas switch cancels dragging even when released ${immediate ? 'before' : 'after'} the next frame',
      (tester) async {
        final canvases = fixture.container.read(
          canvasWorkspaceProvider.notifier,
        );
        final first = fixture.container.read(canvasWorkspaceProvider).activeId;
        final second = canvases.create(duplicate: true);
        gen().updateCharacter('c1', name: '第二张画布', positive: 'second draft');
        canvases.select(first);
        await mount(tester);
        await collapseAll(tester);
        final start = emptyHeader(tester, 'c1');
        final end = Offset(
          start.dx,
          tester.getBottomLeft(key('charc3')).dy + 40,
        );
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(0, 4));
        await tester.pump();
        expect(inList('c1'), isFalse);
        for (var step = 1; step <= 6; step++) {
          await mouse.moveTo(Offset.lerp(start, end, step / 6)!);
          await tester.pump(const Duration(milliseconds: 20));
        }
        canvases.select(second);
        if (!immediate) {
          await tester.pumpAndSettle();
        }
        await mouse.up();
        await tester.pumpAndSettle();
        expect(order(), ['c1', 'c2', 'c3']);
        expect(character('c1').name, '第二张画布');
        expect(character('c1').positive, 'second draft');
        expect(nameInput('c1'), findsNothing);
        canvases.select(first);
        await tester.pumpAndSettle();
        expect(order(), ['c1', 'c2', 'c3']);
        expect(character('c1').name, '角色甲');
        expect(character('c1').positiveRaw, 'traveler, ~hat~, blue sky');
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }
}

void desktopTest(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
