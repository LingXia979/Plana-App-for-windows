import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/features/generate/preset_file.dart';
import 'package:plana_app/features/generate/preset_manage_page.dart';
import 'package:plana_app/features/generate/prompt_presets.dart';

class _Picker extends FilePicker {
  String? text;
  int calls = 0;

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
    calls++;
    expect(type, FileType.custom);
    expect(allowedExtensions, ['json']);
    expect(withData, isTrue);
    expect(allowMultiple, isFalse);
    final bytes = text == null ? null : Uint8List.fromList(utf8.encode(text!));
    return bytes == null
        ? null
        : FilePickerResult([
            PlatformFile(
              name: 'presets.json',
              size: bytes.length,
              bytes: bytes,
            ),
          ]);
  }
}

class _MemoryPresets extends PromptPresetsNotifier {
  int activations = 0;
  int reorders = 0;
  final imported = <List<PromptPreset>>[];
  PromptPresetsState get current => state.requireValue;

  @override
  Future<PromptPresetsState> build() async => const PromptPresetsState(
    presets: [
      PromptPreset(id: 'a', name: 'Alpha', positive: 'a', negative: ''),
      PromptPreset(id: 'b', name: 'Beta', positive: 'b', negative: ''),
      PromptPreset(id: 'c', name: 'Gamma', positive: 'c', negative: ''),
    ],
    activeId: 'c',
  );

  @override
  Future<void> setActive(String id) async {
    activations++;
    state = AsyncData(
      PromptPresetsState(presets: state.requireValue.presets, activeId: id),
    );
  }

  @override
  Future<void> reorder(int from, int to) async {
    reorders++;
    final old = state.requireValue;
    final next = [...old.presets];
    next.insert(to, next.removeAt(from));
    state = AsyncData(
      PromptPresetsState(presets: next, activeId: old.activeId),
    );
  }

  @override
  Future<int> importPresets(
    List<PromptPreset> incoming, {
    String? activeId,
  }) async {
    imported.add(incoming);
    return incoming.length;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late _Picker picker;
  late FilePicker originalPicker;
  late _MemoryPresets presets;

  setUpAll(() => FilePicker.platform = _Picker());
  setUp(() {
    originalPicker = FilePicker.platform;
    picker = _Picker();
    FilePicker.platform = picker;
    presets = _MemoryPresets();
  });
  tearDown(() => FilePicker.platform = originalPicker);

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopModeProvider.overrideWithValue(true),
          promptPresetsProvider.overrideWith(() => presets),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const PromptPresetManagePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'file import supports cancel, rejects invalid files, and retains fields',
    (tester) async {
      await mount(tester);
      final import = find.byTooltip('导入预设（JSON）');
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(presets.imported, isEmpty);
      expect(find.byType(SnackBar), findsNothing);

      picker.text = '[{"positive":"valid"},{"positive":12}]';
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(presets.imported, isEmpty);
      expect(find.textContaining('导入失败'), findsOneWidget);

      picker.text = jsonEncode([
        {'id': 'repeat', 'positive': 'old'},
        {
          'id': 'repeat',
          'name': 'New',
          'positive': 'latest',
          'negative': 'bad',
          'scope': 'v5',
          'positivePlacement': 'suffix',
        },
      ]);
      await tester.tap(import);
      await tester.pumpAndSettle();
      final imported = presets.imported.single.single;
      expect(imported.id, 'repeat');
      expect(imported.positive, 'latest');
      expect(imported.negative, 'bad');
      expect(imported.scope, 'v5');
      expect(imported.suffixPositive, isTrue);
      expect(presets.activations, 0);
      expect(picker.calls, 3);
    },
  );

  testWidgets(
    'mouse movement reorders immediately without activating or editing',
    (tester) async {
      await mount(tester);
      final first = tester.getRect(find.byKey(const ValueKey('a')));
      final last = tester.getRect(find.byKey(const ValueKey('c')));
      final pointer = await tester.startGesture(
        first.center,
        kind: PointerDeviceKind.mouse,
      );
      await pointer.moveBy(const Offset(0, 25));
      await tester.pump(const Duration(milliseconds: 1));
      await pointer.moveTo(Offset(first.center.dx, last.bottom));
      await tester.pump(const Duration(milliseconds: 100));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(presets.reorders, 1);
      expect(presets.current.presets.map((p) => p.id), ['b', 'a', 'c']);
      expect(presets.activations, 0);
      expect(presets.current.activeId, 'c');
      expect(find.text('编辑预设'), findsNothing);

      final click = await tester.startGesture(
        tester.getCenter(find.text('Alpha')),
        kind: PointerDeviceKind.mouse,
      );
      await click.moveBy(const Offset(.1, .1));
      await click.up();
      await tester.pumpAndSettle();
      expect(presets.activations, 1);
      expect(presets.reorders, 1);

      await tester.tap(find.byTooltip('编辑').first);
      await tester.pumpAndSettle();
      expect(find.text('编辑预设'), findsOneWidget);
      expect(presets.reorders, 1);
    },
  );

  testWidgets('touch still waits for long press before reordering on desktop', (
    tester,
  ) async {
    await mount(tester);
    final first = tester.getCenter(find.byKey(const ValueKey('a')));
    final short = await tester.startGesture(first);
    await short.moveBy(const Offset(0, 50));
    await short.up();
    await tester.pumpAndSettle();
    expect(presets.reorders, 0);
    expect(presets.activations, 0);

    final held = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await held.moveTo(tester.getCenter(find.byKey(const ValueKey('c'))));
    await tester.pump(const Duration(milliseconds: 300));
    await held.up();
    await tester.pumpAndSettle();
    expect(presets.reorders, 1);
    expect(presets.activations, 0);
  });

  test(
    'repeated import updates in place, preserves activation and persists scope',
    () async {
      final fixture = Directory.systemTemp.createTempSync(
        'plana_presets_import_',
      );
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => fixture.path,
      );
      final container = ProviderContainer();
      try {
        await container.read(promptPresetsProvider.future);
        final notifier = container.read(promptPresetsProvider.notifier);
        final source = jsonEncode({
          'presets': [
            {
              'id': 'first',
              'positive': 'a',
              'negative': 'b',
              'scope': 'legacy',
              'positivePlacement': 'suffix',
            },
            {'name': 'without id', 'positive': 'c'},
          ],
        });
        final incoming = parsePresetFile(source);
        await notifier.importPresets(incoming);
        await notifier.setActive('first');
        await notifier.reorder(5, 0);
        final orderBefore = container
            .read(promptPresetsProvider)
            .requireValue
            .presets
            .map((p) => p.id)
            .toList();
        await notifier.importPresets(parsePresetFile(source));
        final current = container.read(promptPresetsProvider).requireValue;
        expect(current.presets, hasLength(kDefaultPromptPresets.length + 2));
        expect(current.presets.map((p) => p.id), orderBefore);
        expect(current.activeId, 'first');
        final restoredContainer = ProviderContainer();
        try {
          final restored = await restoredContainer.read(
            promptPresetsProvider.future,
          );
          expect(restored.presets.map((p) => p.id), orderBefore);
          expect(restored.activeId, 'first');
          final first = restored.presets.firstWhere((p) => p.id == 'first');
          expect(first.positive, 'a');
          expect(first.negative, 'b');
          expect(first.scope, 'legacy');
          expect(first.suffixPositive, isTrue);
        } finally {
          restoredContainer.dispose();
        }
      } finally {
        container.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
