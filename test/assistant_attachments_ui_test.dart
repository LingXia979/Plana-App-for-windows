import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/ui/image_drop.dart';
import 'package:plana_app/core/util/image_pick.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/assistant_images.dart';
import 'package:plana_app/features/assistant/assistant_models.dart';
import 'package:plana_app/features/assistant/assistant_page.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/assistant_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';

class _Canvas extends GenerateNotifier {
  @override
  GenerateState build() => GenerateState.initial();
}

class _Picker extends FilePicker {
  List<PlatformFile> files = [];
  bool? multiple;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    multiple = allowMultiple;
    return files.isEmpty ? null : FilePickerResult(files);
  }
}

class _Recorder extends AssistantNotifier {
  final sent = <({String text, List<Uint8List> images})>[];
  bool accept = true;
  Completer<void>? preparing;
  @override
  AssistantState build() => const AssistantState(
    msgs: [AssistantMsg(id: 'previous', role: MsgRole.ai, text: '已有对话', at: 1)],
  );
  void seed(AssistantState value) => state = value;
  @override
  Future<void> send(
    String text, {
    Uint8List? image,
    List<Uint8List> images = const [],
    bool withCanvas = false,
    void Function()? onAccepted,
  }) async {
    sent.add((text: text, images: [?image, ...images]));
    if (preparing != null) await preparing!.future;
    if (accept) onAccepted?.call();
  }
}

class _Settings extends AssistantSettingsNotifier {
  @override
  Future<AssistantSettings> build() async => const AssistantSettings(
    introVersion: kAssistantIntroVersion,
    libraryScope: LibraryScope.none,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pngA = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 16, height: 24)..clear(img.ColorRgb8(240, 80, 90)),
    ),
  );
  final pngB = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 24, height: 16)..clear(img.ColorRgb8(80, 140, 220)),
    ),
  );
  late AppStores stores;
  late ProviderContainer container;
  late _Picker picker;
  late Directory files;
  late File first;
  late File second;
  final historyReads = <String, Completer<Uint8List?>>{};
  var fallbackImports = 0;

  setUp(() {
    historyReads.clear();
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        assistantBotAuthorizedProvider.overrideWithValue(true),
        assistantEndpointProvider.overrideWithValue(null),
        assistantProvider.overrideWith(_Recorder.new),
        generateProvider.overrideWith(_Canvas.new),
        galleryThumbProvider.overrideWith((ref, id) async => pngB),
        galleryImageProvider.overrideWith(
          (ref, id) => historyReads[id]?.future ?? stores.gallery.readImage(id),
        ),
        assistantSettingsProvider.overrideWith(_Settings.new),
        agentModelsProvider.overrideWith((ref) async => const AgentModelList()),
      ],
    );
    picker = _Picker();
    FilePicker.platform = picker;
    files = Directory.systemTemp.createTempSync('plana_assistant_attachments_');
    first = File('${files.path}/first.png')..writeAsBytesSync(pngA);
    second = File('${files.path}/second.png')..writeAsBytesSync(pngB);
    fallbackImports = 0;
  });
  tearDown(() async {
    container.dispose();
    stores.flushNow();
    await stores.assistant.idle;
    await stores.workspace.idle;
    await stores.gallery.idle;
    await stores.ledger.idle;
    await stores.desktopOutput.idle;
    final storeRoot = stores.desktopOutput.root.parent;
    expect(
      storeRoot.path.startsWith(
        '${Directory.systemTemp.path}${Platform.pathSeparator}plana_stores',
      ),
      isTrue,
    );
    storeRoot.deleteSync(recursive: true);
    files.deleteSync(recursive: true);
  });

  Finder key(String value) => find.byKey(ValueKey(value));
  _Recorder recorder() =>
      container.read(assistantProvider.notifier) as _Recorder;

  ResultImage historyItem(String id, {Uint8List? bytes}) =>
      ResultImage(id: id, width: 16, height: 24, seed: 1, bytes: bytes);

  Future<void> mount(
    WidgetTester tester, {
    bool embedded = false,
    double sidebarWidth = 400,
    ValueNotifier<bool>? visibility,
  }) async {
    tester.view.physicalSize = const Size(1200, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final page = embedded
        ? Row(
            children: [
              Expanded(
                child: Center(
                  child: DesktopImageDraggable(
                    data: ImageDropPayload.image(
                      name: 'canvas.png',
                      load: () async => pngA,
                    ),
                    feedback: const SizedBox(width: 32, height: 32),
                    child: const SizedBox(
                      key: ValueKey('canvas-source'),
                      width: 120,
                      height: 120,
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: sidebarWidth,
                child: const AssistantPage(embedded: true),
              ),
            ],
          )
        : const AssistantPage();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          builder: (_, child) => DesktopImageDropHost(child: child!),
          home: Scaffold(
            body: ImageDropRegion(
              label: '导入图片',
              acceptInternal: false,
              onDrop: (_, _) async => fallbackImports++,
              child: visibility == null
                  ? page
                  : ValueListenableBuilder<bool>(
                      valueListenable: visibility,
                      builder: (_, visible, child) =>
                          visible ? child! : const SizedBox(),
                      child: page,
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  Future<void> native(
    WidgetTester tester,
    String method,
    Offset point,
    List<String> paths,
  ) async {
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        DesktopImageDropHost.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, {'x': point.dx, 'y': point.dy, 'paths': paths}),
        ),
        (_) {},
      );
    });
    await settle(tester);
  }

  testWidgets(
    'file picker adds multiple images, later picks append and individual removal preserves order',
    (tester) async {
      await mount(tester, embedded: true);
      picker.files = [
        PlatformFile(name: 'first.png', size: pngA.length, bytes: pngA),
        PlatformFile(name: 'second.png', size: pngB.length, bytes: pngB),
      ];
      await tester.tap(find.byTooltip('添加图片（可多选）'));
      await tester.pumpAndSettle();
      expect(picker.multiple, isTrue);
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      expect(find.text('多张图片会合并为参考图发送'), findsOneWidget);
      picker.files = [
        PlatformFile(name: 'third.png', size: pngA.length, bytes: pngA),
      ];
      await tester.tap(find.byTooltip('添加图片（可多选）'));
      await tester.pumpAndSettle();
      expect(find.text('已添加 3 张图片'), findsOneWidget);
      await tester.tap(find.byTooltip('移除图片 1：first.png'));
      await tester.pumpAndSettle();
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
      await tester.pumpAndSettle();
      expect(recorder().sent.single.images, [pngB, pngA]);
      expect(key('assistant-pending-images'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final embedded in [false, true]) {
    testWidgets(
      'clipboard image and files append without import or send, embedded=$embedded',
      (tester) async {
        await mount(tester, embedded: embedded);
        final point = embedded
            ? const Offset(1000, 180)
            : const Offset(50, 380);
        await tester.runAsync(() async {
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            DesktopImageDropHost.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('paste', {
                'x': point.dx,
                'y': point.dy,
                'bytes': pngA,
                'bitmap': false,
                'paths': <String>[],
                'error': '',
              }),
            ),
            (_) {},
          );
        });
        await settle(tester);
        expect(key('assistant-pending-images'), findsOneWidget);
        await native(tester, 'paste', point, [second.path]);
        expect(find.text('已添加 2 张图片'), findsOneWidget);
        expect(fallbackImports, 0);
        expect(recorder().sent, isEmpty);
        await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
        await tester.pumpAndSettle();
        expect(recorder().sent.single.images, [pngA, pngB]);
      },
    );
    testWidgets(
      'external batch anywhere in assistant attaches instead of importing, embedded=$embedded',
      (tester) async {
        await mount(tester, embedded: embedded);
        // Deliberately outside the composer: sidebar/history or blank right margin.
        final points = embedded
            ? [const Offset(1000, 140), const Offset(1180, 360)]
            : [const Offset(50, 380), const Offset(1180, 320)];
        await native(tester, 'over', points.first, [first.path, second.path]);
        expect(find.text('松开以将图片添加到对话框'), findsOneWidget);
        expect(find.text('松开以导入图片'), findsNothing);
        await native(tester, 'drop', points.first, [first.path, second.path]);
        expect(find.text('已添加 2 张图片'), findsOneWidget);
        await native(tester, 'drop', points.last, [first.path]);
        expect(find.text('已添加 3 张图片'), findsOneWidget);
        expect(fallbackImports, 0);
        expect(recorder().sent, isEmpty);
        if (embedded) {
          await native(tester, 'drop', const Offset(20, 20), [first.path]);
          expect(fallbackImports, 1);
          expect(find.text('已添加 3 张图片'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'canvas drag to conversation appends to existing attachments without import or send',
    (tester) async {
      await mount(tester, embedded: true);
      await native(tester, 'drop', const Offset(1000, 150), [second.path]);
      final gesture = await tester.startGesture(
        tester.getCenter(key('canvas-source')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(20, -20));
      await tester.pump();
      await gesture.moveTo(const Offset(1000, 220));
      await tester.pump();
      expect(find.text('松开以将图片添加到对话框'), findsOneWidget);
      await gesture.up();
      await settle(tester);
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      expect(fallbackImports, 0);
      expect(recorder().sent, isEmpty);
    },
  );

  testWidgets(
    'invalid batch, attachment limit, cancellation and busy drops keep the draft',
    (tester) async {
      await mount(tester);
      await native(tester, 'drop', const Offset(1100, 200), [first.path]);
      final invalid = File('${files.path}/bad.png')
        ..writeAsStringSync('invalid');
      await native(tester, 'drop', const Offset(1100, 200), [
        second.path,
        invalid.path,
      ]);
      expect(find.text('已添加 1 张图片'), findsOneWidget);
      picker.files = List.generate(
        kAssistantMaxAttachments,
        (i) => PlatformFile(name: '$i.png', size: pngA.length, bytes: pngA),
      );
      await tester.tap(find.byTooltip('添加图片（可多选）'));
      await tester.pump();
      expect(find.text('已添加 1 张图片'), findsOneWidget);
      picker.files = [];
      await tester.tap(find.byTooltip('添加图片（可多选）'));
      await tester.pump();
      expect(find.text('已添加 1 张图片'), findsOneWidget);
      recorder().seed(
        container.read(assistantProvider).copyWith(running: true),
      );
      await tester.pump();
      await native(tester, 'drop', const Offset(1100, 200), [second.path]);
      expect(find.text('已添加 1 张图片'), findsOneWidget);
      expect(fallbackImports, 0);
      recorder().seed(
        container.read(assistantProvider).copyWith(running: false),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'draft clears only after acceptance; preparation failure preserves images and text',
    (tester) async {
      await mount(tester);
      await native(tester, 'drop', const Offset(1100, 200), [
        first.path,
        second.path,
      ]);
      final input = find.widgetWithText(TextField, '想画什么、想改哪里…');
      await tester.enterText(input, '对比这两张图片');
      recorder().accept = false;
      await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
      await tester.pumpAndSettle();
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      expect(find.text('对比这两张图片'), findsOneWidget);
      recorder().accept = true;
      final preparing = recorder().preparing = Completer<void>();
      await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
      await tester.pump();
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(recorder().sent.length, 2);
      preparing.complete();
      await tester.pumpAndSettle();
      expect(key('assistant-pending-images'), findsNothing);
      expect(find.text('对比这两张图片'), findsNothing);
      expect(recorder().sent.last.images, [pngA, pngB]);
    },
  );

  testWidgets(
    'attachments that finish reading during send remain pending for the next message',
    (tester) async {
      await mount(tester, embedded: true);
      await native(tester, 'drop', const Offset(1100, 200), [first.path]);
      final acceptedDrop = tester
          .widget<ImageDropRegion>(key('assistant-image-drop'))
          .onDrop;
      final preparing = recorder().preparing = Completer<void>();
      await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
      await tester.pump();
      // The receiver accepted this batch earlier; file decoding finishes now.
      await acceptedDrop([
        PickedImage('late.png', pngB),
      ], ImageDropPayload.files([second.path]));
      await tester.pump();
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      preparing.complete();
      await tester.pumpAndSettle();
      expect(recorder().sent.single.images, [pngA]);
      expect(find.text('已添加 1 张图片'), findsOneWidget);
      recorder().seed(
        container.read(assistantProvider).copyWith(running: true),
      );
      await tester.pump();
      await acceptedDrop([
        PickedImage('later.png', pngA),
      ], ImageDropPayload.files([first.path]));
      await tester.pump();
      expect(find.text('已添加 2 张图片'), findsOneWidget);
      recorder().seed(
        container.read(assistantProvider).copyWith(running: false),
      );
      await tester.pumpAndSettle();
      recorder().preparing = null;
      await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
      await tester.pumpAndSettle();
      expect(recorder().sent.last.images, [pngB, pngA]);
      expect(key('assistant-pending-images'), findsNothing);
    },
  );

  testWidgets(
    'legacy single-image and new multi-image messages both show every stored attachment',
    (tester) async {
      final hashes = (await tester.runAsync(
        () => stores.assistant.putImages([pngA, pngB]),
      ))!;
      final hashA = hashes[0];
      final hashB = hashes[1];
      recorder().seed(
        AssistantState(
          msgs: [
            AssistantMsg(
              id: 'legacy',
              role: MsgRole.user,
              text: '旧消息',
              at: 1,
              imageHash: hashA,
            ),
            AssistantMsg(
              id: 'multi',
              role: MsgRole.user,
              text: '多图消息',
              at: 2,
              imageHashes: [hashA, hashB],
            ),
          ],
        ),
      );
      await mount(tester, embedded: true);
      await settle(tester);
      expect(key('assistant-message-image-legacy-0'), findsOneWidget);
      expect(key('assistant-message-image-multi-0'), findsOneWidget);
      expect(key('assistant-message-image-multi-1'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  for (final embedded in [false, true]) {
    testWidgets(
      'history appends two original images to the draft without selecting or sending, embedded=$embedded',
      (tester) async {
        final diskImage = historyItem('history-disk', bytes: pngA);
        await tester.runAsync(() => stores.gallery.persistResult(diskImage));
        stores.gallery.initialResults = [
          diskImage.stripped(),
          historyItem('history-memory', bytes: pngB),
          historyItem('canvas-selected', bytes: pngA),
        ];
        stores.gallery.initialSelectedId = 'canvas-selected';
        await mount(tester, embedded: embedded, sidebarWidth: 330);
        final originalCanvas = container.read(generateProvider);
        final originalGallery = container.read(galleryProvider);
        picker.files = [
          PlatformFile(name: 'existing.png', size: pngB.length, bytes: pngB),
        ];
        await tester.tap(find.byTooltip('添加图片（可多选）'));
        await tester.pumpAndSettle();
        expect(key('assistant-history-images').hitTestable(), findsOneWidget);
        await tester.tap(key('assistant-history-images'));
        await tester.pumpAndSettle();
        expect(key('history-image-picker'), findsOneWidget);
        await tester.tap(key('history-image-history-disk'));
        await tester.pumpAndSettle();
        await tester.tap(key('history-image-history-memory'));
        await tester.pumpAndSettle();
        expect(find.text('添加（2 张）'), findsOneWidget);
        await tester.tap(key('history-confirm-selection'));
        await settle(tester);
        await tester.pumpAndSettle();
        expect(key('history-image-picker'), findsNothing);
        expect(find.text('已添加 3 张图片'), findsOneWidget);
        expect(recorder().sent, isEmpty);
        expect(container.read(galleryProvider), same(originalGallery));
        expect(container.read(generateProvider), same(originalCanvas));
        await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
        await tester.pumpAndSettle();
        // The disk image's thumbnail is mocked as pngB. Sending pngA proves
        // attachment loading uses the original, not the gallery preview.
        expect(recorder().sent.single.images, [pngB, pngA, pngB]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'cancelling history keeps existing attachments and text, embedded=$embedded',
      (tester) async {
        stores.gallery.initialResults = [historyItem('history', bytes: pngA)];
        await mount(tester, embedded: embedded, sidebarWidth: 330);
        picker.files = [
          PlatformFile(name: 'existing.png', size: pngB.length, bytes: pngB),
        ];
        await tester.tap(find.byTooltip('添加图片（可多选）'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '想画什么、想改哪里…'),
          '保留这条草稿',
        );
        await tester.tap(key('assistant-history-images'));
        await tester.pumpAndSettle();
        await tester.tap(key('history-image-history'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: key('history-image-picker'),
            matching: find.byType(CloseButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('已添加 1 张图片'), findsOneWidget);
        expect(find.text('保留这条草稿'), findsOneWidget);
        expect(recorder().sent, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'empty history stays empty and has no enabled add action, embedded=$embedded',
      (tester) async {
        await mount(tester, embedded: embedded, sidebarWidth: 330);
        await tester.tap(key('assistant-history-images'));
        await tester.pumpAndSettle();
        expect(find.text('暂无历史图片，生成的作品会显示在这里'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(key('history-confirm-selection'))
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.descendant(
            of: key('history-image-picker'),
            matching: find.byType(CloseButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(key('assistant-pending-images'), findsNothing);
        expect(recorder().sent, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'one missing history original rejects the complete selection and preserves the draft, embedded=$embedded',
      (tester) async {
        stores.gallery.initialResults = [
          historyItem('available', bytes: pngA),
          historyItem('missing'),
        ];
        await mount(tester, embedded: embedded, sidebarWidth: 330);
        picker.files = [
          PlatformFile(name: 'existing.png', size: pngB.length, bytes: pngB),
        ];
        await tester.tap(find.byTooltip('添加图片（可多选）'));
        await tester.pumpAndSettle();
        await tester.tap(key('assistant-history-images'));
        await tester.pumpAndSettle();
        await tester.tap(key('history-select-all'));
        await tester.pumpAndSettle();
        await tester.tap(key('history-confirm-selection'));
        await settle(tester);
        await tester.pumpAndSettle();
        expect(find.text('已添加 1 张图片'), findsOneWidget);
        expect(find.text('无法读取选中的历史原图，文件可能已被移动或删除，本次未添加图片'), findsOneWidget);
        expect(recorder().sent, isEmpty);
        expect(
          tester.widget<IconButton>(key('assistant-history-images')).onPressed,
          isNotNull,
        );
        await tester.tap(find.byTooltip('发送 (Enter) · Shift + Enter 换行'));
        await tester.pumpAndSettle();
        expect(recorder().sent.single.images, [pngB]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('history applies the 64-image total limit without truncation', (
    tester,
  ) async {
    stores.gallery.initialResults = [
      historyItem('history-a', bytes: pngA),
      historyItem('history-b', bytes: pngB),
    ];
    await mount(tester, embedded: true, sidebarWidth: 330);
    picker.files = List.generate(
      kAssistantMaxAttachments - 1,
      (i) => PlatformFile(name: '$i.png', size: pngA.length, bytes: pngA),
    );
    await tester.tap(find.byTooltip('添加图片（可多选）'));
    await tester.pumpAndSettle();
    await tester.tap(key('assistant-history-images'));
    await tester.pumpAndSettle();
    await tester.tap(key('history-select-all'));
    await tester.pumpAndSettle();
    await tester.tap(key('history-confirm-selection'));
    await tester.pumpAndSettle();
    expect(find.text('已添加 63 张图片'), findsOneWidget);
    expect(find.text('每条消息最多添加 64 张图片'), findsOneWidget);
    expect(recorder().sent, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing assistant during original loading ignores the result', (
    tester,
  ) async {
    stores.gallery.initialResults = [historyItem('slow')];
    final loading = historyReads['slow'] = Completer<Uint8List?>();
    final visibility = ValueNotifier(true);
    addTearDown(visibility.dispose);
    await mount(
      tester,
      embedded: true,
      sidebarWidth: 330,
      visibility: visibility,
    );
    await tester.tap(key('assistant-history-images'));
    await tester.pumpAndSettle();
    await tester.tap(key('history-select-all'));
    await tester.pumpAndSettle();
    await tester.tap(key('history-confirm-selection'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(key('assistant-history-images')).onPressed,
      isNull,
    );
    visibility.value = false;
    await tester.pumpAndSettle();
    loading.complete(pngA);
    await tester.pumpAndSettle();
    expect(key('assistant-pending-images'), findsNothing);
    expect(recorder().sent, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
