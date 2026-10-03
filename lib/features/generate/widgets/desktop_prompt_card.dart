import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../editor/editor_page.dart';
import '../../editor/editor_state.dart';

/// A persistent, independent editor session for each sidebar prompt.
class DesktopPromptCard extends StatefulWidget {
  const DesktopPromptCard({super.key, this.charId});
  final String? charId;

  @override
  State<DesktopPromptCard> createState() => _DesktopPromptCardState();
}

class _DesktopPromptCardState extends State<DesktopPromptCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final editor = ProviderScope(
      overrides: [
        editorProvider.overrideWith(
          () => EditorNotifier(immediateWriteBack: true),
        ),
      ],
      child: EditorPage(positive: true, charId: widget.charId, embedded: true),
    );
    if (widget.charId != null) return editor;
    return Material(
      color: context.scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: const EdgeInsets.all(12), child: editor),
    );
  }
}
