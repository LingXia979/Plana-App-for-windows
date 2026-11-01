import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/clipboard_image.dart';
import 'network_proxy.dart';

const _channel = MethodChannel('plana/proxy_assist');

class ProxyAddressCandidate {
  const ProxyAddressCandidate(this.address, this.source);
  final String address;
  final String source;
}

/// Parse explicit addresses or labelled HTTP/Mixed ports, never arbitrary digits.
/// A screenshot can contain several ports; preserve choices instead of guessing.
List<ProxyAddressCandidate> parseProxyAddresses(String input) {
  if (input.length > 128 * 1024) {
    throw const FormatException('识别内容过长，请只截取代理端口区域');
  }
  final text = input
      // Chinese Windows OCR can return full-width dots/digits in an IPv4 address.
      .replaceAllMapped(
        RegExp(r'[！-～]'),
        (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0),
      )
      .replaceAll('。', '.')
      .replaceAllMapped(RegExp(r'(?<=\d)\s*\.\s*(?=\d)'), (_) => '.')
      .replaceAllMapped(RegExp(r'(?<=\d)\s*:\s*(?=\d)'), (_) => ':');
  final results = <String, ProxyAddressCandidate>{};
  void add(String address, String source) {
    try {
      final normalized = NetworkProxySettings.normalizeAddress(address);
      results.putIfAbsent(
        normalized,
        () => ProxyAddressCandidate(normalized, source),
      );
    } on FormatException {
      /* An OCR typo is not a valid candidate. */
    }
  }

  final lines = text.split(RegExp(r'[\r\n]+'));
  final excluded = RegExp(
    r'socks|controller|控制|订阅|subscription|dashboard|仪表盘',
    caseSensitive: false,
  );
  final full = RegExp(
    r'''\b(?:https?|socks[45]?)\s*:\s*/\s*/\s*(?:\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.\-]+)\s*:\s*\d+(?:[^\s\u3000，,；;"']*)''',
    caseSensitive: false,
  );
  final bare = RegExp(
    r'(?<![a-zA-Z0-9./@])(?:localhost|127(?:\.\d{1,3}){3}|10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|\[[0-9a-fA-F:]+\])\s*:\s*(\d+)(?![\d/])',
    caseSensitive: false,
  );
  for (final line in lines) {
    if (excluded.hasMatch(line.replaceAll(RegExp(r'\s+'), ''))) continue;
    final matches = full.allMatches(line).toList();
    for (final match in matches) {
      add(match.group(0)!.replaceAll(RegExp(r'\s+'), ''), '截图 / 文本中的地址');
    }
    // Do not reinterpret a rejected SOCKS/HTTPS/credential/subscription URL as HTTP.
    if (matches.isNotEmpty || line.contains('://') || line.contains('@')) {
      continue;
    }
    for (final match in bare.allMatches(line)) {
      add('http://${match.group(0)!.replaceAll(RegExp(r'\s+'), '')}', '主机与端口');
    }
  }
  final label = RegExp(
    r'(?:mixed[\s_-]*port|混合(?:代理)?端口|mixed|http(?:[\s_-]*proxy)?[\s_-]*(?:port|端口)|HTTP代理端口|^port)\s*[:=]?\s*(\d{1,5})(?![\d.:])',
    caseSensitive: false,
  );
  for (var i = 0; i < lines.length; i++) {
    if (excluded.hasMatch(lines[i].replaceAll(RegExp(r'\s+'), ''))) {
      continue;
    }
    // Windows OCR sometimes puts the field value on the following line.
    final next =
        i + 1 < lines.length &&
            RegExp(r'^\s*\d{1,5}\s*$').hasMatch(lines[i + 1])
        ? lines[i + 1]
        : '';
    final compact = '${lines[i]} $next'.replaceAll(RegExp(r'[ \t]+'), '');
    for (final match in label.allMatches(compact)) {
      final port = int.parse(match.group(1)!);
      if (port > 0 && port <= 65535) {
        add('http://127.0.0.1:$port', 'HTTP / Mixed 端口（本机）');
      }
    }
  }
  return results.values.toList();
}

Future<String> recognizeProxyImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
    throw const FormatException('请使用一张不超过 32 MB 的代理设置截图');
  }
  try {
    return await _channel.invokeMethod<String>('recognizeImage', {
          'image': bytes,
        }) ??
        '';
  } on MissingPluginException {
    throw const FormatException('此平台暂不支持截图识别，可以复制代理地址后粘贴');
  } on PlatformException catch (e) {
    throw FormatException(switch (e.code) {
      'image_size' => '截图过大，请只截取代理端口区域后重试',
      'busy' => '正在识别，请稍后重试',
      'ocr_unavailable' => 'Windows 文字识别暂不可用，请检查系统 OCR 语言组件；也可复制文字地址后粘贴',
      _ => '截图识别失败，请重新截图或粘贴文字地址',
    });
  }
}

final proxyImageRecognizerProvider =
    Provider<Future<String> Function(Uint8List)>((ref) => recognizeProxyImage);
final proxyClipboardReaderProvider =
    Provider<Future<ClipboardContent> Function()>(
      (ref) => DesktopClipboard.read,
    );

/// Decode only the single snapshot requested by the user; never monitor clipboard.
Future<Uint8List> proxyClipboardImage(ClipboardContent content) async {
  if (content.error != null) {
    throw const FormatException('剪贴板暂不可读，请重新复制截图后重试');
  }
  if (content.paths.length > 1 || content.images.length > 1) {
    throw const FormatException('请一次只复制一张代理设置截图');
  }
  if (content.images.isNotEmpty) return content.images.single.bytes;
  if (content.paths.isNotEmpty) {
    final file = File(content.paths.single);
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('截图不能超过 32 MB');
    }
    return file.readAsBytes();
  }
  return (await DesktopClipboard.imageFromContent(content)).bytes;
}

final detectedProxySoftwareProvider = FutureProvider.autoDispose
    .family<ProxySoftware, String>((ref, address) async {
      try {
        final uri = Uri.parse(NetworkProxySettings.normalizeAddress(address));
        final result = await _channel.invokeMethod<String>('detectSoftware', {
          'host': uri.host,
          'port': uri.port,
        });
        return switch (result) {
          'clash' => ProxySoftware.clash,
          'other' => ProxySoftware.other,
          _ => ProxySoftware.auto,
        };
      } catch (_) {
        return ProxySoftware.auto;
      }
    });

String proxySoftwareLabel(ProxySoftware kind) =>
    kind == ProxySoftware.clash ? 'Clash' : '代理软件';

String appliedProxyRoute(
  NetworkProxySettings settings, {
  required bool relay,
  ProxySoftware detected = ProxySoftware.auto,
  bool environmentProxy = false,
}) {
  if (!settings.enabled && !relay && !environmentProxy) {
    return '本机直连：Plana → NovelAI';
  }
  final software = settings.software == ProxySoftware.auto
      ? detected
      : settings.software;
  return [
    'Plana',
    if (settings.enabled)
      proxySoftwareLabel(software)
    else if (environmentProxy)
      '代理软件（环境代理）',
    if (relay) 'Cloudflare 转发',
    'NovelAI',
  ].join(' → ');
}
