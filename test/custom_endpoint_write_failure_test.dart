import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/secure_storage.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/agent_model.dart';
import 'package:plana_app/features/assistant/widgets/endpoint_sheet.dart';
import 'package:plana_app/features/assistant/widgets/model_sheet.dart';

class _FlakyStorage extends FlutterSecureStorage {
  String? stored;
  bool failRead = false;
  bool failWrite = true;
  Object? readError;
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    if (failRead) throw readError ?? StateError('secure storage unavailable');
    return stored;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrite) throw StateError('secure storage unavailable');
    stored = value;
  }
}

class _NoModelPreference extends AssistantModelPrefNotifier {
  @override
  Future<String> build() async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed endpoint write preserves the previous list and retries',
    () async {
      final storage = _FlakyStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      expect(await container.read(customEndpointsProvider.future), isEmpty);
      const endpoint = CustomEndpoint(
        id: 'test',
        name: 'Test',
        format: AgentApiFormat.openai,
        baseUrl: '',
        apiKey: 'secret',
        model: 'model',
      );
      await expectLater(
        container.read(customEndpointsProvider.notifier).put(endpoint),
        throwsStateError,
      );
      expect(container.read(customEndpointsProvider).value, isEmpty);
      storage.failWrite = false;
      await container.read(customEndpointsProvider.notifier).put(endpoint);
      expect(container.read(customEndpointsProvider).value, [endpoint]);
      storage.failWrite = true;
      await expectLater(
        container.read(customEndpointsProvider.notifier).remove(endpoint.id),
        throwsStateError,
      );
      expect(container.read(customEndpointsProvider).value, [endpoint]);
      storage.failWrite = false;
      await container
          .read(customEndpointsProvider.notifier)
          .remove(endpoint.id);
      expect(container.read(customEndpointsProvider).value, isEmpty);
    },
  );

  test('failed read cannot replace stored endpoints', () async {
    final storage = _FlakyStorage()
      ..stored = '[{"id":"existing","apiKey":"secret","model":"old"}]'
      ..failRead = true
      ..failWrite = false;
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(customEndpointsProvider.future),
      throwsStateError,
    );
    await expectLater(
      container
          .read(customEndpointsProvider.notifier)
          .put(
            const CustomEndpoint(
              id: 'new',
              name: 'New',
              format: AgentApiFormat.openai,
              baseUrl: '',
              apiKey: 'key',
              model: 'model',
            ),
          ),
      throwsStateError,
    );
    expect(storage.stored, contains('existing'));
  });

  test('concurrent endpoint saves retain both edits', () async {
    final storage = _FlakyStorage()..failWrite = false;
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(customEndpointsProvider.future);
    CustomEndpoint endpoint(String id) => CustomEndpoint(
      id: id,
      name: id,
      format: AgentApiFormat.openai,
      baseUrl: '',
      apiKey: 'key',
      model: 'model',
    );
    await Future.wait([
      container.read(customEndpointsProvider.notifier).put(endpoint('one')),
      container.read(customEndpointsProvider.notifier).put(endpoint('two')),
    ]);
    expect(container.read(customEndpointsProvider).value?.map((e) => e.id), [
      'one',
      'two',
    ]);
  });

  test('a failed reload cannot write the cached endpoint list', () async {
    final storage = _FlakyStorage()
      ..stored = '[{"id":"existing","apiKey":"fixture","model":"old"}]'
      ..failWrite = false;
    final container = ProviderContainer(
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(customEndpointsProvider.future);
    storage.failRead = true;
    container.invalidate(customEndpointsProvider);
    await expectLater(
      container.read(customEndpointsProvider.future),
      throwsStateError,
    );
    await expectLater(
      container.read(customEndpointsProvider.notifier).remove('existing'),
      throwsStateError,
    );
    expect(storage.stored, contains('existing'));
    storage.failRead = false;
    container.invalidate(customEndpointsProvider);
    await container.read(customEndpointsProvider.future);
    await container.read(customEndpointsProvider.notifier).remove('existing');
    expect(jsonDecode(storage.stored!), isEmpty);
  });

  test('invalid stored endpoint JSON is retained for recovery', () async {
    final storage = _FlakyStorage()
      ..stored = '{"unexpected":"fixture"}'
      ..failWrite = false;
    final container = ProviderContainer(
      retry: (count, error) => null,
      overrides: [secureStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(customEndpointsProvider.future),
      throwsFormatException,
    );
    await expectLater(
      container.read(customEndpointsProvider.notifier).remove('any'),
      throwsStateError,
    );
    expect(storage.stored, '{"unexpected":"fixture"}');
  });

  testWidgets(
    'endpoint sheet stays open with entered values after failed save',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = _FlakyStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await container.read(customEndpointsProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showEndpointSheet(context),
                  child: const Text('打开接口表单'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开接口表单'));
      await tester.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.enterText(field('API Key'), 'secret');
      await tester.enterText(field('模型'), 'model');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请检查安全存储后重试'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('API Key')).controller?.text,
        'secret',
      );
      expect(container.read(customEndpointsProvider).value, isEmpty);

      storage.failWrite = false;
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('添加接口'), findsNothing);
      expect(
        container.read(customEndpointsProvider).value?.single.model,
        'model',
      );
    },
  );

  testWidgets(
    'reload after exhausted read retries retains the form and stored endpoints',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = _FlakyStorage()
        ..stored = '[{"id":"existing","apiKey":"old-key","model":"old"}]'
        ..failRead = true
        ..readError = PlatformException(code: 'storage_unavailable')
        ..failWrite = false;
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showEndpointSheet(context),
                  child: const Text('打开接口表单'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开接口表单'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 7));
        await tester.pump();
      }
      expect(storage.reads, 11);
      expect(container.read(customEndpointsProvider).retrying, isFalse);
      expect(find.text('读取接口失败，请重新加载后保存'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      Finder field(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.enterText(field('API Key'), 'new-key');
      await tester.enterText(field('模型'), 'new-model');
      storage.failRead = false;
      await tester.ensureVisible(find.text('重新加载接口'));
      await tester.tap(find.text('重新加载接口'));
      await tester.pumpAndSettle();
      expect(find.text('读取接口失败，请重新加载后保存'), findsNothing);
      expect(
        tester.widget<TextField>(field('API Key')).controller!.text,
        'new-key',
      );
      expect(
        tester.widget<TextField>(field('模型')).controller!.text,
        'new-model',
      );
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final stored = jsonDecode(storage.stored!) as List;
      expect(stored, hasLength(2));
      expect(stored.first['id'], 'existing');
      expect(stored.last['model'], 'new-model');
      expect(find.text('添加接口'), findsNothing);
    },
  );

  testWidgets('desktop model menu reloads endpoints after a read failure', (
    tester,
  ) async {
    final storage = _FlakyStorage()
      ..stored =
          '[{"id":"existing","name":"Saved endpoint","apiKey":"key","model":"old"}]'
      ..failRead = true;
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        assistantModelPrefProvider.overrideWith(_NoModelPreference.new),
        assistantBotAuthorizedProvider.overrideWithValue(false),
        agentModelsProvider.overrideWith(
          (ref) async => const AgentModelList(choices: []),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 300, child: AssistantModelDropdown()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-model-button')));
    await tester.pumpAndSettle();
    expect(find.text('读取接口失败，重新加载接口'), findsOneWidget);
    storage.failRead = false;
    await tester.tap(find.text('读取接口失败，重新加载接口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-model-button')));
    await tester.pumpAndSettle();
    expect(find.text('Saved endpoint'), findsOneWidget);
    expect(find.text('读取接口失败，重新加载接口'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile model picker reloads endpoints after a read failure', (
    tester,
  ) async {
    final storage = _FlakyStorage()
      ..stored =
          '[{"id":"existing","name":"Saved endpoint","apiKey":"key","model":"old"}]'
      ..failRead = true;
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        assistantModelPrefProvider.overrideWith(_NoModelPreference.new),
        assistantBotAuthorizedProvider.overrideWithValue(false),
        agentModelsProvider.overrideWith((ref) async => const AgentModelList()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('open-model-picker'),
                onPressed: () => showModelSheet(context),
                child: const Text('选择模型'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-model-picker')));
    await tester.pumpAndSettle();
    expect(find.text('读取接口失败'), findsOneWidget);
    storage.failRead = false;
    await tester.tap(find.text('重新加载接口'));
    await tester.pumpAndSettle();
    expect(find.text('Saved endpoint'), findsOneWidget);
    expect(find.text('读取接口失败'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
