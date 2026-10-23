import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../net/nai_endpoint.dart';
import '../store/app_stores.dart';
import 'secure_storage.dart';

/// 能存几把。这个上限只管**存**,不管并发 —— 直连并发等于参与出图的把数
/// ([NaiGate]),存进来两个条件都没勾的不占并发。所以备用号(过期 / 欠费时换着
/// 用的那些)尽管存,不会把出图流拖成十几条。
const kMaxNaiKeys = 16;

/// 一把已保存的 NAI Key。
class NaiKey {
  const NaiKey({
    required this.id,
    required this.token,
    this.label = '',
    this.accessKey,
    this.endpoint = '',
    this.primary = false,
    this.joinFree = true,
    this.joinPaid = true,
  });

  /// 本机稳定 id。**不能拿 token 当 id** —— JWT 续期会换掉 token,
  /// 那样重命名、主 Key 这些跟着 id 走的东西全会在续期后错位。
  final String id;

  final String token;

  /// 用户起的名字;空则界面按令牌尾号兜底显示。
  final String label;

  /// 账号密码登录留下的续期凭证(派生 access key,非密码)。
  ///
  /// **跟着这把 Key 走**,不是全局一份:存成全局的话多把 Key 里只有一把能自动
  /// 续期,更糟的是续期会拿这份凭证把**另一把**的令牌换成它所属账号的。
  /// 手贴 pst-/JWT 没有这份,到期只能重贴。
  final String? accessKey;

  /// 这把打哪台机器(已归一,空 = 官方 [kNaiOfficialBase])。
  ///
  /// **跟着这把 Key 走**,不是全局一份的设置:第三方中转站各有各的地址和 key,
  /// 而官方号多半还要照用 —— 全局一份时加一个中转站,官方那几把会被一起带跑
  /// 偏,且界面上看不出是哪把在打哪儿。整条直连线(生成、超分、Vibe 编码、
  /// 查点数)都按取到的那把 Key 的地址走。
  final String endpoint;

  /// 第三方接口(非官方地址)。官方那几把没有这个标记。
  bool get isThirdParty => endpoint.isNotEmpty;

  /// 是不是主账号。**和列表顺序无关** —— 早先拿「排第一」当主账号,于是选中一行
  /// 它就窜到顶上去,跟单选钮的行为完全不搭(单选钮从不会让选项换位置)。
  /// 现在它只是个标记,选中谁谁就是,行留在原地。
  ///
  /// 恒有且只有一把为真(空列表除外),见 [NaiKeysNotifier._normalized]。
  final bool primary;

  /// 参与免费生成:这一单落在它身上**不花它的点**(Opus 免费尺寸、V5 额度没见底)
  /// 时可以派给它。**主账号恒为 true**,见 [NaiKeysNotifier]。
  /// 只勾这一个 = 只用它的免费额度,点数一分不动 —— 留着白嫖号的点数用。
  final bool joinFree;

  /// 参与点数生成:要花点数的单可以派给它、花它的点。**主账号恒为 true**。
  /// 只勾这一个 = 平时不动它,出大图、超分这类要花点数的活才叫上它。
  ///
  /// 「要花点数的单」按主账号算,也就是生成按钮上显示的那个口径:按钮写着免费
  /// 的单,宁可排队等能免费出的号,也不花副账号的点(见 [naiKeysForJob])。
  final bool joinPaid;

  /// 参与出图(两个条件勾了任一个)。两个都不勾 = 这把完全不用,也不占并发;
  /// 条目留着 —— 令牌过期/账号欠费时先关掉比删掉稳妥,修好了勾回来就行。
  bool get joins => joinFree || joinPaid;

  NaiKey copyWith({
    String? token,
    String? label,
    Object? accessKey = const Object(),
    String? endpoint,
    bool? primary,
    bool? joinFree,
    bool? joinPaid,
  }) => NaiKey(
    id: id,
    token: token ?? this.token,
    label: label ?? this.label,
    accessKey: accessKey is String? ? accessKey : this.accessKey,
    endpoint: endpoint ?? this.endpoint,
    primary: primary ?? this.primary,
    joinFree: joinFree ?? this.joinFree,
    joinPaid: joinPaid ?? this.joinPaid,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'token': token,
    if (label.isNotEmpty) 'label': label,
    if (accessKey != null) 'accessKey': accessKey,
    // 官方那几把不落这个字段,老条目读出来就是官方 —— 正好等于升级前的行为。
    if (endpoint.isNotEmpty) 'ep': endpoint,
    if (primary) 'primary': true,
    // 两个条件只在**非默认**时落盘:默认全开,老条目缺字段读出来就是全开,
    // 正好等于升级前的行为。`noPts` 沿用上一版「允许花点数」的键:那时关掉
    // 就是「花点数的单不接」,和现在不勾「参与点数生成」一个意思。
    if (!joinFree) 'noFree': true,
    if (!joinPaid) 'noPts': true,
  };

  static NaiKey? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final token = j['token'];
    if (id is! String || id.isEmpty) return null;
    if (token is! String || token.isEmpty) return null;
    final ak = j['accessKey'];
    // 老版本的总开关:`off`(停用)和 `noGen`(不参与并发生成)关掉时都是「这把
    // 完全不用」,读成两个条件都不勾。
    final out = j['off'] == true || j['noGen'] == true;
    return NaiKey(
      id: id,
      token: token,
      label: j['label'] is String ? j['label'] as String : '',
      accessKey: ak is String && ak.isNotEmpty ? ak : null,
      endpoint: j['ep'] is String ? normalizeNaiBase(j['ep'] as String) : '',
      primary: j['primary'] == true,
      joinFree: !out && j['noFree'] != true,
      joinPaid: !out && j['noPts'] != true,
    );
  }
}

/// 令牌尾号:列表里认人用。整串是凭据,不该在界面上铺开。
String naiKeyTail(String token) =>
    token.length <= 6 ? token : '…${token.substring(token.length - 6)}';

/// 显示名:用户起的名字优先,没起过就用尾号。
String naiKeyTitle(NaiKey k) =>
    k.label.trim().isNotEmpty ? k.label.trim() : naiKeyTail(k.token);

const _keysKey = 'nai_access_keys';

/// 旧的单把存法,只在首次迁移时读一次(见 [NaiKeysNotifier._migrate])。
const _legacyTokenKey = 'nai_access_token';
const _legacyAccessKeyKey = 'nai_login_access_key';

/// 这一单能交给哪几把、谁先谁后。
///
/// [freeOn] = 这一单落在那把上免不免费(true 免费 / false 要扣点 / null 那个号的
/// 状态查不到)。免不免费是**每个号自己的事**:同一张免费尺寸图,在 Opus 且 V5
/// 额度没见底的号上是 0 点,在额度见底或不是 Opus 的号上照扣 Anlas(NAI 不报错)。
///
/// [paidJob] = 这一单算不算「要花点数的单」—— 按主账号算,也就是生成按钮上
/// 显示的那个口径。
///
///  · 在它身上免费的,勾了「参与免费生成」才接;查不到状态的不算免费;
///  · 在它身上要扣点的,勾了「参与点数生成」**而且**这一单本来就要花点数才接 ——
///    按钮上写着免费的单,宁可排队等能免费出的号,也不花副账号的点;
///  · 能免费出的号排在要扣点的前面:一单在主账号上要扣点、在某个副账号上免费
///    时,先派给那个副账号,不去花主账号的点;
///  · 同一档里主账号排头(要扣点时先花它的),其余按列表顺序。主账号什么单都接。
List<NaiKey> naiKeysForJob(
  List<NaiKey> all,
  bool? Function(NaiKey k) freeOn, {
  required bool paidJob,
}) {
  final free = <NaiKey>[];
  final paid = <NaiKey>[];
  for (final k in all) {
    if (freeOn(k) == true) {
      if (k.joinFree) free.add(k);
    } else if (k.joinPaid && (paidJob || k.primary)) {
      paid.add(k);
    }
  }
  List<NaiKey> primaryFirst(List<NaiKey> ks) => [
    for (final k in ks)
      if (k.primary) k,
    for (final k in ks)
      if (!k.primary) k,
  ];
  return [...primaryFirst(free), ...primaryFirst(paid)];
}

/// 主账号那把;一把都没存时 null。
NaiKey? naiPrimaryKey(List<NaiKey> all) {
  for (final k in all) {
    if (k.primary) return k;
  }
  return all.isEmpty ? null : all.first;
}

/// 已保存的全部 NAI Key。**其中恰有一把是主账号**([NaiKey.primary]),
/// 与它排在第几无关 —— 列表顺序是添加顺序,换主账号不会让行跳位。
///
/// 主账号是「一定会被用到」的那个:
///  · 「一次只能对一个账号」的操作(点数读数、超分、标签预览、JWT 续期)认它;
///  · 什么单都接 —— 两个参与条件被强制为真(见 [_normalized]),界面上也不给
///    勾选项;出图取 Key 时它排头,点数先花它的。
///
/// 其余是副账号,各自勾选**参与免费生成**(只用它的免费额度)、**参与点数生成**
/// (花它的点),两个互不牵连,都不勾就是不参与。这样才不会出现「主账号也能
/// 关掉出图」这种自相矛盾的状态 —— 那时点数读数认的还是它,却又不给它出图。
final naiKeysStoreProvider =
    AsyncNotifierProvider<NaiKeysNotifier, List<NaiKey>>(NaiKeysNotifier.new);

class NaiKeysNotifier extends AsyncNotifier<List<NaiKey>> {
  // 必须用共享的 secureStorageProvider,不能自建一个:两者当前配置相同,
  // 但一旦给共享那个加上 AndroidOptions(resetOnError 等),自建的这份会是
  // **唯一没跟上的**,而且编译器和 lint 都不会提醒。见 S1A-04。
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  var _seq = 0;

  String _newId() => 'k${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  @override
  Future<List<NaiKey>> build() async {
    try {
      final raw = await _storage.read(key: _keysKey);
      // 读出来也过一遍 normalize:老数据里主账号可能带着关掉的开关。
      final list = raw != null && raw.isNotEmpty
          ? _decode(raw)
          : await _migrateLegacy();
      return _normalized(await _adoptLegacyEndpoint(list));
    } catch (_) {
      // Keystore 尚未就绪 / 读取异常 —— 按「没存过」处理,不崩。
      return const [];
    }
  }

  /// 老用户升级:接口地址曾是**全局一份**的设置,现在跟着每把 Key 走。把那个
  /// 全局值盖到还没有地址的 Key 上,盖完清掉它 —— 不清的话下次启动会再盖一遍,
  /// 而那时用户可能已经把某把删了重加成官方的。
  ///
  /// 一把都没存时什么都不做:没有地方可盖,清掉反而把用户填过的地址弄丢了。
  /// 写不进去也原样返回,下次启动再搬(同 [_migrateLegacy] 的顾虑)。
  Future<List<NaiKey>> _adoptLegacyEndpoint(List<NaiKey> list) async {
    if (list.isEmpty) return list;
    final String legacy;
    try {
      legacy = normalizeNaiBase(
        ref.read(prefsStoreProvider).get(kLegacyNaiEndpointKey) ?? '',
      );
    } catch (_) {
      return list; // 无 AppStores(测试)
    }
    if (legacy.isEmpty) return list;
    final next = [
      for (final k in list)
        if (k.endpoint.isEmpty) k.copyWith(endpoint: legacy) else k,
    ];
    try {
      await _storage.write(key: _keysKey, value: jsonEncode(next));
      await ref.read(prefsStoreProvider).delete(key: kLegacyNaiEndpointKey);
    } catch (_) {
      return list;
    }
    return next;
  }

  List<NaiKey> _decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return [for (final e in j) ?NaiKey.fromJson(e)];
    } catch (_) {
      return const [];
    }
  }

  /// 老用户升级:把单把存法搬进列表,搬完删旧键。
  ///
  /// 搬不动就原样返回空 —— **绝不删旧键**,否则一次写失败就把用户的令牌弄丢了。
  Future<List<NaiKey>> _migrateLegacy() async {
    final token = await _storage.read(key: _legacyTokenKey);
    if (token == null || token.isEmpty) return const [];
    final accessKey = await _storage.read(key: _legacyAccessKeyKey);
    final list = [
      NaiKey(
        id: _newId(),
        token: token,
        accessKey: (accessKey == null || accessKey.isEmpty) ? null : accessKey,
      ),
    ];
    try {
      await _storage.write(key: _keysKey, value: jsonEncode(list));
    } catch (_) {
      return list; // 写不进去也先用着,下次启动再搬
    }
    // 写成功了才删旧的
    for (final k in const [_legacyTokenKey, _legacyAccessKeyKey]) {
      try {
        await _storage.delete(key: k);
      } catch (_) {}
    }
    return list;
  }

  /// 两条不变式收在这一处 —— 删掉主账号、首次添加、老数据读入都可能破坏它们,
  /// 散在各处补一定会漏:
  ///   1. 恰有一把是主账号(没人认领就让第一把当);
  ///   2. 主账号的两个参与条件强制为真。
  static List<NaiKey> _normalized(List<NaiKey> list) {
    if (list.isEmpty) return list;
    var at = list.indexWhere((k) => k.primary);
    if (at < 0) at = 0;
    return [
      for (var i = 0; i < list.length; i++)
        if (i == at)
          list[i].copyWith(primary: true, joinFree: true, joinPaid: true)
        else if (list[i].primary)
          list[i].copyWith(primary: false) // 多认领的一律降为副账号
        else
          list[i],
    ];
  }

  Future<void> _persist(List<NaiKey> list) async {
    final next = _normalized(list);
    try {
      await _storage.write(key: _keysKey, value: jsonEncode(next));
      state = AsyncData(next);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  List<NaiKey> get _cur => state.value ?? const [];

  /// 加一把。同一个 token **打同一个地址**已经在列表里,就只更新它的凭证/名字,
  /// 不重复添加 —— 重复的两把指向同一个账号,并发会当成两条放行,正好是 429 的
  /// 成因。同一串 key 填了两个地址则是两把:那是两台机器上的两个账号,合并会把
  /// 其中一台的读数挂到另一台上。
  ///
  /// 返回加/更新后的那把;满了返回 null。
  Future<NaiKey?> add(
    String token, {
    String label = '',
    String? accessKey,
    String endpoint = '',
  }) async {
    final t = token.trim();
    if (t.isEmpty) return null;
    final ep = normalizeNaiBase(endpoint);
    final cur = _cur;
    final i = cur.indexWhere((k) => k.token == t && k.endpoint == ep);
    if (i >= 0) {
      final merged = cur[i].copyWith(
        label: label.isNotEmpty ? label : null,
        accessKey: accessKey ?? cur[i].accessKey,
      );
      await _persist([...cur]..[i] = merged);
      return merged;
    }
    if (cur.length >= kMaxNaiKeys) return null;
    final k = NaiKey(
      id: _newId(),
      token: t,
      label: label,
      accessKey: accessKey,
      endpoint: ep,
    );
    await _persist([...cur, k]);
    return k;
  }

  Future<void> remove(String id) async => _persist([
    for (final k in _cur)
      if (k.id != id) k,
  ]);

  Future<void> rename(String id, String label) async => _persist([
    for (final k in _cur)
      if (k.id == id) k.copyWith(label: label.trim()) else k,
  ]);

  /// 换令牌(JWT 续期落盘)。id 不动,名字和续期凭证都留着。
  Future<void> replaceToken(String id, String token) async => _persist([
    for (final k in _cur)
      if (k.id == id) k.copyWith(token: token.trim()) else k,
  ]);

  /// 改一把的参与条件(null = 不动那一项)。主账号那把会被 [_normalized] 拨回全开。
  Future<void> setFlags(String id, {bool? joinFree, bool? joinPaid}) async =>
      _persist([
        for (final k in _cur)
          if (k.id == id)
            k.copyWith(joinFree: joinFree, joinPaid: joinPaid)
          else
            k,
      ]);

  /// 拖动排序。顺序是**出图取 Key 的先后**(主账号除外,它恒排头),也决定账号页
  /// 那张卡摆的是哪几块(那里只摆得下前几个)。主账号标记跟着那把 Key 走,
  /// 拖动不会换人。
  Future<void> reorder(int from, int to) async {
    final cur = _cur;
    if (from == to) return;
    if (from < 0 || from >= cur.length) return;
    if (to < 0 || to >= cur.length) return;
    final next = [...cur];
    next.insert(to, next.removeAt(from));
    await _persist(next);
  }

  /// 设为主账号。**不动列表顺序** —— 只是把标记挪过去(两个开关随即被强制全开,
  /// 原主账号降为副账号,见 [_normalized])。
  ///
  /// 主账号有三个身份:①「一次只能对一个账号」的操作(点数读数、超分、
  /// 标签预览、续期)认它;② 出图取 Key 时它排头,点数**先被花**;
  /// ③ 它必定参与出图、必定可花点数。三件事合成一个标记,是因为用户心里本来
  /// 就只有「主要用哪个号」这一个概念。
  Future<void> makePrimary(String id) async {
    final cur = _cur;
    if (!cur.any((k) => k.id == id)) return;
    await _persist([for (final k in cur) k.copyWith(primary: k.id == id)]);
  }

  Future<void> clearAll() async {
    try {
      await _storage.delete(key: _keysKey);
    } catch (_) {
      // 删除失败也把内存态清空,避免残留显示。
    }
    state = const AsyncData([]);
  }
}
