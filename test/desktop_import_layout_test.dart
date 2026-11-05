import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/util/png_meta.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/import/import_panel.dart';
import 'package:plana_app/features/import/import_prefs.dart';
import 'package:plana_app/features/import/image_prompt_import.dart';

class _Presets extends PromptPresetsNotifier {
  @override
  Future<PromptPresetsState> build() async =>
      const PromptPresetsState(presets: kDefaultPromptPresets);

  @override
  Future<void> setActive(String id) async {
    ref.read(generateProvider.notifier).setPromptPreset(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Uint8List plain, metadata;
  setUp(() async {
    stores = AppStores.ephemeral();
    plain = Uint8List.fromList(
      img.encodePng(img.Image(width: 320, height: 480)),
    );
    metadata = await writeImageMetadataPng(
      plain,
      source: 'NovelAI Diffusion V4.5 4BDE2A90',
      comment: {
        'prompt': 'cat girl, cherry blossoms',
        'uc': 'new negative',
        'seed': 4321,
        'steps': 28,
        'scale': 6.5,
        'sampler': 'k_euler',
        'noise_schedule': 'native',
      },
    );
  });
  tearDown(() async {
    container.dispose();
    stores.flushNow();
    await stores.gallery.idle;
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  Future<void> drain(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
    await tester.pumpAndSettle();
  }

  Future<void> mount(
    WidgetTester tester, {
    bool desktop = true,
    bool hasMetadata = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = desktop
        ? const Size(1440, 900)
        : const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(desktop),
        promptPresetsProvider.overrideWith(_Presets.new),
      ],
    );
    container.read(generateProvider.notifier).setPromptPreset('v5-light');
    container
        .read(generateProvider.notifier)
        .setPrompts(positive: 'original', negative: 'keep negative');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ImportImagePanel(
                      bytes: hasMetadata ? metadata : plain,
                      fileName: 'preview.png',
                      displayName: 'preview',
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await drain(
      tester,
      () =>
          find.byType(ImportImagePanel).evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'clicking the import backdrop closes without changing the draft',
    (tester) async {
      await mount(tester);
      final before = container.read(generateProvider);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ImportImagePanel), findsNothing);
      expect(container.read(generateProvider), same(before));
      await finish(tester);
    },
  );

  for (final mode in ImagePromptImportMode.values) {
    testWidgets(
      'image prompt import ${mode.name} keeps its promised section behavior and can undo',
      (tester) async {
        await mount(tester);
        const section = PromptSection(
          id: 'kept',
          name: '原有分区',
          positive: 'cat girl',
          positiveRaw: 'cat girl, ~hidden~',
          negative: 'section negative',
          enabled: false,
        );
        container.read(generateProvider.notifier).replaceSections([
          const PromptSection.main(),
          section,
        ]);
        final before = container.read(generateProvider);
        await tester.tap(key('import-select-负向提示词'));
        final option = find.descendant(
          of: key('image-prompt-import-mode'),
          matching: find.text(mode.label),
        );
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
        await tester.tap(key('desktop-import-confirm'));
        await drain(
          tester,
          () => find.byType(ImportImagePanel).evaluate().isEmpty,
        );
        final after = container.read(generateProvider);
        expect(after.negativePrompt, 'keep negative');
        if (mode == ImagePromptImportMode.addSection) {
          expect(after.prompt, 'original');
          expect(after.sections[1], same(section));
          expect(after.sections.last.name, '图片导入1');
          expect(after.sections.last.positive, 'cat girl, cherry blossoms');
          expect(after.sections.last.negative, isEmpty);
        } else {
          expect(after.prompt, 'cat girl, cherry blossoms');
          if (mode == ImagePromptImportMode.replaceAll) {
            expect(after.sections, isEmpty);
          } else {
            expect(after.sections, before.sections);
          }
        }
        expect(
          container.read(importPrefsProvider).requireValue.promptMode,
          mode,
        );
        await tester.tap(find.text('撤销'));
        await tester.pumpAndSettle();
        expect(container.read(generateProvider).prompt, before.prompt);
        expect(container.read(generateProvider).sections, before.sections);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'repeat image imports remember additional mode and allocate the next named section',
    (tester) async {
      await mount(tester);
      final option = find.descendant(
        of: key('image-prompt-import-mode'),
        matching: find.text('额外添加'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-import-confirm'));
      await drain(
        tester,
        () => find.byType(ImportImagePanel).evaluate().isEmpty,
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await drain(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await tester.tap(key('desktop-import-confirm'));
      await drain(
        tester,
        () => find.byType(ImportImagePanel).evaluate().isEmpty,
      );
      final after = container.read(generateProvider);
      expect(after.prompt, 'original');
      expect(after.sections.map((s) => s.name), ['主体', '图片导入1', '图片导入2']);
      expect(after.sections[1].positive, after.sections[2].positive);
      expect(after.sections[1].negative, after.sections[2].negative);
      await finish(tester);
    },
  );

  testWidgets('cancelling mode selection does not persist it or edit prompts', (
    tester,
  ) async {
    await mount(tester);
    final before = container.read(generateProvider);
    final option = find.descendant(
      of: key('image-prompt-import-mode'),
      matching: find.text('完全覆盖'),
    );
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(container.read(generateProvider), same(before));
    expect(
      container.read(importPrefsProvider).requireValue.promptMode,
      ImagePromptImportMode.replaceMain,
    );
    await finish(tester);
  });

  testWidgets(
    'reverse result uses the selected mode on its original canvas after switching',
    (tester) async {
      await mount(tester, hasMetadata: false);
      final canvases = container.read(canvasWorkspaceProvider.notifier);
      final originalId = container.read(canvasWorkspaceProvider).activeId;
      await tester.tap(find.text('反推提示词'));
      await tester.pumpAndSettle();
      final secondId = canvases.create();
      container
          .read(generateProvider.notifier)
          .setPrompts(positive: 'second canvas');
      // Supply the completed tagger result without calling the live Bot service.
      Navigator.of(
        tester.element(find.byType(AlertDialog)),
      ).pop('original, new tags');
      await tester.pumpAndSettle();
      final option = find.descendant(
        of: key('image-prompt-import-mode'),
        matching: find.text('额外添加'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.tap(key('desktop-import-confirm'));
      await drain(
        tester,
        () => find.byType(ImportImagePanel).evaluate().isEmpty,
      );
      var workspace = container.read(canvasWorkspaceProvider);
      expect(workspace.activeId, secondId);
      expect(container.read(generateProvider).prompt, 'second canvas');
      final original = workspace.find(originalId)!.prompts;
      expect(original.prompt, 'original');
      expect(original.negativePrompt, 'keep negative');
      expect(original.sections.last.name, '图片导入1');
      expect(original.sections.last.positive, 'original, new tags');
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      workspace = container.read(canvasWorkspaceProvider);
      expect(workspace.find(originalId)!.prompts.sections, isEmpty);
      expect(container.read(generateProvider).prompt, 'second canvas');
      await finish(tester);
    },
  );

  for (final presetId in ['v5-light', 'v5-standard']) {
    testWidgets(
      'Medium PNG import selects effort without replacing High sampling: $presetId',
      (tester) async {
        final preset = kDefaultPromptPresets.firstWhere(
          (p) => p.id == presetId,
        );
        final heavy = kDefaultPromptPresets.firstWhere(
          (p) => p.id == 'v5-standard',
        );
        metadata = (await tester.runAsync(
          () => writeImageMetadataPng(
            plain,
            source: 'NovelAI Diffusion V5 93F4BD30',
            comment: {
              'prompt': applyPromptPreset(preset, 'blue sky', '').positive,
              'uc': heavy.negative,
              'tag_hint_qt': promptPresetTagHints(presetId).qt,
              'tag_hint_uc_preset': 0,
              'seed': 123,
              'steps': 14,
              'scale': 5.5,
              'sampler': 'k_euler_ancestral',
              'cfg_rescale': 0,
            },
          ),
        ))!;
        await mount(tester);
        await drain(
          tester,
          () => container.read(promptPresetsProvider).hasValue,
        );
        container
            .read(generateProvider.notifier)
            .applyParams(
              const GenParams(
                model: 'NAI 5.0 Full',
                steps: 35,
                sampler: 'Euler',
                cfgRescale: .6,
              ),
            );
        await tester.tap(key('desktop-import-confirm'));
        await drain(
          tester,
          () => find.byType(ImportImagePanel).evaluate().isEmpty,
        );
        final p = container.read(generateProvider).params;
        expect(p.model, 'NAI 5.0 Full');
        expect(p.activeSteps, 14);
        expect(p.steps, 35);
        expect(p.sampler, 'Euler');
        expect(p.cfgRescale, .6);
        expect(container.read(generateProvider).prompt, 'blue sky');
        expect(
          container.read(generateProvider).negativePrompt,
          'keep negative',
        );
        expect(container.read(activePromptPresetIdProvider), presetId);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'desktop preview and options sit side by side; resize preserves selection and import semantics',
    (tester) async {
      await mount(tester);
      expect(
        tester.getRect(key('desktop-import-preview')).right,
        lessThan(tester.getRect(key('desktop-import-details')).left),
      );
      expect(
        tester.getSize(key('desktop-import-window')).width,
        lessThanOrEqualTo(1240),
      );
      expect(
        tester.getSize(key('desktop-import-confirm')).width,
        lessThan(220),
      );
      expect(
        tester.widget<Image>(key('desktop-import-preview')).fit,
        BoxFit.contain,
      );
      final footer = tester.getRect(key('desktop-import-footer'));
      await tester.tap(key('import-select-负向提示词'));
      await tester.tap(find.text('正向提示词'));
      await tester.pumpAndSettle();
      expect(tester.getRect(key('desktop-import-footer')), footer);
      tester.view.physicalSize = const Size(700, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(key('desktop-import-confirm').hitTestable(), findsOneWidget);
      await tester.tap(key('desktop-import-confirm'));
      await drain(
        tester,
        () => find.byType(ImportImagePanel).evaluate().isEmpty,
      );
      expect(
        container.read(generateProvider).prompt,
        'cat girl, cherry blossoms',
      );
      expect(container.read(generateProvider).negativePrompt, 'keep negative');
      await finish(tester);
    },
  );

  testWidgets(
    'no metadata keeps reference actions and Escape cancels without changing creation',
    (tester) async {
      await mount(tester, hasMetadata: false);
      expect(key('desktop-import-confirm'), findsNothing);
      expect(find.text('图生图'), findsOneWidget);
      expect(find.text('反推提示词'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ImportImagePanel), findsNothing);
      expect(container.read(generateProvider).prompt, 'original');
      await finish(tester);
    },
  );

  testWidgets('phone import retains its original layout', (tester) async {
    await mount(tester, desktop: false);
    expect(key('desktop-import-window'), findsNothing);
    expect(find.text('导入所选内容'), findsOneWidget);
    expect(find.text('图生图'), findsOneWidget);
    await finish(tester);
  });
}
