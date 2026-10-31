import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/features/stats/stats_providers.dart';

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async =>
      const BotSession(sessionId: 'bot-fixture');
}

void main() {
  late HttpServer server;
  late BackendClient client;
  late FutureOr<void> Function(HttpRequest) respond;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = BackendClient('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      await respond(req);
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));
  void json(HttpRequest req, Object value, {int status = 200}) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(value));
  }

  test(
    'wallet, filtered cursor, relay and QR use the configured backend and Bot session',
    () async {
      final calls = <String>[];
      respond = (req) async {
        calls.add(req.uri.path);
        expect(req.headers.value('authorization'), 'Bearer bot-fixture');
        switch (req.uri.path) {
          case '/api/wallet':
            expect(req.uri.queryParameters, {'limit': '0'});
            json(req, {'balance': -0.29, 'balance_fen': -29, 'charged': .29});
          case '/api/wallet/ledger':
            expect(req.uri.queryParameters, {
              'limit': '17',
              'kind': 'credit',
              'cursor': 'a+b/= 空格',
              'since': '2026-10-31',
              'until': '2026-11-01',
            });
            json(req, {
              'items': [
                {'id': 8, 'amount': 20.29, 'ts': '2026-10-31T10:00:00'},
              ],
              'next_cursor': 'next/+',
            });
          case '/api/user/quota/relay':
            expect(req.method, 'POST');
            expect(jsonDecode(await utf8.decoder.bind(req).join()), {
              'enabled': true,
            });
            json(req, {'enabled': true, 'available': false});
          default:
            fail('Unexpected request: ${req.uri}');
        }
      };
      expect((await client.wallet('bot-fixture', limit: 0)).balanceFen, -29);
      final page = await client.walletLedger(
        'bot-fixture',
        limit: 17,
        kind: 'credit',
        cursor: 'a+b/= 空格',
        since: DateTime(2026, 10, 31, 22),
        until: DateTime(2026, 11, 1),
      );
      expect(page.items.single.amountFen, 2029);
      expect(page.nextCursor, 'next/+');
      expect(await client.setMyRelay('bot-fixture', true), (
        enabled: true,
        available: false,
      ));
      expect(
        client.paymentQrUrl('wechat'),
        'http://127.0.0.1:${server.port}/api/billing/qrcode?type=wechat',
      );
      expect(calls, [
        '/api/wallet',
        '/api/wallet/ledger',
        '/api/user/quota/relay',
      ]);
    },
  );

  test(
    'missing wallet balances and relay acknowledgements are errors, not zero or success',
    () async {
      respond = (req) => json(req, {});
      await expectLater(client.wallet('bot-fixture'), throwsFormatException);
      await expectLater(
        client.setMyRelay('bot-fixture', true),
        throwsFormatException,
      );
      respond = (req) => json(req, {'message': 'unavailable'}, status: 503);
      await expectLater(
        client.wallet('bot-fixture'),
        throwsA(isA<BackendException>().having((e) => e.status, 'status', 503)),
      );
    },
  );

  test('legacy quota defaults survive and new relay fields round-trip', () {
    final old = NaiQuota.fromJson({'daily_balance': 3, 'daily_limit': 20});
    expect(old.sharedPool, isTrue);
    expect(old.relayOnly, isFalse);
    final current = NaiQuota.fromJson({
      'shared_pool': false,
      'relay_enabled': true,
      'relay_available': false,
      'relay_price': .08,
      'relay_price_legacy': .04,
      'daily_balance': 7,
    });
    expect(current.relayOnly, isTrue);
    expect(current.relayEnabled, isTrue);
    expect(current.relayAvailable, isFalse);
    final changed = current.copyWith(relayEnabled: false, relayAvailable: true);
    expect(changed.balance, 7);
    expect(changed.relayPrice, .08);
    expect(changed.relayPriceLegacy, .04);
    expect(changed.sharedPool, isFalse);
  });

  Future<WalletLedger?> day() async {
    final c = ProviderContainer(
      overrides: [
        botSessionProvider.overrideWith(_Session.new),
        backendClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(c.dispose);
    final subscription = c.listen(
      dayWalletLedgerProvider(DateTime(2026, 10, 31)),
      (_, _) {},
    );
    addTearDown(subscription.close);
    return c.read(dayWalletLedgerProvider(DateTime(2026, 10, 31)).future);
  }

  test(
    'daily ledger deduplicates overlapping pages and stops repeated cursors with a partial flag',
    () async {
      var requests = 0;
      respond = (req) {
        expect(req.uri.queryParameters['since'], '2026-10-31');
        expect(req.uri.queryParameters['until'], '2026-11-01');
        requests++;
        json(req, {
          'items': [
            {'id': 1, 'amount': -.29},
            if (requests > 1) {'id': 2, 'amount': 2.01},
          ],
          'next_cursor': 'same',
        });
      };
      final result = (await day())!;
      expect(requests, 2);
      expect(result.items.map((e) => e.id), [1, 2]);
      expect(result.items.fold(0, (s, e) => s + e.amountFen), 172);
      expect(result.nextCursor, isNotNull);
    },
  );
  test(
    'daily ledger completes normal paging and caps a nonterminating server at 20 pages',
    () async {
      var requests = 0;
      respond = (req) {
        requests++;
        json(req, {
          'items': [
            {'id': requests, 'amount': -.05},
          ],
          'next_cursor': requests < 3 ? '$requests' : null,
        });
      };
      final complete = (await day())!;
      expect(complete.items.length, 3);
      expect(complete.nextCursor, isNull);
      requests = 0;
      respond = (req) {
        requests++;
        json(req, {
          'items': [
            {'id': requests, 'amount': -.05},
          ],
          'next_cursor': '$requests',
        });
      };
      final partial = (await day())!;
      expect(partial.items.length, 20);
      expect(requests, 20);
      expect(partial.nextCursor, '20');
    },
  );
}
