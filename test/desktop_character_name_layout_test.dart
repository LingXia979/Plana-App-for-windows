import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'support/character_avatar_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CharacterAvatarFixture fixture;
  GenerateNotifier gen() => fixture.container.read(generateProvider.notifier);
  Finder key(String id) => find.byKey(ValueKey(id));
  setUp(() async {
    fixture = CharacterAvatarFixture();
    await fixture.initialize();
    gen().applyCanvas(
      CanvasPrompts.of(fixture.container.read(generateProvider)).copyWith(
        characters: const [
          CharacterPrompt(id: 'a', name: '凉', positive: 'blue sky'),
          CharacterPrompt(id: 'b', name: '角色 2', positive: 'forest'),
        ],
      ),
      force: true,
    );
  });
  tearDown(() async => fixture.dispose());
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await pumpUntilComplete(tester, fixture.stores.flushForExit());
    tester.view.reset();
  }

  bool sameRow(WidgetTester tester, String id) =>
      tester.getRect(key('character-fullscreen-$id')).top <
      tester.getRect(key('character-avatar-$id')).bottom;

  testWidgets(
    'short names keep narrow controls on one row; longest actual name updates the threshold',
    (tester) async {
      // The test font is wider than YaHei; real-font captures also check 340px.
      await fixture.mount(tester, width: 360);
      expect(sameRow(tester, 'a'), isTrue);
      expect(sameRow(tester, 'b'), isTrue);
      gen().updateCharacter('b', name: '一二三四五六七八九十更多');
      await tester.pumpAndSettle();
      expect(sameRow(tester, 'a'), isFalse);
      expect(sameRow(tester, 'b'), isFalse);
      gen().removeCharacter('b');
      await tester.pumpAndSettle();
      expect(sameRow(tester, 'a'), isTrue);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  for (final text in [
    '一二三四五六七八九十后续',
    '1234567890ABC',
    '👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦尾',
  ]) {
    testWidgets(
      'display ten graphemes but edit the full name: $text',
      (tester) async {
        gen().updateCharacter('a', name: text);
        await fixture.mount(tester, width: 600);
        expect(find.text('${text.characters.take(10)}…'), findsOneWidget);
        await tester.tap(key('character-name-a'));
        await tester.pumpAndSettle();
        final editor = tester.widget<TextField>(key('character-name-a-editor'));
        expect(editor.controller!.text, text);
        expect(
          editor.controller!.selection,
          TextSelection(baseOffset: 0, extentOffset: text.length),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          fixture.container.read(generateProvider).characters.first.name,
          text,
        );
        gen().updateCharacter('a', name: text.characters.take(10).toString());
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: key('character-name-a'),
            matching: find.text(text.characters.take(10).toString()),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );
  }
}
