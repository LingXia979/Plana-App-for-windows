import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/widgets/primary_mouse_drag.dart';

void main() {
  testWidgets(
    'immediate mouse dragging competes correctly with clicks and double clicks',
    (tester) async {
      var taps = 0, doubles = 0, drags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RawGestureDetector(
              gestures: {
                PrimaryMouseDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      PrimaryMouseDragGestureRecognizer
                    >(
                      PrimaryMouseDragGestureRecognizer.new,
                      (recognizer) => recognizer.onStart = (_) => drags++,
                    ),
              },
              child: GestureDetector(
                onTap: () => taps++,
                onDoubleTap: () => doubles++,
                child: const SizedBox(
                  width: 160,
                  height: 160,
                  child: ColoredBox(
                    key: ValueKey('mouse-target'),
                    color: Colors.blue,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final point = tester.getCenter(
        find.byKey(const ValueKey('mouse-target')),
      );
      var mouse = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(3, 0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(drags, 0);
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 350));
      expect(taps, 1);

      for (var i = 0; i < 2; i++) {
        mouse = await tester.startGesture(point, kind: PointerDeviceKind.mouse);
        await mouse.up();
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(doubles, 1);
      expect(taps, 1);
      expect(drags, 0);
      await tester.pump(const Duration(milliseconds: 350));

      mouse = await tester.startGesture(point, kind: PointerDeviceKind.mouse);
      await mouse.moveBy(const Offset(0, 5));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 350));
      expect(drags, 1);
      expect(taps, 1);
      expect(doubles, 1);
    },
  );
}
