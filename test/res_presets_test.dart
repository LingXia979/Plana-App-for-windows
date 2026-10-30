import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/generate/res_presets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('plana_sizes_');
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
    'normalizes dimensions, deduplicates, removes and persists in configured directory',
    () async {
      final n = c.read(resPresetsProvider.notifier);
      await n.add(833, 1025);
      await n.add(832, 1024);
      await n.add(1024, 832);
      expect(c.read(resPresetsProvider), hasLength(2));
      expect(c.read(resPresetsProvider).first.name, '竖图');
      await n.remove(832, 1024);
      await stores.flushForExit();
      final reloaded = await AppStores.open(rootOverride: root);
      final c2 = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(reloaded)],
      );
      addTearDown(c2.dispose);
      final result = c2.read(resPresetsProvider).single;
      expect((result.width, result.height), (1024, 832));
    },
  );
  test(
    'failed settings write retains preset and blocks exit until retry succeeds',
    () async {
      final blocker = Directory('${root.path}/settings.json');
      await blocker.create();
      await expectLater(
        c.read(resPresetsProvider.notifier).add(832, 1024),
        throwsA(isA<FileSystemException>()),
      );
      expect(c.read(resPresetsProvider), hasLength(1));
      expect(stores.saveError.value, contains('设置'));
      await expectLater(
        stores.flushForExit(),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      await stores.flushForExit();
      expect(
        await File('${root.path}/settings.json').readAsString(),
        contains('res_presets'),
      );
    },
  );
  test('malformed preset payload is preserved when trying to add', () async {
    await stores.prefs.write(key: 'res_presets', value: '{broken');
    expect(c.read(resPresetsProvider), isEmpty);
    await expectLater(
      c.read(resPresetsProvider.notifier).add(832, 1024),
      throwsStateError,
    );
    expect(stores.prefs.get('res_presets'), '{broken');
  });
}
