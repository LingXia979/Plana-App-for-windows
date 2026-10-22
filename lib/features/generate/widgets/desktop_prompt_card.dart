import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../editor/editor_page.dart';
import '../../editor/editor_state.dart';

/// A persistent, independent editor session for each sidebar prompt.
class DesktopPromptCard extends StatefulWidget {
  const DesktopPromptCard({
    super.key,
    this.charId,
    this.sectionId,
    this.framed = true,
  });
  final bool framed;
  final String? charId;
  final String? sectionId;

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
      child: EditorPage(
        positive: true,
        charId: widget.charId,
        sectionId: widget.sectionId,
        embedded: true,
      ),
    );
    if (!widget.framed || widget.charId != null || widget.sectionId != null) {
      return editor;
    }
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

/// Opens the same prompt target in a large desktop editing dialog.
class PromptFullscreenButton extends ConsumerWidget {
  const PromptFullscreenButton({super.key, this.charId, this.sectionId});

  final String? charId;
  final String? sectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: '大屏编辑提示词',
      icon: const Icon(Icons.open_in_full, size: 16),
      constraints: const BoxConstraints.tightFor(width: 26, height: 32),
      padding: EdgeInsets.zero,
      onPressed: () async {
        final sessions = ref.read(editorSessionsProvider);
        sessions.flushPending();
        FocusManager.instance.primaryFocus?.unfocus();
        final container = ProviderScope.containerOf(context);
        await showDialog<void>(
          context: context,
          barrierDismissible: true,
          builder: (context) {
            final size = MediaQuery.sizeOf(context);
            return UncontrolledProviderScope(
              container: container,
              child: Dialog(
                insetPadding: const EdgeInsets.all(24),
                constraints: const BoxConstraints(),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: size.width - 48,
                  height: size.height - 48,
                  child: ProviderScope(
                    overrides: [
                      editorProvider.overrideWith(
                        () => EditorNotifier(immediateWriteBack: true),
                      ),
                    ],
                    child: EditorPage(
                      positive: true,
                      floatingPanels: true,
                      charId: charId,
                      sectionId: sectionId,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
