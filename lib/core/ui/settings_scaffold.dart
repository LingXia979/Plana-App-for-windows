import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/desktop.dart';

/// Settings titles are part of the content scroll on desktop. Mobile keeps its
/// normal navigation bar. Put SettingsPageHeader at the start of the scroll.
class SettingsScaffold extends ConsumerWidget {
  const SettingsScaffold({super.key, required this.appBar, required this.body});

  final AppBar appBar;
  final Widget body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = ref.watch(desktopModeProvider);
    return Scaffold(
      appBar: desktop ? null : appBar,
      body: _SettingsHeading(bar: desktop ? appBar : null, child: body),
    );
  }
}

class _SettingsHeading extends InheritedWidget {
  const _SettingsHeading({required this.bar, required super.child});
  final AppBar? bar;

  @override
  bool updateShouldNotify(_SettingsHeading oldWidget) => bar != oldWidget.bar;
}

class SettingsPageHeader extends StatelessWidget {
  const SettingsPageHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final bar = context
        .dependOnInheritedWidgetOfExactType<_SettingsHeading>()
        ?.bar;
    if (bar == null) return const SizedBox.shrink();
    final back = bar.automaticallyImplyLeading && Navigator.canPop(context);
    return Padding(
      key: const ValueKey('settings-scrolling-heading'),
      padding: const EdgeInsets.only(top: 6, bottom: 18),
      child: Row(
        children: [
          if (bar.leading != null)
            bar.leading!
          else if (back)
            const BackButton(),
          Expanded(
            child: DefaultTextStyle(
              style: Theme.of(context).textTheme.headlineSmall!,
              child: bar.title ?? const SizedBox.shrink(),
            ),
          ),
          ...?bar.actions,
        ],
      ),
    );
  }
}
