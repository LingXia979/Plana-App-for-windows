import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/artist_oc_library.dart';
import 'package:plana_app/features/editor/data/completion_source.dart';
import 'package:plana_app/features/editor/data/local_tag_db.dart';
import 'package:plana_app/features/editor/data/tag_completion.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final local = [
    TagEntry(
      id: 'local-role',
      name: '雪猫 qqxxzzqq',
      category: TagCategory.character,
      positive: 'blue hair, cat ears',
      origin: TagOrigin.local,
    ),
  ];

  TagCompletion completion({
    CompletionSource source = CompletionSource.enhanced,
    String base = 'https://completion.test',
    String? session,
    required http.Client client,
  }) {
    final tc = TagCompletion(
      source: source,
      baseUrl: base,
      localDb: LocalTagDb(),
      artistOcLib: ArtistOcLibrary(base, session, client),
      localOcs: Future.value(local),
      client: client,
    );
    addTearDown(tc.dispose);
    return tc;
  }

  test('增强模式英文先走内置词库,断网仍能补全角色', () async {
    var requests = 0;
    final tc = completion(
      client: MockClient((_) async {
        requests++;
        throw const SocketException('test offline');
      }),
    );
    expect(
      (await tc.query('hatsune mi')).characters.first.text,
      'hatsune miku',
    );
    expect(requests, 0);
  });

  test('后端地址尚未加载时仍可使用离线英文和本地 OC', () async {
    var requests = 0;
    final tc = completion(
      base: '',
      client: MockClient((_) async {
        requests++;
        throw const SocketException('test offline');
      }),
    );
    expect((await tc.query('blue hair')).tags.first.text, 'blue hair');
    expect((await tc.query('雪猫')).ocs.single.insertText, 'blue hair, cat ears');
    expect(requests, 0);
  });

  for (final query in ['雪猫', 'qqxxzzqq']) {
    test('联网失败不能丢弃本地角色: $query', () async {
      final tc = completion(
        session: 'fixture-session',
        client: MockClient((_) async {
          throw const SocketException('test offline');
        }),
      );
      final result = await tc.query(query);
      expect(result.ocs.single.text, local.single.name);
      expect(result.ocs.single.local, isTrue);
    });
  }

  test('离线模式角色分组、本地中文 OC 和辅助入口全部不联网', () async {
    var requests = 0;
    final tc = completion(
      source: CompletionSource.danbooru,
      session: 'fixture-session',
      client: MockClient((_) async {
        requests++;
        throw const SocketException('offline mode must not request');
      }),
    );
    expect(
      (await tc.query('hatsune mi')).characters.first.text,
      'hatsune miku',
    );
    expect((await tc.query('雪猫')).ocs.single.text, local.single.name);
    expect((await tc.query('qqxxzzqq')).ocs.single.text, local.single.name);
    expect(await tc.fetchWiki('blue hair'), isNull);
    expect(await tc.fetchWikiZh('blue hair'), isNull);
    expect(await tc.randomCharacterOf('vocaloid'), isNull);
    await tc.relatedOf('blue hair');
    expect(requests, 0);
  });

  for (final source in CompletionSource.values) {
    test('补全来源 $source 保存重启后保留,翻译开关跟随选择', () async {
      final root = Directory.systemTemp.createTempSync('plana_completion_pref');
      addTearDown(() => root.deleteSync(recursive: true));
      var stores = await AppStores.open(rootOverride: root);
      var container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      await container.read(completionSourcePrefProvider.future);
      expect(
        container.read(effectiveCompletionSourceProvider),
        CompletionSource.enhanced,
      );
      await container.read(completionSourcePrefProvider.notifier).set(source);
      container.dispose();
      await stores.flushForExit();

      stores = await AppStores.open(rootOverride: root);
      container = ProviderContainer(
        overrides: [appStoresProvider.overrideWithValue(stores)],
      );
      addTearDown(() async {
        container.dispose();
        await stores.flushForExit();
      });
      await container.read(completionSourcePrefProvider.future);
      expect(container.read(effectiveCompletionSourceProvider), source);
      expect(
        container.read(tagTranslationServiceProvider).enabled,
        source == CompletionSource.enhanced,
      );
      expect(
        container.read(tagTranslationServiceProvider).saved,
        same(stores.transCache),
      );
      expect(await stores.prefs.read(key: 'completion_source_v2'), source.name);
    });
  }
}
