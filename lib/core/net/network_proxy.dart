import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/app_stores.dart';

const kNetworkProxyKey = 'network_proxy';
const kDefaultNetworkProxyAddress = 'http://127.0.0.1:7890';

enum ProxySoftware { auto, clash, other }

/// Transport settings are independent of NAI endpoint selection and credentials.
class NetworkProxySettings {
  const NetworkProxySettings({
    this.enabled = false,
    this.address = kDefaultNetworkProxyAddress,
    this.bypassLocal = true,
    this.software = ProxySoftware.auto,
  });

  final bool enabled;
  final String address;
  final bool bypassLocal;
  final ProxySoftware software;

  static String normalizeAddress(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'http') {
      throw const FormatException(
        '请填写 http://主机:端口，使用 Clash 的 HTTP / Mixed 端口',
      );
    }
    // Explicit port prevents a pasted dashboard/subscription URL silently using 80.
    final explicitPort = RegExp(r':(\d+)/?$').firstMatch(value);
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        explicitPort == null ||
        uri.port < 1 ||
        uri.port > 65535 ||
        !RegExp(r'^[a-zA-Z0-9.\-\[\]:]+$').hasMatch(uri.host)) {
      throw const FormatException('地址需包含主机和 1–65535 的端口，不含路径、账号或密码');
    }
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    return 'http://$host:${uri.port}';
  }

  NetworkProxySettings validated() => NetworkProxySettings(
    enabled: enabled,
    address: normalizeAddress(address),
    bypassLocal: bypassLocal,
    software: software,
  );

  static NetworkProxySettings decode(String? raw) {
    if (raw == null) return const NetworkProxySettings();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return NetworkProxySettings(
        enabled: json['enabled'] == true,
        address: json['address'] as String,
        bypassLocal: json['bypassLocal'] != false,
        software:
            ProxySoftware.values
                .where((v) => v.name == json['software'])
                .firstOrNull ??
            ProxySoftware.auto,
      ).validated();
    } catch (_) {
      return const NetworkProxySettings();
    }
  }

  String encode() => jsonEncode({
    'enabled': enabled,
    'address': address,
    'bypassLocal': bypassLocal,
    'software': software.name,
  });

  String get directive {
    return 'PROXY ${normalizeAddress(address).substring(7)}';
  }

  String findProxy(Uri uri) {
    // Preserve the SDK's existing environment-proxy behavior when switched off.
    if (!enabled) return HttpClient.findProxyFromEnvironment(uri);
    if (bypassLocal && isLocalProxyDestination(uri.host)) return 'DIRECT';
    // Never silently bypass a selected proxy on connection failure.
    return directive;
  }
}

bool isLocalProxyDestination(String host) {
  var name = host.toLowerCase();
  if (name.startsWith('[') && name.endsWith(']')) {
    name = name.substring(1, name.length - 1);
  }
  if (name.endsWith('.')) name = name.substring(0, name.length - 1);
  if (name == 'localhost' ||
      name.endsWith('.localhost') ||
      name.endsWith('.local')) {
    return true;
  }
  final ip = InternetAddress.tryParse(name);
  if (ip == null) return false; // No blocking DNS or broad hostname bypass.
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final bytes = ip.rawAddress;
  if (bytes.length == 16) {
    if ((bytes[0] & 0xfe) == 0xfc) return true; // IPv6 unique-local.
    // IPv4-mapped IPv6 addresses follow the IPv4 rule too.
    if (bytes.take(10).every((n) => n == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return isLocalProxyDestination(bytes.skip(12).join('.'));
    }
    return false;
  }
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168);
}

/// Installed before runApp: package:http, raw HTTP/SSE, images and WebSockets
/// all use this factory. Existing clients read the current route per new request;
/// in-flight requests/connections are not cancelled when settings change.
class NetworkProxyOverrides extends HttpOverrides {
  NetworkProxyOverrides(this.settings);
  NetworkProxySettings settings;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (uri) => settings.findProxy(uri);
}

final networkProxyRuntimeProvider = Provider<NetworkProxyOverrides>((ref) {
  String? raw;
  try {
    raw = ref.read(prefsStoreProvider).get(kNetworkProxyKey);
  } catch (_) {
    // Standalone widget tests may not install AppStores.
    raw = null;
  }
  return NetworkProxyOverrides(NetworkProxySettings.decode(raw));
});

final networkProxyProvider =
    NotifierProvider<NetworkProxyNotifier, NetworkProxySettings>(
      NetworkProxyNotifier.new,
    );

class NetworkProxyNotifier extends Notifier<NetworkProxySettings> {
  @override
  NetworkProxySettings build() =>
      ref.read(networkProxyRuntimeProvider).settings;

  Future<void> save(NetworkProxySettings next) async {
    next = next.validated();
    ref.read(networkProxyRuntimeProvider).settings = next;
    state = next;
    final prefs = ref.read(prefsStoreProvider);
    await prefs.write(key: kNetworkProxyKey, value: next.encode());
    // PrefsStore retains failed writes for retry; don't report them as saved.
    await prefs.idle;
  }
}

typedef ProxyProbe = Future<String> Function(NetworkProxySettings settings);
final networkProxyProbeProvider = Provider<ProxyProbe>(
  (ref) => testNetworkProxy,
);

/// Probe the typed proxy, without changing saved settings or sending credentials.
/// A real HTTPS response proves CONNECT + TLS, not merely an open local TCP port.
Future<String> testNetworkProxy(
  NetworkProxySettings settings, {
  Uri? target,
  Duration timeout = const Duration(seconds: 10),
  SecurityContext? securityContext,
}) async {
  final validated = settings.validated();
  final client =
      NetworkProxyOverrides(validated).createHttpClient(securityContext)
        ..findProxy = ((_) => validated.directive)
        ..connectionTimeout = timeout;
  try {
    return await (() async {
      final request = await client.headUrl(
        target ?? Uri.parse('https://image.novelai.net/'),
      );
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode == 407) {
        return '代理要求身份验证；请使用无需账号密码的本机 HTTP / Mixed 端口。';
      }
      return '已通过代理收到目标响应（HTTP ${response.statusCode}）。这不代表账号或生成可用。';
    })().timeout(timeout);
  } on TimeoutException {
    return '连接超时，请检查 Clash 是否运行、端口及节点是否可用。';
  } on SocketException {
    return '无法连接，请检查 Clash 是否运行、HTTP / Mixed 地址与端口是否正确。';
  } on HandshakeException {
    return '安全连接失败，请检查节点和证书；未跳过证书验证。';
  } on HttpException {
    return '代理未能建立连接，请检查 HTTP / Mixed 端口、节点及代理认证设置。';
  } finally {
    client.close(force: true);
  }
}
