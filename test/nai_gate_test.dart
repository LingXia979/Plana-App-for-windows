// 直连 NAI 的并发闸门。NAI 按账号限流 —— 同一把 Key 同时打两个请求,第二个
// 直接 429,而且这是条**静默错**:用户看到的只是「第二张失败了」。
//
// 闸门是全 app 共用的,吃这条限额的不止生成:图库 NAI 超分、灵感页标签预览打的
// 是同一个账号。所以这里既验「按可用 Key 放行」,也验「谁来都得排同一个队」,
// 外加副账号的两个参与条件(参与免费生成 / 参与点数生成)和「同时出几张」。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_gate.dart';

/// 只读的 Key 列表 —— 闸门只 read,不需要真的存储。
class _FakeKeys extends NaiKeysNotifier {
  _FakeKeys(this._seed);
  final List<NaiKey> _seed;
  @override
  Future<List<NaiKey>> build() async => _seed;
}

/// [free] / [paid] = 参与免费生成 / 参与点数生成。
NaiKey _k(
  String id, {
  bool free = true,
  bool paid = true,
  bool primary = false,
}) => NaiKey(
  id: id,
  token: 'tok-$id',
  primary: primary,
  joinFree: free,
  joinPaid: paid,
);

/// 主账号在前的一组全开 Key。
List<NaiKey> _plainN(int n) => [
  for (var i = 0; i < n; i++) _k('$i', primary: i == 0),
];

(ProviderContainer, NaiGate) _setup(List<NaiKey> keys) {
  final c = ProviderContainer(
    overrides: [naiKeysStoreProvider.overrideWith(() => _FakeKeys(keys))],
  );
  addTearDown(c.dispose);
  c.read(naiKeysStoreProvider); // 闸门读的是 .future,先预热到有值
  return (c, c.read(naiGateProvider));
}

NaiGate _gate(List<NaiKey> keys) => _setup(keys).$2;

List<NaiKey> _plain(int n) => _plainN(n);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('唯一第三方主账号不依赖订阅端点，也不等待第二把 Key', () async {
    final gate = _gate([
      const NaiKey(
        id: 'relay',
        token: 'test-only',
        endpoint: 'https://relay.example.test',
        primary: true,
      ),
    ]);
    var subscriptionQueries = 0;
    final freeOn = naiFreeOnPerKey(
      buttonFree: () => false,
      onKey: (key) async {
        subscriptionQueries++;
        return null;
      },
    );
    expect(await gate.limit(freeOn: freeOn), 1);
    final pass = await gate
        .acquire(freeOn: freeOn)
        .timeout(const Duration(seconds: 1));
    expect(pass.token, 'test-only');
    expect(pass.base, 'https://relay.example.test');
    expect(subscriptionQueries, 0);
    gate.release(pass.slot);
  });

  group('按 Key 数放行', () {
    test('一把 Key:第二个必须等第一个放槽', () async {
      final gate = _gate(_plain(1));

      final a = await gate.acquire();
      expect(a.token, 'tok-0');

      var bDone = false;
      final b = gate.acquire().then((p) {
        bDone = true;
        return p;
      });

      // 放槽之前 b 只能挂着 —— 挂不住就是 429 的来路
      await Future<void>.delayed(Duration.zero);
      expect(bDone, isFalse);
      expect(gate.busyCount, 1);

      gate.release(a.slot);
      expect((await b).token, 'tok-0');
    });

    test('三把 Key:三条同时放行且各用各的,第四条才排队', () async {
      final gate = _gate(_plain(3));

      final got = [
        await gate.acquire(),
        await gate.acquire(),
        await gate.acquire(),
      ];
      // 同一把 Key 不能发两张通行证,否则等于自己打自己
      expect({for (final p in got) p.token}, {'tok-0', 'tok-1', 'tok-2'});

      var fourth = false;
      unawaited(gate.acquire().then((_) => fourth = true));
      await Future<void>.delayed(Duration.zero);
      expect(fourth, isFalse);

      gate.release(got[1].slot);
      await Future<void>.delayed(Duration.zero);
      expect(fourth, isTrue);
    });

    // 一把都没存时不能把人卡死在等位里 —— 那种卡法在界面上就是「点了没反应」。
    // 给一张空通行证,让调用方去报「没有令牌」。
    test('一把都没存:立刻返回空通行证,不排队', () async {
      final gate = _gate(const []);
      final p = await gate.acquire();
      expect(p.token, isNull);
      expect(p.slot, -1);
    });
  });

  group('副账号的参与条件', () {
    test('两个都没勾的不参与', () async {
      final gate = _gate([
        _k('0', primary: true),
        _k('1', free: false, paid: false),
        _k('2'),
      ]);
      expect(await gate.limit(), 2);
      expect((await gate.acquire()).token, 'tok-0');
      expect((await gate.acquire()).token, 'tok-2');
    });

    // 白嫖号的点数不该被偷偷花掉:免费单照用,付费单跳过。
    test('只参与免费生成:付费单跳过它', () async {
      final gate = _gate([_k('0', primary: true), _k('1', paid: false)]);

      // 免费单:两把都能用,主账号先出
      final a = await gate.acquire();
      final b = await gate.acquire();
      expect({a.token, b.token}, {'tok-0', 'tok-1'});
      gate.release(a.slot);
      gate.release(b.slot);

      // 付费单:1 号被跳过,只剩主账号
      final p1 = await gate.acquire(paid: true);
      expect(p1.token, 'tok-0');
      var second = false;
      unawaited(gate.acquire(paid: true).then((_) => second = true));
      await Future<void>.delayed(Duration.zero);
      expect(second, isFalse);
    });

    // 平时不动它,出大图、超分这类要花点数的活才叫上它。
    test('只参与点数生成:免费单不接,付费单才接', () async {
      final gate = _gate([_k('0', primary: true), _k('1', free: false)]);

      // 免费单:只有主账号接,第二单只能等
      final a = await gate.acquire();
      expect(a.token, 'tok-0');
      var freeGot = false;
      unawaited(gate.acquire().then((_) => freeGot = true));
      await Future<void>.delayed(Duration.zero);
      expect(freeGot, isFalse);

      // 付费单:主账号占着,副账号顶上
      expect((await gate.acquire(paid: true)).token, 'tok-1');
    });

    // 槽位记的是 Key 的 id。若按「可用集合内的序号」记账,免费单占了第 0 把、
    // 付费单看到的可用集合首位是第 1 把也叫序号 0 —— 两条会认成同一个槽,
    // 于是要么误放行、要么误排队。
    test('免费单与付费单的槽位不串台', () async {
      final gate = _gate([_k('0', primary: true), _k('1', paid: false)]);

      final free = await gate.acquire(paid: true); // 付费只能用主账号,占住第 0 把
      expect(free.token, 'tok-0');

      final other = await gate.acquire(); // 免费单:第 1 把仍空着,应当放行
      expect(other.token, 'tok-1');
      expect(gate.busyCount, 2);
    });

    // 主账号的两个参与条件由存储层强制为真,所以「一把可用的都没有」只可能是
    // 一把都没存。副账号全关掉,主账号照样能出图。
    test('副账号全关掉:主账号照样出图', () async {
      final gate = _gate([
        _k('0', primary: true),
        _k('1', free: false, paid: false),
        _k('2', free: false, paid: false),
      ]);
      expect(await gate.limit(), 1);
      expect((await gate.acquire()).token, 'tok-0');
    });
  });

  // 并发上限没有单独设置:就是参与出图的把数。
  group('并发上限 = 参与出图的把数', () {
    test('四把全开 → 4', () async {
      expect(await _gate(_plain(4)).limit(), 4);
    });

    test('关掉两把副账号 → 2', () async {
      final gate = _gate([
        _k('0', primary: true),
        _k('1', free: false, paid: false),
        _k('2'),
        _k('3', free: false, paid: false),
      ]);
      expect(await gate.limit(), 2);
    });

    // 循环一批出的是同一张图:接不了它的号不该白占一条、挂一张一直等待的卡。
    test('按这一单数:只数接得了它的', () async {
      final gate = _gate([
        _k('0', primary: true),
        _k('1', paid: false), // 只免费
        _k('2', free: false), // 只花点数
        _k('3'),
      ]);
      expect(await gate.limit(paid: false), 3); // 0 1 3
      expect(await gate.limit(paid: true), 3); // 0 2 3
      expect(await gate.limit(freeOn: (k) async => k.id != '3'), 2); // 0 1
    });

    test('一把都没存 → 给 1,不把人卡死在等位里', () async {
      expect(await _gate(const []).limit(), 1);
    });
  });

  group('取消与成对释放', () {
    test('等位期间被取消:返回 -1,不占槽', () async {
      final gate = _gate(_plain(1));
      final held = await gate.acquire();

      final abort = GenAbort();
      final waiting = gate.acquire(abort: abort);
      await Future<void>.delayed(Duration.zero);

      abort.abort();
      expect((await waiting).slot, -1);

      gate.release(held.slot);
      expect(gate.busyCount, 0);
    });

    // 取消留下的空壳 completer 不能把唤醒吞掉:release 要一路跳到真正在等的那个。
    test('取消者留下的空壳不吞唤醒', () async {
      final gate = _gate(_plain(1));
      final held = await gate.acquire();

      final abort = GenAbort();
      unawaited(gate.acquire(abort: abort));
      await Future<void>.delayed(Duration.zero);
      abort.abort(); // 空壳留在等位队列里

      var live = false;
      unawaited(gate.acquire().then((_) => live = true));
      await Future<void>.delayed(Duration.zero);

      gate.release(held.slot);
      await Future<void>.delayed(Duration.zero);
      expect(live, isTrue);
    });

    // run() 是超分 / 标签预览用的成对包装:body 抛了也必须把槽还回来,
    // 漏还一次闸门就永久焊死,之后所有生成都卡在等位。
    test('run():body 抛异常也把槽还回来', () async {
      final gate = _gate(_plain(1));

      await expectLater(
        gate.run((_, _) async => throw StateError('boom')),
        throwsStateError,
      );
      expect(gate.busyCount, 0);

      expect(await gate.run((t, _) async => t), 'tok-0');
      expect(gate.busyCount, 0);
    });

    test('run() 与生成排同一个队', () async {
      final gate = _gate(_plain(1));
      final gen = await gate.acquire(); // 假装一条生成正在跑

      var upscaled = false;
      unawaited(gate.run((_, _) async => upscaled = true));
      await Future<void>.delayed(Duration.zero);
      expect(upscaled, isFalse); // 超分得等生成让位,不能自己开一路打过去

      gate.release(gen.slot);
      await Future<void>.delayed(Duration.zero);
      expect(upscaled, isTrue);
    });
  });

  // 占用按 Key 的 id 记。按列表下标记的话,令牌管理页出图途中拖一下、删一把,
  // 下标就指到别的 Key 上:还在跑的那把被当成空的再发出去(429),空着的反被当成占用。
  group('出图途中改列表', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('拖动排序:还在跑的那把不会再发出去', () async {
      final (c, gate) = _setup(_plain(3));
      final got = [await gate.acquire(), await gate.acquire()];
      expect([for (final p in got) p.token], ['tok-0', 'tok-1']);

      await c.read(naiKeysStoreProvider.notifier).reorder(2, 1); // 0, 2, 1
      expect((await gate.acquire()).token, 'tok-2');
    });

    test('删掉一把:别的 Key 不会因此被认错', () async {
      final (c, gate) = _setup(_plain(3));
      final p = await gate.acquire(); // tok-0
      await gate.acquire(); // tok-1,一直占着

      await c.read(naiKeysStoreProvider.notifier).remove('0');
      gate.release(p.slot);
      expect((await gate.acquire()).token, 'tok-2');
    });
  });

  group('逐把问免不免费', () {
    // 主账号额度见底、副账号还能白出:先派给副账号,别去花主账号的点。
    test('这一单在副账号上免费:只免费参与的副账号也接,而且排在主账号前面', () async {
      final gate = _gate([_k('0', primary: true), _k('1', paid: false)]);
      final pass = await gate.acquire(freeOn: (k) async => k.id == '1');
      expect(pass.token, 'tok-1');
    });

    test('副账号的状态查不到:只免费参与的不接,只能等主账号', () async {
      final gate = _gate([_k('0', primary: true), _k('1', paid: false)]);
      Future<bool?> freeOn(NaiKey k) async => k.id == '0' ? true : null;

      expect((await gate.acquire(freeOn: freeOn)).token, 'tok-0');
      var second = false;
      unawaited(gate.acquire(freeOn: freeOn).then((_) => second = true));
      await Future<void>.delayed(Duration.zero);
      expect(second, isFalse);
    });

    // 按钮上写着免费的单,落到副账号上却要扣它的点(不是 Opus / 额度见底):
    // 两个条件都勾了也不接 —— 宁可等主账号,不花副账号的点。
    test('在主账号上免费的单:不花副账号的点,主账号忙也等', () async {
      final gate = _gate([_k('0', primary: true), _k('1')]);
      Future<bool?> freeOn(NaiKey k) async => k.id == '0';

      final a = await gate.acquire(freeOn: freeOn);
      expect(a.token, 'tok-0');
      String? got;
      unawaited(gate.acquire(freeOn: freeOn).then((p) => got = p.token));
      await Future<void>.delayed(Duration.zero);
      expect(got, isNull);

      gate.release(a.slot);
      await Future<void>.delayed(Duration.zero);
      expect(got, 'tok-0');
    });

    // 主账号额度见底时,按钮上写着要花点数:这时只参与点数生成的副账号可以顶上。
    test('在主账号上要花点数的单:只参与点数生成的副账号接', () async {
      final gate = _gate([_k('0', primary: true), _k('1', free: false)]);
      Future<bool?> freeOn(NaiKey k) async => false;

      expect((await gate.acquire(freeOn: freeOn)).token, 'tok-0');
      expect((await gate.acquire(freeOn: freeOn)).token, 'tok-1');
    });

    // 多数中转没有订阅接口:查的话永远是「查不到」,只参与免费生成的中转一张
    // 免费单都接不到(升级前是接的)。
    test('第三方中转不查订阅,免不免费跟按钮走', () async {
      final asked = <String>[];
      NaiFreeOn freeOn({required bool button}) => naiFreeOnPerKey(
        buttonFree: () => button,
        onKey: (k) async {
          asked.add(k.id);
          return k.primary ? button : null;
        },
      );
      NaiKey relay(String id, {bool free = true, bool paid = true}) => NaiKey(
        id: id,
        token: 'tok-$id',
        endpoint: 'https://relay.example',
        joinFree: free,
        joinPaid: paid,
      );

      // 按钮写着免费:只参与免费生成的中转接,主账号占着也不用等
      var gate = _gate([_k('0', primary: true), relay('r', paid: false)]);
      expect((await gate.acquire(freeOn: freeOn(button: true))).token, 'tok-0');
      expect((await gate.acquire(freeOn: freeOn(button: true))).token, 'tok-r');
      expect(asked, isNot(contains('r')));

      // 按钮写着要花点数:只参与免费生成的不接,勾了参与点数生成的才接
      gate = _gate([
        _k('0', primary: true),
        relay('f', paid: false),
        relay('p', free: false),
      ]);
      expect(
        (await gate.acquire(freeOn: freeOn(button: false))).token,
        'tok-0',
      );
      expect(
        (await gate.acquire(freeOn: freeOn(button: false))).token,
        'tok-p',
      );
      expect(asked, isNot(anyOf(contains('f'), contains('p'))));
    });

    // 挑号那份查主账号超时 / 失败,而按钮那份读数还在:两边得是同一个口径。
    test('主账号的状态查不到:按按钮判,写着免费的单不花副账号的点', () async {
      NaiFreeOn freeOn({required bool button}) => naiFreeOnPerKey(
        buttonFree: () => button,
        onKey: (k) async => k.primary ? null : false, // 副账号落上去要扣点
      );

      var gate = _gate([_k('0', primary: true), _k('1', free: false)]);
      final a = await gate.acquire(freeOn: freeOn(button: true));
      expect(a.token, 'tok-0');
      String? got;
      unawaited(
        gate.acquire(freeOn: freeOn(button: true)).then((p) => got = p.token),
      );
      await Future<void>.delayed(Duration.zero);
      expect(got, isNull, reason: '按钮写着免费:宁可等主账号');
      gate.release(a.slot);
      await Future<void>.delayed(Duration.zero);
      expect(got, 'tok-0');

      // 按钮写着要花点数:只参与点数生成的副账号照常顶上
      gate = _gate([_k('0', primary: true), _k('1', free: false)]);
      expect(
        (await gate.acquire(freeOn: freeOn(button: false))).token,
        'tok-0',
      );
      expect(
        (await gate.acquire(freeOn: freeOn(button: false))).token,
        'tok-1',
      );
    });
  });

  group('等位与唤醒', () {
    // 还槽只叫醒排头那一个的话,它若用不了空出来的这把,这次唤醒就被它吞了。
    test('付费单排在前面:空出来的副账号照样由后面的免费单接走', () async {
      final gate = _gate([_k('0', primary: true), _k('1', paid: false)]);
      final p = await gate.acquire();
      final s = await gate.acquire();
      expect([p.token, s.token], ['tok-0', 'tok-1']);

      var paidGot = false;
      String? freeGot;
      unawaited(gate.acquire(paid: true).then((_) => paidGot = true));
      await Future<void>.delayed(Duration.zero);
      unawaited(gate.acquire().then((x) => freeGot = x.token));
      await Future<void>.delayed(Duration.zero);

      gate.release(s.slot);
      await Future<void>.delayed(Duration.zero);
      expect(freeGot, 'tok-1');
      expect(paidGot, isFalse); // 付费单只能等主账号
    });

    // 挑号时要等各号的状态查回来;这期间还的槽,唤醒叫不到它(还没进等位名单)。
    test('挑号途中有人还槽:不漏掉那一次', () async {
      final gate = _gate([_k('0', primary: true), _k('1', paid: false)]);
      final held = await gate.acquire(); // 主账号占着

      final asked = Completer<void>();
      final answer = Completer<bool?>();
      final pass = gate.acquire(
        freeOn: (k) {
          if (k.id == '0') return Future.value(true);
          if (!asked.isCompleted) asked.complete();
          return answer.future;
        },
      );
      await asked.future; // 正在问副账号
      gate.release(held.slot); // 主账号这时空了
      answer.complete(false); // 这一单在副账号上不免费
      expect((await pass).token, 'tok-0');
    });
  });
}
