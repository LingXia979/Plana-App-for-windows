import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/auth/bot_session_store.dart';
import 'package:plana_app/core/net/anlas_provider.dart';
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/nai_client.dart';
import 'package:plana_app/core/net/remote_image.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/generate/models.dart';
import 'package:plana_app/features/generate/widgets/anlas_panel.dart';
import 'package:plana_app/features/generate/widgets/bottom_action_bar.dart';
import 'package:plana_app/features/generate/widgets/top_bar_status.dart';
import 'package:plana_app/features/stats/day_detail_page.dart';
import 'package:plana_app/features/stats/wallet_page.dart';
import 'package:plana_app/features/stats/stats_page.dart';
import 'package:plana_app/features/stats/stats_providers.dart';

class _SavePicker extends FilePicker {
  String? path;
  String? name;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    name = fileName;
    return path;
  }
}

class _Session extends BotSessionNotifier {
  @override
  Future<BotSession?> build() async => const BotSession(sessionId: 'A');
  @override
  Future<void> save(BotSession value) async => state = AsyncData(value);
}

class _Mode extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.bot;
  @override
  Future<void> set(AuthMode mode) async => state = AsyncData(mode);
}

class _Generate extends GenerateNotifier {
  @override
  GenerateState build() => GenerateState.initial().copyWith(
    params: const GenParams(model: 'NAI 5.0 Full'),
  );
}

class _Anlas extends AnlasNotifier {
  @override
  Future<NaiSubscription?> build() async => (
    anlas: 9800,
    fixedAnlas: 9800,
    purchasedAnlas: 0,
    isOpus: true,
    tier: 3,
    usage: null,
  );
  @override
  Future<void> refresh() async {}
}

class _Backend extends BackendClient {
  _Backend() : super('http://fixture.invalid');
  Future<WalletSummary> Function(String)? summary;
  Future<WalletLedger> Function(String, String, String?)? ledger;
  Future<({bool enabled, bool available})> Function(bool)? relay;
  NaiQuota quota = const NaiQuota(balance: 75, limit: 100);
  final requests = <(String, String, String?)>[];
  @override
  Future<WalletSummary> wallet(String sessionId, {int limit = 10}) async =>
      summary?.call(sessionId) ??
      WalletSummary(
        userId: sessionId,
        balanceFen: sessionId == 'A' ? -12345 : 98765,
        chargedFen: 12545,
        creditedFen: 200,
        pendingRentalFen: 135,
        pendingRentalCount: 1,
        categories: const [
          WalletCategory(kind: 'nai', title: 'NAI 出图', amountFen: 12000),
          WalletCategory(kind: 'rental', title: '租卡', amountFen: 545),
        ],
      );
  @override
  Future<WalletLedger> walletLedger(
    String sessionId, {
    int limit = 50,
    String? cursor,
    String kind = 'all',
    DateTime? since,
    DateTime? until,
  }) async {
    requests.add((sessionId, kind, cursor));
    return ledger?.call(sessionId, kind, cursor) ??
        WalletLedger(
          items: [
            WalletEntry(
              id: 1,
              ts: '2026-10-31T10:00:00',
              title: '$sessionId 中转出图',
              note: 'V5 Full · 832×1216',
              amountFen: -5,
              kind: 'nai',
            ),
            const WalletEntry(
              id: 2,
              ts: '2026-10-31T09:00:00',
              title: '充值入账',
              amountFen: 200,
              kind: 'topup',
            ),
          ],
        );
  }

  @override
  Future<NaiQuota> myNaiQuota(String sessionId) async => quota;
  @override
  Future<({bool enabled, bool available})> setMyRelay(
    String sessionId,
    bool enabled,
  ) async => relay?.call(enabled) ?? (enabled: enabled, available: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!Platform.isWindows) return;
    for (final font in [
      ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
      ('monospace', r'C:\Windows\Fonts\consola.ttf'),
      (
        'MaterialIcons',
        r'D:\Android\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      ),
    ]) {
      final file = File(font.$2);
      if (await file.exists()) {
        await (FontLoader(
          font.$1,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  late _Backend backend;
  late ProviderContainer container;
  late AppStores stores;
  final capture = GlobalKey();
  setUp(() {
    backend = _Backend();
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        desktopModeProvider.overrideWithValue(true),
        appStoresProvider.overrideWithValue(stores),
        userStatsProvider.overrideWith(
          (ref, range) async => const UsageStats(),
        ),
        userStatsAllProvider.overrideWith((ref) async => const UsageStats()),
        userDailyProvider.overrideWith((ref, range) async => []),
        platformHourlyProvider.overrideWith((ref, args) async => null),
        billingEstimateProvider.overrideWith((ref) async => null),
        billingSettlementProvider.overrideWith((ref) async => null),
        gpuBillsProvider.overrideWith((ref) async => null),
        authModeProvider.overrideWith(_Mode.new),
        botSessionProvider.overrideWith(_Session.new),
        backendClientProvider.overrideWithValue(backend),
        generateProvider.overrideWith(_Generate.new),
        anlasProvider.overrideWith(_Anlas.new),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
  });
  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(760, 850),
    bool dark = false,
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = dark ? AppTheme.dark() : AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme.copyWith(
            platform: TargetPlatform.windows,
            textTheme: theme.textTheme.apply(fontFamily: 'Microsoft YaHei'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: capture, child: child!),
          ),
          home: page,
        ),
      ),
    );
    // Pending request cases intentionally have a live progress indicator.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLANA_DESKTOP_CAPTURE'] != '1') return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/windows-validation/batch10-$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'desktop wallet shows separate charges, credits and pending rentals; filter rejects old pages',
    (tester) async {
      final old = Completer<WalletLedger>();
      backend.ledger = (_, kind, _) => kind == 'all'
          ? old.future
          : Future.value(
              const WalletLedger(
                items: [
                  WalletEntry(id: 7, ts: '', title: '筛选后的充值', amountFen: 201),
                ],
              ),
            );
      await mount(tester, const WalletPage());
      expect(find.text('-¥123.45'), findsOneWidget);
      expect(find.textContaining('关机时扣'), findsOneWidget);
      await tester.tap(find.text('充值').last);
      await tester.pumpAndSettle();
      old.complete(
        const WalletLedger(
          items: [WalletEntry(id: 9, ts: '', title: '过时流水', amountFen: -5)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('筛选后的充值'), findsOneWidget);
      expect(find.text('过时流水'), findsNothing);
      expect(backend.requests.map((e) => e.$2), ['all', 'credit']);
      await screenshot(tester, 'wallet');
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'account switch discards prior balance, filter and delayed ledger',
    (tester) async {
      final old = Completer<WalletLedger>();
      backend.ledger = (sid, _, _) => sid == 'A'
          ? old.future
          : Future.value(
              const WalletLedger(
                items: [
                  WalletEntry(id: 4, ts: '', title: 'B 的流水', amountFen: -9),
                ],
              ),
            );
      await mount(tester, const WalletPage());
      await container
          .read(botSessionProvider.notifier)
          .save(const BotSession(sessionId: 'B'));
      await tester.pumpAndSettle();
      expect(find.text('-¥123.45'), findsNothing);
      expect(find.text('¥987.65'), findsOneWidget);
      expect(find.text('B 的流水'), findsOneWidget);
      old.complete(
        const WalletLedger(
          items: [WalletEntry(id: 3, ts: '', title: 'A 的旧流水', amountFen: 5)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A 的旧流水'), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'repeated cursor stops automatic paging, deduplicates rows, and refresh recovers failure',
    (tester) async {
      backend.ledger = (_, _, _) async => const WalletLedger(
        items: [WalletEntry(id: 3, ts: '', title: '同一笔记录', amountFen: -9)],
        nextCursor: 'loop',
      );
      await mount(tester, const WalletPage());
      await tester.pumpAndSettle();
      expect(backend.requests, hasLength(2));
      expect(find.text('同一笔记录'), findsOneWidget);
      expect(find.textContaining('仅显示已加载记录'), findsOneWidget);
      backend.ledger = (_, _, _) async => throw BackendException('offline');
      await tester.tap(find.byTooltip('刷新钱包'));
      await tester.pumpAndSettle();
      expect(find.text('同一笔记录'), findsOneWidget);
      expect(find.text('加载失败,点此重试'), findsOneWidget);
      backend.ledger = (_, _, _) async => const WalletLedger(items: []);
      await tester.tap(find.text('加载失败,点此重试'));
      await tester.pumpAndSettle();
      expect(find.text('还没有流水'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'only unsupported wallet uses legacy bills; network errors offer refresh',
    (tester) async {
      backend.summary = (_) async =>
          throw BackendException('old backend', status: 404);
      await mount(tester, const WalletPage());
      await tester.pumpAndSettle();
      expect(find.text('NAI 账单'), findsOneWidget);
      expect(find.text('算力账单'), findsOneWidget);
      await finish(tester);
      backend.summary = (_) async =>
          throw BackendException('offline', status: 500);
      container.invalidate(walletSummaryProvider);
      await mount(tester, const WalletPage());
      await tester.pumpAndSettle();
      expect(find.text('NAI 账单'), findsNothing);
      expect(find.text('余额暂时查不到，请刷新重试'), findsOneWidget);
      backend.summary = null;
      await tester.tap(find.byTooltip('刷新钱包'));
      await tester.pumpAndSettle();
      expect(find.text('-¥123.45'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets('wallet and daily totals fit narrow desktop with enlarged text', (
    tester,
  ) async {
    await mount(
      tester,
      const WalletPage(),
      size: const Size(360, 800),
      dark: true,
      scale: 1.3,
    );
    await tester.pumpAndSettle();
    await screenshot(tester, 'wallet-narrow');
    expect(tester.takeException(), isNull);
    await mount(
      tester,
      DayDetailPage(
        bot: true,
        day: DateTime(2026, 10, 31),
        label: '今天',
        mode: DayDetailMode.points,
      ),
      size: const Size(360, 800),
      scale: 1.2,
    );
    await tester.pumpAndSettle();
    expect(find.text('当日扣款'), findsOneWidget);
    expect(find.text('当日入账'), findsOneWidget);
    expect(find.text('¥0.05'), findsOneWidget);
    expect(find.text('¥2.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets(
    'balance switches between percentage and meter and preserves direct Anlas',
    (tester) async {
      await mount(
        tester,
        const Scaffold(body: Center(child: AnlasChip(budget: 260))),
      );
      await tester.pumpAndSettle();
      expect(find.text('75%'), findsOneWidget);
      expect(
        tester.widget<TopBarStatus>(find.byType(TopBarStatus)).meter,
        isNull,
      );
      await mount(
        tester,
        const Scaffold(body: Center(child: AnlasChip(budget: 145))),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TopBarStatus>(find.byType(TopBarStatus)).meter,
        isNotNull,
      );
      expect(find.text('75%'), findsNothing);
      await container.read(authModeProvider.notifier).set(AuthMode.token);
      await tester.pumpAndSettle();
      expect(find.text('9,800'), findsOneWidget);
      expect(find.text('-¥123.45'), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'desktop relay panel displays server pricing, restores failed toggle and navigates to wallet',
    (tester) async {
      backend.quota = const NaiQuota(
        sharedPool: false,
        relayPrice: .08,
        relayPriceLegacy: .04,
      );
      backend.relay = (_) async => throw BackendException('offline');
      await mount(
        tester,
        Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAnlasSheet(context),
                child: const Text('打开余额'),
              ),
            ),
          ),
        ),
        size: const Size(740, 900),
      );
      await tester.tap(find.text('打开余额'));
      await tester.pumpAndSettle();
      expect(find.text('钱包与中转'), findsOneWidget);
      expect(find.textContaining('V5 ¥0.08'), findsOneWidget);
      expect(find.text('我的 NAI 5 额度'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      backend.relay = null;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await screenshot(tester, 'relay');
      await tester.tap(find.text('钱包余额'));
      await tester.pumpAndSettle();
      expect(find.byType(WalletPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'relay pricing never appears as free Anlas and leaves direct costs unchanged',
    (tester) async {
      backend.quota = const NaiQuota(
        sharedPool: false,
        relayEnabled: true,
        relayPrice: .08,
        relayPriceLegacy: .04,
      );
      await mount(
        tester,
        const Scaffold(body: Center(child: GenerationCostPill(cost: 0))),
      );
      await tester.pumpAndSettle();
      expect(find.text('¥0.08/张'), findsOneWidget);
      expect(find.text('免费'), findsNothing);
      await container.read(naiQuotaProvider.notifier).setRelay(false);
      await tester.pumpAndSettle();
      expect(find.text('中转未启用'), findsOneWidget);
      await container.read(authModeProvider.notifier).set(AuthMode.token);
      await tester.pumpAndSettle();
      expect(find.text('免费'), findsOneWidget);
      await mount(
        tester,
        const Scaffold(body: Center(child: GenerationCostPill(cost: 28))),
      );
      await tester.pumpAndSettle();
      expect(find.text('28'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'stats can explicitly view the saved Bot wallet while generation stays direct',
    (tester) async {
      await container.read(authModeProvider.future);
      await container.read(authModeProvider.notifier).set(AuthMode.token);
      await mount(tester, const StatsPage());
      await tester.pumpAndSettle();
      expect(find.text('钱包'), findsNothing);
      await tester.tap(find.byTooltip('数据源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bot 授权'));
      await tester.pumpAndSettle();
      expect(container.read(authModeProvider).requireValue, AuthMode.token);
      expect(find.text('钱包'), findsOneWidget);
      await tester.ensureVisible(find.text('钱包'));
      await tester.tap(find.text('钱包'));
      await tester.pumpAndSettle();
      expect(find.byType(WalletPage), findsOneWidget);
      expect(find.text('-¥123.45'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'QR dialog saves a PNG through the desktop picker and invalidates after switching account',
    (tester) async {
      FilePicker? previous;
      try {
        previous = FilePicker.platform;
      } catch (_) {
        /* No desktop plugin in widget tests. */
      }
      final picker = _SavePicker();
      FilePicker.platform = picker;
      final temp = Directory.systemTemp.createTempSync('plana_wallet_test_');
      addTearDown(() async {
        FilePicker.platform = previous ?? _SavePicker();
        await RemoteImageStore.clear();
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final url = backend.paymentQrUrl('wechat');
      final bytes = img.encodeJpg(img.Image(width: 24, height: 32));
      await tester.runAsync(() async {
        RemoteImageStore.bind(temp);
        await RemoteImageStore.write(url, bytes);
        RemoteImageStore.markChecked(url);
      });
      await mount(tester, const WalletPage());
      await tester.tap(find.widgetWithText(FilledButton, '充值'));
      for (var i = 0; i < 20 && find.text('另存收款码').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('保存到相册'), findsNothing);
      expect(find.text('另存收款码'), findsOneWidget);
      // Cancel leaves the directory without a result file.
      await tester.tap(find.text('另存收款码'));
      await tester.pumpAndSettle();
      final target = File('${temp.path}/saved.png');
      expect(target.existsSync(), isFalse);
      picker.path = target.path;
      await tester.tap(find.text('另存收款码'));
      for (var i = 0; i < 60 && find.text('已保存收款码').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(picker.name, 'plana_payment_qr_wechat.png');
      expect(target.existsSync(), isTrue);
      expect(img.decodePng(target.readAsBytesSync())!.height, 32);
      expect(File('${target.path}.tmp').existsSync(), isFalse);
      await screenshot(tester, 'wallet-qr');
      await container
          .read(botSessionProvider.notifier)
          .save(const BotSession(sessionId: 'B'));
      await tester.pumpAndSettle();
      expect(find.text('另存收款码'), findsNothing);
      expect(find.textContaining('账号或后端已切换'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
}
