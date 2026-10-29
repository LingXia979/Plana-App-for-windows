import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/data/trans_cache_store.dart';

/// 后端翻回来的译名存到本机:写盘、开机灌回反查缓存、条数封顶。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 反查缓存是顶层全局,各用例用互不重叠的生造词。
  Directory tmp() {
    final d = Directory.systemTemp.createTempSync('trans_cache');
    addTearDown(() => d.deleteSync(recursive: true));
    return d;
  }

  test('落盘后,新开一份载入就能反查到', () async {
    final root = tmp();
    final a = TransCacheStore(root);
    a.put('zzq pearl necklace hanging', '垂挂珍珠项链');
    a.flush();
    await a.idle;

    final b = TransCacheStore(root);
    await b.load();
    expect(b.length, 1);
    expect(translationOf('zzq pearl necklace hanging'), '垂挂珍珠项链');
  });

  test('没有改动时 flush 不写盘', () async {
    final root = tmp();
    final s = TransCacheStore(root);
    s.flush();
    await s.idle;
    expect(File('${root.path}/tag_trans_cache.json').existsSync(), isFalse);
  });

  test('超过上限丢最早的', () async {
    final root = tmp();
    final a = TransCacheStore(root);
    for (var i = 0; i < TransCacheStore.cap + 10; i++) {
      a.put('zzq cap $i', '译$i');
    }
    a.flush();
    await a.idle;

    final saved =
        jsonDecode(File('${root.path}/tag_trans_cache.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(saved, hasLength(TransCacheStore.cap));
    expect(saved.containsKey('zzq cap 0'), isFalse);
    expect(
      saved['zzq cap ${TransCacheStore.cap + 9}'],
      '译${TransCacheStore.cap + 9}',
    );
  });

  test('翻译服务把后端翻出来的存进本机,查过没有的不存', () async {
    final root = tmp();
    final store = TransCacheStore(root);
    const hit = 'zzq livestream interface';
    const miss = 'zzq qqxx';
    final svc = TagTranslationService(
      enabled: true,
      baseUrl: 'https://x.test',
      saved: store,
      client: MockClient(
        (req) async => http.Response(
          jsonEncode({
            'translations': {hit: '直播界面'},
            'missing': [miss],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    addTearDown(svc.dispose);

    svc.request([hit, miss]);
    await Future<void>.delayed(const Duration(milliseconds: 900)); // 防抖 700ms
    store.flush();
    await store.idle;

    final saved =
        jsonDecode(File('${root.path}/tag_trans_cache.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(saved, {hit: '直播界面'});
  });

  test('写失败保留缓存,磁盘恢复后可重试', () async {
    final root = tmp();
    final blocker = Directory('${root.path}/tag_trans_cache.json')
      ..createSync();
    var errors = 0;
    final store = TransCacheStore(root, onSaveError: (_) => errors++);
    store.put('zzq retry cache', '重试缓存');
    store.flush();
    await expectLater(store.idle, throwsA(isA<FileSystemException>()));
    expect(errors, 1);
    blocker.deleteSync();
    store.flush();
    await store.idle;
    expect(
      jsonDecode(File('${root.path}/tag_trans_cache.json').readAsStringSync()),
      {'zzq retry cache': '重试缓存'},
    );
  });

  test('连续排队保存保留最新值及此前条目', () async {
    final root = tmp();
    final store = TransCacheStore(root);
    store.put('zzq queued alpha', '旧值');
    store.put('zzq queued keep', '保留');
    store.flush();
    store.put('zzq queued alpha', '新值');
    store.put('zzq queued beta', '新增');
    store.flush();
    await store.idle;
    expect(
      jsonDecode(File('${root.path}/tag_trans_cache.json').readAsStringSync()),
      {
        'zzq queued keep': '保留',
        'zzq queued alpha': '新值',
        'zzq queued beta': '新增',
      },
    );
  });

  test('规范化重复键,忽略空译名和原样返回的标签', () async {
    final root = tmp();
    final store = TransCacheStore(root);
    store.put('ZZQ_SAME__NAME', '旧值');
    store.put(' zzq same  name ', ' 新值 ');
    store.put('  ', '无名称');
    store.put('zzq empty translation', ' ');
    store.put('zzq unchanged', 'zzq unchanged');
    store.flush();
    await store.idle;
    final reopened = TransCacheStore(root);
    await reopened.load();
    expect(reopened.length, 1);
    expect(translationOf('ZZQ_SAME_NAME'), '新值');
  });

  test('旧缓存载入也限制条数,损坏行不影响有效译名', () async {
    final root = tmp();
    final data = <String, dynamic>{
      for (var i = 0; i < TransCacheStore.cap + 10; i++)
        'zzq loaded $i': '载入$i',
      'bad value': 10,
      'bad blank': ' ',
      '': '空键',
    };
    File(
      '${root.path}/tag_trans_cache.json',
    ).writeAsStringSync(jsonEncode(data));
    final store = TransCacheStore(root);
    await store.load();
    expect(store.length, TransCacheStore.cap);
    expect(translationOf('zzq loaded 0'), isNull, reason: '淘汰项不回填内存');
    expect(
      translationOf('zzq loaded ${TransCacheStore.cap + 9}'),
      '载入${TransCacheStore.cap + 9}',
    );
    expect(translationOf('bad value'), isNull);
  });

  test('损坏缓存不阻止启动,无新翻译时不覆盖原文件', () async {
    final root = tmp();
    final file = File('${root.path}/tag_trans_cache.json')
      ..writeAsStringSync('{broken');
    final stores = await AppStores.open(rootOverride: root);
    expect(stores.transCache.length, 0);
    await stores.flushForExit();
    expect(file.readAsStringSync(), '{broken');
  });

  test('正常退出保存防抖窗口内译名,重启后离线显示且不重新请求', () async {
    final root = tmp();
    final stores = await AppStores.open(rootOverride: root);
    const tag = 'zzq exited before debounce';
    stores.transCache.put(tag, '退出前的译名');
    expect(translationOf(tag), isNull, reason: 'put 仅写持久缓存,验证重启确实回填');
    await stores.flushForExit();
    final reopened = await AppStores.open(rootOverride: root);
    expect(translationOf(tag), '退出前的译名');
    var requests = 0;
    final service = TagTranslationService(
      enabled: true,
      baseUrl: 'https://offline.test',
      saved: reopened.transCache,
      client: MockClient((_) async {
        requests++;
        throw const SocketException('offline');
      }),
    );
    addTearDown(service.dispose);
    service.request([tag]);
    expect(service.isPending(tag), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(requests, 0);
    await reopened.flushForExit();
  });

  test('退出等待能发现缓存写失败,修复后重试保存最新内容', () async {
    final root = tmp();
    final stores = await AppStores.open(rootOverride: root);
    final blocker = Directory('${root.path}/tag_trans_cache.json')
      ..createSync();
    stores.transCache.put('zzq exit retry', '失败时的译名');
    await expectLater(
      stores.flushForExit(),
      throwsA(isA<FileSystemException>()),
    );
    expect(stores.saveError.value, contains('译名缓存保存失败'));
    blocker.deleteSync();
    stores.transCache.put('zzq exit retry', '修复后的译名');
    await stores.flushForExit();
    final reopened = await AppStores.open(rootOverride: root);
    expect(translationOf('zzq exit retry'), '修复后的译名');
    await reopened.flushForExit();
  });
}
