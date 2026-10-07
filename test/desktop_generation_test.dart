import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/desktop/desktop_library_state.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/generation_controller.dart';
import 'package:plana_app/features/generate/loop_controller.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/shell/shell_state.dart';

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
  final frames = StreamController<NaiFrame>();
  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) {
    started.complete();
    return frames.stream;
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

class _LoopClient extends _Client {
  _LoopClient(this.bytes);

  final Uint8List bytes;
  final requests = List.generate(4, (_) => Completer<void>());
  final finish = List.generate(4, (_) => Completer<void>());
  int count = 0;

  @override
  Stream<NaiFrame> generateImageStream({
    required String token,
    required Map<String, dynamic> body,
    GenAbort? abort,
  }) async* {
    final index = count++;
    requests[index].complete();
    await finish[index].future;
    yield (step: 28, isFinal: true, bytes: bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    (desktop: true, stop: false),
    (desktop: false, stop: false),
    (desktop: true, stop: true),
  ]) {
    test('循环生成保留桌面页与主动切页，移动端仅开始时切图库：$scenario', () async {
      final stores = AppStores.ephemeral();
      final client = _LoopClient(
        await File('assets/app_icon.png').readAsBytes(),
      );
      final c = ProviderContainer(
        overrides: [
          appStoresProvider.overrideWithValue(stores),
          desktopModeProvider.overrideWithValue(scenario.desktop),
          authModeProvider.overrideWith(_Auth.new),
          naiKeysStoreProvider.overrideWith(_Keys.new),
          naiClientProvider.overrideWith((ref, base) => client),
        ],
      );
      try {
        await c.read(authModeProvider.future);
        await c.read(naiKeysStoreProvider.future);
        c.read(generateProvider.notifier).setLoop(LoopCount.x4);
        final loop = c.read(loopStatusProvider.notifier);
        final work = loop.start();
        final pages = <int>[];
        final count = scenario.stop ? 1 : 4;
        for (var i = 0; i < count; i++) {
          await client.requests[i].future.timeout(const Duration(seconds: 10));
          pages.add(c.read(shellIndexProvider));
          if (scenario.stop) loop.stop();
          if (i == 1) {
            c.read(shellIndexProvider.notifier).select(kTabAssistant);
          }
          client.finish[i].complete();
        }
        await work.timeout(const Duration(seconds: 10));
        final initialPage = scenario.desktop ? kTabCreate : kTabGallery;
        expect(
          pages,
          scenario.stop
              ? [initialPage]
              : [initialPage, initialPage, kTabAssistant, kTabAssistant],
        );
        expect(
          c.read(shellIndexProvider),
          scenario.stop ? kTabCreate : kTabAssistant,
        );
        expect(client.count, count);
        expect(c.read(galleryProvider).results, hasLength(count));
        expect(c.read(generationProvider).jobs, isEmpty);
        expect(c.read(loopStatusProvider).active, isFalse);
      } finally {
        c.dispose();
        stores.flushNow();
        await stores.gallery.idle;
        await stores.albums.idle;
      }
    });
  }
  for (final automatic in [true, false]) {
    test('真实生成状态流保持任务图库，不打断正在浏览的网格：auto=$automatic', () async {
      final stores = AppStores.ephemeral();
      final client = _Client();
      final c = ProviderContainer(
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
      final albums = c.read(albumsProvider.notifier);
      final a = automatic
          ? dailyAlbumId(DateTime.now())
          : await albums.create('提交时图库');
      final b = await albums.create('后来查看的图库');
      if (!automatic) c.read(desktopLibraryProvider.notifier).choose(a);
      final work = c
          .read(generationProvider.notifier)
          .generate(using: GenerateState.initial());
      await client.started.future.timeout(const Duration(seconds: 10));
      expect(c.read(shellIndexProvider), kTabCreate);
      c.read(desktopLibraryProvider.notifier).choose(b);
      c.read(shellIndexProvider.notifier).select(kTabGallery);
      final bytes = await File('assets/app_icon.png').readAsBytes();
      client.frames.add((step: 28, isFinal: true, bytes: bytes));
      expect(await work, GenOutcome.ok);
      expect(c.read(shellIndexProvider), kTabGallery);
      expect(c.read(galleryBrowseAlbumProvider), b);
      final image = c.read(galleryProvider).results.single;
      expect(c.read(albumsProvider).ofImage(image.id), {a});
      final directory = stores.desktopOutput.folderFor(a, DateTime.now());
      final output = await directory
          .list()
          .where((f) => f.path.endsWith('.png'))
          .single;
      expect(await File(output.path).readAsBytes(), bytes);
      expect(c.read(generationProvider).jobs, isEmpty);
      await client.frames.close();
      stores.flushNow();
      await stores.gallery.idle;
      await stores.albums.idle;
      c.dispose();
    });
  }
}
