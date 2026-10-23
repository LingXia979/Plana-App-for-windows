// 直连 Key 的多把存储。两处最容易出静默错:
//
//  1. **老用户迁移** —— 旧的单把存法(`nai_access_token` + `nai_login_access_key`)
//     要搬进列表。搬错了用户的令牌就没了,而界面只会显示「未设置」。
//  2. **续期凭证跟着谁** —— 凭证以前是全局一份。多把 Key 下若还是全局一份,
//     续期会拿 A 账号的凭证把 B 那把的令牌换成 A 的,用户毫无察觉。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/auth/token_store.dart';
import 'package:plana_app/core/net/nai_endpoint.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

Future<NaiKeysNotifier> _store(ProviderContainer c) async {
  await c.read(naiKeysStoreProvider.future);
  return c.read(naiKeysStoreProvider.notifier);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('老用户迁移', () {
    test('旧的单把令牌 + 续期凭证搬进列表,旧键删掉', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_token': 'pst-abc123456',
        'nai_login_access_key': 'derived-key',
      });
      final c = _container();
      final keys = await c.read(naiKeysStoreProvider.future);

      expect(keys.length, 1);
      expect(keys.first.token, 'pst-abc123456');
      // 凭证跟着这把走,不再是全局一份
      expect(keys.first.accessKey, 'derived-key');

      // 旧键已清:留着的话下次还会再搬一遍,搬出第二把重复的
      const s = FlutterSecureStorage();
      expect(await s.read(key: 'nai_access_token'), isNull);
      expect(await s.read(key: 'nai_login_access_key'), isNull);
      expect(await s.read(key: 'nai_access_keys'), isNotNull);
    });

    test('手贴令牌没有续期凭证:搬过去也是 null,不瞎编', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_token': 'pst-only',
      });
      final keys = await _container().read(naiKeysStoreProvider.future);
      expect(keys.single.accessKey, isNull);
    });

    test('全新用户:空列表,不写任何东西', () async {
      final keys = await _container().read(naiKeysStoreProvider.future);
      expect(keys, isEmpty);
      expect(
        await const FlutterSecureStorage().read(key: 'nai_access_keys'),
        isNull,
      );
    });

    test('迁移落盘后重开:读新键,内容一致', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_token': 'pst-abc123456',
      });
      await _container().read(naiKeysStoreProvider.future); // 第一次:迁移
      final again = await _container().read(naiKeysStoreProvider.future);
      expect(again.single.token, 'pst-abc123456');
    });
  });

  group('接口地址跟着每把走', () {
    test('同一串 key 填两个地址 = 两把:那是两台机器上的两个账号', () async {
      final s = await _store(_container());
      final a = await s.add('same-key', endpoint: 'https://relay.a.com');
      final b = await s.add('same-key', endpoint: 'https://relay.b.com/');
      expect(a!.id, isNot(b!.id));
      expect(b.endpoint, 'https://relay.b.com', reason: '尾斜杠要归一掉');

      // 同地址再加一次才是同一把
      final again = await s.add('same-key', endpoint: 'https://relay.a.com');
      expect(again!.id, a.id);
      expect((await s.future).length, 2);
    });

    test('官方那把不落地址字段,落盘再读回来还是官方', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('pst-official');
      await s.add('third-key', endpoint: 'https://relay.example.com');
      final raw = await const FlutterSecureStorage().read(
        key: 'nai_access_keys',
      );
      expect(raw, isNot(contains('"ep":"https://image.novelai.net"')));

      final back = await _container().read(naiKeysStoreProvider.future);
      expect(back[0].endpoint, '');
      expect(back[0].isThirdParty, isFalse);
      expect(back[1].endpoint, 'https://relay.example.com');
      expect(back[1].isThirdParty, isTrue);
    });

    test('填成官方地址本身 = 官方,不算第三方', () async {
      final s = await _store(_container());
      final k = await s.add('tok', endpoint: '$kNaiOfficialBase/');
      expect(k!.endpoint, '');
      expect(k.isThirdParty, isFalse);
    });
  });

  group('增删改', () {
    test('add 追加;第一把自动成为主账号', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('tok-a');
      await s.add('tok-b');

      final now = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in now) k.token], ['tok-a', 'tok-b']);
      expect([for (final k in now) k.primary], [true, false]);
    });

    // 同一把存两遍会被当成两个账号放行两条并发 —— 正是 429 的成因。
    test('同一个令牌不重复添加,只并进已有那把', () async {
      final c = _container();
      final s = await _store(c);
      final first = await s.add('tok-a');
      final again = await s.add('tok-a', accessKey: 'ak');

      expect(c.read(naiKeysStoreProvider).value!.length, 1);
      expect(again!.id, first!.id); // id 不变,重命名/主 Key 不会错位
      expect(again.accessKey, 'ak'); // 补上了凭证
    });

    test('存满之后加不进去(返回 null)', () async {
      final c = _container();
      final s = await _store(c);
      for (var i = 0; i < kMaxNaiKeys; i++) {
        expect(await s.add('tok-$i'), isNotNull);
      }
      expect(await s.add('tok-overflow'), isNull);
      expect(c.read(naiKeysStoreProvider).value!.length, kMaxNaiKeys);
    });

    // 换主账号**不动顺序** —— 早先是挪到首位,于是在列表里选中一行它就窜到
    // 顶上去,跟单选钮的行为完全不搭(单选钮从不让选项换位置)。
    test('makePrimary 只挪标记,列表顺序不动', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      final third = c.read(naiKeysStoreProvider).value![2];

      await s.makePrimary(third.id);
      final now = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in now) k.token], ['a', 'b', 'c']);
      expect([for (final k in now) k.primary], [false, false, true]);
      expect(naiPrimaryKey(now)!.token, 'c');
    });

    // 拖动排序改的是列表顺序,主账号标记跟着那把 Key 走 —— 拖动不该换人。
    test('reorder 挪位置,主账号跟着那把 Key 走', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      await s.makePrimary(c.read(naiKeysStoreProvider).value![2].id);

      await s.reorder(2, 0); // c 拖到首位
      final now = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in now) k.token], ['c', 'a', 'b']);
      expect(naiPrimaryKey(now)!.token, 'c');

      await s.reorder(0, 2); // 再拖回末位
      final back = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in back) k.token], ['a', 'b', 'c']);
      expect(naiPrimaryKey(back)!.token, 'c');
    });

    // 越界/原地不动的下标不该把列表搅乱,更不该抛。
    test('reorder 下标越界或原地不动:列表不变', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');

      for (final (from, to) in const [(0, 0), (-1, 1), (0, 5), (9, 0)]) {
        await s.reorder(from, to);
        expect(
          [for (final k in c.read(naiKeysStoreProvider).value!) k.token],
          ['a', 'b'],
        );
      }
    });

    // 顺序落盘了才算数:重启回来还得是拖好的那个顺序。
    test('reorder 的顺序会落盘', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      await s.reorder(0, 2);

      final again = await _container().read(naiKeysStoreProvider.future);
      expect([for (final k in again) k.token], ['b', 'c', 'a']);
    });

    // 出图顺序才认主账号:它排头,其余按列表顺序。
    test('出图取 Key:主账号排头,其余保持列表顺序', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      await s.makePrimary(c.read(naiKeysStoreProvider).value![2].id);

      final order = naiKeysForJob(
        c.read(naiKeysStoreProvider).value!,
        (_) => true,
        paidJob: false,
      );
      expect([for (final k in order) k.token], ['c', 'a', 'b']);
    });

    // 续期换的是令牌本身,id / 名字 / 凭证都得留着,否则续一次就「换了个人」。
    test('replaceToken:换令牌不动 id、名字、凭证', () async {
      final c = _container();
      final s = await _store(c);
      final k = (await s.add('old-jwt', label: '主号', accessKey: 'ak'))!;

      await s.replaceToken(k.id, 'new-jwt');
      final after = c.read(naiKeysStoreProvider).value!.single;
      expect(after.token, 'new-jwt');
      expect(after.id, k.id);
      expect(after.label, '主号');
      expect(after.accessKey, 'ak');
    });

    test('rename / remove / clearAll', () async {
      final c = _container();
      final s = await _store(c);
      final a = (await s.add('a'))!;
      await s.add('b');

      await s.rename(a.id, '  小号  '); // 顺手 trim
      expect(c.read(naiKeysStoreProvider).value!.first.label, '小号');

      await s.remove(a.id);
      expect(c.read(naiKeysStoreProvider).value!.single.token, 'b');

      await s.clearAll();
      expect(c.read(naiKeysStoreProvider).value, isEmpty);
    });
  });

  group('对老接口的兼容', () {
    test('tokenProvider = 主账号;naiKeysProvider = 全部', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');

      expect(await c.read(tokenProvider.future), 'a');
      expect(await c.read(naiKeysProvider.future), ['a', 'b']);
    });

    test('一把都没存:主账号为 null,列表为空', () async {
      final c = _container();
      expect(await c.read(tokenProvider.future), isNull);
      expect(await c.read(naiKeysProvider.future), isEmpty);
    });

    // 引导页/邮箱登录都走 save():它的语义是「把这把加进来」,不是「顶掉原来那把」。
    test('save() 是追加,不顶掉已有的', () async {
      final c = _container();
      await c.read(tokenProvider.future);
      await c.read(tokenProvider.notifier).save('first');
      await c.read(tokenProvider.notifier).save('second', accessKey: 'ak2');

      final keys = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in keys) k.token], ['first', 'second']);
      expect(keys[1].accessKey, 'ak2');
      expect(await c.read(tokenProvider.future), 'first'); // 主账号还是头一把
    });

    test('save(空串) 等同清空', () async {
      final c = _container();
      await c.read(tokenProvider.future);
      await c.read(tokenProvider.notifier).save('a');
      await c.read(tokenProvider.notifier).save('   ');
      expect(c.read(naiKeysStoreProvider).value, isEmpty);
    });
  });

  // 主账号(首位)是「一定会被用到」的那个:什么单都接。
  // 这条不变式收在存储层,换主账号/删主账号/首次添加都由它兜住。
  group('主账号强制全开', () {
    test('主账号那把的两个参与条件被拨回真', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      final second = c.read(naiKeysStoreProvider).value![1];

      // 副账号可以关
      await s.setFlags(second.id, joinFree: false, joinPaid: false);
      expect(c.read(naiKeysStoreProvider).value![1].joins, isFalse);

      // 提成主账号 → 立刻全开(位置不动,还在第二个)
      await s.makePrimary(second.id);
      final now = c.read(naiKeysStoreProvider).value![1];
      expect(now.id, second.id);
      expect(now.primary, isTrue);
      expect(now.joinFree, isTrue);
      expect(now.joinPaid, isTrue);
    });

    test('关不掉主账号自己的参与条件', () async {
      final c = _container();
      final s = await _store(c);
      final a = (await s.add('a'))!;

      await s.setFlags(a.id, joinFree: false, joinPaid: false);
      final now = c.read(naiKeysStoreProvider).value!.single;
      expect(now.joinFree, isTrue);
      expect(now.joinPaid, isTrue);
    });

    // 删掉主账号 → 下一把顶上来,它的参与条件也得跟着全开。
    test('删掉主账号:接班的那把自动全开', () async {
      final c = _container();
      final s = await _store(c);
      final a = (await s.add('a'))!;
      final b = (await s.add('b'))!;
      await s.setFlags(b.id, joinFree: false, joinPaid: false);

      await s.remove(a.id);
      final now = c.read(naiKeysStoreProvider).value!.single;
      expect(now.id, b.id);
      expect((now.joinFree, now.joinPaid), (true, true));
    });
  });

  // 上一版是「并发生成」总开关 + 其下的「允许花点数」,表达不了「只参与点数
  // 生成」;现在是两个互不牵连的条件。
  group('参与条件的存取', () {
    test('老数据:off / noGen 读成不参与,noPts 读成只参与免费生成', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_keys':
            '[{"id":"k0","token":"a"},'
            '{"id":"k1","token":"b","off":true},'
            '{"id":"k2","token":"c","noGen":true},'
            '{"id":"k3","token":"d","noPts":true}]',
      });
      final keys = await _container().read(naiKeysStoreProvider.future);
      expect(
        [for (final k in keys) (k.joinFree, k.joinPaid)],
        [(true, true), (false, false), (false, false), (true, false)],
      );
    });

    test('只参与点数生成:落盘再读回来还是它', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      final b = (await s.add('b'))!;
      await s.setFlags(b.id, joinFree: false);

      final again = await _container().read(naiKeysStoreProvider.future);
      expect((again[1].joinFree, again[1].joinPaid), (false, true));
    });
  });

  // 免不免费是每个号自己的事:同一张免费尺寸图,在额度还有的 Opus 号上是 0 点,
  // 在额度见底或不是 Opus 的号上照扣,而且 NAI 不报错。「算不算要花点数的单」
  // 则按主账号算,也就是生成按钮上的口径。
  group('按号挑', () {
    const p = NaiKey(id: 'p', token: 'p', primary: true);
    const a = NaiKey(id: 'a', token: 'a', joinPaid: false); // 只参与免费生成
    const w = NaiKey(id: 'w', token: 'w', joinFree: false); // 只参与点数生成
    const b = NaiKey(id: 'b', token: 'b'); // 都勾
    const off = NaiKey(id: 'x', token: 'x', joinFree: false, joinPaid: false);

    List<String> pick(Map<String, bool?> free) => [
      for (final k in naiKeysForJob(
        [a, p, w, b, off],
        (k) => free[k.id],
        paidJob: free['p'] != true, // 同闸门:看这一单在主账号上免不免费
      ))
        k.id,
    ];

    test('参与免费生成:确定在它身上免费才接,查不到的不接', () {
      expect(pick({'p': true, 'a': true, 'w': true, 'b': true}), [
        'p',
        'a',
        'b',
      ]);
      expect(pick({'p': true, 'a': null, 'b': true}), ['p', 'b']);
    });

    // 主账号额度见底、副账号还能白出:先派给副账号,别去花主账号的点。
    test('要花点数的单:只参与点数生成的也接,能免费出的号排前面', () {
      expect(pick({'p': false, 'a': false, 'w': false, 'b': false}), [
        'p',
        'w',
        'b',
      ]);
      expect(pick({'p': false, 'a': true, 'w': false, 'b': false}), [
        'a',
        'p',
        'w',
        'b',
      ]);
    });

    // 按钮上写着免费的单,落到副账号上要扣它的点:不接,宁可排队。
    test('在主账号上免费的单:不花副账号的点', () {
      expect(pick({'p': true, 'a': false, 'w': false, 'b': false}), ['p']);
    });

    test('两个都没勾的一律不用', () {
      expect(pick({'x': true, 'p': true}), isNot(contains('x')));
      expect(pick({'x': false, 'p': false}), isNot(contains('x')));
    });
  });

  test('naiKeyTitle:起过名用名字,没起过用尾号', () {
    const a = NaiKey(id: '1', token: 'pst-verylongtoken123456', label: '主号');
    const b = NaiKey(id: '2', token: 'pst-verylongtoken123456');
    expect(naiKeyTitle(a), '主号');
    expect(naiKeyTitle(b), '…123456');
  });
}
