import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/blob_store.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/cost.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';
import 'package:plana_app/features/generate/state_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late BlobStore blobs;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plana_effort_test_');
    blobs = BlobStore(root);
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<GenerateState> state({
    String? effort = 'medium',
    String model = 'NAI 5.0 Full',
  }) => decodeGenerateState({
    'prompt': '1girl, -3::hat::',
    'negativePrompt': 'test custom negative',
    'characters': [
      {
        'id': 'character-test',
        'positive': 'blue hair',
        'negative': 'test character negative',
      },
    ],
    'params': {
      'model': model,
      'naiEffort': ?effort,
      'steps': 40,
      'sampler': 'Euler',
      'cfg': 5.5,
      'cfgRescale': 0.7,
      'seed': '123',
      'width': 832,
      'height': 1216,
    },
  }, blobs);

  final fixedNegative = kDefaultPromptPresets
      .firstWhere((p) => p.id == 'v5-standard')
      .negative;

  test(
    'Medium uses the real model and fixed settings on both transports',
    () async {
      final s = await state();
      final direct = buildNaiPayload(s, presetId: 'none').body;
      final p = direct['parameters'] as Map;
      expect(direct['model'], 'nai-diffusion-5-full-medium');
      expect(p['steps'], 14);
      expect(p['sampler'], 'k_euler_ancestral');
      expect(p['cfg_rescale'], 0);
      expect(p['scale'], 5.5);
      expect(p['seed'], 123);
      expect(p['ucPreset'], 0);
      expect(p['tag_hint_uc_preset'], 0);
      expect(p['negative_prompt'], fixedNegative);
      expect(p['v4_negative_prompt']['caption']['base_caption'], fixedNegative);
      expect(
        p['v4_negative_prompt']['caption']['char_captions'][0]['char_caption'],
        '',
      );
      expect(p['characterPrompts'][0]['uc'], '');
      expect(direct['input'], s.prompt);
      final bot = buildBotParams(s, seed: 123, presetId: 'none');
      expect(bot['model'], 'nai-diffusion-5-full-medium');
      expect(bot['steps'], 14);
      expect(bot['sampler'], 'k_euler_ancestral');
      expect(bot['cfgRescale'], 0);
      expect(bot['negativePrompt'], fixedNegative);
      expect(bot['characterPrompts'][0]['negative'], '');
      expect(bot['ucPreset'], 0);
      expect(bot['tagHintUcPreset'], 0);
      expect(s.negativePrompt, 'test custom negative');
      expect(s.characters.single.negative, 'test character negative');
      expect(s.params.steps, 40);
      expect(s.params.sampler, 'Euler');
      expect(s.params.cfgRescale, .7);
    },
  );

  test('Medium inpainting uses the Medium inpainting endpoint model', () async {
    final s = (await state()).copyWith(
      inpaint: InpaintJob(
        image: Uint8List(4),
        mask: Uint8List(4),
        strength: .5,
      ),
    );
    final direct = buildNaiPayload(s, presetId: 'v5-light').body;
    expect(direct['model'], 'nai-diffusion-5-full-medium-inpainting');
    expect(direct['parameters']['steps'], 14);
    expect(direct['parameters']['negative_prompt'], fixedNegative);
  });

  test(
    'Medium costs and active steps use 14 without overwriting High settings',
    () async {
      final s = await state();
      expect(s.params.activeSteps, 14);
      expect(estimateCost(s, isOpus: false), 18);
      expect(estimateCost(s, isOpus: true), 0);
      expect(estimateCost(s, isOpus: true, v5Charged: true), 18);
      expect(
        estimateInpaintCost(
          s,
          isOpus: false,
          sendW: 832,
          sendH: 1216,
          strength: .5,
        ),
        9,
      );
      expect(s.params.withActiveSteps(25).steps, 40);
      final encoded = await encodeGenerateState(s, blobs);
      expect(encoded.json['params']['naiEffort'], 'medium');
      final restored = await decodeGenerateState(encoded.json, blobs);
      expect(restored.params.activeSteps, 14);
      expect(restored.params.steps, 40);
      expect(
        buildNaiPayload(restored, presetId: 'none').body['model'],
        'nai-diffusion-5-full-medium',
      );
    },
  );

  test(
    'old, High and unknown effort snapshots retain existing behavior',
    () async {
      for (final effort in [null, 'high', 'unknown']) {
        final s = await state(effort: effort);
        final body = buildNaiPayload(s, presetId: 'none').body;
        expect(body['model'], 'nai-diffusion-5-full');
        expect(body['parameters']['steps'], 40);
        expect(body['parameters']['sampler'], 'k_euler');
        expect(body['parameters']['cfg_rescale'], .7);
        expect(body['parameters']['negative_prompt'], s.negativePrompt);
      }
    },
  );

  test(
    'Medium preference has no effect on Curated or earlier models',
    () async {
      for (final model in ['NAI 5.0 Curated', 'NAI 4.5 Full']) {
        final s = await state(model: model);
        final body = buildNaiPayload(s, presetId: 'none').body;
        expect(body['model'], naiModelId(model));
        expect(body['parameters']['steps'], 40);
        expect(body['parameters']['negative_prompt'], s.negativePrompt);
        expect(s.params.activeSteps, 40);
      }
    },
  );
}
