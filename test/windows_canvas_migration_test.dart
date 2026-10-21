import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/state_codec.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer container;
  late Directory root;

  void bind(AppStores next) {
    stores = next;
    container = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('plana_canvas_windows_');
    bind(await AppStores.open(rootOverride: root));
  });
  tearDown(() async {
    container.dispose();
    await stores.flushForExit();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    root.deleteSync(recursive: true);
  });

  test(
    'Medium and High survive switch, copy and restart with paired fold drafts',
    () async {
      final gen = container.read(generateProvider.notifier);
      final canvases = container.read(canvasWorkspaceProvider.notifier);
      final a = container.read(canvasWorkspaceProvider).activeId;
      gen.setModel('NAI 5.0 Full');
      gen.applyParams(
        container
            .read(generateProvider)
            .params
            .copyWith(
              steps: 37,
              sampler: 'Euler',
              cfgRescale: .7,
              seed: '1234',
            ),
      );
      final folded = appendTagPromptsFolded(
        positiveDraft: '',
        negativeDraft: '',
        links: const [],
        entries: const [
          TagEntry(
            id: 'fixture',
            category: TagCategory.artist,
            name: '合成画风',
            positive: 'blue sky',
            negative: 'rain',
          ),
        ],
      );
      gen.setPrompts(
        positive: outputOf(folded.positiveDraft),
        negative: outputOf(folded.negativeDraft),
        positiveRaw: folded.positiveDraft,
        negativeRaw: folded.negativeDraft,
        promptFoldLinks: folded.links,
      );
      gen.setNaiEffort(NaiEffort.medium);
      final b = canvases.create(duplicate: true);
      gen.setNaiEffort(NaiEffort.high);
      gen.applyParams(
        container.read(generateProvider).params.copyWith(steps: 45),
      );
      canvases.select(a);
      expect(container.read(generateProvider).params.activeSteps, 14);
      expect(container.read(generateProvider).params.steps, 37);
      expect(container.read(generateProvider).negativePrompt, 'rain');
      await stores.flushForExit();
      container.dispose();
      bind(await AppStores.open(rootOverride: root));
      final restored = container.read(generateProvider);
      expect(restored.params.naiEffort, NaiEffort.medium);
      expect(restored.params.cfgRescale, .7);
      expect(restored.promptRaw, folded.positiveDraft);
      expect(restored.negativePromptRaw, folded.negativeDraft);
      expect(restored.promptFoldLinks, folded.links);
      container.read(generateProvider.notifier).setNaiEffort(NaiEffort.high);
      expect(container.read(generateProvider).params.activeSteps, 37);
      container.read(canvasWorkspaceProvider.notifier).select(b);
      expect(container.read(generateProvider).params.naiEffort, NaiEffort.high);
      expect(container.read(generateProvider).params.steps, 45);
      expect(container.read(generateProvider).promptFoldLinks, folded.links);
    },
  );

  for (final corrupt in ['broken-json', '{"v":3}']) {
    test(
      'legacy migration backs up bytes, retains blob refs and recovers $corrupt',
      () async {
        final gen = container.read(generateProvider.notifier);
        gen.setPrompts(
          positive: 'synthetic legacy draft',
          negative: 'saved negative',
        );
        gen.setModel('NAI 5.0 Full');
        gen.setNaiEffort(NaiEffort.medium);
        gen.addVibe(image: Uint8List.fromList([11, 12, 13]), name: 'fixture');
        await stores.flushForExit();
        final encoded = await encodeGenerateState(
          container.read(generateProvider),
          stores.blobs,
        );
        encoded.json.remove('promptPresetId');
        final legacy = jsonEncode({
          'v': 1,
          'state': encoded.json,
          'refs': encoded.refs.toList(),
          'idSeq': 333,
        });
        final file = File('${root.path}/workspace/state.json');
        await file.writeAsString(legacy);
        await File(
          '${root.path}/prompt_presets.json',
        ).writeAsString('{"activeId":"v5-light","custom":[]}');
        container.dispose();
        bind(await AppStores.open(rootOverride: root));
        final backup = File('${file.path}.pre-v3.bak');
        expect(await backup.readAsString(), legacy);
        expect(
          container.read(generateProvider).params.naiEffort,
          NaiEffort.medium,
        );
        expect(container.read(generateProvider).promptPresetId, 'v5-light');
        expect(stores.workspace.idSeq, 333);
        container
            .read(generateProvider.notifier)
            .setPrompts(positive: 'new draft');
        container
            .read(generateProvider.notifier)
            .removeVibe(container.read(generateProvider).vibes.single.id);
        await stores.flushForExit();
        expect(
          await stores.workspace.liveRefs(strict: true),
          containsAll(encoded.refs),
        );
        final upgraded = jsonDecode(await file.readAsString()) as Map;
        expect(upgraded['v'], 3);
        // The top-level state still allows the previous single-canvas decoder to read it.
        final compatible = await decodeGenerateState(
          upgraded['state'] as Map<String, dynamic>,
          stores.blobs,
        );
        expect(compatible.prompt, 'new draft');
        expect(compatible.params.naiEffort, NaiEffort.medium);
        expect(await backup.readAsString(), legacy);
        await file.writeAsString(corrupt);
        container.dispose();
        bind(await AppStores.open(rootOverride: root));
        expect(
          container.read(generateProvider).prompt,
          'synthetic legacy draft',
        );
        expect(container.read(generateProvider).vibes.single.image, [
          11,
          12,
          13,
        ]);
        expect(await File('${file.path}.corrupt.bak').readAsString(), corrupt);
        expect(await backup.readAsString(), legacy);
      },
    );
  }

  test('pending character writes and undo stay with the source canvas', () {
    final gen = container.read(generateProvider.notifier);
    final canvases = container.read(canvasWorkspaceProvider.notifier);
    final editor = container.read(editorProvider.notifier);
    final a = container.read(canvasWorkspaceProvider).activeId;
    gen.addCharacter();
    final id = container.read(generateProvider).characters.single.id;
    gen.updateCharacter(id, positive: 'before');
    editor.load(
      positive: 'before',
      negative: '',
      startPositive: true,
      charId: id,
    );
    editor.editActive('after', structural: true);
    final b = canvases.create(duplicate: true);
    expect(
      container.read(generateProvider).characters.single.positive,
      'after',
    );
    editor.load(
      positive: 'after',
      negative: '',
      startPositive: true,
      charId: id,
    );
    expect(container.read(editorProvider).canUndo, isFalse);
    editor.editActive('only B', structural: true);
    canvases.select(a);
    editor.load(
      positive: 'after',
      negative: '',
      startPositive: true,
      charId: id,
    );
    editor.undo();
    editor.flushWriteBack();
    expect(
      container.read(generateProvider).characters.single.positive,
      'before',
    );
    canvases.select(b);
    expect(
      container.read(generateProvider).characters.single.positive,
      'only B',
    );
  });
}
