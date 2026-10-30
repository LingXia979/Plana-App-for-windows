import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';

class _Auth extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

class _Keys extends NaiKeysNotifier {
  @override
  Future<List<NaiKey>> build() async => [
    const NaiKey(id: 'test', token: 'local-test-only', primary: true),
  ];
}

class _Client extends NaiClient {
  final started = Completer<void>();
  final stream = StreamController<NaiFrame>();
  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) {
    started.complete();
    return stream.stream;
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
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  late _Client client;
  final png = Uint8List.fromList(
    img.encodePng(img.Image(width: 64, height: 64)),
  );
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('plana_history_generation_');
    stores = await AppStores.open(rootOverride: root);
    client = _Client();
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        authModeProvider.overrideWith(_Auth.new),
        naiKeysStoreProvider.overrideWith(_Keys.new),
        naiClientProvider.overrideWith((ref, base) => client),
      ],
    );
    await c.read(authModeProvider.future);
    await c.read(naiKeysStoreProvider.future);
  });
  tearDown(() async {
    if (client.stream.hasListener) {
      await client.stream.close();
    } else {
      unawaited(client.stream.close());
    }
    await stores.flushForExit();
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<void> complete() async {
    client.stream.add((step: 28, isFinal: true, bytes: png));
    await client.stream.close();
  }

  test(
    'successful generation records its starting canvas after switching and editing',
    () async {
      final gen = c.read(generateProvider.notifier);
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final a = c.read(canvasWorkspaceProvider).activeId;
      gen.setPrompts(positive: 'starting prompt');
      final future = c.read(generationProvider.notifier).generate();
      await client.started.future;
      final b = canvases.create();
      gen.setPrompts(positive: 'other prompt');
      await complete();
      expect(await future, GenOutcome.ok);
      await stores.history.idle;
      final entry = (await stores.history.load(a)).single;
      expect(entry.preview.prompt, 'starting prompt');
      expect(await stores.history.load(b), isEmpty);
      expect(entry.resultIds.single, c.read(galleryProvider).results.first.id);
      expect(c.read(generateProvider).prompt, 'other prompt');
    },
  );
  test(
    'explicit gallery snapshot does not become current canvas history',
    () async {
      final snapshot = c.read(generateProvider);
      final id = c.read(canvasWorkspaceProvider).activeId;
      final future = c
          .read(generationProvider.notifier)
          .generate(using: snapshot);
      await client.started.future;
      await complete();
      expect(await future, GenOutcome.ok);
      expect(await stores.history.load(id), isEmpty);
    },
  );
  test(
    'canvas removed before generation finishes is not recreated by history',
    () async {
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final id = canvases.create();
      final future = c.read(generationProvider.notifier).generate();
      await client.started.future;
      canvases.remove(id);
      await complete();
      expect(await future, GenOutcome.ok);
      expect(await stores.history.load(id), isEmpty);
    },
  );
}
