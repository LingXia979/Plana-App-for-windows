import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/widgets/char_ref_card.dart';
import 'package:plana_app/features/generate/widgets/img2img_card.dart';
import 'package:plana_app/features/generate/widgets/krea_style_ref_card.dart';
import 'package:plana_app/features/generate/widgets/vibe_card.dart';

import 'support/pump_until.dart';

class _DeferredDrop extends ImageDropPayload {
  _DeferredDrop() : super.image(name: 'test.png', load: () async => null);
  final ready = Completer<List<PickedImage>>();
  bool started = false;

  @override
  Future<List<PickedImage>> read() {
    started = true;
    return ready.future;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory libraryRoot;
  setUp(() {
    libraryRoot = Directory.systemTemp.createTempSync(
      'plana_canvas_asset_library_',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathsChannel,
      (_) async => libraryRoot.path,
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathsChannel, null);
    expect(
      libraryRoot.parent.absolute.path,
      Directory.systemTemp.absolute.path,
    );
    libraryRoot.deleteSync(recursive: true);
  });
  final bytes = File('assets/app_icon.png').readAsBytesSync();
  for (final kind in ['vibe', 'character', 'style', 'base']) {
    testWidgets(
      '$kind drop belongs to the canvas at drop time, including delayed reads',
      (tester) async {
        final stores = AppStores.ephemeral();
        final container = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            desktopModeProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);
        final gen = container.read(generateProvider.notifier);
        final canvases = container.read(canvasWorkspaceProvider.notifier);
        if (kind == 'style') gen.setModel('Krea 2 Turbo');
        final a = container.read(canvasWorkspaceProvider).activeId;
        final card = switch (kind) {
          'vibe' => const VibeCard(),
          'character' => const CharRefCard(),
          'style' => const KreaStyleRefCard(),
          _ => const Img2ImgCard(),
        };
        int count(CanvasPrompts p) => switch (kind) {
          'vibe' => p.vibes.length,
          'character' => p.charRefs.length,
          'style' => p.kreaStyleRefs.length,
          _ => p.img2img == null ? 0 : 1,
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: SizedBox(width: 500, child: card),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        void drop(_DeferredDrop payload) {
          tester
              .widget<DragTarget<ImageDropPayload>>(
                find.byType(DragTarget<ImageDropPayload>),
              )
              .onAcceptWithDetails!(
            DragTargetDetails(data: payload, offset: Offset.zero),
          );
        }

        final delayed = _DeferredDrop();
        drop(delayed);
        expect(delayed.started, isTrue);
        final b = canvases.create();
        await tester.pump();
        delayed.ready.complete([PickedImage('slow.png', bytes)]);
        await tester.pumpAndSettle();
        final workspace = container.read(canvasWorkspaceProvider);
        expect(count(workspace.find(a)!.prompts), 0);
        expect(count(workspace.find(b)!.prompts), 0);

        // A subsequent drop on the new canvas still works after the old target
        // was disposed. Exercise the real hashing/library/decoder path as well.
        final fresh = _DeferredDrop();
        drop(fresh);
        fresh.ready.complete([PickedImage('fresh.png', bytes)]);
        await pumpUntil(
          tester,
          () => count(CanvasPrompts.of(container.read(generateProvider))) == 1,
        );
        expect(
          count(container.read(canvasWorkspaceProvider).find(a)!.prompts),
          0,
        );
        expect(container.read(canvasWorkspaceProvider).activeId, b);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await pumpUntilComplete(tester, stores.flushForExit());
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'base picker helper cancels a captured source after switching canvases',
    (tester) async {
      final stores = AppStores.ephemeral();
      final container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(container.dispose);
      late WidgetRef widgetRef;
      late BuildContext mountedContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  widgetRef = ref;
                  mountedContext = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      final a = container.read(canvasWorkspaceProvider).activeId;
      container.read(canvasWorkspaceProvider.notifier).create();
      await pumpUntilComplete(
        tester,
        setImg2ImgFromImage(
          mountedContext,
          widgetRef,
          Uint8List.fromList(bytes),
          canvasId: a,
        ),
      );
      expect(container.read(generateProvider).img2img, isNull);
      expect(
        container.read(canvasWorkspaceProvider).find(a)!.prompts.img2img,
        isNull,
      );
      await pumpUntilComplete(tester, stores.flushForExit());
      await tester.pumpWidget(const SizedBox());
    },
  );
}
