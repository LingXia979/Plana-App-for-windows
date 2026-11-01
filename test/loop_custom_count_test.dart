import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/cost.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/loop_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/generate/widgets/loop_sheet.dart';
import 'support/desktop_capture.dart';

class _Balance extends AnlasNotifier {
  @override
  Future<NaiSubscription?> build() async => null;
}

class _Loop extends LoopNotifier {
  int? startedWith;
  @override
  Future<void> start() async {
    startedWith = ref.read(generateProvider).params.loopCount;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesktopCaptureFonts);
  late AppStores stores;
  late ProviderContainer container;
  late GenerateNotifier gen;
  late _Loop loop;
  setUp(() {
    stores = AppStores.ephemeral();
    loop = _Loop();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        anlasProvider.overrideWith(_Balance.new),
        loopStatusProvider.overrideWith(() => loop),
      ],
    );
    gen = container.read(generateProvider.notifier);
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });

  test(
    'custom count survives preset switches and saved state round trips',
    () async {
      gen.setCustomLoopCount(37);
      gen.setLoop(LoopCount.custom);
      expect(gen.state.params.loopCount, 37);
      gen.setLoop(LoopCount.x4);
      expect(gen.state.params.loopCount, 4);
      gen.setLoop(LoopCount.infinite);
      expect(gen.state.params.loopCount, 0);
      final encoded = await encodeGenerateState(gen.state, stores.blobs);
      final restored = await decodeGenerateState(encoded.json, stores.blobs);
      expect(restored.params.loop, LoopCount.infinite);
      expect(restored.params.copyWith(loop: LoopCount.custom).loopCount, 37);
      gen.applyParams(restored.params.copyWith(loop: LoopCount.custom));
      final again = await decodeGenerateState(
        (await encodeGenerateState(gen.state, stores.blobs)).json,
        stores.blobs,
      );
      expect(again.params.loopCount, 37);
    },
  );

  test(
    'legacy presets and malformed custom values never become infinite',
    () async {
      for (final entry in {
        LoopCount.x4: 4,
        LoopCount.x8: 8,
        LoopCount.x16: 16,
        LoopCount.infinite: 0,
      }.entries) {
        final back = await decodeGenerateState({
          'params': {'loop': entry.key.name},
        }, stores.blobs);
        expect(back.params.loopCount, entry.value);
      }
      for (final value in [null, 0, -1, 1.5, '12', true, 10000]) {
        final back = await decodeGenerateState({
          'params': {'loop': 'custom', 'customLoopCount': value},
        }, stores.blobs);
        expect(back.params.loopCount, kDefaultCustomLoopCount);
      }
      for (final value in [1, 9999]) {
        gen.setCustomLoopCount(value);
        gen.setLoop(LoopCount.custom);
        expect(gen.state.params.loopCount, value);
      }
      expect(() => gen.setCustomLoopCount(0), throwsArgumentError);
      expect(gen.state.params.loopCount, 9999);
    },
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('打开循环'));
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    testWidgets(
      'custom count controls estimate, validation and start at narrow width; dark=$dark',
      (tester) async {
        final capture = GlobalKey();
        final theme = dark ? AppTheme.dark() : AppTheme.light();
        tester.view.physicalSize = const Size(320, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme.copyWith(
                  textTheme: theme.textTheme.apply(
                    fontFamily: 'Microsoft YaHei',
                  ),
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showLoopSheet(context),
                      child: const Text('打开循环'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await open(tester);
        await tester.tap(find.text('自定义'));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('custom-loop-count'));
        await tester.enterText(field, '7');
        await tester.pumpAndSettle();
        final cost = estimateCost(gen.state, isOpus: false, v5Charged: false);
        expect(find.text('$cost/张 · 共 ${cost * 7} Anlas'), findsOneWidget);
        expect(find.text('开始循环 ×7'), findsOneWidget);
        await captureDesktop(
          tester,
          capture,
          'loop-custom-${dark ? 'dark' : 'light'}',
        );
        for (final value in ['', '0', '-2', '1.5', 'abc', '10000']) {
          await tester.enterText(field, value);
          await tester.pump();
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, '请填写生成张数'),
                )
                .onPressed,
            isNull,
          );
          expect(gen.state.params.customLoopCount, 7);
        }
        await tester.tap(find.text('4'));
        await tester.pumpAndSettle();
        expect(find.text('开始循环 ×4'), findsOneWidget);
        await tester.tap(find.text('自定义'));
        await tester.pumpAndSettle();
        await tester.enterText(field, '7');
        await tester.pump();
        Navigator.of(tester.element(field)).pop();
        await tester.pumpAndSettle();
        await open(tester);
        expect(tester.widget<TextField>(field).controller!.text, '7');
        await tester.ensureVisible(find.text('开始循环 ×7'));
        await tester.tap(find.text('开始循环 ×7'));
        await tester.pumpAndSettle();
        expect(loop.startedWith, 7);
        expect(find.text('循环生成'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}
