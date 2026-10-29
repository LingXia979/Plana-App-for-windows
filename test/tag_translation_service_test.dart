import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/editor/data/suggestions.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/editor/data/trans_cache_store.dart';

/// 2026-08-28 把两步(`/api/tags/translations/lookup` + `/api/translate/en2zh`)
/// 合成一次 `POST /api/tags/translate`。这个类一直留着 `http.Client` 注入口却零测试
/// 覆盖,借这次补上——尤其是「missing 也算有定论」那条:漏掉它芯片流的加载态会一直转。
void main() {
  // 反查缓存是顶层全局,测试间共享。各用例用互不重叠的生造词,避免相互污染。
  const hit = 'zzz alpha tag';
  const miss = 'zzz beta tag';
  const fail = 'zzz gamma tag';

  test('一次请求拿回译名;missing 也算有定论,不再重问', () async {
    final reqs = <http.Request>[];
    final svc = TagTranslationService(
      enabled: true,
      baseUrl: 'https://x.test',
      client: MockClient((req) async {
        reqs.add(req);
        return http.Response(
          jsonEncode({
            'translations': {hit: '阿尔法'},
            'sources': {hit: 'dataset'},
            'missing': [miss],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(svc.dispose);

    svc.request([hit, miss]);
    expect(svc.isPending(hit), isTrue, reason: '入队后、到货前应是加载态');
    await Future<void>.delayed(const Duration(milliseconds: 900)); // 防抖 700ms

    expect(reqs, hasLength(1), reason: '合并之后一批只该发一次请求');
    expect(reqs.single.url.path, '/api/tags/translate');
    expect(jsonDecode(reqs.single.body)['tags'], [hit, miss]);

    expect(translationOf(hit), '阿尔法');
    expect(svc.isPending(hit), isFalse);
    expect(
      svc.isPending(miss),
      isFalse,
      reason: 'missing 是「查过、确实没有」,不记下来芯片流会一直转',
    );
    expect(translationOf(miss), isNull);
  });

  test('后端没问成:不画加载态,词留着,下次问成就补上', () async {
    var calls = 0;
    var notified = 0;
    final svc = TagTranslationService(
      enabled: true,
      baseUrl: 'https://x.test',
      client: MockClient((req) async {
        calls++;
        if (calls == 1) return http.Response('boom', 500);
        return http.Response(
          jsonEncode({
            'translations': {fail: '伽马'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(svc.dispose);
    svc.addListener(() => notified++);

    svc.request([fail]);
    expect(svc.isPending(fail), isTrue, reason: '还在问');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(calls, 1);
    expect(translationOf(fail), isNull);
    expect(svc.isPending(fail), isFalse, reason: '没问成就别一直转');
    expect(notified, 1, reason: '加载态要收掉,得通知重绘');

    // 有新词进来会提前重试,上次没问成的那个一起带上
    svc.request(['zzz epsilon tag']);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(calls, 2);
    expect(translationOf(fail), '伽马');
    expect(notified, 2);
  });

  test('enabled=false 全程 no-op,一个请求都不发', () async {
    var calls = 0;
    final svc = TagTranslationService(
      enabled: false,
      baseUrl: 'https://x.test',
      client: MockClient((req) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(svc.dispose);

    svc.request(['zzz delta tag']);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(calls, 0);
    expect(svc.isPending('zzz delta tag'), isFalse, reason: '没人去问,挂着加载动画等于骗人');
  });

  for (final failed in [false, true]) {
    testWidgets('来源切换销毁服务后,旧${failed ? '失败' : '成功'}响应不回填也不重试', (tester) async {
      final root = Directory.systemTemp.createTempSync('plana_trans_disposed');
      addTearDown(() => root.deleteSync(recursive: true));
      final response = Completer<http.Response>();
      final tag = 'zzz disposed ${failed ? 'failure' : 'success'}';
      final store = TransCacheStore(root);
      var requests = 0;
      var notifications = 0;
      final svc = TagTranslationService(
        enabled: true,
        baseUrl: 'https://x.test',
        saved: store,
        client: MockClient((_) {
          requests++;
          return response.future;
        }),
      )..addListener(() => notifications++);
      svc.request([tag]);
      await tester.pump(const Duration(milliseconds: 750));
      expect(requests, 1);
      svc.dispose();
      response.complete(
        http.Response(
          failed
              ? '{}'
              : jsonEncode({
                  'translations': {tag: '过期译文'},
                }),
          failed ? 500 : 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(minutes: 2));
      svc.request(['zzz request after dispose']);
      await tester.pump(const Duration(seconds: 1));
      expect(translationOf(tag), isNull);
      expect(store.length, 0);
      expect(notifications, 0);
      expect(requests, 1);
      expect(svc.isPending(tag), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
