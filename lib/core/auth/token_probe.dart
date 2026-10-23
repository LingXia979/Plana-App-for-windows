import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/nai_client.dart';

/// NAI 令牌在线校验:输入防抖 → 查订阅 → 暴露(档位 + 点数 / 查询中 / 失败 / 令牌被拒)。
/// 引导页与「账号与接入」共用一套判定,避免两处规则漂移。
///
/// 只读订阅接口,不写任何存储,也不动全局 anlasProvider(那个跟接入方式走)。
class TokenProbe extends ChangeNotifier {
  TokenProbe(this._fetch);

  final Future<NaiSubscription> Function(String token) _fetch;

  NaiSubscription? sub;
  bool loading = false;
  bool failed = false;

  /// [failed] 的原因是令牌被拒(见 [naiTokenRejected]),不是没查通。
  bool rejected = false;

  Timer? _debounce;

  /// 最近一次发起查询的令牌;当前输入,用于丢弃过期响应。
  String _queried = '';
  String _current = '';

  /// 令牌形态判定:NAI 持久令牌(`pst-` 开头)或网页会话 JWT
  /// (`头.载荷.签名` 三段式,浏览器 F12 里抓的那种,同样是 Bearer 直用)。
  /// 不成形就不查(省得每敲一个字符打一次网络)。
  static bool looksLikeToken(String t) {
    if (t.startsWith('pst-')) return t.length >= 30;
    final parts = t.split('.');
    return parts.length == 3 &&
        parts.every((p) => p.isNotEmpty) &&
        !t.contains(' ');
  }

  /// 输入变化入口(TextField listener 里调)。
  void input(String raw) {
    final t = raw.trim();
    _current = t;
    _debounce?.cancel();
    if (!looksLikeToken(t)) {
      _queried = '';
      if (sub != null || failed || loading) {
        sub = null;
        failed = false;
        rejected = false;
        loading = false;
        notifyListeners();
      }
      return;
    }
    if (t == _queried && (sub != null || loading)) return;
    _debounce = Timer(const Duration(milliseconds: 600), () => run(t));
  }

  /// 立即查(失败后点按重试)。
  Future<void> run(String token) async {
    final t = token.trim();
    if (!looksLikeToken(t)) return;
    _queried = t;
    loading = true;
    failed = false;
    rejected = false;
    notifyListeners();
    try {
      final s = await _fetch(t);
      if (_current != t) return; // 输入已变,结果作废
      sub = s;
      loading = false;
    } catch (e) {
      if (_current != t) return;
      sub = null;
      failed = true;
      rejected = naiTokenRejected(e);
      loading = false;
    }
    notifyListeners();
  }

  /// 清空(清除令牌时调)。
  void reset() {
    _debounce?.cancel();
    _queried = '';
    _current = '';
    sub = null;
    loading = false;
    failed = false;
    rejected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
