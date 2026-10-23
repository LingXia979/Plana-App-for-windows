import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 桌面引导的外框。内容保活，步骤导航只允许返回或按顺序继续。
class DesktopWelcomeLayout extends StatelessWidget {
  const DesktopWelcomeLayout({
    super.key,
    required this.index,
    required this.pages,
    required this.onStepSelected,
    required this.onNext,
    required this.nextLabel,
    this.onBack,
    this.onSkip,
    this.onClose,
    this.hint,
  });

  final int index;
  final List<Widget> pages;
  final ValueChanged<int> onStepSelected;
  final VoidCallback? onNext;
  final String nextLabel;
  final VoidCallback? onBack;
  final VoidCallback? onSkip;
  final VoidCallback? onClose;
  final String? hint;

  static const _steps = [
    ('欢迎', '熟悉桌面工作台'),
    ('外观', '主题与配色'),
    ('接入方式', '官方或第三方接口'),
    ('扩展功能', '按需授权 Bot'),
    ('完成', '确认设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 引导也会打开在「我的」右侧面板内，以实际可用宽度判断布局。
        final wide = constraints.maxWidth >= 760;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '使用引导',
                          style: context.texts.titleMedium!.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '第 ${index + 1} 步，共 ${pages.length} 步 · ${_steps[index].$1}',
                          key: const ValueKey('desktop-welcome-progress'),
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onClose != null)
                    TextButton.icon(
                      key: const ValueKey('desktop-welcome-close'),
                      onPressed: onClose,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('返回'),
                    ),
                ],
              ),
            ),
            if (!wide)
              LinearProgressIndicator(
                value: (index + 1) / pages.length,
                minHeight: 3,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide)
                    SizedBox(
                      key: const ValueKey('desktop-welcome-navigation'),
                      width: 196,
                      child: Material(
                        color: scheme.surfaceContainerLow,
                        shape: Border(
                          right: BorderSide(
                            color: scheme.outlineVariant.withValues(alpha: .5),
                          ),
                        ),
                        child: ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            for (var i = 0; i < _steps.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: ListTile(
                                  key: ValueKey('desktop-welcome-step-$i'),
                                  selected: i == index,
                                  enabled:
                                      i <= index ||
                                      (i == index + 1 && onNext != null),
                                  onTap: () => onStepSelected(i),
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  minLeadingWidth: 24,
                                  horizontalTitleGap: 10,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  selectedTileColor: scheme.primaryContainer,
                                  leading: i < index
                                      ? Icon(
                                          Icons.check_circle_outline,
                                          size: 24,
                                          color: scheme.primary,
                                        )
                                      : CircleAvatar(
                                          radius: 12,
                                          backgroundColor: i == index
                                              ? scheme.primary
                                              : scheme.surfaceContainerHighest,
                                          foregroundColor: i == index
                                              ? scheme.onPrimary
                                              : scheme.onSurfaceVariant,
                                          child: Text(
                                            '${i + 1}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                  title: Text(_steps[i].$1),
                                  subtitle: Text(_steps[i].$2),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    key: const ValueKey('desktop-welcome-content'),
                    child: IndexedStack(
                      index: index,
                      sizing: StackFit.expand,
                      children: [
                        for (var i = 0; i < pages.length; i++)
                          TickerMode(
                            enabled: i == index,
                            child: ExcludeFocus(
                              excluding: i != index,
                              child: pages[i],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              key: const ValueKey('desktop-welcome-footer'),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              padding: const EdgeInsets.all(16),
              child: constraints.maxWidth >= 620
                  ? Row(
                      children: [
                        Expanded(
                          child: _hint(context, hint ?? '之后可在「我的」中修改这些设置。'),
                        ),
                        const SizedBox(width: 16),
                        _actions(),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hint != null) ...[
                          _hint(context, hint!),
                          const SizedBox(height: 8),
                        ],
                        _actions(),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _hint(BuildContext context, String text) => Text(
    text,
    style: context.texts.bodySmall!.copyWith(
      color: context.scheme.onSurfaceVariant,
    ),
  );

  Widget _actions() => Wrap(
    alignment: WrapAlignment.end,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      TextButton.icon(
        key: const ValueKey('desktop-welcome-back'),
        onPressed: onBack,
        icon: const Icon(Icons.chevron_left, size: 18),
        label: const Text('上一步'),
      ),
      if (onSkip != null)
        TextButton(
          key: const ValueKey('desktop-welcome-skip'),
          onPressed: onSkip,
          child: const Text('暂时跳过'),
        ),
      FilledButton.icon(
        key: const ValueKey('desktop-welcome-next'),
        onPressed: onNext,
        icon: Icon(
          index == pages.length - 1 ? Icons.check : Icons.chevron_right,
          size: 18,
        ),
        iconAlignment: IconAlignment.end,
        label: Text(nextLabel),
      ),
    ],
  );
}
