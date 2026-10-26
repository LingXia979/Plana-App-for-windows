import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';
import 'package:plana_app/features/generate/widgets/prompt_card.dart';

import 'support/character_avatar_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CharacterAvatarFixture fixture;
  late ScrollController scroll;
  final viewportKey = GlobalKey();
  Finder key(String id) => find.byKey(ValueKey(id));
  GenerateNotifier gen() => fixture.container.read(generateProvider.notifier);

  setUp(() async {
    fixture = CharacterAvatarFixture();
    await fixture.initialize();
    scroll = ScrollController();
    gen().setModel('NAI 5.0 Full');
    gen().applyCanvas(
      CanvasPrompts.of(fixture.container.read(generateProvider)).copyWith(
        sections: [
          const PromptSection.main(),
          for (var i = 1; i <= 5; i++)
            PromptSection(id: 's$i', name: '分区 $i', positive: 'forest $i'),
        ],
        characters: [
          for (var i = 0; i <= 5; i++)
            CharacterPrompt(id: 'c$i', name: '角色 $i', positive: 'traveler $i'),
        ],
      ),
      force: true,
    );
  });
  tearDown(() async {
    scroll.dispose();
    await fixture.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 520,
              child: Column(
                children: [
                  const SizedBox(height: 60, child: Text('固定顶部')),
                  Expanded(
                    child: SizedBox(
                      key: viewportKey,
                      child: Scrollbar(
                        controller: scroll,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: scroll,
                          child: const Column(
                            children: [
                              SizedBox(height: 350, child: Text('前面的模块')),
                              PromptCard(key: ValueKey('prompt-group')),
                              SizedBox(height: 16),
                              CharacterCard(key: ValueKey('character-group')),
                              SizedBox(height: 900, child: Text('后面的模块')),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 70, child: Text('固定底部')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect viewport(WidgetTester tester) => tester.getRect(find.byKey(viewportKey));
  Rect group(WidgetTester tester, bool role) =>
      tester.getRect(key(role ? 'character-group' : 'prompt-group'));
  Finder header(String id, bool role) =>
      key(role ? 'character-header-$id' : 'prompt-section-header-$id');
  List<String> order(bool role) {
    final state = fixture.container.read(generateProvider);
    return role
        ? state.characters.map((c) => c.id).toList()
        : state.sections.map((s) => s.id).toList();
  }

  Future<void> frames(WidgetTester tester, int count) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await pumpUntilComplete(tester, fixture.stores.flushForExit());
    tester.view.reset();
  }

  Offset grab(WidgetTester tester, String id, bool role) {
    final box = tester.getRect(header(id, role));
    if (!role) return box.centerRight - const Offset(18, 0);
    final avatar = tester.getRect(key('character-avatar-$id'));
    final button = tester.getRect(key('character-fullscreen-$id'));
    return Offset(button.left - 20, avatar.center.dy);
  }

  for (final role in [false, true]) {
    testWidgets(
      '${role ? 'characters' : 'sections'} accelerate smoothly and stop without inertia',
      (tester) async {
        await mount(tester);
        final id = order(role).first;
        scroll.jumpTo(
          scroll.offset + group(tester, role).top - viewport(tester).top - 8,
        );
        await tester.pumpAndSettle();
        final mouse = await tester.startGesture(
          grab(tester, id, role),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(0, 4));
        await tester.pump();
        await mouse.moveTo(Offset(250, viewport(tester).bottom - 2));
        final steps = <double>[];
        for (var i = 0; i < 12; i++) {
          final before = scroll.offset;
          await tester.pump(const Duration(milliseconds: 20));
          steps.add(scroll.offset - before);
        }
        final movingSteps = steps.where((d) => d > .01).toList();
        expect(movingSteps.length, greaterThan(8));
        expect(movingSteps.last, greaterThan(movingSteps.first * 2));
        expect(movingSteps, everyElement(lessThanOrEqualTo(16.01)));
        await mouse.moveTo(viewport(tester).center);
        final stopped = scroll.offset;
        await frames(tester, 30);
        expect(scroll.offset, closeTo(stopped, .01));
        await mouse.cancel();
        await tester.pumpAndSettle();
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );

    testWidgets(
      '${role ? 'characters' : 'sections'} unequal rows settle without changing proxy size or folding',
      (tester) async {
        await mount(tester);
        final initial = order(role);
        final first = initial.first;
        final second = initial[1];
        scroll.jumpTo(
          scroll.offset + group(tester, role).top - viewport(tester).top - 8,
        );
        await tester.pumpAndSettle();
        await tester.tapAt(
          grab(tester, second, role),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        Finder row(String id) => key(role ? 'char$id' : 'sec$id');
        final small = tester.getSize(row(second));
        expect(
          tester.getSize(row(first)).height,
          greaterThan(small.height + 50),
        );
        final start = grab(tester, second, role);
        final firstRect = tester.getRect(row(first));
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(0, -4));
        await tester.pump();
        await mouse.moveTo(Offset(start.dx, firstRect.top + 45));
        await frames(tester, 20);
        expect(tester.getSize(row(second)), small);
        final settled = tester.getTopLeft(row(first));
        for (var i = 0; i < 20; i++) {
          // Repeated real drag updates at the same location must not oscillate
          // as a tall neighbor animates around a short placeholder.
          await mouse.moveTo(Offset(start.dx, firstRect.top + 45));
          await tester.pump(const Duration(milliseconds: 30));
          expect(tester.getTopLeft(row(first)), settled);
        }
        await mouse.up();
        await tester.pumpAndSettle();
        expect(order(role), [second, first, ...initial.skip(2)]);
        // Character rows omit the 9px inter-card gap when moved to the top.
        expect(
          tester.getSize(row(second)),
          Size(small.width, small.height - (role ? 9 : 0)),
        );
        expect(
          tester.getSize(row(first)).height,
          greaterThan(small.height + 50),
        );
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );

    testWidgets(
      '${role ? 'characters' : 'sections'} scroll in a wider band and through fixed bars without hover popups',
      (tester) async {
        await mount(tester);
        final id = order(role).first;
        scroll.jumpTo(
          scroll.offset + group(tester, role).top - viewport(tester).top - 8,
        );
        await tester.pumpAndSettle();
        final start = grab(tester, id, role);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: start);
        await mouse.moveTo(start);
        await frames(tester, 40);
        expect(find.textContaining('按住拖动排序'), findsWidgets);
        await mouse.down(start);
        await mouse.moveBy(const Offset(0, 4));
        await tester.pump();
        final top = scroll.offset;
        await mouse.moveTo(Offset(250, viewport(tester).bottom - 65));
        await frames(tester, 25);
        expect(scroll.offset, greaterThan(top + 15));
        expect(find.textContaining('按住拖动排序'), findsNothing);

        // Overshooting the list into the fixed footer must keep scrolling,
        // even when the pointer stops moving there.
        final beforeFooter = scroll.offset;
        await mouse.moveTo(Offset(250, viewport(tester).bottom + 40));
        await frames(tester, 25);
        expect(scroll.offset, greaterThan(beforeFooter + 100));
        expect(find.textContaining('按住拖动排序'), findsNothing);

        final beforeHeader = scroll.offset;
        await mouse.moveTo(Offset(250, viewport(tester).top - 30));
        await frames(tester, 20);
        expect(scroll.offset, lessThan(beforeHeader - 80));
        await mouse.moveTo(const Offset(250, -10));
        final outside = scroll.offset;
        await frames(tester, 20);
        expect(scroll.offset, closeTo(outside, .01));
        await mouse.cancel();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );

    testWidgets(
      '${role ? 'characters' : 'sections'} continuously scroll both ways, reorder and stop at group boundaries',
      (tester) async {
        await mount(tester);
        final initial = order(role);
        final id = initial.first;
        final top =
            scroll.offset + group(tester, role).top - viewport(tester).top - 8;
        scroll.jumpTo(top);
        await tester.pumpAndSettle();
        final mouse = await tester.startGesture(
          role
              ? tester.getCenter(key('character-name-$id'))
              : grab(tester, id, role),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(0, 4));
        await tester.pump();
        final bottomEdge = Offset(250, viewport(tester).bottom - 2);
        await mouse.moveTo(bottomEdge);
        await frames(tester, 20);
        final intermediate = scroll.offset;
        expect(intermediate, greaterThan(top + 30));
        await frames(tester, 300); // Keep pointer still; no wheel events.
        final bottom = scroll.offset;
        expect(bottom, greaterThan(intermediate + 30));
        expect(
          group(tester, role).bottom,
          closeTo(viewport(tester).bottom - 8, 1),
        );
        await frames(tester, 35);
        expect(scroll.offset, closeTo(bottom, .01));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(order(role), [...initial.skip(1), id]);
        await frames(tester, 30);
        expect(scroll.offset, closeTo(bottom, .01));

        // Reuse the same mouse to drag the last item back above all others.
        await mouse.down(grab(tester, id, role));
        await mouse.moveBy(const Offset(0, -4));
        await tester.pump();
        await mouse.moveTo(Offset(250, viewport(tester).top + 2));
        await frames(tester, 320);
        expect(group(tester, role).top, closeTo(viewport(tester).top + 8, 1));
        final upper = scroll.offset;
        await frames(tester, 35);
        expect(scroll.offset, closeTo(upper, .01));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(order(role), initial);
        expect(
          order(!role),
          role
              ? ['main', 's1', 's2', 's3', 's4', 's5']
              : ['c0', 'c1', 'c2', 'c3', 'c4', 'c5'],
        );
        // Ordinary sidebar scrolling remains unrestricted after the drag.
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: viewport(tester).center,
            scrollDelta: const Offset(0, -240),
          ),
        );
        await tester.pumpAndSettle();
        expect(scroll.offset, lessThan(upper));
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  for (final role in [false, true]) {
    for (final ending in ['cancel', 'canvas', 'delete', 'unmount']) {
      testWidgets(
        '${role ? 'characters' : 'sections'} stop outside the edge and after $ending',
        (tester) async {
          final canvases = fixture.container.read(
            canvasWorkspaceProvider.notifier,
          );
          final first = fixture.container
              .read(canvasWorkspaceProvider)
              .activeId;
          final second = canvases.create(duplicate: true);
          canvases.select(first);
          await mount(tester);
          final initial = order(role);
          final id = initial.first;
          scroll.jumpTo(
            scroll.offset + group(tester, role).top - viewport(tester).top - 8,
          );
          await tester.pumpAndSettle();
          final mouse = await tester.startGesture(
            grab(tester, id, role),
            kind: PointerDeviceKind.mouse,
          );
          await mouse.moveBy(const Offset(0, 4));
          await tester.pump();
          await mouse.moveTo(Offset(250, viewport(tester).bottom - 2));
          await frames(tester, 25);
          final moving = scroll.offset;
          await mouse.moveTo(viewport(tester).center);
          await frames(tester, 25);
          expect(scroll.offset, closeTo(moving, .01));
          await mouse.moveTo(
            Offset(viewport(tester).right + 25, viewport(tester).bottom - 2),
          );
          await frames(tester, 25);
          expect(scroll.offset, closeTo(moving, .01));
          await mouse.moveTo(Offset(250, viewport(tester).bottom - 2));
          await frames(tester, 25);
          expect(scroll.offset, greaterThan(moving + 30));
          if (ending == 'canvas') {
            canvases.select(second);
          } else if (ending == 'delete') {
            if (role) {
              gen().removeCharacter(id);
            } else {
              gen().removeSection(id);
            }
          } else if (ending == 'unmount') {
            await tester.pumpWidget(const SizedBox());
          } else {
            await mouse.cancel();
          }
          await tester.pumpAndSettle();
          final stopped = scroll.hasClients ? scroll.offset : null;
          await frames(tester, 40);
          if (stopped == null) {
            expect(scroll.hasClients, isFalse);
          } else {
            expect(scroll.offset, closeTo(stopped, .01));
          }
          if (ending != 'cancel') {
            await mouse.up();
            await tester.pumpAndSettle();
          }
          if (ending == 'canvas') {
            expect(order(role), initial);
            canvases.select(first);
            await tester.pumpAndSettle();
            expect(order(role), initial);
          }
          expect(tester.takeException(), isNull);
          await finish(tester);
        },
        variant: TargetPlatformVariant({TargetPlatform.windows}),
      );
    }
    testWidgets(
      '${role ? 'characters' : 'sections'} single card never auto scrolls',
      (tester) async {
        final prompts = CanvasPrompts.of(
          fixture.container.read(generateProvider),
        );
        gen().applyCanvas(
          prompts.copyWith(
            sections: prompts.sections.take(1).toList(),
            characters: prompts.characters.take(1).toList(),
          ),
          force: true,
        );
        await mount(tester);
        tester.view.physicalSize = const Size(900, 300);
        await tester.pumpAndSettle();
        scroll.jumpTo(
          scroll.offset + group(tester, role).top - viewport(tester).top - 8,
        );
        await tester.pumpAndSettle();
        final id = order(role).single;
        final before = scroll.offset;
        final mouse = await tester.startGesture(
          grab(tester, id, role),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveBy(const Offset(0, 4));
        await tester.pump();
        await mouse.moveTo(Offset(250, viewport(tester).bottom - 2));
        await frames(tester, 45);
        expect(scroll.offset, closeTo(before, .01));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(order(role), [id]);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );
  }
}
