import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/network_proxy.dart';
import 'package:plana_app/core/net/proxy_import.dart';
import 'package:plana_app/core/platform/clipboard_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  List<String> addresses(String text) =>
      parseProxyAddresses(text).map((v) => v.address).toList();

  test('parse copied URLs, host ports and proxy shell commands', () {
    expect(addresses('http://127.0.0.1:7897'), ['http://127.0.0.1:7897']);
    expect(addresses('localhost:7897'), ['http://localhost:7897']);
    expect(addresses('http://[::1]:7897'), ['http://[::1]:7897']);
    expect(addresses(r'$env:HTTP_PROXY="http://127.0.0.1:7897";'), [
      'http://127.0.0.1:7897',
    ]);
    expect(addresses("export http_proxy='http://127.0.0.1:7897'"), [
      'http://127.0.0.1:7897',
    ]);
    expect(
      addresses(
        'set http_proxy=http://127.0.0.1:7897\nset https_proxy=http://127.0.0.1:7897',
      ),
      ['http://127.0.0.1:7897'],
    );
  });

  test(
    'OCR labels, Chinese whitespace and next-line ports retain exact numbers',
    () {
      expect(
        addresses(
          'Clash Verge\nMixed Port: 7897\nSOCKS Port: 7898\nExternal Controller: 9090',
        ),
        ['http://127.0.0.1:7897'],
      );
      expect(addresses('混 合 端 口\n7897\n控制端口 9090'), ['http://127.0.0.1:7897']);
      expect(addresses('HTTP 端口： 8080'), ['http://127.0.0.1:8080']);
      expect(addresses('HTTP 端口：192.168.1.2:7897'), [
        'http://192.168.1.2:7897',
      ]);
      expect(addresses('http://127 . 0 . 0 . 1 : 7897'), [
        'http://127.0.0.1:7897',
      ]);
      expect(addresses('mixed-port: 7897\nport: 7890\nsocks-port: 7891'), [
        'http://127.0.0.1:7897',
        'http://127.0.0.1:7890',
      ]);
    },
  );

  test(
    'reject subscriptions, controllers, SOCKS, credentials and unrelated numbers',
    () {
      for (final text in [
        '7897',
        '余额 7897',
        'HTTP Port: 0',
        'Mixed Port: 70000',
        'socks5://127.0.0.1:7891',
        'https://127.0.0.1:7897',
        'http://user:password@127.0.0.1:7897',
        'http://127.0.0.1:9090/ui',
        'http://example.com:7897/sub?token=secret',
        'External Controller: http://127.0.0.1:9090',
        '外 部 控 制 器 HTTP 端 口：9090',
        '控 制 端 口：http://127.0.0.1:9090',
        'S O C K S 端 口：127.0.0.1:7898',
        'SOCKS: 127.0.0.1:7891',
      ]) {
        expect(addresses(text), isEmpty, reason: text);
      }
    },
  );

  test(
    'system proxy OCR accepts full-width punctuation and digits without guessing a port',
    () {
      expect(
        addresses(
          '系 统 代 理 设 置\n当 前 系 统 代 理\n开 启 状 态 ： 已 启 用\n服 务 地 址 ： 127 ． 0 ． 0 ． 1 ： 7897',
        ),
        ['http://127.0.0.1:7897'],
      );
      expect(addresses('服务地址：１２７．０．０．１：７８９７'), ['http://127.0.0.1:7897']);
      expect(addresses('ＨＴＴＰ：／／１２７．０．０．１：７８９７'), ['http://127.0.0.1:7897']);
      expect(addresses('ＳＯＣＫＳ：１２７．０．０．１：７８９８'), isEmpty);
      expect(addresses('控 制 地 址 ： 127 ． 0 ． 0 ． 1 ： 9090'), isEmpty);
      expect(addresses('系统代理 已启用 7897'), isEmpty);
    },
  );

  test(
    'old settings preserve connection while new software choice survives encoding',
    () {
      final old = NetworkProxySettings.decode(
        '{"enabled":true,"address":"http://127.0.0.1:7897","bypassLocal":false}',
      );
      expect(old.enabled, isTrue);
      expect(old.address, 'http://127.0.0.1:7897');
      expect(old.bypassLocal, isFalse);
      expect(old.software, ProxySoftware.auto);
      const chosen = NetworkProxySettings(
        enabled: true,
        software: ProxySoftware.clash,
      );
      expect(
        NetworkProxySettings.decode(chosen.encode()).software,
        ProxySoftware.clash,
      );
      expect(
        chosen.directive,
        old.validated().directive.replaceAll('7897', '7890'),
      );
    },
  );

  test(
    'applied routes distinguish direct, Cloudflare, detected Clash and other proxies',
    () {
      expect(
        appliedProxyRoute(const NetworkProxySettings(), relay: false),
        '本机直连：Plana → NovelAI',
      );
      expect(
        appliedProxyRoute(const NetworkProxySettings(), relay: true),
        'Plana → Cloudflare 转发 → NovelAI',
      );
      expect(
        appliedProxyRoute(
          const NetworkProxySettings(enabled: true),
          relay: false,
          detected: ProxySoftware.clash,
        ),
        'Plana → Clash → NovelAI',
      );
      expect(
        appliedProxyRoute(
          const NetworkProxySettings(enabled: true),
          relay: false,
        ),
        'Plana → 代理软件 → NovelAI',
      );
      expect(
        appliedProxyRoute(
          const NetworkProxySettings(enabled: true),
          relay: true,
          detected: ProxySoftware.other,
        ),
        'Plana → 代理软件 → Cloudflare 转发 → NovelAI',
      );
      expect(
        appliedProxyRoute(
          const NetworkProxySettings(
            enabled: true,
            software: ProxySoftware.clash,
          ),
          relay: true,
        ),
        'Plana → Clash → Cloudflare 转发 → NovelAI',
      );
      expect(
        appliedProxyRoute(
          const NetworkProxySettings(),
          relay: false,
          environmentProxy: true,
        ),
        'Plana → 代理软件（环境代理） → NovelAI',
      );
    },
  );

  test(
    'OCR unavailable errors remain actionable and do not masquerade as recognition',
    () async {
      const channel = MethodChannel('plana/proxy_assist');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'ocr_unavailable'),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await expectLater(
        recognizeProxyImage(Uint8List.fromList([1])),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('OCR'),
          ),
        ),
      );
      await expectLater(
        proxyClipboardImage(const ClipboardContent(paths: ['one', 'two'])),
        throwsFormatException,
      );
      await expectLater(
        proxyClipboardImage(const ClipboardContent(error: 'clipboard_busy')),
        throwsFormatException,
      );
    },
  );
}
