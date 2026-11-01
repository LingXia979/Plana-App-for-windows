import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plana_app/core/net/backend_client.dart';
import 'package:plana_app/core/net/bot_stream.dart';
import 'package:plana_app/core/net/nai_endpoint.dart';
import 'package:plana_app/core/net/nai_proxy.dart';
import 'package:plana_app/core/net/network_proxy.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/prefs_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'accept HTTP/mixed addresses including IPv6 and reject wrong proxy inputs',
    () {
      expect(
        NetworkProxySettings.normalizeAddress(' http://localhost:7890/ '),
        'http://localhost:7890',
      );
      expect(
        NetworkProxySettings.normalizeAddress('http://[::1]:7897'),
        'http://[::1]:7897',
      );
      expect(
        NetworkProxySettings.normalizeAddress('http://localhost:80'),
        'http://localhost:80',
      );
      for (final address in [
        '',
        '127.0.0.1:7890',
        'socks5://localhost:7891',
        'https://localhost:7890',
        'http://localhost',
        'http://localhost:0',
        'http://localhost:65536',
        'http://localhost:7890/ui',
        'http://localhost:7890?token=secret',
        'http://user:secret@localhost:7890',
        'http://localhost:7890#token',
        'http://localhost:7890; DIRECT',
      ]) {
        expect(
          () => NetworkProxySettings.normalizeAddress(address),
          throwsFormatException,
          reason: address,
        );
      }
      expect(NetworkProxySettings.decode('broken').enabled, isFalse);
      expect(
        NetworkProxySettings.decode(
          '{"enabled":true,"address":"socks5://localhost:7891"}',
        ).enabled,
        isFalse,
      );
    },
  );

  test('bypass is limited to loopback, private IPs and local names', () {
    const settings = NetworkProxySettings(enabled: true);
    for (final host in [
      'localhost',
      'LOCALHOST.',
      'app.local',
      'app.localhost',
      '127.12.0.1',
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.2.1',
      '169.254.1.1',
      '[::1]',
      '[fc00::1]',
      '[fe80::1]',
      '[::ffff:127.0.0.1]',
    ]) {
      expect(
        settings.findProxy(Uri.parse('http://$host/')),
        'DIRECT',
        reason: host,
      );
    }
    for (final host in [
      'image.novelai.net',
      'localhost.example.com',
      '172.15.0.1',
      '172.32.0.1',
      '8.8.8.8',
      '[2606:4700::1111]',
    ]) {
      expect(
        settings.findProxy(Uri.parse('https://$host/')),
        settings.directive,
        reason: host,
      );
    }
    expect(
      const NetworkProxySettings(
        enabled: true,
        bypassLocal: false,
      ).findProxy(Uri.parse('http://localhost/')),
      settings.directive,
    );
    final official = Uri.parse(kNaiOfficialBase);
    expect(
      const NetworkProxySettings().findProxy(official),
      HttpClient.findProxyFromEnvironment(official),
    );
  });

  test(
    'settings survive a real disk reopen without changing NAI relay or endpoints',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'plana_proxy_settings_',
      );
      addTearDown(() => root.delete(recursive: true));
      final prefs = PrefsStore.emptyForTest(root);
      final container = ProviderContainer(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      await container
          .read(networkProxyProvider.notifier)
          .save(
            const NetworkProxySettings(
              enabled: true,
              address: 'http://localhost:7897',
            ),
          );
      expect(container.read(naiProxyProvider), isFalse);
      expect(naiBaseOf(''), kNaiOfficialBase);
      container.read(naiProxyProvider.notifier).set(true);
      await prefs.idle;
      expect(
        container.read(networkProxyProvider).address,
        'http://localhost:7897',
      );
      expect(naiBaseOf('', proxy: true), kNaiProxyBase);
      expect(
        naiBaseOf('https://third.example', proxy: true),
        'https://third.example',
      );
      final reopened = await PrefsStore.open(
        root,
        legacyRead: (_) async => null,
        legacyDelete: (_) async {},
      );
      final boot = ProviderContainer(
        overrides: [prefsStoreProvider.overrideWithValue(reopened)],
      );
      addTearDown(boot.dispose);
      expect(boot.read(networkProxyProvider).enabled, isTrue);
      expect(boot.read(networkProxyProvider).address, 'http://localhost:7897');
      expect(boot.read(naiProxyProvider), isTrue);
      await boot
          .read(networkProxyProvider.notifier)
          .save(const NetworkProxySettings(address: 'http://localhost:7897'));
      expect(boot.read(naiProxyProvider), isTrue);
      expect(boot.read(networkProxyRuntimeProvider).settings.enabled, isFalse);
    },
  );

  test(
    'immediate toggles and configuration saves preserve each other through disk reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('plana_proxy_toggle_');
      addTearDown(() => root.delete(recursive: true));
      final prefs = PrefsStore.emptyForTest(root);
      final container = ProviderContainer(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(networkProxyProvider.notifier);
      final enable = notifier.setEnabled(true);
      expect(
        container.read(networkProxyRuntimeProvider).settings.enabled,
        isTrue,
      );
      final configure = notifier.saveConfiguration(
        address: 'http://localhost:7897',
        bypassLocal: false,
        software: ProxySoftware.other,
      );
      expect(container.read(networkProxyProvider).enabled, isTrue);
      final disable = notifier.setEnabled(false);
      expect(
        container.read(networkProxyRuntimeProvider).settings.enabled,
        isFalse,
      );
      await Future.wait([enable, configure, disable]);
      final reopened = await PrefsStore.open(
        root,
        legacyRead: (_) async => null,
        legacyDelete: (_) async {},
      );
      final saved = NetworkProxySettings.decode(reopened.get(kNetworkProxyKey));
      expect(saved.enabled, isFalse);
      expect(saved.address, 'http://localhost:7897');
      expect(saved.bypassLocal, isFalse);
      expect(saved.software, ProxySoftware.other);
      await notifier.saveConfiguration(
        address: 'http://localhost:7898',
        bypassLocal: true,
        software: ProxySoftware.auto,
      );
      expect(container.read(networkProxyProvider).enabled, isFalse);
    },
  );

  test(
    'disk failure is reported, runtime stays usable and same settings can retry',
    () async {
      final root = await Directory.systemTemp.createTemp('plana_proxy_fail_');
      addTearDown(() => root.delete(recursive: true));
      final blocker = File('${root.path}/blocked');
      await blocker.writeAsString('synthetic');
      final prefs = PrefsStore.emptyForTest(Directory(blocker.path));
      final container = ProviderContainer(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(networkProxyProvider.notifier);
      await expectLater(
        notifier.setEnabled(true),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        container.read(networkProxyRuntimeProvider).settings.enabled,
        isTrue,
      );
      await blocker.delete();
      await notifier.setEnabled(true);
      final saved =
          jsonDecode(await File('${blocker.path}/settings.json').readAsString())
              as Map;
      expect(
        NetworkProxySettings.decode(saved[kNetworkProxyKey] as String).enabled,
        isTrue,
      );
    },
  );

  test(
    'HTTP clients, streaming and WebSockets follow runtime proxy changes',
    () async {
      final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      for (final server in [direct, first, second]) {
        addTearDown(() => server.close(force: true));
      }
      final received = <String>[];
      void serve(HttpServer server, String name) {
        server.listen((request) async {
          received.add('$name:${request.method}:${request.uri}');
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final socket = await WebSocketTransformer.upgrade(request);
            socket.listen((message) => socket.add('$name:$message'));
          } else {
            request.response.write(name);
            await request.response.close();
          }
        });
      }

      serve(direct, 'direct');
      serve(first, 'first');
      serve(second, 'second');
      final runtime = NetworkProxyOverrides(const NetworkProxySettings());
      NetworkProxySettings via(HttpServer server) => NetworkProxySettings(
        enabled: true,
        address: 'http://127.0.0.1:${server.port}',
        bypassLocal: false,
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = http.Client();
        final raw = HttpClient();
        try {
          final local = Uri.parse('http://127.0.0.1:${direct.port}/test');
          expect((await client.get(local)).body, 'direct');
          runtime.settings = via(first);
          expect((await client.get(local)).body, 'first');
          final remote = Uri.parse('http://never-resolve.invalid/stream');
          final request = await raw.getUrl(remote);
          expect(
            await (await request.close()).transform(utf8.decoder).join(),
            'first',
          );
          final socket = await WebSocket.connect(
            'ws://never-resolve.invalid:80/ws',
            customClient: raw,
          );
          socket.add('ping');
          expect(await socket.first, 'first:ping');
          await socket.close();
          runtime.settings = via(second);
          expect((await client.get(local)).body, 'second');
          final nextSocket = await WebSocket.connect(
            'ws://never-resolve.invalid:80/ws',
            customClient: raw,
          );
          nextSocket.add('ping');
          expect(await nextSocket.first, 'second:ping');
          await nextSocket.close();
          runtime.settings = const NetworkProxySettings();
          expect((await client.get(local)).body, 'direct');
        } finally {
          client.close();
          raw.close(force: true);
        }
      }, runtime);
      expect(
        received.any((line) => line.contains('never-resolve.invalid/stream')),
        isTrue,
      );
      expect(
        received.where((line) => line.startsWith('direct:')),
        hasLength(2),
      );
    },
  );

  test(
    'real Bot task receives WebSocket completion and downloads via the proxy',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final actions = <String>[];
      final paths = <String>[];
      proxy.listen((request) async {
        paths.add(request.uri.path);
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((raw) {
            final message = jsonDecode(raw as String) as Map;
            actions.add(message['action'] as String);
            if (message['action'] == 'subscribe_task') {
              socket.add(
                jsonEncode({
                  'action': 'task_update',
                  'status': 'completed',
                  'result': {'url': '/api/i/synthetic.png'},
                }),
              );
            }
          });
        } else {
          request.response.add([1, 2, 3]);
          await request.response.close();
        }
      });
      final runtime = NetworkProxyOverrides(
        NetworkProxySettings(
          enabled: true,
          address: 'http://127.0.0.1:${proxy.port}',
        ),
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        const base = 'http://never-resolve.invalid:80';
        final images = await streamBotTask(
          baseUrl: base,
          sessionId: 'synthetic-session',
          taskId: 'synthetic-task',
          client: BackendClient(base),
          timeout: const Duration(seconds: 3),
        );
        expect(images.single, [1, 2, 3]);
      }, runtime);
      expect(actions, ['bind_session', 'subscribe_task']);
      expect(paths, ['/ws/bot', '/api/i/synthetic.png']);
    },
  );

  test(
    'unavailable proxy fails without quietly contacting the origin',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var hits = 0;
      origin.listen((request) {
        hits++;
        request.response.close();
      });
      final unavailable = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = unavailable.port;
      await unavailable.close();
      final runtime = NetworkProxyOverrides(
        NetworkProxySettings(
          enabled: true,
          address: 'http://127.0.0.1:$port',
          bypassLocal: false,
        ),
      );
      final client = runtime.createHttpClient(null)
        ..connectionTimeout = const Duration(seconds: 2);
      addTearDown(() => client.close(force: true));
      await expectLater(
        client.getUrl(Uri.parse('http://127.0.0.1:${origin.port}/')),
        throwsA(isA<SocketException>()),
      );
      expect(hits, 0);
    },
  );

  test(
    'HTTPS probe uses CONNECT, checks certificates and sends no authorization',
    () async {
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/network_proxy/localhost-cert.pem')
        ..usePrivateKey('test/fixtures/network_proxy/localhost-key.pem');
      final secure = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => secure.close(force: true));
      final methods = <String>[];
      secure.listen((request) async {
        methods.add(request.method);
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        request.response.statusCode =
            404; // A real response, not a login/generation test.
        await request.response.close();
      }, onError: (Object _) {});
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      var connects = 0;
      final tunnels = <Socket>[];
      addTearDown(() {
        for (final socket in tunnels) {
          socket.destroy();
        }
      });
      proxy.listen((request) async {
        expect(request.method, 'CONNECT');
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        connects++;
        final upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          secure.port,
        );
        request.response.statusCode = 200;
        request.response.contentLength = 0;
        final downstream = await request.response.detachSocket();
        tunnels.addAll([upstream, downstream]);
        unawaited(
          upstream.cast<List<int>>().pipe(downstream).catchError((Object _) {}),
        );
        unawaited(
          downstream.cast<List<int>>().pipe(upstream).catchError((Object _) {}),
        );
      });
      // Even a disabled draft is explicitly tested via the typed proxy.
      final draft = NetworkProxySettings(
        address: 'http://127.0.0.1:${proxy.port}',
      );
      final target = Uri.parse('https://localhost:${secure.port}/');
      final trusted = SecurityContext()
        ..setTrustedCertificates(
          'test/fixtures/network_proxy/localhost-cert.pem',
        );
      final success = await testNetworkProxy(
        draft,
        target: target,
        securityContext: trusted,
      );
      expect(success, contains('HTTP 404'));
      expect(methods, ['HEAD']);
      expect(await testNetworkProxy(draft, target: target), contains('证书'));
      expect(connects, 2);
      expect(methods, ['HEAD']);
    },
  );

  test(
    'probe timeout closes its connection instead of leaving a background request',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      proxy.listen((_) {});
      final message = await testNetworkProxy(
        NetworkProxySettings(address: 'http://127.0.0.1:${proxy.port}'),
        target: Uri.parse('http://never-resolve.invalid/'),
        timeout: const Duration(milliseconds: 100),
      );
      expect(message, contains('超时'));
    },
  );
}
