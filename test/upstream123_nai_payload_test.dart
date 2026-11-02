import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/bot_request.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/nai_request.dart';

class _Auth extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

class _Keys extends NaiKeysNotifier {
  _Keys(this.endpoint);
  final String endpoint;

  @override
  Future<List<NaiKey>> build() async => [
    NaiKey(
      id: 'test',
      token: 'synthetic-test-token',
      endpoint: endpoint,
      primary: true,
    ),
  ];
}

class _Client extends NaiClient {
  final requests = <Map<String, dynamic>>[];

  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) async* {
    requests.add(body);
    yield (
      step: 28,
      isFinal: true,
      bytes: Uint8List.fromList(
        img.encodePng(img.Image(width: 32, height: 32)),
      ),
    );
  }

  @override
  Future<NaiSubscription> subscription(String token) async => (
    anlas: 10000,
    fixedAnlas: 10000,
    purchasedAnlas: 0,
    isOpus: true,
    tier: 3,
    usage: null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final model in [
    'NAI 4.0 Full',
    'NAI 4.5 Full',
    'NAI 5.0 Full',
    'NAI 5.0 Curated',
  ]) {
    test(
      '$model sends the selected inpaint strength without changing its input',
      () {
        for (final effort in NaiEffort.values) {
          for (final strength in [.01, .37, .83, 1.0]) {
            final job = InpaintJob(
              image: Uint8List.fromList([1, 2]),
              mask: Uint8List.fromList([3, 4]),
              strength: strength,
              sourceId: 'saved-original',
              grid: Uint8List.fromList([5, 6]),
            );
            final state = GenerateState.initial().copyWith(
              inpaint: job,
              params: const GenParams().copyWith(
                model: model,
                naiEffort: effort,
                seed: '123',
              ),
            );
            for (final thirdParty in [false, true]) {
              final body = buildNaiPayload(
                state,
                presetId: 'none',
                thirdParty: thirdParty,
              ).body;
              final p = body['parameters'] as Map;
              expect(body['action'], 'infill');
              expect(p['strength'], strength);
              expect(p['inpaintImg2ImgStrength'], strength);
              if (strength < 1) {
                expect(p['img2img'], {
                  'strength': strength,
                  'color_correct': true,
                });
              } else {
                expect(p.containsKey('img2img'), isFalse);
              }
              expect(p['seed'], 123);
            }
            // Bot uses its own contract and must also preserve the selected value.
            final bot = buildBotParams(state, seed: 123, presetId: 'none');
            expect(bot['inpaint']['strength'], strength);
            expect(identical(state.inpaint, job), isTrue);
            expect(state.inpaint!.grid, [5, 6]);
            expect(state.inpaint!.sourceId, 'saved-original');
          }
        }
      },
    );
  }

  test(
    'third-party tag hints follow the actual sent model, including Curated inpaint fallback',
    () {
      for (final model in [
        'NAI 4.0 Curated',
        'NAI 4.5 Full',
        'NAI 5.0 Full',
        'NAI 5.0 Curated',
      ]) {
        for (final inpaint in [false, true]) {
          final state = GenerateState.initial().copyWith(
            params: const GenParams().copyWith(model: model),
            inpaint: inpaint
                ? InpaintJob(
                    image: Uint8List(1),
                    mask: Uint8List(1),
                    strength: .4,
                  )
                : null,
          );
          final official = buildNaiPayload(state, presetId: 'heavy').body;
          final third = buildNaiPayload(
            state,
            presetId: 'heavy',
            thirdParty: true,
          ).body;
          final p = third['parameters'] as Map;
          final isV5 = (third['model'] as String).startsWith('nai-diffusion-5');
          expect(p.containsKey('tag_hint_qt'), isV5);
          expect(p.containsKey('tag_hint_uc_preset'), isV5);
          expect(official['parameters']['tag_hint_qt'], isNotNull);
          expect(official['parameters']['tag_hint_uc_preset'], isNotNull);
          expect(p['ucPreset'], official['parameters']['ucPreset']);
          expect(p['qualityToggle'], official['parameters']['qualityToggle']);
          expect(
            p['negative_prompt'],
            official['parameters']['negative_prompt'],
          );
        }
      }
    },
  );

  test(
    'ordinary text and image generation do not acquire an inpaint img2img block',
    () {
      final state = GenerateState.initial();
      final text = buildNaiPayload(state, presetId: 'none').body;
      expect(text['action'], 'generate');
      expect(text['parameters'].containsKey('img2img'), isFalse);
      final image = buildNaiPayload(
        state,
        presetId: 'none',
        img2img: (
          image: 'synthetic-image',
          strength: .42,
          noise: .12,
          upscaledEnhance: false,
        ),
      ).body;
      expect(image['action'], 'img2img');
      expect(image['parameters']['strength'], .42);
      expect(image['parameters']['noise'], .12);
      expect(image['parameters'].containsKey('img2img'), isFalse);
    },
  );

  for (final endpoint in ['', 'https://synthetic-gateway.invalid']) {
    test(
      'generation uses the selected key endpoint for tag hints: $endpoint',
      () async {
        final stores = AppStores.ephemeral();
        final client = _Client();
        final container = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            authModeProvider.overrideWith(_Auth.new),
            naiKeysStoreProvider.overrideWith(() => _Keys(endpoint)),
            naiClientProvider.overrideWith((ref, base) {
              expect(base, endpoint);
              return client;
            }),
          ],
        );
        try {
          await container.read(authModeProvider.future);
          await container.read(naiKeysStoreProvider.future);
          final outcome = await container
              .read(generationProvider.notifier)
              .generate(
                using: GenerateState.initial().copyWith(
                  prompt: 'test',
                  params: const GenParams().copyWith(model: 'NAI 4.5 Full'),
                ),
              );
          expect(outcome, GenOutcome.ok);
          final p = client.requests.single['parameters'] as Map;
          expect(p.containsKey('tag_hint_qt'), endpoint.isEmpty);
          expect(p.containsKey('tag_hint_uc_preset'), endpoint.isEmpty);
        } finally {
          container.dispose();
          stores.flushNow();
          await stores.gallery.idle;
          await stores.albums.idle;
        }
      },
    );
  }
}
