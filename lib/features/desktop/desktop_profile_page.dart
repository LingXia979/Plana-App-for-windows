import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../generate/preset_manage_page.dart';
import '../migrate/web_backup_page.dart';
import '../profile/about_page.dart';
import '../profile/account_page.dart';
import '../profile/appearance_page.dart';
import '../profile/gen_settings_page.dart';
import '../profile/storage_page.dart';
import '../stats/stats_page.dart';
import '../shell/shell_state.dart';
import '../tools/tools_page.dart';

enum _Section {
  account('账号与接入', Icons.manage_accounts_outlined, '账户与服务', AccountPage()),
  dataImport('数据导入', Icons.import_export, '账户与服务', WebBackupPage()),
  generation('生成设置', Icons.tune, '创作偏好', GenSettingsPage()),
  presets('提示词预设', Icons.bookmark_outline, '创作偏好', PromptPresetManagePage()),
  appearance('外观与体验', Icons.color_lens_outlined, '应用', AppearancePage()),
  storage('存储管理', Icons.storage_outlined, '应用', StoragePage()),
  tools('工具箱', Icons.handyman_outlined, '应用', ToolsPage()),
  stats('统计', Icons.query_stats, '应用', StatsPage()),
  about('关于 Plana', Icons.info_outline, '应用', AboutPage());

  const _Section(this.label, this.icon, this.group, this.page);
  final String label;
  final IconData icon;
  final String group;
  final Widget page;
}

/// Keep settings navigation inside the content pane. Lazily retain each visited
/// section, including its subpages and drafts, when switching sidebar entries.
class DesktopProfilePage extends ConsumerStatefulWidget {
  const DesktopProfilePage({super.key});

  @override
  ConsumerState<DesktopProfilePage> createState() => _DesktopProfilePageState();
}

class _DesktopProfilePageState extends ConsumerState<DesktopProfilePage>
    with AutomaticKeepAliveClientMixin {
  _Section _selected = _Section.account;
  final _visited = {_Section.account};
  final _navigators = {
    for (final section in _Section.values) section: GlobalKey<NavigatorState>(),
  };

  @override
  bool get wantKeepAlive => true;

  void _select(_Section section) {
    if (_selected == section) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selected = section;
      _visited.add(section);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final active = ref.watch(shellIndexProvider) == kTabProfile;
    return LayoutBuilder(
      builder: (context, constraints) {
        final sidebar = constraints.maxWidth >= 700;
        final scheme = context.scheme;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            sidebar ? 20 : 12,
            16,
            sidebar ? 20 : 12,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '我的',
                      style: context.texts.headlineSmall!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (!sidebar)
                    PopupMenuButton<_Section>(
                      key: const ValueKey('profile-section-menu'),
                      tooltip: '设置分类',
                      initialValue: _selected,
                      onSelected: _select,
                      itemBuilder: (context) => [
                        for (final section in _Section.values)
                          CheckedPopupMenuItem(
                            value: section,
                            checked: section == _selected,
                            child: Text(section.label),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_selected.label),
                            const SizedBox(width: 8),
                            const Icon(Icons.expand_more, size: 18),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '账户、创作偏好与应用设置',
                style: context.texts.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (sidebar) ...[
                      SizedBox(
                        key: const ValueKey('profile-sidebar'),
                        width: constraints.maxWidth >= 1100 ? 208 : 184,
                        child: Material(
                          color: scheme.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: .4,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                            children: [
                              for (final group in const [
                                '账户与服务',
                                '创作偏好',
                                '应用',
                              ]) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    18,
                                    12,
                                    8,
                                  ),
                                  child: Text(
                                    group,
                                    style: context.texts.labelSmall!.copyWith(
                                      color: scheme.outline,
                                    ),
                                  ),
                                ),
                                for (final section in _Section.values.where(
                                  (s) => s.group == group,
                                ))
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: ListTile(
                                      key: ValueKey(
                                        'profile-section-${section.name}',
                                      ),
                                      dense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                      minLeadingWidth: 20,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      selected: _selected == section,
                                      selectedTileColor: scheme.primaryContainer
                                          .withValues(alpha: .65),
                                      selectedColor: scheme.primary,
                                      leading: Icon(section.icon, size: 20),
                                      title: Text(
                                        section.label,
                                        style: TextStyle(
                                          fontWeight: _selected == section
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                        ),
                                      ),
                                      onTap: () => _select(section),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                    ],
                    Expanded(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1000),
                          child: IndexedStack(
                            key: const ValueKey('profile-content'),
                            index: _selected.index,
                            sizing: StackFit.expand,
                            children: [
                              for (final section in _Section.values)
                                _visited.contains(section)
                                    ? TickerMode(
                                        enabled: _selected == section,
                                        child: ExcludeFocus(
                                          excluding: _selected != section,
                                          child: NavigatorPopHandler<Object?>(
                                            enabled:
                                                active && _selected == section,
                                            onPopWithResult: (result) {
                                              final navigator =
                                                  _navigators[section]!
                                                      .currentState!;
                                              if (active &&
                                                  _selected == section &&
                                                  navigator.canPop()) {
                                                navigator.pop(result);
                                              }
                                            },
                                            child: Navigator(
                                              key: _navigators[section],
                                              onGenerateRoute: (_) =>
                                                  MaterialPageRoute<void>(
                                                    builder: (_) =>
                                                        section.page,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
