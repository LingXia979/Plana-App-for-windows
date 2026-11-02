import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_info.dart';
import '../../core/theme/app_theme.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../profile/widgets/settings_ui.dart';
import 'update_service.dart';

/// 「检查更新」行。放在关于页,按设置行规范:单行 + 右侧状态,不写副标题。
class UpdateRow extends ConsumerStatefulWidget {
  const UpdateRow({super.key});

  @override
  ConsumerState<UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends ConsumerState<UpdateRow> {
  bool _checking = false;
  UpdateCheck? _result;
  bool _failed = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _failed = false;
      _result = null;
    });
    try {
      final installed = await installedInfo();
      final release = installed.isKnown
          ? await fetchLatestRelease(installed.versionName)
          : null;
      if (!mounted) return;
      final check = UpdateCheck(installed: installed, release: release);
      setState(() => _result = check);
      if (check.hasUpdate) {
        await showUpdateSheet(context, check);
      } else if (kGithubRepo.isEmpty || !installed.isKnown) {
        // 没填仓库 / 拿不到本机版本 —— 不是错误,别报红
        hintSnack(context, '暂无更新信息', icon: Icons.info_outline);
      } else {
        hintSnack(context, '已是最新版本', icon: Icons.check_circle_outline);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _failed = true);
      hintSnack(context, '$e', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final r = _result;
    final (String value, Color? color) = switch (null) {
      _ when _checking => ('检查中…', null),
      _ when _failed => ('检查失败', scheme.error),
      _ when r != null && r.hasUpdate => (
        '新版本 ${r.release!.display}',
        scheme.tertiary,
      ),
      _ when r != null && (!r.installed.isKnown || kGithubRepo.isEmpty) => (
        '暂无更新信息',
        null,
      ),
      _ when r != null => ('已是最新', null),
      _ => ('', null),
    };
    return SettingsRow(
      icon: Icons.system_update_alt,
      title: '检查更新',
      value: value,
      valueColor: color,
      onTap: _check,
    );
  }
}

/// 新版本提示。只提示 + 跳转,**不下载不安装** —— 那两步交给浏览器和系统。
Future<void> showUpdateSheet(BuildContext context, UpdateCheck check) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _UpdateSheet(release: check.release!, installed: check.installed),
  );
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.release, required this.installed});

  final GithubRelease release;
  final InstalledInfo installed;

  Future<void> _open(BuildContext context) async {
    final ok = await launchUrl(
      Uri.parse(release.url),
      mode: LaunchMode.externalApplication,
    );
    if (!context.mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      hintSnack(context, '打不开浏览器', icon: Icons.link_off);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.system_update_alt,
                    size: 26,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '新版本 ${release.display}',
                          style: context.texts.titleMedium!.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '当前 ${installed.versionName}',
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (release.notes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  // 更新说明是 GitHub 上的 Markdown 原文,长度不可控 —— 限高可滚,
                  // 不能让它把按钮顶出屏幕
                  constraints: const BoxConstraints(maxHeight: 260),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      release.notes,
                      style: context.texts.bodySmall!.copyWith(height: 1.55),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('以后再说'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: () => _open(context),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('去 GitHub 下载'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
