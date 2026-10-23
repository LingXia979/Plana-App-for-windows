import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/net/nai_gate.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/gen_queue.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/models.dart';

class _Auth extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

class _Keys extends NaiKeysNotifier {
  @override
  Future<List<NaiKey>> build() async => const [
    NaiKey(id: 'main', token: 'main-test-only', primary: true),
    NaiKey(id: 'free', token: 'free-test-only', joinPaid: false),
  ];
}

class _Client extends NaiClient {
  _Client(this.image);
  final Uint8List image;
  final sent = <String>[];
  final bodies = <Map<String, dynamic>>[];
  @override
  Future<NaiSubscription> subscription(String token) async => (
    anlas: 1000,
    fixedAnlas: 1000,
    purchasedAnlas: 0,
    isOpus: token == 'free-test-only',
    tier: token == 'free-test-only' ? 3 : 1,
    usage: null,
  );
  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) async* {
    sent.add(token);
    bodies.add(body);
    yield (step: 14, isFinal: true, bytes: image);
  }
}

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStores stores;
  late ProviderContainer c;
  late _Client client;
  setUp(() async {
    stores = AppStores.ephemeral();
    client = _Client(await File('assets/app_icon.png').readAsBytes());
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        authModeProvider.overrideWith(_Auth.new),
        naiKeysStoreProvider.overrideWith(_Keys.new),
        naiClientProvider.overrideWith((ref, base) => client),
      ],
    );
    await c.read(authModeProvider.future);
    await c.read(naiKeysStoreProvider.future);
  });
  tearDown(() async {
    c.dispose();
    await stores.flushForExit();
  });

  test(
    'Medium uses the free secondary account with fixed steps and its own ledger cost',
    () async {
      final input = GenerateState.initial().copyWith(
        prompt: 'synthetic sky',
        params: const GenParams(
          model: 'NAI 5.0 Full',
          naiEffort: NaiEffort.medium,
          steps: 40,
          sampler: 'Euler',
          cfgRescale: .7,
          seed: '12',
        ),
      );
      expect(
        await c.read(generationProvider.notifier).generate(using: input),
        GenOutcome.ok,
      );
      expect(client.sent, ['free-test-only']);
      expect(client.bodies.single['model'], 'nai-diffusion-5-full-medium');
      expect((client.bodies.single['parameters'] as Map)['steps'], 14);
      await stores.ledger.idle;
      expect(stores.ledger.gens.single.pts, 0);
      expect(stores.ledger.gens.single.steps, 14);
      expect(stores.ledger.totalFree, 1);
    },
  );

  test(
    'cancelling a waiting queue job does not retry or send a paid request',
    () async {
      final gate = c.read(naiGateProvider);
      // Occupy the main account as another operation would. The paid job below can
      // use only the main account; cancelling it must finish before release.
      final held = await gate.acquire(paid: true);
      c
          .read(generateProvider.notifier)
          .applyParams(
            c.read(generateProvider).params.copyWith(width: 1536, height: 1536),
          );
      final queue = c.read(genQueueProvider.notifier);
      queue.enqueue();
      final work = queue.maybeStart();
      try {
        await until(() => c.read(generationProvider).jobs.isNotEmpty);
        c.read(generationProvider.notifier).cancel();
        await work.timeout(const Duration(seconds: 3));
        expect(client.sent, isEmpty);
        expect(c.read(generationProvider).jobs, isEmpty);
        expect(c.read(genQueueProvider).active, isFalse);
        expect(c.read(genQueueProvider).items, hasLength(1));
      } finally {
        gate.release(held.slot);
      }
    },
  );

  test(
    'late img2img dimensions update the source canvas only, deleted targets do nothing',
    () {
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final a = canvases.create();
      final b = canvases.create();
      final gen = c.read(generateProvider.notifier);
      final before = c.read(generateProvider).params;
      gen.setImg2ImgImage(
        image: client.image,
        width: 1280,
        height: 768,
        canvasId: a,
      );
      expect(c.read(canvasWorkspaceProvider).activeId, b);
      expect(c.read(generateProvider).params.width, before.width);
      expect(c.read(generateProvider).params.height, before.height);
      canvases.select(a);
      expect(c.read(generateProvider).params.width, 1280);
      expect(c.read(generateProvider).params.height, 768);
      canvases.select(b);
      canvases.remove(a);
      final unchanged = c.read(generateProvider);
      gen.setImg2ImgImage(
        image: Uint8List(0),
        width: 64,
        height: 64,
        canvasId: a,
      );
      expect(c.read(generateProvider), same(unchanged));
    },
  );
}
