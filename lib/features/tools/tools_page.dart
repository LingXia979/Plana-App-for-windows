import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/ui_prefs.dart';
import '../../core/platform/desktop.dart';
import '../../core/ui/settings_scaffold.dart';
import 'metadata_tool_page.dart';
import 'weight_convert_page.dart';

/// 工具箱(对齐 web):权重转换 / 图片元数据 两个页签,
/// IndexedStack 保活,切页签不丢已输入内容与已选图。
class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key});

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  late int _tab = ref.read(uiPrefsProvider).toolsTab.clamp(0, 1);
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = ref.watch(desktopModeProvider);
    final tabs = Padding(
      padding: desktop
          ? const EdgeInsets.only(bottom: 20)
          : const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: SizedBox(
        width: desktop ? null : double.infinity,
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              label: Text('权重转换'),
              icon: Icon(Icons.swap_horiz, size: 17),
            ),
            ButtonSegment(
              value: 1,
              label: Text('图片元数据'),
              icon: Icon(Icons.document_scanner_outlined, size: 17),
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (s) {
            FocusManager.instance.primaryFocus?.unfocus();
            ref
                .read(uiPrefsProvider.notifier)
                .patch((p) => p.copyWith(toolsTab: s.first));
            setState(() => _tab = s.first);
          },
          showSelectedIcon: false,
        ),
      ),
    );
    const views = [WeightConvertView(), MetadataToolView()];
    return SettingsScaffold(
      appBar: AppBar(title: const Text('工具箱')),
      body: desktop
          ? Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                key: const PageStorageKey('desktop-tools-scroll'),
                controller: _scroll,
                padding: const EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1440),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SettingsPageHeader(),
                        Align(alignment: Alignment.centerLeft, child: tabs),
                        for (var i = 0; i < views.length; i++)
                          Offstage(
                            offstage: _tab != i,
                            child: TickerMode(
                              enabled: _tab == i,
                              child: ExcludeFocus(
                                excluding: _tab != i,
                                child: views[i],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : Column(
              children: [
                tabs,
                Expanded(
                  child: IndexedStack(index: _tab, children: views),
                ),
              ],
            ),
    );
  }
}
