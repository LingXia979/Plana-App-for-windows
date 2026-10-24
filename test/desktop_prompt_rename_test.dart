import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';
import 'package:plana_app/features/inspiration/widgets/tag_card.dart';

import 'support/character_avatar_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CharacterAvatarFixture fixture;
  GenerateNotifier gen() => fixture.container.read(generateProvider.notifier);
  GenerateState state() => fixture.container.read(generateProvider);
  CanvasWorkspaceNotifier canvases() =>
      fixture.container.read(canvasWorkspaceProvider.notifier);
  String activeId() => fixture.container.read(canvasWorkspaceProvider).activeId;

  Object payload(CanvasPrompts p) => [
    p.prompt,
    p.promptRaw,
    p.negativePrompt,
    p.negativePromptRaw,
    p.promptFoldLinks,
    p.promptPresetId,
    p.useCoords,
    [
      for (final s in p.sections)
        [
          s.id,
          s.positive,
          s.positiveRaw,
          s.negative,
          s.negativeRaw,
          s.foldLinks,
          s.enabled,
          s.artist,
        ],
    ],
    [
      for (final c in p.characters)
        [
          c.id,
          c.positive,
          c.positiveRaw,
          c.negative,
          c.negativeRaw,
          c.foldLinks,
          c.enabled,
          c.avatar,
          c.position,
          c.activeTab,
        ],
    ],
  ];

  void seed() {
    fixture.setCharacter(fixture.local);
    gen().applyCanvas(
      CanvasPrompts.of(
        state().copyWith(
          prompt: 'forest',
          promptRaw: 'forest, ~hat~',
          negativePrompt: 'lowres',
          negativePromptRaw: 'lowres, ~blur~',
          sections: const [
            PromptSection.main(),
            PromptSection(
              id: 'artist',
              name: '画风名字',
              artist: true,
              positive: 'watercolor',
              negative: 'photo',
            ),
            PromptSection(
              id: 's1',
              name: '重名',
              positive: 'blue sky',
              positiveRaw: 'blue sky, ~hat~',
              negative: 'rain',
              negativeRaw: 'rain, ~blur~',
              enabled: false,
            ),
            PromptSection(id: 's2', name: '重名', positive: 'lake'),
          ],
          characters: [
            state().characters.single.copyWith(name: '重名'),
            const CharacterPrompt(
              id: 'other',
              name: '重名',
              positive: 'other person',
            ),
          ],
        ),
      ),
      force: true,
    );
  }

  setUp(() async {
    fixture = CharacterAvatarFixture();
    await fixture.initialize();
    seed();
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await fixture.dispose();
  });

  Finder label(String id, bool character) => find.byKey(
    ValueKey(character ? 'character-name-$id' : 'prompt-section-name-$id'),
  );
  Finder input(String id, bool character) => find.byKey(
    ValueKey(
      character
          ? 'character-name-$id-editor'
          : 'prompt-section-name-$id-editor',
    ),
  );
  String name(String id, bool character, [String? canvasId]) {
    final p = canvasId == null
        ? CanvasPrompts.of(state())
        : fixture.container
              .read(canvasWorkspaceProvider)
              .find(canvasId)!
              .prompts;
    return character
        ? p.characters.firstWhere((c) => c.id == id).name
        : p.sections.firstWhere((s) => s.id == id).name;
  }

  Future<void> mount(WidgetTester tester, bool character) async {
    await fixture.mount(
      tester,
      child: character ? const CharacterCard() : const PromptCard(),
    );
    if (character) {
      await waitForAvatarImage(tester, find.byType(TagCardPreview).first);
    }
  }

  Future<TextField> begin(
    WidgetTester tester,
    String id,
    bool character,
  ) async {
    await tester.ensureVisible(label(id, character));
    await tester.tap(label(id, character), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final field = tester.widget<TextField>(input(id, character));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(
      field.controller!.selection,
      TextSelection(baseOffset: 0, extentOffset: field.controller!.text.length),
    );
    return field;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    tester.view.reset();
  }

  for (final target in [
    (id: 'main', character: false, fallback: '主体'),
    (id: 'artist', character: false, fallback: '画风'),
    (id: 's1', character: false, fallback: '分区 1'),
    (id: 'avatar', character: true, fallback: '角色 1'),
  ]) {
    testWidgets(
      '${target.id}: single click selects full name, Enter saves, Escape cancels, blank uses fallback',
      (tester) async {
        await mount(tester, target.character);
        final before = CanvasPrompts.of(state());
        await begin(tester, target.id, target.character);
        await tester.enterText(
          input(target.id, target.character),
          '  新的  名称  ',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(name(target.id, target.character), '新的  名称');
        expect(input(target.id, target.character), findsNothing);
        // Naming changes no prompts, raw drafts, flags, avatars or positions.
        final after = CanvasPrompts.of(state());
        expect(payload(after), payload(before));
        expect(after.sampling!.sameAs(before.sampling!), isTrue);
        await begin(tester, target.id, target.character);
        await tester.enterText(input(target.id, target.character), '取消的名称');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(850, 850));
        await tester.pumpAndSettle();
        expect(name(target.id, target.character), '新的  名称');
        await begin(tester, target.id, target.character);
        await tester.enterText(input(target.id, target.character), '   ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(name(target.id, target.character), target.fallback);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  for (final character in [false, true]) {
    final id = character ? 'avatar' : 's1';
    testWidgets(
      '$id: outside click and focus loss save full long name without a length cap',
      (tester) async {
        await mount(tester, character);
        final longName = List.filled(12, '长名称 hello ').join();
        await begin(tester, id, character);
        await tester.enterText(input(id, character), longName);
        await tester.tapAt(const Offset(850, 850));
        await tester.pumpAndSettle();
        expect(name(id, character), longName.trim());
        final field = await begin(tester, id, character);
        expect(field.controller!.text, longName.trim());
        await tester.enterText(input(id, character), '失焦提交');
        field.focusNode!.unfocus();
        await tester.pumpAndSettle();
        expect(name(id, character), '失焦提交');
        await finish(tester);
      },
    );

    testWidgets(
      '$id: Enter confirms IME composition before submitting the rename',
      (tester) async {
        await mount(tester, character);
        await begin(tester, id, character);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'lu',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(input(id, character), findsOneWidget);
        expect(name(id, character), '重名');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '露',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(input(id, character), findsOneWidget);
        expect(name(id, character), '重名');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(name(id, character), '露');
        await finish(tester);
      },
    );

    testWidgets(
      '$id: existing canvas switch flushes the source name without touching equal IDs or names elsewhere',
      (tester) async {
        final first = activeId();
        final second = canvases().create(duplicate: true);
        canvases().select(first);
        await mount(tester, character);
        await begin(tester, id, character);
        await tester.enterText(input(id, character), '第一张画布的名字');
        canvases().select(second);
        // Check before a frame or delayed focus notification can run.
        expect(name(id, character, first), '第一张画布的名字');
        expect(name(id, character, second), '重名');
        await tester.pumpAndSettle();
        expect(input(id, character), findsNothing);
        await begin(tester, id, character);
        await tester.enterText(input(id, character), '第二张画布的名字');
        canvases().select(first);
        await tester.pumpAndSettle();
        expect(name(id, character, first), '第一张画布的名字');
        expect(name(id, character, second), '第二张画布的名字');
        expect(name(character ? 'other' : 's2', character, first), '重名');
        canvases().select(second);
        await tester.pumpAndSettle();
        await begin(tester, id, character);
        await tester.enterText(input(id, character), '删除前提交');
        final removed = canvases().remove(second)!;
        await tester.pumpAndSettle();
        expect(activeId(), first);
        final removedNames = character
            ? removed.canvas.prompts.characters.map((c) => c.name)
            : removed.canvas.prompts.sections.map((s) => s.name);
        expect(removedNames, contains('删除前提交'));
        expect(name(id, character, first), '第一张画布的名字');
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );

    testWidgets(
      '$id: reorder keeps the edit on its ID; deleting it cannot recreate it',
      (tester) async {
        await mount(tester, character);
        await begin(tester, id, character);
        await tester.enterText(input(id, character), '排序后名称');
        if (character) {
          gen().reorderCharacters(0, 1);
        } else {
          gen().reorderSections(2, 1);
        }
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(name(id, character), '排序后名称');
        expect(name(character ? 'other' : 's2', character), '重名');
        await begin(tester, id, character);
        await tester.enterText(input(id, character), '不能写入别处');
        if (character) {
          gen().removeCharacter(id);
        } else {
          gen().removeSection(id);
        }
        await tester.pumpAndSettle();
        fixture.container.read(editorSessionsProvider).flushPending();
        await tester.pumpAndSettle();
        expect(input(id, character), findsNothing);
        expect(
          character
              ? state().characters.any((c) => c.id == id)
              : state().sections.any((s) => s.id == id),
          isFalse,
        );
        expect(name(character ? 'other' : 's2', character), '重名');
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );

    testWidgets(
      '$id: right and middle clicks do not rename; completed names survive store reload',
      (tester) async {
        await mount(tester, character);
        await tester.ensureVisible(label(id, character));
        for (final button in [kSecondaryButton, kMiddleMouseButton]) {
          await tester.tap(
            label(id, character),
            kind: PointerDeviceKind.mouse,
            buttons: button,
          );
          await tester.pumpAndSettle();
          expect(input(id, character), findsNothing);
        }
        await begin(tester, id, character);
        await tester.enterText(input(id, character), '保存到本地');
        fixture.container.read(editorSessionsProvider).flushPending();
        await tester.pumpAndSettle();
        await pumpUntilComplete(tester, fixture.stores.flushForExit());
        await pumpUntilComplete(tester, fixture.stores.workspace.load());
        final reloaded = ProviderContainer(
          overrides: [appStoresProvider.overrideWithValue(fixture.stores)],
        );
        final p = reloaded.read(canvasWorkspaceProvider).active.prompts;
        expect(
          character
              ? p.characters.firstWhere((c) => c.id == id).name
              : p.sections.firstWhere((s) => s.id == id).name,
          '保存到本地',
        );
        reloaded.dispose();
        await finish(tester);
      },
    );
  }

  testWidgets(
    'resizing a character header preserves the in-progress name and selection',
    (tester) async {
      await mount(tester, true);
      final field = await begin(tester, 'avatar', true);
      await tester.enterText(input('avatar', true), '仍在编辑的角色名');
      field.controller!.selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 4,
      );
      await fixture.mount(
        tester,
        child: const CharacterCard(),
        width: 340,
        scale: 1.4,
      );
      final resized = tester.widget<TextField>(input('avatar', true));
      expect(resized.controller, same(field.controller));
      expect(resized.focusNode!.hasFocus, isTrue);
      expect(
        resized.controller!.selection,
        const TextSelection(baseOffset: 1, extentOffset: 4),
      );
      expect(name('avatar', true), '重名');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(name('avatar', true), '仍在编辑的角色名');
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets('multi-select name clicks toggle selection instead of editing', (
    tester,
  ) async {
    await mount(tester, false);
    await tester.tap(find.byKey(const ValueKey('prompt-section-select')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(label('s1', false));
    await tester.tap(label('s1', false));
    await tester.pumpAndSettle();
    expect(input('s1', false), findsNothing);
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('prompt-section-pick-s1')),
          )
          .value,
      isTrue,
    );
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  group('mobile', () {
    setUp(() async {
      await fixture.dispose();
      fixture = CharacterAvatarFixture();
      await fixture.initialize(desktop: false);
      seed();
    });
    for (final character in [false, true]) {
      testWidgets(
        '${character ? 'character' : 'section'} still uses the rename dialog',
        (tester) async {
          await mount(tester, character);
          await tester.tap(find.text('重名').first);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text('重命名'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await finish(tester);
        },
      );
    }
  });
}
