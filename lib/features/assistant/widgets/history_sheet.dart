/// 历史会话。标题取第一句用户输入,副行取最后一句 AI 回复,右下角只放一个数字:
/// 这段对话最终攒出多少 tag —— 那是用户回头找它的真正理由。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/desktop.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/desktop_popover.dart';
import '../../generate/widgets/common.dart' show confirmDialog, dropFocusSoon;
import '../assistant_models.dart';
import '../assistant_state.dart';

Future<void> showHistorySheet(BuildContext context) async {
  if (ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopModeProvider)) {
    await showDesktopPopover(
      context,
      width: 380,
      maxHeight: 460,
      builder: (_) => const AssistantHistoryPanel(),
    );
    return;
  }
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _HistorySheet(),
  );
  dropFocusSoon();
}

/// Shared by the desktop history popover and the main assistant's left rail.
class AssistantHistoryPanel extends ConsumerStatefulWidget {
  const AssistantHistoryPanel({
    super.key,
    this.sidebar = false,
    this.onNewChat,
  });
  final bool sidebar;
  final VoidCallback? onNewChat;

  @override
  ConsumerState<AssistantHistoryPanel> createState() =>
      _AssistantHistoryPanelState();
}

class _AssistantHistoryPanelState extends ConsumerState<AssistantHistoryPanel> {
  String _query = '';

  Future<void> _clear(int count) async {
    final ok = await confirmDialog(
      context,
      title: '清空历史会话?',
      message: '$count 段对话都会删掉,当前对话和创作页不受影响。',
      confirmLabel: '清空',
    );
    if (ok && mounted) ref.read(assistantProvider.notifier).clearSessions();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final state = ref.watch(assistantProvider);
    final notifier = ref.read(assistantProvider.notifier);
    final query = _query.trim().toLowerCase();
    bool matches(ArchivedSession s) =>
        query.isEmpty ||
        '${s.title}\n${s.preview}'.toLowerCase().contains(query);
    final sessions = state.sessions.where(matches).toList();
    final current = ArchivedSession(
      id: 0,
      msgs: state.msgs,
      at: state.msgs.isEmpty ? 0 : state.msgs.last.at,
    );
    final list = ListView(
      shrinkWrap: !widget.sidebar,
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        if (widget.sidebar && (state.isEmpty || matches(current))) ...[
          _DesktopSessionRow(
            session: current,
            current: true,
            empty: state.isEmpty,
          ),
          const SizedBox(height: 12),
        ],
        if (widget.sidebar && sessions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Text(
              '历史会话',
              style: context.texts.labelSmall!.copyWith(color: scheme.outline),
            ),
          ),
        for (final session in sessions)
          _DesktopSessionRow(
            key: ValueKey('assistant-session-${session.id}'),
            session: session,
            onOpen: state.running
                ? null
                : () {
                    notifier.openSession(session.id);
                    if (!widget.sidebar) Navigator.pop(context);
                  },
            onDelete: () => notifier.deleteSession(session.id),
          ),
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            child: Text(
              query.isNotEmpty ? '没有匹配的会话' : '还没有历史会话\n新建对话后,这段聊天会保存在这里。',
              style: context.texts.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.7,
              ),
            ),
          ),
      ],
    );
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: widget.sidebar ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.sidebar ? '会话' : '历史会话',
                    style: context.texts.titleSmall!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (state.sessions.isNotEmpty)
                  IconButton(
                    tooltip: '清空历史会话',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _clear(state.sessions.length),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  ),
                if (!widget.sidebar)
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
          ),
          if (widget.sidebar)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: FilledButton.tonalIcon(
                onPressed: state.running ? null : widget.onNewChat,
                icon: const Icon(Icons.edit_square, size: 18),
                label: const Text('新对话'),
              ),
            ),
          if (widget.sidebar || state.sessions.length >= 6 || _query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: TextField(
                key: const ValueKey('assistant-history-search'),
                onChanged: (value) => setState(() => _query = value),
                style: context.texts.bodySmall,
                decoration: InputDecoration(
                  hintText: '搜索会话',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          if (widget.sidebar) Expanded(child: list) else Flexible(child: list),
        ],
      ),
    );
  }
}

class _DesktopSessionRow extends StatelessWidget {
  const _DesktopSessionRow({
    super.key,
    required this.session,
    this.current = false,
    this.empty = false,
    this.onOpen,
    this.onDelete,
  });
  final ArchivedSession session;
  final bool current;
  final bool empty;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        selected: current,
        child: Material(
          color: current ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          empty ? '新对话' : session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          current
                              ? '当前对话'
                              : '${_when(session.at)} · ${session.turns} 轮',
                          style: context.texts.labelSmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (!current && session.preview.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            session.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.labelSmall!.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (onDelete != null)
                    IconButton(
                      tooltip: '删除会话',
                      visualDensity: VisualDensity.compact,
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: scheme.outline,
                      ),
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistorySheet extends ConsumerWidget {
  const _HistorySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.scheme;
    final sessions = ref.watch(assistantProvider.select((s) => s.sessions));
    final n = ref.read(assistantProvider.notifier);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '历史会话',
                      style: context.texts.titleMedium!.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (sessions.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        final ok = await confirmDialog(
                          context,
                          title: '清空历史会话?',
                          message: '${sessions.length} 段对话都会删掉,已经写进创作页的改动不受影响。',
                          confirmLabel: '清空',
                        );
                        if (ok) n.clearSessions();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.error,
                        minimumSize: const Size(0, 44),
                      ),
                      child: const Text('清空'),
                    ),
                ],
              ),
            ),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 30, 20, 46),
                child: Text(
                  '还没有归档的对话。\n点右上角「新对话」就会把当前这段存进来。',
                  textAlign: TextAlign.center,
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.7,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  itemCount: sessions.length,
                  itemBuilder: (context, i) => _Row(
                    s: sessions[i],
                    onOpen: () {
                      n.openSession(sessions[i].id);
                      Navigator.pop(context);
                    },
                    onDelete: () => n.deleteSession(sessions[i].id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.s, required this.onOpen, required this.onDelete});

  final ArchivedSession s;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    // 左滑删单条(原生手势);顶栏「清空」是兜底入口,不让手势成为唯一路径。
    return Dismissible(
      key: ValueKey(s.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.only(bottom: 9),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodyMedium!.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (s.hasError) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.error_outline,
                          size: 15,
                          color: scheme.error,
                        ),
                      ],
                    ],
                  ),
                  if (s.preview.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      s.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  DefaultTextStyle(
                    style: context.texts.labelSmall!.copyWith(
                      color: scheme.outline,
                    ),
                    child: Row(
                      children: [
                        Text(_when(s.at)),
                        const SizedBox(width: 10),
                        Text('${s.turns} 轮'),
                        if (s.tagCount > 0) ...[
                          const SizedBox(width: 10),
                          Text('${s.tagCount} tag'),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 相对时间:今天报时分,昨天报「昨天 HH:mm」,更早报「M/d」。
String _when(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final diff = today.difference(that).inDays;
  if (diff == 0) {
    return now.difference(t).inMinutes < 3 ? '刚刚' : hm;
  }
  if (diff == 1) return '昨天 $hm';
  return '${t.month}/${t.day}';
}
