import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/net/remote_image.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/editor_settings.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/character_card.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

class _Library extends TagLibrary {
  _Library(this.preview);
  final String preview;

  @override
  Future<TagLibraryState> build() async => TagLibraryState(
    entries: [
      TagEntry(
        id: 'replacement',
        category: TagCategory.character,
        name: '新角色',
        positive: 'new traveler',
        negative: 'hat',
        previews: [preview],
      ),
    ],
  );

  @override
  Future<void> markUsed(TagCategory c, List<String> ids) async {}
}

/// Synthetic portrait: a face in the orange top third, blue below it.
class CharacterAvatarFixture {
  final root = Directory.systemTemp.createTempSync('plana_avatar_ui_');
  final stores = AppStores.ephemeral();
  late final ProviderContainer container;
  late final String local = '${root.path}/portrait.png';
  static const remote = 'https://images.invalid/avatar-ui.png';

  Future<void> initialize({bool desktop = true}) async {
    final pixels = img.Image(width: 90, height: 270);
    for (var y = 0; y < 270; y++) {
      for (var x = 0; x < 90; x++) {
        final face = (x - 45) * (x - 45) + (y - 44) * (y - 44) < 29 * 29;
        final eye =
            (y >= 36 && y <= 41) &&
            ((x >= 33 && x <= 37) || (x >= 53 && x <= 57));
        final mouth = y >= 53 && y <= 57 && x >= 36 && x <= 54;
        if (eye || mouth) {
          pixels.setPixelRgb(x, y, 50, 50, 50);
        } else if (face) {
          pixels.setPixelRgb(x, y, 255, 225, 170);
        } else if (y < 90) {
          pixels.setPixelRgb(x, y, 240, 140, 60);
        } else {
          pixels.setPixelRgb(x, y, 50, 120, 220);
        }
      }
    }
    final png = Uint8List.fromList(img.encodePng(pixels));
    File(local).writeAsBytesSync(png);
    RemoteImageStore.bind(root);
    await RemoteImageStore.write(remote, png);
    RemoteImageStore.markChecked(remote);
    await stores.prefs.write(
      key: 'editor_settings',
      value: jsonEncode(
        const EditorSettings(
          enableCompletion: false,
          showTranslation: false,
        ).toJson(),
      ),
    );
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(desktop),
        publicTagsProvider.overrideWith((ref, cat) async => []),
        tagLibraryProvider.overrideWith(() => _Library(local)),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    container.read(generateProvider.notifier).addCharacter();
  }

  void setCharacter(String? avatar, {bool enabled = true}) {
    final gen = container.read(generateProvider.notifier);
    gen.applyCanvas(
      CanvasPrompts.of(
        container
            .read(generateProvider)
            .copyWith(
              characters: [
                CharacterPrompt(
                  id: 'avatar',
                  name: '示例角色',
                  positive: 'traveler, blue sky',
                  negative: 'lowres',
                  positiveRaw: 'traveler, ~hat~, blue sky',
                  avatar: avatar,
                  enabled: enabled,
                  position: 'B2',
                ),
              ],
            ),
      ),
      force: true,
    );
  }

  Future<void> mount(
    WidgetTester tester, {
    Widget child = const CharacterCard(),
    double width = 500,
    double scale = 1,
    bool dark = false,
    GlobalKey? capture,
  }) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: width, child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    container.dispose();
    stores.flushNow();
    await RemoteImageStore.clear();
    root.deleteSync(recursive: true);
  }
}

Future<void> waitForAvatarImage(WidgetTester tester, Finder parent) async {
  final images = find.descendant(of: parent, matching: find.byType(RawImage));
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (images.evaluate().isNotEmpty &&
        tester
            .widgetList<RawImage>(images)
            .every((image) => image.image != null)) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Avatar did not decode');
}
