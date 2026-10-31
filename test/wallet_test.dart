// 钱包的解析契约(`GET /api/wallet`、`GET /api/wallet/ledger`)。
//
// 服务端金额下发的是**元**(两位小数),App 一律换成整数分再用 —— 这里钉的是
// 换算不丢分、正负不搞反、缺字段不炸。算错一处,用户看到的余额就和管理员那边
// 对不上。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/stats/stats_providers.dart'
    show fmtFen, sharePercents;

const _summary = {
  'user_id': '123456',
  'nickname': '',
  'balance': -3.27,
  'balance_fen': -327,
  'charged_total': 23.27,
  'credited_total': 20.0,
  'count': 81,
  'recent': [
    {
      'id': 123,
      'ts': '2026-10-18T14:02:03',
      'amount': -0.03,
      'kind': 'nai',
      'title': 'NAI 出图',
      'note': 'V5 Full · 832×1216',
    },
    {
      'id': 120,
      'ts': '2026-10-18T09:00:00',
      'amount': 20,
      'kind': 'topup',
      'title': '充值',
      'note': '微信转账',
    },
  ],
  'categories': [
    {'title': 'NAI 出图', 'kind': 'nai', 'count': 78, 'amount': 20.27},
    {'title': '扣款调整', 'kind': 'adjust', 'count': 1, 'amount': 3},
  ],
  'pending': {'rental': 0.85, 'rental_count': 1},
  'start_from': '2026-09-26',
  'is_admin': false,
};

void main() {
  group('钱包摘要', () {
    test('完整返回:余额、累计、在跑租卡各就各位', () {
      final w = WalletSummary.fromJson(_summary);
      expect(w.userId, '123456');
      expect(w.balanceFen, -327);
      expect(w.owing, isTrue);
      expect(w.chargedFen, 2327);
      expect(w.creditedFen, 2000);
      expect(w.count, 81);
      expect(w.recent, hasLength(2));
      expect(w.categories, hasLength(2));
      expect(w.categories[0].title, 'NAI 出图');
      expect(w.categories[0].kind, 'nai');
      expect(w.categories[0].count, 78);
      expect(w.categories[0].amountFen, 2027);
      expect(w.categories[1].amountFen, 300);
      expect(w.pendingRentalFen, 85);
      expect(w.pendingRentalCount, 1);
      expect(w.startFrom, '2026-09-26');
      expect(w.isAdmin, isFalse);
    });

    test('没有 balance_fen 时从元换算,不被浮点尾巴吃掉一分', () {
      // 0.29 * 100 = 28.999999999999996,截断的话就成了 28
      final w = WalletSummary.fromJson(const {'balance': 0.29});
      expect(w.balanceFen, 29);
      expect(w.owing, isFalse);
    });

    test('缺字段一律按 0 / 空,不抛 —— 没在跑的租卡就是 0 台', () {
      final w = WalletSummary.fromJson(const {});
      expect(w.balanceFen, 0);
      expect(w.owing, isFalse);
      expect(w.recent, isEmpty);
      expect(w.categories, isEmpty);
      expect(w.pendingRentalCount, 0);
      expect(w.pendingRentalFen, 0);
      expect(
        WalletSummary.fromJson(const {'pending': null}).pendingRentalCount,
        0,
      );
    });
  });

  group('流水条目', () {
    test('扣款为负、充值为正;整数金额也认', () {
      final items = WalletSummary.fromJson(_summary).recent;
      final charge = items[0];
      expect(charge.amountFen, -3);
      expect(charge.isCredit, isFalse);
      expect(charge.kind, 'nai');
      expect(charge.title, 'NAI 出图');
      expect(charge.note, 'V5 Full · 832×1216');

      final topup = items[1];
      expect(topup.amountFen, 2000);
      expect(topup.isCredit, isTrue);
    });

    test('时间按位切成「月-日 时:分」与「时:分」,不做时区换算', () {
      final e = WalletEntry.fromJson(const {
        'id': 1,
        'ts': '2026-10-18T14:02:03',
        'amount': -0.03,
      });
      expect(e.shortTime, '10-18 14:02');
      expect(e.clock, '14:02');
      // 串不够长就原样给,不抛
      expect(WalletEntry.fromJson(const {'ts': '坏'}).shortTime, '坏');
    });
  });

  group('流水翻页', () {
    test('next_cursor 原样留着续翻;null / 空串 = 到底', () {
      final page = WalletLedger.fromJson(const {
        'user_id': '123456',
        'items': [
          {'id': 42, 'ts': '2026-10-05T12:00:00', 'amount': -0.05},
        ],
        'next_cursor': '2026-10-05T12:00:00.123456|42',
      });
      expect(page.items.single.id, 42);
      expect(page.nextCursor, '2026-10-05T12:00:00.123456|42');

      expect(
        WalletLedger.fromJson(const {
          'items': [],
          'next_cursor': null,
        }).nextCursor,
        isNull,
      );
      expect(
        WalletLedger.fromJson(const {'next_cursor': ''}).nextCursor,
        isNull,
      );
      expect(WalletLedger.fromJson(const {}).items, isEmpty);
    });
  });

  group('金额文案', () {
    test('和服务端同一种写法:扣款带 -,入账带 +', () {
      expect(fmtFen(-3), '-¥0.03');
      expect(fmtFen(2000), '+¥20.00');
      expect(fmtFen(0), '¥0.00');
    });

    test('余额 / 合计不带 +,负数照样带 -', () {
      expect(fmtFen(2000, sign: false), '¥20.00');
      expect(fmtFen(-327, sign: false), '-¥3.27');
    });

    test('类目占比取整后合计恰为 100,余数大的先补', () {
      expect(sharePercents([1, 1, 1]), [34, 33, 33]);
      expect(sharePercents([2027, 300]), [87, 13]);
      expect(sharePercents([995, 5]), [100, 0]);
      expect(sharePercents([0, 0]), [0, 0]);
      expect(sharePercents(const []), isEmpty);
    });
  });
}
