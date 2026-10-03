import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/resolution_sheet.dart';
import 'support/desktop_capture.dart';

void main() {
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() {
    c.dispose();
    stores.flushNow();
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    c.read(generateProvider.notifier).setSize(832, 1216);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(
                  width: 320,
                  child: MediaQuery(
                    data: const MediaQueryData(size: Size(320, 700)),
                    child: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showResolutionSheet(context),
                        child: const Text('打开分辨率'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开分辨率'));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'resolution popover anchors above its button and applies presets',
    (tester) async {
      await mount(tester);
      expect(find.byType(BottomSheet), findsNothing);
      final surface = key('desktop-popover');
      final rect = tester.getRect(surface);
      expect(rect.width, 340);
      expect(rect.left, 12);
      expect(rect.bottom, lessThan(tester.getTopLeft(find.text('打开分辨率')).dy));
      expect(
        tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color?.a ??
            0,
        0,
      );
      await captureDesktop(tester, capture, 'windows16-resolution-presets');
      await tester.tap(find.text('横图').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(key('resolution-confirm'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).params.width, 1216);
      expect(c.read(generateProvider).params.height, 832);
      expect(key('desktop-popover'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'manual dimensions truncate decimals before snapping, swap and validate',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'windows16-resolution-custom');
      await tester.enterText(key('resolution-width'), '863.9');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '832',
      );
      await tester.enterText(key('resolution-height'), '1024.8');
      // Confirm without submitting the text field must still use the draft.
      await tester.tap(key('resolution-confirm'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).params.width, 832);
      expect(c.read(generateProvider).params.height, 1024);
      await tester.tap(find.text('打开分辨率'));
      await tester.pumpAndSettle();
      await tester.enterText(key('resolution-width'), 'NaN');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(key('resolution-confirm')).onPressed,
        isNull,
      );
      await tester.enterText(key('resolution-width'), '3072');
      await tester.enterText(key('resolution-height'), '3072');
      await tester.pumpAndSettle();
      expect(find.text('超出像素上限'), findsOneWidget);
      await tester.enterText(key('resolution-width'), '832');
      await tester.enterText(key('resolution-height'), '1216');
      await tester.tap(find.byTooltip('交换宽高').hitTestable());
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '1216',
      );
      expect(
        tester.widget<TextField>(key('resolution-height')).controller!.text,
        '832',
      );
      tester.view.physicalSize = const Size(720, 500);
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('resolution-confirm'));
      await tester.tap(key('resolution-confirm'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).params.width, 1216);
      expect(c.read(generateProvider).params.height, 832);
      await finish(tester);
    },
  );

  testWidgets('Escape and outside click discard unconfirmed dimensions', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('横图'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(key('desktop-popover'), findsNothing);
    expect(c.read(generateProvider).params.width, 832);
    await tester.tap(find.text('打开分辨率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(key('resolution-width'), '1024');
    await tester.tapAt(const Offset(900, 50));
    await tester.pumpAndSettle();
    expect(key('desktop-popover'), findsNothing);
    expect(c.read(generateProvider).params.width, 832);
    await finish(tester);
  });
}
