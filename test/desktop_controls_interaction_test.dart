import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/ui/param_input.dart';
import 'package:plana_app/features/generate/widgets/reference_strip.dart';

void main() {
  testWidgets(
    'normal wheel over references scrolls the sidebar; Shift+wheel stays horizontal',
    (tester) async {
      final vertical = ScrollController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [desktopModeProvider.overrideWithValue(true)],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: SizedBox(
                width: 280,
                child: ListView(
                  controller: vertical,
                  children: [
                    ReferenceStrip(
                      items: [
                        for (var i = 0; i < 8; i++)
                          (id: '$i', image: null, enabled: true),
                      ],
                      selectedId: '0',
                      onSelect: (_) {},
                      onReorder: (_, _) {},
                    ),
                    const SizedBox(height: 1200),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final horizontal = tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .scrollController!;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ReferenceStrip)),
          scrollDelta: const Offset(0, 30),
        ),
      );
      await tester.pumpAndSettle();
      expect(vertical.offset, 30);
      expect(horizontal.offset, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ReferenceStrip)),
          scrollDelta: const Offset(0, 60),
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(vertical.offset, 30);
      expect(horizontal.offset, 60);
      await tester.pumpWidget(const SizedBox());
      vertical.dispose();
    },
  );

  testWidgets(
    'inline parameter preserves decimals, validates, and Escape cancels',
    (tester) async {
      var value = .6;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  InlineParamInput(
                    label: '强度',
                    value: value,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    onCommit: (next) => setState(() => value = next),
                  ),
                  const TextField(key: ValueKey('outside')),
                ],
              ),
            ),
          ),
        ),
      );
      final input = find.byKey(const ValueKey('inline-param-强度'));
      await tester.tap(input);
      expect(find.byType(Dialog), findsNothing);
      await tester.enterText(input, '0.427');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(value, .427);
      await tester.enterText(input, '12');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(value, .427);
      expect(find.byTooltip('请输入 0 ～ 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '0.43');
      await tester.enterText(input, '0.8');
      await tester.tap(find.byKey(const ValueKey('outside')));
      await tester.pump();
      expect(value, .8);
      await tester.enterText(input, '1.00');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '1.00');
      await tester.enterText(input, '0.70');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '0.70');
    },
  );

  testWidgets(
    'mouse click selects edges, 100 ms hold reorders, arrows reveal and Shift+wheel scrolls',
    (tester) async {
      var items = [
        for (var i = 0; i < 8; i++)
          (id: '$i', image: null as Uint8List?, enabled: true),
      ];
      var selected = '0';
      var reorders = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [desktopModeProvider.overrideWithValue(true)],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    SizedBox(
                      width: 260,
                      child: ReferenceStrip(
                        items: items,
                        selectedId: selected,
                        onSelect: (id) => setState(() => selected = id),
                        onReorder: (a, b) => setState(() {
                          final next = [...items];
                          final item = next.removeAt(a);
                          next.insert(b, item);
                          items = next;
                          reorders++;
                        }),
                      ),
                    ),
                    const TextField(key: ValueKey('text')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final second = find.byKey(const ValueKey('1'));
      final rect = tester.getRect(second);
      final click = await tester.startGesture(
        rect.topLeft + const Offset(7, 9),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 40));
      await click.up();
      await tester.pumpAndSettle();
      expect(selected, '1');
      expect(reorders, 0);
      final drag = await tester.startGesture(
        tester.getCenter(second),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 110));
      for (var i = 0; i < 7; i++) {
        await drag.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 250));
      await drag.up();
      await tester.pumpAndSettle();
      expect(reorders, 1);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
      }
      expect(selected, '7');
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      final scroll = list.scrollController!;
      expect(scroll.offset, greaterThan(0));
      final beforeWheel = scroll.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ReferenceStrip)),
          scrollDelta: const Offset(0, -70),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        scroll.offset,
        beforeWheel,
        reason: 'Ordinary wheel must not move references',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ReferenceStrip)),
          scrollDelta: const Offset(0, -70),
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(scroll.position.maxScrollExtent));
      await tester.tap(find.byKey(const ValueKey('text')));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(selected, '7');
    },
  );
}
