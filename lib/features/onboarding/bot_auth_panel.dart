import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/net/backend_client.dart';
import '../../core/net/backend_config.dart';
import '../../core/theme/app_theme.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../../core/util/haptics.dart';

class _AuthorizationSaveFailure implements Exception {
  const _AuthorizationSaveFailure();
}

/// Bot 绑定码授权面板(无 Scaffold,可内嵌):
/// 取 6 位码 → 用户在 QQ 发给 Bot → 本面板轮询 → 存会话并置接入方式。
///
/// 授权页与首启欢迎流程共用,避免两处各写一份轮询。
class BotAuthPanel extends ConsumerStatefulWidget {
  const BotAuthPanel({super.key, this.onAuthorized, this.compact = false});

  /// 授权成功后的收尾(授权页用来 pop;欢迎页原地留着)。
  final VoidCallback? onAuthorized;

  /// 内嵌模式:后端地址收进折叠项,文案更短。
  final bool compact;

  @override
  ConsumerState<BotAuthPanel> createState() => _BotAuthPanelState();
}

class _BotAuthPanelState extends ConsumerState<BotAuthPanel> {
  final _urlCtrl = TextEditingController();
  bool _seeded = false;

  Timer? _timer;
  String? _code;
  int _secondsLeft = 0;
  int _tick = 0;
  bool _loading = false;
  int _attempt = 0;
  int? _pollingAttempt;
  bool get _polling => _pollingAttempt == _attempt;
  bool _savingAuthorization = false;
  int _pollFailures = 0;
  String? _pollError;

  bool _isCurrent(int attempt) =>
      mounted && _attempt == attempt && _code != null;

  @override
  void dispose() {
    _attempt++;
    _timer?.cancel();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _getCode() async {
    // 内嵌模式不露地址栏,直接用已存/内置默认后端;自建的去「账号与接入」改
    final url = widget.compact
        ? (ref.read(backendBaseProvider).value ?? '')
        : _urlCtrl.text.trim();
    if (url.isEmpty) {
      hintSnack(context, '请先填写后端地址', icon: Icons.error_outline);
      return;
    }
    FocusScope.of(context).unfocus();
    final attempt = ++_attempt;
    setState(() => _loading = true);
    try {
      if (!widget.compact) {
        await ref.read(backendBaseProvider.notifier).save(url);
        if (!mounted || attempt != _attempt) return;
        if (ref.read(backendBaseProvider).hasError) {
          throw const _AuthorizationSaveFailure();
        }
      }
      final r = await ref.read(backendClientProvider).authGenerate();
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _code = r.code;
        _secondsLeft = r.expiresIn;
        _tick = 0;
        _loading = false;
        _pollFailures = 0;
        _pollError = null;
      });
      _startTimer();
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() => _loading = false);
      hintSnack(
        context,
        error is BackendException ? error.message : '获取授权码失败，请检查网络或安全存储后重试',
        icon: Icons.error_outline,
      );
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) return;
      _tick++;
      setState(() => _secondsLeft = (_secondsLeft - 1).clamp(0, 999));
      // Once credentials start being written, finish that commit before allowing
      // cancellation or expiry to replace this attempt.
      if (_secondsLeft <= 0 && !_savingAuthorization) {
        t.cancel();
        setState(() {
          _attempt++;
          _code = null;
          _pollError = null;
          _pollFailures = 0;
        }); // 过期 → 回到「获取授权码」
        return;
      }
      if (_tick % 3 == 0) await _poll(); // 每 3 秒轮询一次
    });
  }

  Future<void> _poll() async {
    final code = _code;
    final attempt = _attempt;
    if (code == null || _polling || _savingAuthorization) return;
    setState(() => _pollingAttempt = attempt);
    try {
      final r = await ref.read(backendClientProvider).authCheck(code);
      if (!_isCurrent(attempt)) return;
      if (_pollFailures > 0) {
        setState(() {
          _pollFailures = 0;
          _pollError = null;
        });
      }
      if (r.verified && r.sessionId != null && r.sessionId!.isNotEmpty) {
        await _onAuthorized(r.sessionId!, attempt);
      }
    } catch (error) {
      if (!_isCurrent(attempt)) return;
      _pollFailures++;
      if (_pollFailures >= 2 || error is _AuthorizationSaveFailure) {
        setState(() {
          _pollError = error is _AuthorizationSaveFailure
              ? '授权信息保存失败，请检查安全存储后重试'
              : error is BackendException
              ? '验证暂时失败：${error.message}'
              : '验证暂时失败，请检查网络';
        });
      }
    } finally {
      if (mounted && _attempt == attempt) {
        setState(() => _pollingAttempt = null);
      }
    }
  }

  Future<void> _onAuthorized(String sessionId, int attempt) async {
    // 拿归属/过期(best-effort),存会话,切模式
    int? expiresAtMs;
    String? botUserId;
    try {
      final v = await ref.read(backendClientProvider).validate(sessionId);
      if (v.valid) {
        expiresAtMs = v.expiresAtMs;
        botUserId = v.botUserId;
      }
    } catch (_) {}
    if (!_isCurrent(attempt)) return;
    setState(() => _savingAuthorization = true);
    try {
      await ref
          .read(botSessionProvider.notifier)
          .save(
            BotSession(
              sessionId: sessionId,
              botUserId: botUserId,
              expiresAtMs: expiresAtMs,
            ),
          );
      if (!_isCurrent(attempt)) return;
      // These existing stores report write errors through AsyncValue.
      if (ref.read(botSessionProvider).hasError) {
        throw const _AuthorizationSaveFailure();
      }
      await ref.read(authModeProvider.notifier).set(AuthMode.bot);
      if (!mounted || !_isCurrent(attempt)) return;
      if (ref.read(authModeProvider).hasError) {
        throw const _AuthorizationSaveFailure();
      }
      _timer?.cancel();
      setState(() => _code = null);
      Haptics.medium();
      hintSnack(context, 'Bot 授权成功', icon: Icons.verified_outlined);
      widget.onAuthorized?.call();
    } finally {
      if (mounted) setState(() => _savingAuthorization = false);
    }
  }

  String _fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final baseAsync = ref.watch(backendBaseProvider);
    if (!_seeded && baseAsync.hasValue) {
      _urlCtrl.text = baseAsync.value ?? '';
      _seeded = true;
    }
    final hasCode = _code != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 内嵌模式不露后端地址(走已存/内置默认),只留一句流程说明
        if (widget.compact && !hasCode) ...[
          Text(
            '获取授权码后,复制指令发送给 Bot 即可完成授权',
            style: context.texts.labelSmall!.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 12),
        ],
        if (!widget.compact) ...[
          Text(
            '后端地址',
            style: context.texts.labelLarge!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            enabled: !hasCode,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: mono(context, size: 13),
            decoration: InputDecoration(
              filled: true,
              fillColor: scheme.surfaceContainerHigh,
              hintText: 'http://192.168.x.x:8765',
              hintStyle: TextStyle(color: scheme.outline),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (!hasCode)
          FilledButton(
            onPressed: _loading ? null : _getCode,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(23),
              ),
            ),
            child: _loading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onPrimary,
                    ),
                  )
                : const Text(
                    '获取授权码',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
          )
        else
          _CodePanel(
            code: _code!,
            secondsLeftText: _fmt(_secondsLeft),
            pollError: _pollError,
            polling: _polling,
            saving: _savingAuthorization,
            onRetry: _poll,
            onCopy: () {
              // 复制完整指令(含 web授权 前缀),粘贴到 QQ 直接发送即可
              Clipboard.setData(ClipboardData(text: 'web授权${_code!}'));
              hintSnack(
                context,
                '已复制,粘贴发给 Bot',
                icon: Icons.check_circle_outline,
              );
            },
            onCancel: _savingAuthorization
                ? null
                : () {
                    _timer?.cancel();
                    setState(() {
                      _attempt++;
                      _code = null;
                      _pollError = null;
                      _pollFailures = 0;
                    });
                  },
          ),
      ],
    );
  }
}

/// 授权码面板:大号码 + 倒计时 + 复制 + 等待指示。
class _CodePanel extends StatelessWidget {
  const _CodePanel({
    required this.code,
    required this.secondsLeftText,
    required this.pollError,
    required this.polling,
    required this.saving,
    required this.onRetry,
    required this.onCopy,
    required this.onCancel,
  });

  final String code;
  final String secondsLeftText;
  final String? pollError;
  final bool polling;
  final bool saving;
  final VoidCallback onRetry;
  final VoidCallback onCopy;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              children: [
                Text(
                  '复制指令发送给 Bot',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: .8),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  code,
                  style: mono(
                    context,
                    size: 34,
                    weight: FontWeight.w800,
                    color: scheme.onPrimaryContainer,
                  ).copyWith(letterSpacing: 6),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      size: 15,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      secondsLeftText,
                      style: context.texts.labelLarge!.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 14),
                    TextButton.icon(
                      onPressed: onCopy,
                      icon: const Icon(Icons.content_copy, size: 15),
                      label: const Text('复制指令'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (pollError == null)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              )
            else
              Icon(Icons.wifi_off_outlined, size: 16, color: scheme.error),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                saving ? '正在保存授权信息…' : (pollError ?? '等待 Bot 验证…'),
                style: context.texts.bodySmall!.copyWith(
                  color: pollError == null
                      ? scheme.onSurfaceVariant
                      : scheme.error,
                ),
              ),
            ),
            if (pollError == null) ...[
              const SizedBox(width: 8),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ],
          ],
        ),
        if (pollError != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: polling ? null : onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ],
          ),
      ],
    );
  }
}
