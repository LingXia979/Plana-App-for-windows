import 'package:flutter/material.dart';

import '../tools/tools_page.dart';

/// One retained tool navigator can move between the main navigation and settings.
/// Its key belongs to AppShell so drafts, images and detail routes move together.
class DesktopToolsPage extends StatefulWidget {
  const DesktopToolsPage({super.key, required this.active});

  final bool active;

  @override
  State<DesktopToolsPage> createState() => _DesktopToolsPageState();
}

class _DesktopToolsPageState extends State<DesktopToolsPage>
    with AutomaticKeepAliveClientMixin {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(
        excluding: !widget.active,
        child: NavigatorPopHandler<Object?>(
          enabled: widget.active,
          onPopWithResult: (result) {
            final navigator = _navigator.currentState;
            if (widget.active && navigator != null && navigator.canPop()) {
              navigator.pop(result);
            }
          },
          child: Navigator(
            key: _navigator,
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => const ToolsPage()),
          ),
        ),
      ),
    );
  }
}
