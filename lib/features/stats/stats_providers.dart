import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/nai_client.dart' show NaiUsage;

/// 统计页的数据源。服务端端点(除在线人数)都要 Bot 会话;
/// 失败/未授权一律回 null,由页面按「—」/未授权提示降级,不弹错。
/// range ∈ today/week/month。

Future<T?> _withSession<T>(
  Ref ref,
  Future<T> Function(BackendClient c, String sid) run,
) async {
  final session = await ref.watch(botSessionProvider.future);
  if (session == null) return null;
  try {
    return await run(ref.watch(backendClientProvider), session.sessionId);
  } catch (_) {
    return null;
  }
}

/// 个人统计(bot 账号,跨端)。range ∈ today/week/month。
final userStatsProvider = FutureProvider.autoDispose
    .family<UsageStats?, String>(
      (ref, range) => _withSession(ref, (c, sid) => c.userStats(sid, range)),
    );

/// 个人历史累计。后端 `_time_bounds` 对任何非 today/week/month 的值
/// 返回空边界 → 不加时间过滤即全量(源码核实),故传 `all` 取累计。
final userStatsAllProvider = FutureProvider.autoDispose<UsageStats?>(
  (ref) => _withSession(ref, (c, sid) => c.userStats(sid, 'all')),
);

/// 个人逐日序列。today 档后端给的是逐小时点(date 形如 `HH:mm`),
/// 主页趋势图与账单每日流水共用。
final userDailyProvider = FutureProvider.autoDispose
    .family<List<DailyStat>?, String>(
      (ref, range) =>
          _withSession(ref, (c, sid) => c.userStatsDaily(sid, range)),
    );

/// 平台当期统计。
final platformStatsProvider = FutureProvider.autoDispose
    .family<UsageStats?, String>(
      (ref, range) =>
          _withSession(ref, (c, sid) => c.platformStats(sid, range)),
    );

/// 平台历史全局。
final platformAllProvider = FutureProvider.autoDispose<UsageStats?>(
  (ref) => _withSession(ref, (c, sid) => c.platformStatsAll(sid)),
);

/// 平台 24 小时热力图;参数 (种类, 统计天数)。
final platformHourlyProvider = FutureProvider.autoDispose
    .family<HourlyHeat?, (HourlyKind, int)>(
      (ref, arg) =>
          _withSession(ref, (c, sid) => c.platformHourly(sid, arg.$1, arg.$2)),
    );

/// 某一天的服务端消耗明细(逐笔 + 构成)。参数为该天 00:00。
/// 优先按 bot_user_id 精确到当天;没有归属 id 时退回按范围取(仅今日可用)。
final dayDetailsProvider = FutureProvider.autoDispose
    .family<UsageDetails?, DateTime>((ref, day) async {
      final session = await ref.watch(botSessionProvider.future);
      if (session == null) return null;
      final c = ref.watch(backendClientProvider);
      final uid = session.botUserId;
      try {
        if (uid != null && uid.isNotEmpty) {
          return await c.usageDetails(
            sessionId: session.sessionId,
            from: day,
            to: day.add(const Duration(days: 1)),
          );
        }
        final now = DateTime.now();
        if (day.year != now.year ||
            day.month != now.month ||
            day.day != now.day) {
          return null; // 无归属 id 时只有「今日」可退回范围端点
        }
        return UsageDetails(
          records: await c.pointRecords(session.sessionId, 'today'),
        );
      } catch (_) {
        return null;
      }
    });

/// 某一天的逐笔生成明细(服务端 `/api/user/stats/calls`)。
/// 后端未部署该接口时返回 null,页面退回「只有当日次数」的说明。
final dayCallsProvider = FutureProvider.autoDispose
    .family<List<CallRecord>?, DateTime>(
      (ref, day) => _withSession(
        ref,
        (c, sid) => c.callRecords(
          sessionId: sid,
          from: day,
          to: day.add(const Duration(days: 1)),
        ),
      ),
    );

/// 本期费用预估。
final billingEstimateProvider = FutureProvider.autoDispose<BillingReport?>(
  (ref) => _withSession(ref, (c, sid) => c.billingEstimate(sid)),
);

/// 上期结算。
final billingSettlementProvider = FutureProvider.autoDispose<BillingReport?>(
  (ref) => _withSession(ref, (c, sid) => c.billingSettlement(sid)),
);

/// 算力账单(租卡 + 视频)。与 NAI 那本**不是一本账**:那本是按月阶梯分摊的
/// 订阅费,这本是按次实付,两个数不能相加。
final gpuBillsProvider = FutureProvider.autoDispose<GpuBills?>(
  (ref) => _withSession(ref, (c, sid) => c.rentalBills(sid)),
);

/// 共享号池的 NAI 官方额度(全平台水位)。**公开端点,不要会话** —— 所以不走
/// [_withSession];全平台统计页在没授权时本来就整页不可见,不必再挡一道。
final poolUsageProvider = FutureProvider.autoDispose<NaiUsage?>((ref) async {
  try {
    return await ref.watch(backendClientProvider).poolUsage();
  } catch (_) {
    return null; // 老服务端没这个端点 → 那块不画
  }
});

/// 金额:整数照 [fmtInt],带角分的保留两位。
String fmtFee(double v) =>
    v == v.roundToDouble() ? fmtInt(v) : v.toStringAsFixed(2);

/// 千分位(App 无 intl 依赖,手搓)。
String fmtInt(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return v < 0 ? '-$b' : b.toString();
}

const rangeLabels = {'today': '今日', 'week': '本周', 'month': '本月'};

/// 时间范围 → 热力图统计天数(对齐 web)。
const rangeDays = {'today': 1, 'week': 7, 'month': 30};
