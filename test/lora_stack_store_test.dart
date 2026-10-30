import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/lora/lora_stacks.dart';

const entries = [
  LoraStackEntry(
    name: 'LR1',
    displayName: 'one',
    weight: 1.2,
    clipWeight: .4,
    enabled: false,
  ),
];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('plana_lora_stack_');
    stores = await AppStores.open(rootOverride: root);
    c = ProviderContainer(
      overrides: [appStoresProvider.overrideWithValue(stores)],
    );
  });
  tearDown(() async {
    c.dispose();
    try {
      await stores.flushForExit();
    } catch (_) {}
    await root.delete(recursive: true);
  });
  test(
    'concurrent saves, same-base replacement, delete and undo survive restart',
    () async {
      final n = c.read(loraStacksProvider.notifier);
      await c.read(loraStacksProvider.future);
      final saves = await Future.wait([
        n.save(name: '组合', base: 'anima', loras: entries),
        n.save(name: '组合', base: 'krea', loras: entries),
        n.save(name: '组合', base: 'anima', loras: entries),
        n.save(name: '第二组', base: 'anima', loras: entries),
      ]);
      expect(saves[2].replaced, isTrue);
      expect(saves[2].stack.id, saves[0].stack.id);
      final all = c.read(loraStacksProvider).requireValue;
      expect(all, hasLength(3));
      expect(all.map((s) => s.id).toSet(), hasLength(3));
      final index = await n.remove(saves[0].stack.id);
      await n.restore(saves[2].stack, index);
      await stores.flushForExit();
      final restored = await (await AppStores.open(
        rootOverride: root,
      )).loraStacks.load();
      expect(restored.map((s) => s.toJson()), all.map((s) => s.toJson()));
      expect(restored.first.loras.single.clipWeight, .4);
      expect(restored.first.loras.single.enabled, isFalse);
    },
  );
  test(
    'disk failure is visible, retained in provider and retried on exit',
    () async {
      final n = c.read(loraStacksProvider.notifier);
      await c.read(loraStacksProvider.future);
      final blocker = Directory('${root.path}/lora_stacks.json');
      await blocker.create();
      await expectLater(
        n.save(name: '组合', base: 'anima', loras: entries),
        throwsA(isA<FileSystemException>()),
      );
      expect(c.read(loraStacksProvider).requireValue.single.name, '组合');
      expect(stores.saveError.value, contains('LoRA'));
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      await stores.flushForExit();
      expect(
        await (await AppStores.open(rootOverride: root)).loraStacks.load(),
        hasLength(1),
      );
    },
  );
  test(
    'viewing an unreadable stack file does not trap application exit',
    () async {
      await File('${root.path}/lora_stacks.json').writeAsString('{broken');
      await expectLater(stores.loraStacks.load(), throwsFormatException);
      await stores.flushForExit();
      expect(
        await File('${root.path}/lora_stacks.json').readAsString(),
        '{broken',
      );
    },
  );

  test('corrupt stack file cannot be overwritten by save', () async {
    final file = File('${root.path}/lora_stacks.json');
    await file.writeAsString('{broken');
    await expectLater(
      stores.loraStacks.save(name: 'new', base: 'anima', loras: entries),
      throwsFormatException,
    );
    expect(await file.readAsString(), '{broken');
  });
  test('undo cannot duplicate a name saved again after deletion', () async {
    final a = await stores.loraStacks.save(
      name: 'same',
      base: 'anima',
      loras: entries,
    );
    final index = await stores.loraStacks.remove(a.stack.id);
    final b = await stores.loraStacks.save(
      name: 'same',
      base: 'anima',
      loras: entries,
    );
    await stores.loraStacks.restore(a.stack, index);
    expect((await stores.loraStacks.load()).single.id, b.stack.id);
  });
}
