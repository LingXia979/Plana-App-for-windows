import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/nai_endpoint.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';

const _endpoint = 'https://synthetic-relay.invalid/v1/chat/completions';

class _Auth extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

class _Keys extends NaiKeysNotifier {
  @override
  Future<List<NaiKey>> build() async => const [
    NaiKey(
      id: 'chat',
      token: 'synthetic-chat-key',
      endpoint: _endpoint,
      primary: true,
    ),
    NaiKey(
      id: 'official',
      token: 'synthetic-official-key',
      joinFree: false,
      joinPaid: false,
    ),
  ];
}

String _reply(Uint8List bytes) => jsonEncode({
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': '![image](data:image/png;base64,${base64Encode(bytes)})',
      },
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer c;
  late Uint8List image;
  late Uint8List mask;
  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) respond;

  setUp(() async {
    requests.clear();
    stores = AppStores.ephemeral();
    // Official forwarding must never redirect a third-party key.
    await stores.prefs.write(key: 'nai_proxy', value: '1');
    image = Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));
    mask = Uint8List.fromList(
      img.encodePng(
        img.fill(
          img.Image(width: 64, height: 64),
          color: img.ColorRgb8(255, 255, 255),
        ),
      ),
    );
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        authModeProvider.overrideWith(_Auth.new),
        naiKeysStoreProvider.overrideWith(_Keys.new),
      ],
    );
    await c.read(authModeProvider.future);
    await c.read(naiKeysStoreProvider.future);
    respond = (_) async => http.Response(_reply(image), 200);
  });
  tearDown(() async {
    c.dispose();
    await stores.flushForExit();
  });

  Future<T> withTransport<T>(Future<T> Function() work) => http.runWithClient(
    work,
    () => MockClient((request) async {
      requests.add(request);
      if (request.url.host == Uri.parse(kNaiOfficialBase).host) {
        // Account discovery may read the unused official account. A POST there
        // would leak the chosen relay key and must fail this test.
        expect(request.method, 'GET');
        expect(
          request.headers['authorization'],
          'Bearer synthetic-official-key',
        );
        return http.Response('{}', 503);
      }
      if (request.url.host == Uri.parse(kNaiProxyBase).host) {
        expect(request.method, 'GET');
        expect(
          request.headers['authorization'],
          'Bearer synthetic-official-key',
        );
        return http.Response('{}', 503);
      }
      expect(request.url.toString(), _endpoint);
      expect(request.method, 'POST');
      expect(request.headers['authorization'], 'Bearer synthetic-chat-key');
      return respond(request);
    }),
  );

  for (final (model, effort, wireModel) in [
    ('NAI 4.5 Full', NaiEffort.high, 'nai-diffusion-4-5-full'),
    ('NAI 5.0 Full', NaiEffort.high, 'nai-diffusion-5-full'),
    ('NAI 5.0 Full', NaiEffort.medium, 'nai-diffusion-5-full-medium'),
  ]) {
    test(
      '$model ${effort.name}: main Generate preserves inpaint strength in chat POST and history',
      () async {
        await withTransport(() async {
          final editor = c.read(generateProvider.notifier);
          editor.applyParams(
            const GenParams().copyWith(
              model: model,
              naiEffort: effort,
              seed: '123456',
            ),
          );
          editor.setPrompts(positive: 'synthetic prompt');
          editor.setInpaint(
            InpaintJob(image: image, mask: mask, strength: .5),
            width: 64,
            height: 64,
          );
          final generate = c.read(generationProvider.notifier);
          final first = generate.generate();
          editor.updateInpaintStrength(.75);
          expect(await first, GenOutcome.ok);
          expect(await generate.generate(), GenOutcome.ok);
          final posts = requests.where((r) => r.method == 'POST').toList();
          expect(posts, hasLength(2));
          for (var i = 0; i < posts.length; i++) {
            final strength = [.5, .75][i];
            final body = jsonDecode(posts[i].body) as Map;
            expect(body['model'], wireModel);
            expect(body['stream'], isFalse);
            final content =
                jsonDecode(body['messages'][0]['content'] as String) as Map;
            expect(content['seed'], 123456);
            expect(content['inpaint'], {
              'image': base64Encode(image),
              'mask': base64Encode(mask),
              'strength': strength,
            });
            expect(content['inpaintImg2ImgStrength'], strength);
            expect(content['img2img'], {
              'strength': strength,
              'color_correct': true,
            });
            expect(content.containsKey('image'), isFalse);
            expect(content.containsKey('stream'), isFalse);
          }
          await stores.gallery.idle;
          final results = c.read(galleryProvider).results;
          expect(results, hasLength(2));
          final saved = [
            for (final result in results)
              (await stores.gallery.readInput(result.id))!,
          ];
          expect(
            saved.map((s) => s.inpaint!.strength),
            unorderedEquals([.5, .75]),
          );
          expect(saved.map((s) => s.params.seed), everyElement('123456'));
          expect(c.read(generateProvider).inpaint!.strength, .75);
        });
      },
    );
  }

  test(
    'a chat endpoint 404 sends only one request and does not fall back to an NAI path',
    () async {
      respond = (_) async => http.Response(
        jsonEncode({
          'error': {'message': 'Unsupported bridge'},
        }),
        404,
      );
      await withTransport(() async {
        final outcome = await c.read(generationProvider.notifier).generate();
        expect(outcome, GenOutcome.notCharged);
        expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        expect(c.read(galleryProvider).results, isEmpty);
      });
    },
  );

  test(
    'cancelled chat generation discards a late image and never retries',
    () async {
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      respond = (_) {
        started.complete();
        return reply.future;
      };
      await withTransport(() async {
        final controller = c.read(generationProvider.notifier);
        final pending = controller.generate();
        await started.future.timeout(const Duration(seconds: 10));
        controller.cancel();
        reply.complete(http.Response(_reply(image), 200));
        expect(await pending, GenOutcome.cancelled);
        expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        expect(c.read(galleryProvider).results, isEmpty);
      });
    },
  );
}
