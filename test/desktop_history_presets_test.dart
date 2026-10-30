import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/res_presets.dart';
import 'package:plana_app/features/generate/widgets/desktop_canvas_tabs.dart';
import 'package:plana_app/features/generate/widgets/resolution_sheet.dart';
import 'package:plana_app/features/lora/lora_manager_page.dart';
import 'package:plana_app/features/lora/lora_providers.dart';
import 'package:plana_app/features/lora/lora_stacks.dart';
import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

class _Library extends InstalledLoras {
  _Library(super.base);
  @override
  Future<List<LoraCardInfo>> build() async => const [
    LoraCardInfo(
      name: 'LR1',
      displayName: '测试画风',
      triggerWords: ['style'],
      favorited: true,
    ),
  ];
}

class _RecoverableStacks extends LoraStacksNotifier {
  int builds = 0;
  @override
  Future<List<LoraStack>> build() async {
    builds++;
    return const [];
  }

  void fail() => state = AsyncError(
    StateError('temporary disk failure'),
    StackTrace.current,
  );
}

void main() {
  late AppStores stores;
  late ProviderContainer c;
  final capture = GlobalKey();
  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    stores = AppStores.ephemeral();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        installedLorasProvider('anima').overrideWith(() => _Library('anima')),
      ],
    );
  });
  tearDown(() => c.dispose());
  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
              body: Builder(
                builder: (context) => Column(
                  children: [
                    const SizedBox(width: 380, child: DesktopCanvasTabs()),
                    const Spacer(),
                    Builder(
                      builder: (button) => TextButton(
                        onPressed: () => showResolutionSheet(button),
                        child: const Text('尺寸'),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const LoraManagerPage(),
                        ),
                      ),
                      child: const Text('LoRA'),
                    ),
                  ],
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
    await pumpUntilComplete(tester, stores.flushForExit());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  }

  Future<void> history(WidgetTester tester, String id) async {
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(tester.getCenter(key('desktop-canvas-$id')));
    await mouse.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('画布历史'));
    await pumpUntil(
      tester,
      () => find.text('rain, moon').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop history restores, undoes and copies without popping the workspace',
    (tester) async {
      final gen = c.read(generateProvider.notifier);
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final id = c.read(canvasWorkspaceProvider).activeId;
      gen.setPrompts(positive: 'rain, moon');
      await pumpUntilComplete(
        tester,
        stores.history.record(id, CanvasPrompts.of(c.read(generateProvider)), [
          'r1',
        ]),
      );
      gen.setPrompts(positive: 'new draft');
      await mount(tester);
      await history(tester, id);
      await captureDesktop(tester, capture, 'batch7-canvas-history');
      await tester.tap(find.text('rain, moon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复到这版'));
      await pumpUntil(
        tester,
        () => c.read(generateProvider).prompt == 'rain, moon',
      );
      await tester.pumpAndSettle();
      expect(find.byType(DesktopCanvasTabs), findsOneWidget);
      expect(find.text('默认画布 · 历史'), findsNothing);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).prompt, 'new draft');
      await history(tester, id);
      await tester.tap(find.text('rain, moon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制为新画布'));
      await pumpUntil(
        tester,
        () => c.read(canvasWorkspaceProvider).canvases.length == 2,
      );
      await tester.pumpAndSettle();
      expect(c.read(generateProvider).prompt, 'rain, moon');
      canvases.select(id);
      expect(c.read(generateProvider).prompt, 'new draft');
      await finish(tester);
    },
  );

  testWidgets(
    'desktop custom size saves to Mine and mouse delete removes last tab safely',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('尺寸'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      await tester.enterText(key('resolution-width'), '896.5');
      await tester.enterText(key('resolution-height'), '1152');
      await tester.ensureVisible(key('resolution-save-preset'));
      await tester.tap(key('resolution-save-preset'));
      await pumpUntil(tester, () => find.text('我的').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () => find.byTooltip('删除尺寸预设').evaluate().isNotEmpty,
      );
      await captureDesktop(tester, capture, 'batch7-personal-size');
      expect(c.read(resPresetsProvider).single.width, 896);
      expect(c.read(resPresetsProvider).single.height, 1152);
      await tester.tap(find.byTooltip('删除尺寸预设'));
      await pumpUntil(tester, () => c.read(resPresetsProvider).isEmpty);
      await tester.pumpAndSettle();
      expect(find.text('我的'), findsNothing);
      expect(
        tester.widget<TextField>(key('resolution-width')).controller!.text,
        '896',
      );
      await finish(tester);
    },
  );

  testWidgets('LoRA stack error retry reloads local combinations', (
    tester,
  ) async {
    c.dispose();
    final stacks = _RecoverableStacks();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        installedLorasProvider('anima').overrideWith(() => _Library('anima')),
        loraStacksProvider.overrideWith(() => stacks),
      ],
    );
    await pumpUntilComplete(tester, c.read(loraStacksProvider.future));
    await mount(tester);
    await tester.tap(find.text('LoRA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LoRA 堆'));
    await tester.pumpAndSettle();
    stacks.fail();
    await tester.pumpAndSettle();
    expect(find.text('LoRA 组合无法读取，原文件已保留'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(stacks.builds, 2);
    expect(find.text('LoRA 组合无法读取，原文件已保留'), findsNothing);
    await finish(tester);
  });

  testWidgets(
    'LoRA stack tab applies saved weights and keeps download placeholders',
    (tester) async {
      c.read(generateProvider.notifier).setModel('Anima');
      await pumpUntilComplete(
        tester,
        c
            .read(loraStacksProvider.notifier)
            .save(
              name: '画风组合',
              base: 'anima',
              loras: const [
                LoraStackEntry(
                  name: 'LR1',
                  displayName: '旧名称',
                  weight: 1.2,
                  clipWeight: .4,
                ),
              ],
            ),
      );
      c.read(generateProvider.notifier).applyLoraSelection(const [
        ActiveLora(
          name: 'pending:9',
          displayName: '下载中',
          pending: LoraPending(versionId: 9),
        ),
      ]);
      await mount(tester);
      await tester.tap(find.text('LoRA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('LoRA 堆'));
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'batch7-lora-stacks');
      expect(find.text('画风组合'), findsOneWidget);
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      final loras = c.read(generateProvider).loras;
      expect(loras.map((l) => l.name), ['pending:9', 'LR1']);
      expect(loras.last.displayName, '测试画风');
      expect(loras.last.weight, 1.2);
      expect(loras.last.clipWeight, .4);
      expect(find.byType(DesktopCanvasTabs), findsOneWidget);
      await finish(tester);
    },
  );
}
