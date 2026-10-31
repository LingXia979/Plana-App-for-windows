import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/auth/token_store.dart';
import 'package:plana_app/core/net/nai_client.dart';

class _Mode extends AuthModeNotifier {
  _Mode(this.initial);
  final AuthMode initial;
  @override
  Future<AuthMode?> build() async => initial;
  @override
  Future<void> set(AuthMode mode) async => state = AsyncData(mode);
}

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async => const BotSession(sessionId: 'A');
  @override
  Future<void> save(BotSession value) async => state = AsyncData(value);
  @override
  Future<void> clear() async => state = const AsyncData(null);
}

class _Backend extends BackendClient {
  _Backend([this.offset = 0]) : super('http://test.invalid');
  final int offset;
  final walletCalls = <String>[];
  final quotaCalls = <String>[];
  final relayCalls = <(String, bool)>[];
  Future<WalletSummary> Function(String)? walletResponse;
  Future<NaiQuota> Function(String)? quotaResponse;
  Future<({bool enabled, bool available})> Function(String, bool)?
  relayResponse;

  @override
  Future<WalletSummary> wallet(String sessionId, {int limit = 10}) async {
    walletCalls.add(sessionId);
    return walletResponse?.call(sessionId) ??
        WalletSummary(
          userId: sessionId,
          balanceFen: offset + (sessionId == 'A' ? 100 : 200),
        );
  }

  @override
  Future<NaiQuota> myNaiQuota(String sessionId) async {
    quotaCalls.add(sessionId);
    return quotaResponse?.call(sessionId) ??
        const NaiQuota(balance: 10, limit: 20);
  }

  @override
  Future<({bool enabled, bool available})> setMyRelay(
    String sessionId,
    bool enabled,
  ) async {
    relayCalls.add((sessionId, enabled));
    return relayResponse?.call(sessionId, enabled) ??
        (enabled: enabled, available: true);
  }
}

class _Server extends Notifier<BackendClient> {
  _Server(this.initial);
  final BackendClient initial;
  @override
  BackendClient build() => initial;
  void change(BackendClient value) => state = value;
}

class _Key extends Notifier<NaiKey> {
  @override
  NaiKey build() => const NaiKey(id: 'one', token: 'one');
  void change() => state = const NaiKey(id: 'two', token: 'two');
}

final _key = NotifierProvider<_Key, NaiKey>(_Key.new);

class _Nai extends NaiClient {
  final lateRefresh = Completer<NaiSubscription>();
  final calls = <String>[];
  @override
  Future<NaiSubscription> subscription(String token) async {
    calls.add(token);
    if (token == 'one' && calls.length > 1) return lateRefresh.future;
    return subscriptionOf(token == 'one' ? 100 : 200);
  }
}

NaiSubscription subscriptionOf(int n) => (
  anlas: n,
  fixedAnlas: n,
  purchasedAnlas: 0,
  isOpus: true,
  tier: 3,
  usage: null,
);

final _server = NotifierProvider<_Server, BackendClient>(
  () => throw UnimplementedError(),
);

ProviderContainer harness(
  BackendClient backend, {
  AuthMode mode = AuthMode.bot,
}) {
  final c = ProviderContainer(
    overrides: [
      authModeProvider.overrideWith(() => _Mode(mode)),
      botSessionProvider.overrideWith(_Session.new),
      _server.overrideWith(() => _Server(backend)),
      backendClientProvider.overrideWith((ref) => ref.watch(_server)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Expected asynchronous request did not start');
}

void main() {
  test(
    'late direct Anlas refresh cannot overwrite a different primary key',
    () async {
      final nai = _Nai();
      final c = ProviderContainer(
        overrides: [
          authModeProvider.overrideWith(() => _Mode(AuthMode.token)),
          primaryNaiKeyProvider.overrideWith((ref) async => ref.watch(_key)),
          naiClientProvider('').overrideWithValue(nai),
        ],
      );
      addTearDown(c.dispose);
      expect((await c.read(anlasProvider.future))!.anlas, 100);
      final pending = c.read(anlasProvider.notifier).refresh();
      await until(() => nai.calls.length == 2);
      c.read(_key.notifier).change();
      expect((await c.read(anlasProvider.future))!.anlas, 200);
      nai.lateRefresh.complete(subscriptionOf(999));
      await pending;
      expect(c.read(anlasProvider).requireValue!.anlas, 200);
      expect(nai.calls, ['one', 'one', 'two']);
    },
  );
  test(
    'direct mode without a Bot session never requests wallet, quota or relay',
    () async {
      final backend = _Backend();
      final c = harness(backend, mode: AuthMode.token);
      await c.read(botSessionProvider.future);
      await c.read(botSessionProvider.notifier).clear();
      expect(await c.read(walletSummaryProvider.future), isNull);
      expect(await c.read(naiQuotaProvider.future), isNull);
      await c.read(walletSummaryProvider.notifier).refresh();
      await c.read(naiQuotaProvider.notifier).refresh();
      await expectLater(
        c.read(naiQuotaProvider.notifier).setRelay(true),
        throwsStateError,
      );
      expect(backend.walletCalls, isEmpty);
      expect(backend.quotaCalls, isEmpty);
      expect(backend.relayCalls, isEmpty);
    },
  );

  test(
    'explicit statistics wallet uses the saved Bot session while generation remains direct',
    () async {
      final backend = _Backend();
      final c = harness(backend, mode: AuthMode.token);
      expect((await c.read(walletSummaryProvider.future))!.userId, 'A');
      expect(await c.read(naiQuotaProvider.future), isNull);
      await expectLater(
        c.read(naiQuotaProvider.notifier).setRelay(true),
        throwsStateError,
      );
      expect(backend.walletCalls, ['A']);
      expect(backend.quotaCalls, isEmpty);
      expect(backend.relayCalls, isEmpty);
    },
  );

  test('unsupported wallet falls back; server failures stay errors', () async {
    for (final status in [404, 405, 501, 500, 401]) {
      final backend = _Backend()
        ..walletResponse = (_) async =>
            throw BackendException('unavailable', status: status);
      final c = harness(backend);
      if ([404, 405, 501].contains(status)) {
        expect(await c.read(walletSummaryProvider.future), isNull);
      } else {
        await expectLater(
          c.read(walletSummaryProvider.future),
          throwsA(isA<BackendException>()),
        );
        expect(c.read(walletSummaryProvider).hasError, isTrue);
      }
    }
  });

  test(
    'late wallet refresh cannot overwrite a different Bot account',
    () async {
      final backend = _Backend();
      final c = harness(backend);
      expect((await c.read(walletSummaryProvider.future))!.balanceFen, 100);
      final late = Completer<WalletSummary>();
      backend.walletResponse = (id) async =>
          id == 'A' ? late.future : WalletSummary(userId: id, balanceFen: 200);
      final refresh = c.read(walletSummaryProvider.notifier).refresh();
      await until(() => backend.walletCalls.length == 2);
      await c
          .read(botSessionProvider.notifier)
          .save(const BotSession(sessionId: 'B'));
      expect((await c.read(walletSummaryProvider.future))!.balanceFen, 200);
      late.complete(const WalletSummary(userId: 'A', balanceFen: 999));
      await refresh;
      expect(c.read(walletSummaryProvider).requireValue!.userId, 'B');
      expect(c.read(walletSummaryProvider).requireValue!.balanceFen, 200);
    },
  );

  test(
    'backend change invalidates balances even with the same session ID',
    () async {
      final backend = _Backend();
      final c = harness(backend);
      await c.read(walletSummaryProvider.future);
      final late = Completer<WalletSummary>();
      backend.walletResponse = (_) => late.future;
      final refresh = c.read(walletSummaryProvider.notifier).refresh();
      await until(() => backend.walletCalls.length == 2);
      c.read(_server.notifier).change(_Backend(500));
      expect((await c.read(walletSummaryProvider.future))!.balanceFen, 600);
      late.complete(const WalletSummary(balanceFen: 999));
      await refresh;
      expect(c.read(walletSummaryProvider).requireValue!.balanceFen, 600);
    },
  );

  test(
    'the most recent refresh wins; failed refresh preserves its last balance',
    () async {
      final backend = _Backend();
      final c = harness(backend);
      await c.read(walletSummaryProvider.future);
      final late = Completer<WalletSummary>();
      backend.walletResponse = (_) => late.future;
      final first = c.read(walletSummaryProvider.notifier).refresh();
      await until(() => backend.walletCalls.length == 2);
      backend.walletResponse = (_) async =>
          const WalletSummary(balanceFen: 250);
      await c.read(walletSummaryProvider.notifier).refresh();
      late.complete(const WalletSummary(balanceFen: 150));
      await first;
      expect(c.read(walletSummaryProvider).requireValue!.balanceFen, 250);
      backend.walletResponse = (_) async => throw BackendException('offline');
      await c.read(walletSummaryProvider.notifier).refresh();
      expect(c.read(walletSummaryProvider).requireValue!.balanceFen, 250);
    },
  );

  test(
    'relay acknowledgement cannot restore quota after switching to direct mode',
    () async {
      final backend = _Backend();
      final c = harness(backend);
      await c.read(naiQuotaProvider.future);
      final late = Completer<({bool enabled, bool available})>();
      backend.relayResponse = (_, _) => late.future;
      final setting = c.read(naiQuotaProvider.notifier).setRelay(true);
      await until(() => backend.relayCalls.isNotEmpty);
      await c.read(authModeProvider.notifier).set(AuthMode.token);
      expect(await c.read(naiQuotaProvider.future), isNull);
      late.complete((enabled: true, available: true));
      await setting;
      expect(c.read(naiQuotaProvider).requireValue, isNull);
    },
  );

  test('confirmed relay setting survives an older quota refresh', () async {
    final backend = _Backend();
    final c = harness(backend);
    await c.read(naiQuotaProvider.future);
    final late = Completer<NaiQuota>();
    backend.quotaResponse = (_) => late.future;
    final refresh = c.read(naiQuotaProvider.notifier).refresh();
    await until(() => backend.quotaCalls.length == 2);
    await c.read(naiQuotaProvider.notifier).setRelay(true);
    expect(c.read(naiQuotaProvider).requireValue!.relayEnabled, isTrue);
    late.complete(const NaiQuota(relayEnabled: false));
    await refresh;
    expect(c.read(naiQuotaProvider).requireValue!.relayEnabled, isTrue);
  });

  test('failed relay update preserves the server-confirmed setting', () async {
    final backend = _Backend();
    final c = harness(backend);
    await c.read(naiQuotaProvider.future);
    backend.relayResponse = (_, _) async => throw BackendException('offline');
    await expectLater(
      c.read(naiQuotaProvider.notifier).setRelay(true),
      throwsA(isA<BackendException>()),
    );
    expect(c.read(naiQuotaProvider).requireValue!.relayEnabled, isFalse);
  });
}
