import 'dart:async';
import 'dart:io';

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
import 'package:plana_app/features/generate/generation_controller.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
