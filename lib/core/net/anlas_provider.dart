import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_mode.dart';
import '../auth/bot_session_store.dart';
import '../auth/token_store.dart';
import 'backend_client.dart';
import 'backend_config.dart';
import 'nai_client.dart';

/// 点数信息(Anlas + 是否 Opus + NAI 5 额度电池)。按接入方式取源:
///  - token 直连:NAI `/user/subscription`(用户账户剩余 Anlas)。
///  - bot 授权:后端 `/api/anlas`(共享服务账户余额,对齐 web,isOpus 恒 true;
///    NAI 5 额度由服务端把主池各 Opus 号合并成一块水位再回来)。
/// 模式/令牌/后端地址变化自动重拉;失败回退 null。
final anlasProvider = AsyncNotifierProvider<AnlasNotifier, NaiSubscription?>(
  AnlasNotifier.new,
);

class AnlasNotifier extends AsyncNotifier<NaiSubscription?> {
  int _request = 0;
  @override
  Future<NaiSubscription?> build() async {
    _request++;
    // await 依赖(而非取 .value):懒加载 storage 首读期间 .value 是 null,
    // 会先空跑一轮返回 null、再等重建,首帧点数/Opus 状态平白慢一拍。
    final mode = await ref.watch(authModeProvider.future);
    if (mode == null) return null;
    if (mode == AuthMode.bot) {
      final base = await ref.watch(backendBaseProvider.future);
      if (base.isEmpty) return null;
      try {
        final res = await ref.read(backendClientProvider).getAnlas();
        // 后端只回一个点数合计,分不出订阅额/已购额,整笔按订阅额记(界面于是
        // 只显示一个数,不会摊成「x+0」)。NAI 5 额度那边已按主池合并好再回来。
        return (
          anlas: res.anlas,
          fixedAnlas: res.anlas,
          purchasedAnlas: 0,
          isOpus: true,
          tier: 3,
          usage: res.usage,
        );
      } catch (_) {
        return null;
      }
    }
    final key = await ref.watch(primaryNaiKeyProvider.future);
    if (key == null || key.token.isEmpty) return null;
    try {
      // watch:换了主账号、或它打的机器变了,客户端跟着换,这里重查一次
      // (读到的是另一台机器上的账户读数,留着旧数就是错数)。
      return await ref
          .watch(naiClientProvider(key.endpoint))
          .subscription(key.token);
    } catch (_) {
      return null;
    }
  }

  /// 主动刷新(顶栏点按 / 生成后):**静默**拉新,成功才替换。
  /// 不置 loading——那会让所有消费端瞬间丢值:点数闪没、isOpus 丢失导致
  /// 免费图的费用胶囊闪现 20 Anlas 再变回免费。
  /// 例外是手里本来就没数:没有值可丢,置 loading 顶栏那格才转得起来。
  Future<void> refresh() async {
    if (state.isLoading) {
      try {
        await future;
      } catch (_) {}
      if (!ref.mounted) return;
    }
    final mode = ref.read(authModeProvider).asData?.value;
    if (mode == null) return;
    final request = ++_request;
    final blank = state.asData?.value == null;
    bool Function() ownerValid = () => true;
    bool current() =>
        ref.mounted &&
        request == _request &&
        ref.read(authModeProvider).asData?.value == mode &&
        ownerValid();
    try {
      final NaiSubscription? next;
      if (mode == AuthMode.bot) {
        unawaited(ref.read(walletSummaryProvider.notifier).refresh());
        final base = await ref.read(backendBaseProvider.future);
        if (!current() || base.isEmpty) return;
        final client = ref.read(backendClientProvider);
        ownerValid = () => identical(client, ref.read(backendClientProvider));
        if (blank) state = const AsyncLoading();
        final res = await client.getAnlas();
        next = (
          anlas: res.anlas,
          fixedAnlas: res.anlas,
          purchasedAnlas: 0,
          isOpus: true,
          tier: 3,
          usage: res.usage,
        );
      } else {
        final key = await ref.read(primaryNaiKeyProvider.future);
        if (!current() || key == null || key.token.isEmpty) return;
        final client = ref.read(naiClientProvider(key.endpoint));
        ownerValid = () =>
            identical(key, ref.read(primaryNaiKeyProvider).asData?.value) &&
            identical(client, ref.read(naiClientProvider(key.endpoint)));
        if (blank) state = const AsyncLoading();
        next = await client.subscription(key.token);
      }
      if (current()) state = AsyncData(next);
    } catch (_) {
      if (current() && blank) state = const AsyncData(null);
    }
  }
}

/// V5 的免费尺寸**现在还免不免**:true = 额度已见底,免费尺寸转按 Anlas 计价。
///
/// V5 的免费尺寸图吃的是 Opus 充电式额度([NaiUsage]),额度见底后 NAI **不报错**,
/// 而是安静地改用 Anlas 计费 —— 界面上那个「免费」得跟着变回真实点数,不然用户
/// 是在不知情的状态下花钱,而且下一眼看到的是余额莫名其妙少了一截。
///
/// **只对 token 直连线成立**:bot 线花的是共享号池,服务端取号时就把见底的号排除
/// 了(全见底直接拒绝出图,回 `NO_V5_QUOTA_MSG`),那条线上的免费是真免费 ——
/// 报个点数出来反而是假的。
final v5ChargedProvider = Provider<bool>((ref) {
  if (ref.watch(authModeProvider).value != AuthMode.token) return false;
  final usage = ref.watch(anlasProvider).asData?.value?.usage;
  return usage != null && usage.isNegative;
});

/// 我的 NAI 5 出图额度(`GET /api/user/quota`,**bot 授权线专有**)。
///
/// token 直连线没有这回事:那条线花的是自己账户的 Opus 电池
/// ([NaiSubscription.usage]),不经我们发配额,所以这里恒 null。
///
/// 与 [anlasProvider] 分开而不是并进同一个 notifier:两者来源不同(一个公开
/// 端点、一个要会话),任一失败都不该把另一个也拖没 —— 点数拉不到时至少还能
/// 告诉用户「还能出几张」,反过来也一样。
final naiQuotaProvider = AsyncNotifierProvider<NaiQuotaNotifier, NaiQuota?>(
  NaiQuotaNotifier.new,
);

class NaiQuotaNotifier extends AsyncNotifier<NaiQuota?> {
  int _fetchRequest = 0;
  int _relayRequest = 0;

  @override
  Future<NaiQuota?> build() async {
    _fetchRequest++;
    _relayRequest++;
    final scope = await ref.watch(botFinanceScopeProvider.future);
    return scope == null ? null : _fetch(scope);
  }

  Future<void> refresh() async {
    if (state.isLoading) {
      try {
        await future;
      } catch (_) {}
      return;
    }
    final request = ++_fetchRequest;
    final scope = await ref.read(botFinanceScopeProvider.future);
    if (scope == null || !_sameFinanceScope(ref, scope)) return;
    final next = await _fetch(scope);
    if (_sameFinanceScope(ref, scope) &&
        request == _fetchRequest &&
        next != null) {
      state = AsyncData(next);
    }
  }

  /// 只在服务端确认后更新开关,失败保留原值。确认之前的额度请求不得盖回旧开关。
  Future<void> setRelay(bool enabled) async {
    final scope = await ref.read(botFinanceScopeProvider.future);
    if (scope == null || !_sameFinanceScope(ref, scope)) {
      throw StateError('未授权');
    }
    final request = ++_relayRequest;
    final result = await scope.client.setMyRelay(scope.sessionId, enabled);
    if (!_sameFinanceScope(ref, scope) || request != _relayRequest) return;
    _fetchRequest++;
    final quota = state.asData?.value;
    if (quota != null) {
      state = AsyncData(
        quota.copyWith(
          relayEnabled: result.enabled,
          relayAvailable: result.available,
        ),
      );
    }
  }

  Future<NaiQuota?> _fetch(BotFinanceScope scope) async {
    try {
      return await scope.client.myNaiQuota(scope.sessionId);
    } catch (_) {
      return null;
    }
  }
}

/// 钱包与中转请求绑定到接入方式、会话和后端。切换期间不给旧会话继续发请求。
typedef BotFinanceScope = ({String sessionId, BackendClient client});

final botFinanceScopeProvider = FutureProvider<BotFinanceScope?>((ref) async {
  final mode = await ref.watch(authModeProvider.future);
  if (mode != AuthMode.bot) return null;
  final session = await ref.watch(botSessionProvider.future);
  if (session == null || session.expired) return null;
  return (
    sessionId: session.sessionId,
    client: ref.watch(backendClientProvider),
  );
});

bool _sameFinanceScope(Ref ref, BotFinanceScope scope) =>
    ref.mounted && ref.read(botFinanceScopeProvider).asData?.value == scope;

/// 统计页允许手动查看另一套账本。钱包始终用 Bot 会话,不会用 NAI 直连密钥。
/// 创作页只在 Bot 接入方式下订阅它。
final walletAccountScopeProvider = FutureProvider<BotFinanceScope?>((
  ref,
) async {
  final session = await ref.watch(botSessionProvider.future);
  if (session == null || session.expired) return null;
  return (
    sessionId: session.sessionId,
    client: ref.watch(backendClientProvider),
  );
});

bool _sameWalletScope(Ref ref, BotFinanceScope scope) =>
    ref.mounted && ref.read(walletAccountScopeProvider).asData?.value == scope;

/// 旧后端未实现钱包接口时才回退旧账单;网络错误不能冒充空钱包。
bool walletEndpointUnsupported(Object error) =>
    error is BackendException && const [404, 405, 501].contains(error.status);

final walletSummaryProvider =
    AsyncNotifierProvider<WalletSummaryNotifier, WalletSummary?>(
      WalletSummaryNotifier.new,
      retry: (_, _) => null,
    );

class WalletSummaryNotifier extends AsyncNotifier<WalletSummary?> {
  int _request = 0;

  @override
  Future<WalletSummary?> build() async {
    _request++;
    final scope = await ref.watch(walletAccountScopeProvider.future);
    if (scope == null) return null;
    try {
      return await scope.client.wallet(scope.sessionId, limit: 0);
    } catch (error) {
      if (walletEndpointUnsupported(error)) return null;
      rethrow;
    }
  }

  /// 成功才替换余额;旧账号、旧后端和较早的刷新结果不能写回当前状态。
  Future<void> refresh() async {
    if (state.isLoading) {
      try {
        await future;
      } catch (_) {}
      return;
    }
    final request = ++_request;
    final scope = await ref.read(walletAccountScopeProvider.future);
    if (scope == null || !_sameWalletScope(ref, scope)) return;
    bool current() => _sameWalletScope(ref, scope) && request == _request;
    try {
      final next = await scope.client.wallet(scope.sessionId, limit: 0);
      if (current()) state = AsyncData(next);
    } catch (error, stack) {
      if (!current()) return;
      if (walletEndpointUnsupported(error)) {
        state = const AsyncData(null);
      } else if (state.asData?.value == null) {
        state = AsyncError(error, stack);
      }
    }
  }
}
