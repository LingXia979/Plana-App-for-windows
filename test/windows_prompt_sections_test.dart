import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/editor/editor_state.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/gen_modules.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/generate/prompt_sections.dart';
import 'package:plana_app/features/generate/style_recipes.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

GenerateState fixture() {
  final paired = appendTagPromptsFolded(
    positiveDraft: '',
    negativeDraft: '',
    entries: const [
      TagEntry(
        id: 'style',
        category: TagCategory.artist,
        name: '合成画风',
        positive: 'watercolor, soft light',
        negative: 'hard shadows',
      ),
    ],
  );
  return GenerateState.initial().copyWith(
    prompt: 'forest',
    negativePrompt: 'lowres',
    promptPresetId: 'none',
    params: const GenParams().copyWith(
      model: 'NAI 5.0 Full',
      naiEffort: NaiEffort.medium,
      steps: 40,
      sampler: 'Euler',
      cfgRescale: .7,
    ),
    sections: [
      const PromptSection.main(),
      PromptSection(
        id: 'section900',
        name: '合成画风',
        positive: outputOf(paired.positiveDraft),
        negative: outputOf(paired.negativeDraft),
        positiveRaw: paired.positiveDraft,
        negativeRaw: paired.negativeDraft,
        foldLinks: paired.links,
        artist: true,
      ),
    ],
    characters: [
      CharacterPrompt(
        id: 'char901',
        name: '合成角色',
        positive: 'blue hair',
        negative: 'red hair',
        positiveRaw: '<#头发: blue hair#>',
        avatar: 'https://example.test/avatar.png',
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  void bind(AppStores next) {
    stores = next;
    c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('plana_windows_sections_');
    bind(await AppStores.open(rootOverride: root));
    c
        .read(generateProvider.notifier)
        .applyCanvas(CanvasPrompts.of(fixture()), force: true);
  });
  tearDown(() async {
    c.dispose();
    await stores.flushForExit();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    root.deleteSync(recursive: true);
  });

  test('sections reach both transports while Medium keeps High drafts', () {
    final original = c.read(generateProvider);
    final sent = stripHiddenModules(original, const GenModuleSettings());
    final direct = buildNaiPayload(sent, presetId: 'none').body;
    final bot = buildBotParams(sent, seed: 123, presetId: 'none');
    expect(direct['input'], 'forest, watercolor, soft light');
    expect(bot['positivePrompt'], direct['input']);
    expect(direct['parameters']['steps'], 14);
    expect(bot['steps'], 14);
    expect(
      direct['parameters']['negative_prompt'],
      isNot(contains('hard shadows')),
    );
    expect(original.sections.last.negative, 'hard shadows');
    c.read(generateProvider.notifier).setNaiEffort(NaiEffort.high);
    final high = stripHiddenModules(
      c.read(generateProvider),
      const GenModuleSettings(),
    );
    expect(
      buildNaiPayload(
        high,
        presetId: 'none',
      ).body['parameters']['negative_prompt'],
      'lowres, hard shadows',
    );
    expect(high.params.steps, 40);
    expect(high.params.sampler, 'Euler');
    expect(high.params.cfgRescale, .7);
  });

  test(
    'Medium recipes record effective values and preserve stored High sampling',
    () {
      final p = c.read(generateProvider).params;
      final recipe = recipeOf(p);
      expect(recipe.model, 'v5-full-medium');
      expect(recipe.steps, 14);
      expect(recipeFits(recipe, 'NAI 5.0 Full'), isTrue);
      final restored = StyleRecipe.fromJson(
        jsonDecode(jsonEncode(recipe.toJson())),
      )!;
      expect(recipeBrief(restored), contains('Medium'));
      final applied = withRecipe(p, restored);
      expect(applied.naiEffort, NaiEffort.medium);
      expect(
        (applied.steps, applied.sampler, applied.cfgRescale),
        (40, 'Euler', .7),
      );
    },
  );

  test(
    'pending section edits and undo stay on their canvas across duplicate and restart',
    () async {
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final a = c.read(canvasWorkspaceProvider).activeId;
      final editor = c.read(editorProvider.notifier);
      final section = c.read(generateProvider).sections.last;
      editor.load(
        positive: section.positiveRaw,
        negative: section.negativeRaw,
        startPositive: true,
        sectionId: section.id,
      );
      editor.editActive(
        '${c.read(editorProvider).positiveText}, rain',
        structural: true,
      );
      final b = canvases.create(duplicate: true);
      expect(c.read(generateProvider).sections.last.positive, contains('rain'));
      final copied = c.read(generateProvider).sections.last;
      editor.load(
        positive: copied.positiveRaw,
        negative: copied.negativeRaw,
        startPositive: true,
        sectionId: section.id,
      );
      expect(c.read(editorProvider).canUndo, isFalse);
      editor.editActive('only second canvas', structural: true);
      canvases.select(a);
      final current = c.read(generateProvider).sections.last;
      editor.load(
        positive: current.positiveRaw,
        negative: current.negativeRaw,
        startPositive: true,
        sectionId: section.id,
      );
      editor.undo();
      editor.flushWriteBack();
      final expected = PromptSnapshot.of(c.read(generateProvider));
      expect(expected.sections.last.positive, section.positive);
      expect(expected.sections.last.foldLinks, section.foldLinks);
      await stores.flushForExit();
      c.dispose();
      bind(await AppStores.open(rootOverride: root));
      expect(
        PromptSnapshot.of(c.read(generateProvider)).sameAs(expected),
        isTrue,
      );
      expect(c.read(generateProvider).params.naiEffort, NaiEffort.medium);
      expect(c.read(generateProvider).params.steps, 40);
      c.read(canvasWorkspaceProvider.notifier).select(b);
      expect(
        c.read(generateProvider).sections.last.positive,
        'only second canvas',
      );
    },
  );

  test(
    'assistant import clears old section words and undo restores drafts after restart on source canvas',
    () async {
      stores.assistant.initialCurrent = const [
        AssistantMsg(
          id: 'reply',
          role: MsgRole.ai,
          text: '合成回复',
          at: 1,
          draw: DrawProposal(positive: 'new scene'),
        ),
      ];
      final assistant = c.read(assistantProvider.notifier);
      final a = c.read(canvasWorkspaceProvider).activeId;
      final before = PromptSnapshot.of(c.read(generateProvider));
      final preview = assistant.previewSendState('reply')!;
      expect(preview.prompt, 'new scene');
      expect(preview.sections, isEmpty);
      expect(assistant.applyProposal('reply'), isTrue);
      expect(composeSections(c.read(generateProvider)).prompt, 'new scene');
      expect(composeSections(c.read(generateProvider)).negativePrompt, isEmpty);
      c
          .read(generateProvider.notifier)
          .updateSection('section900', name: '用户修改');
      expect(assistant.undo('reply'), isFalse);
      final b = c.read(canvasWorkspaceProvider.notifier).create();
      c
          .read(generateProvider.notifier)
          .setPrompts(positive: 'keep second canvas');
      await stores.flushForExit();
      c.dispose();
      bind(await AppStores.open(rootOverride: root));
      expect(
        c.read(assistantProvider.notifier).undo('reply', force: true),
        isTrue,
      );
      expect(c.read(canvasWorkspaceProvider).activeId, b);
      expect(c.read(generateProvider).prompt, 'keep second canvas');
      c.read(canvasWorkspaceProvider.notifier).select(a);
      expect(
        PromptSnapshot.of(c.read(generateProvider)).sameAs(before),
        isTrue,
      );
    },
  );

  test(
    'assistant content gate counts enabled sections without a main prompt',
    () {
      final sectionOnly = GenerateState.initial().copyWith(
        sections: const [
          PromptSection(id: 'scene', name: '场景', positive: 'forest'),
        ],
      );
      expect(canvasHasContent(sectionOnly), isTrue);
      expect(
        canvasHasContent(
          sectionOnly.copyWith(
            sections: [sectionOnly.sections.single.copyWith(enabled: false)],
          ),
        ),
        isFalse,
      );
    },
  );
}
