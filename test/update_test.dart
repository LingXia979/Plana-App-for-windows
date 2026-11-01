import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/features/update/update_service.dart';

/// 更新判定的纯逻辑。错了不会崩,只会"永远不提示"或"反复提示已装的版本" ——
/// 两种都是用户不会报、你也看不见的静默故障,所以钉在这里。
void main() {
  test(
    'Windows release checks use the Windows repository and recognize the combined update',
    () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        expect(
          request.url.path,
          '/repos/LingXia979/Plana-App-for-windows/releases',
        );
        return http.Response(
          jsonEncode([
            {
              'tag_name': 'v1.2.2-windows.59',
              'html_url':
                  'https://github.com/LingXia979/Plana-App-for-windows/releases/tag/v1.2.2-windows.59',
              'prerelease': false,
              'draft': false,
            },
          ]),
          200,
        );
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        expect(
          (await fetchLatestRelease('1.2.1-windows.57'))?.tag,
          'v1.2.2-windows.59',
        );
        expect(
          (await fetchLatestRelease('1.2.2-windows.58'))?.tag,
          'v1.2.2-windows.59',
        );
        expect(await fetchLatestRelease('1.2.2-windows.59'), isNull);
      }, () => client);
    },
  );

  group('compareSemver', () {
    void newer(String a, String b) {
      expect(compareSemver(a, b), greaterThan(0), reason: '$a 应比 $b 新');
      expect(compareSemver(b, a), lessThan(0), reason: '$b 应比 $a 旧');
    }

    test('主次修订逐段按数字比', () {
      newer('1.0.1', '1.0.0');
      newer('1.1.0', '1.0.9');
      newer('2.0.0', '1.99.99');
    });

    test('**预发布段按数字比,不按字典序** —— beta.10 必须比 beta.9 新', () {
      // 字符串比会判反,这正是不能偷懒用 String.compareTo 的原因
      newer('1.0.0-beta.10', '1.0.0-beta.9');
      newer('1.0.0-beta.2', '1.0.0-beta.1');
    });

    test('带预发布标识的版本小于同号正式版', () {
      newer('1.0.0', '1.0.0-beta.1');
      newer('1.0.0', '1.0.0-rc.1');
    });

    test('预发布标识:数字段 < 字母段;前缀相同则段数少的更小', () {
      newer('1.0.0-beta', '1.0.0-1');
      newer('1.0.0-beta.1', '1.0.0-beta');
      newer('1.0.0-rc.1', '1.0.0-beta.1');
    });

    test('剥前导 v,忽略 +build 元数据', () {
      expect(compareSemver('v1.0.0', '1.0.0'), 0);
      expect(compareSemver('1.0.0+3', '1.0.0+9'), 0);
      newer('v1.0.1+1', '1.0.0+99');
    });

    test('缺段按 0 补(1.0 == 1.0.0)', () {
      expect(compareSemver('1.0', '1.0.0'), 0);
      newer('1.1', '1.0.5');
    });

    test('相等就是相等 —— 不能把自己判成有新版', () {
      expect(compareSemver('1.0.0-beta.1', 'v1.0.0-beta.1'), 0);
    });
  });

  group('isPrerelease', () {
    test('识别预发布', () {
      expect(isPrerelease('1.0.0-beta.1'), isTrue);
      expect(isPrerelease('v1.0.0'), isFalse);
      expect(isPrerelease('1.0.0+3'), isFalse);
    });
  });

  group('pickNewer', () {
    Map<String, dynamic> rel(
      String tag, {
      bool pre = false,
      bool draft = false,
    }) => {
      'tag_name': tag,
      'html_url': 'https://github.com/x/y/releases/tag/$tag',
      'name': '',
      'body': '',
      'prerelease': pre,
      'draft': draft,
    };

    test('挑出更新的那个', () {
      final r = pickNewer('1.0.0-beta.1', [rel('v1.0.0-beta.2', pre: true)]);
      expect(r?.tag, 'v1.0.0-beta.2');
    });

    test('同版本或更旧 → 无更新', () {
      expect(
        pickNewer('1.0.0-beta.2', [rel('v1.0.0-beta.2', pre: true)]),
        isNull,
      );
      expect(pickNewer('1.0.0', [rel('v0.9.0')]), isNull);
    });

    test('草稿不算数', () {
      expect(pickNewer('1.0.0', [rel('v2.0.0', draft: true)]), isNull);
    });

    test('正式版用户不会被推预发布', () {
      expect(pickNewer('1.0.0', [rel('v1.1.0-beta.1', pre: true)]), isNull);
      // 但正式版仍然推
      expect(pickNewer('1.0.0', [rel('v1.1.0')])?.tag, 'v1.1.0');
    });

    test('beta 用户照收 beta', () {
      final r = pickNewer('1.0.0-beta.1', [rel('v1.0.0-beta.2', pre: true)]);
      expect(r?.tag, 'v1.0.0-beta.2');
    });

    test('列表里混着旧版也能挑对(GitHub 按时间倒序,不保证版本序)', () {
      final r = pickNewer('1.0.0-beta.1', [
        rel('v0.9.0'),
        rel('v1.0.0-beta.3', pre: true),
      ]);
      expect(r?.tag, 'v1.0.0-beta.3');
    });

    test('脏数据条目跳过,不整体炸掉', () {
      final r = pickNewer('1.0.0', [
        {'no_tag': true},
        rel('v1.2.0'),
      ]);
      expect(r?.tag, 'v1.2.0');
    });

    test('展示名:release 标题为空时回落到 tag', () {
      final r = pickNewer('1.0.0', [rel('v1.2.0')]);
      expect(r?.display, 'v1.2.0');
    });
  });

  group('shouldAutoCheck', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('plana_update'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('从没查过 → 查', () {
      expect(shouldAutoCheck(PrefsStore.emptyForTest(tmp)), isTrue);
    });

    test('刚查过 → 不查;超过间隔 → 查', () async {
      final prefs = PrefsStore.emptyForTest(tmp);
      await markUpdateChecked(prefs);
      expect(shouldAutoCheck(prefs), isFalse);
      expect(shouldAutoCheck(prefs, interval: Duration.zero), isTrue);
    });

    test('存的值是脏数据 → 当作没查过,不要因此永远不检查', () async {
      final prefs = PrefsStore.emptyForTest(tmp);
      await prefs.write(key: 'update_last_check', value: 'oops');
      expect(shouldAutoCheck(prefs), isTrue);
    });
  });
}
