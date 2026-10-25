import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import 'prompt_reorder_scroll.dart';
import '../../editor/editor_state.dart'
    show EditorSessions, editorSessionsProvider;

/// A desktop name editor. The caller binds [onRename] to the source canvas and
/// item IDs; an edit keeps that callback even if its row later rebuilds.
class PromptInlineName extends ConsumerStatefulWidget {
  const PromptInlineName({
    super.key,
    required this.identifier,
    required this.identity,
    required this.name,
    required this.fallbackName,
    required this.onRename,
    required this.style,
    this.onSelect,
    this.padding = const EdgeInsets.all(4),
    this.labelMaxWidth = double.infinity,
    this.displayName,
    this.reorderIndex,
  });

  final String identifier;
  final Object identity;
  final String name;
  final String fallbackName;
  final ValueChanged<String> onRename;
  final TextStyle style;
  final VoidCallback? onSelect;
  final EdgeInsets padding;
  final double labelMaxWidth;
  // Display-only shortening must never become the value being edited/saved.
  final String? displayName;
  final int? reorderIndex;

  @override
  ConsumerState<PromptInlineName> createState() => _PromptInlineNameState();
}

class _PromptInlineNameState extends ConsumerState<PromptInlineName> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Prompt name');
  late final EditorSessions _sessions;
  ({ValueChanged<String> save, String fallback})? _edit;
  bool _compositionEnter = false;

  bool get _composing =>
      _controller.value.composing.isValid &&
      !_controller.value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _sessions = ref.read(editorSessionsProvider);
    _sessions.prepareInputs.add(_prepareSwitch);
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant PromptInlineName oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      // Normal canvas switches have already flushed the source edit. Never
      // reuse a late focus notification for a newly displayed target.
      _edit = null;
      _focus.unfocus();
    }
  }

  void _start() {
    if (_edit != null) return;
    _sessions.flushPending();
    _controller.value = TextEditingValue(
      text: widget.name,
      selection: TextSelection(baseOffset: 0, extentOffset: widget.name.length),
    );
    _compositionEnter = false;
    final edit = (save: widget.onRename, fallback: widget.fallbackName);
    setState(() => _edit = edit);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _edit != edit) return;
      _focus.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _finish();
  }

  void _prepareSwitch() => _finish();

  void _finish({bool save = true}) {
    final edit = _edit;
    if (edit == null) return;
    // Clear first: unfocus and a pending input action must not save twice,
    // especially after Escape.
    setState(() => _edit = null);
    _focus.unfocus();
    if (save) {
      final value = _controller.text.trim();
      edit.save(value.isEmpty ? edit.fallback : value);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _finish(save: false);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_composing) {
        _compositionEnter = true;
        // Leave the event to the IME, without invoking ancestor shortcuts.
        return KeyEventResult.skipRemainingHandlers;
      }
      _compositionEnter = false;
      _finish();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _submitted(String _) {
    if (_compositionEnter) {
      _compositionEnter = false;
      return;
    }
    if (!_composing) _finish();
  }

  @override
  void dispose() {
    _sessions.prepareInputs.remove(_prepareSwitch);
    _edit = null; // A deleted row must not be restored by a focus callback.
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_edit == null) {
      final label = Tooltip(
        message:
            '${widget.displayName != null && widget.displayName != widget.name ? '${widget.name}\n' : ''}'
            '${widget.onSelect == null ? '单击重命名' : '选择分区'}'
            '${widget.reorderIndex == null ? '' : ' · 按住拖动排序'}',
        child: InkWell(
          key: ValueKey(widget.identifier),
          onTap: widget.onSelect ?? _start,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.labelMaxWidth),
            child: Padding(
              padding: widget.padding,
              child: Text(
                widget.displayName ?? widget.name,
                semanticsLabel: widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.style,
              ),
            ),
          ),
        ),
      );
      return widget.reorderIndex == null
          ? label
          : PromptReorderDragStartListener(
              index: widget.reorderIndex!,
              child: label,
            );
    }
    return Focus(
      onKeyEvent: _key,
      child: TextSelectionTheme(
        data: TextSelectionTheme.of(context).copyWith(
          selectionColor: context.scheme.primary.withValues(alpha: .30),
        ),
        child: TextField(
          key: ValueKey('${widget.identifier}-editor'),
          controller: _controller,
          focusNode: _focus,
          style: widget.style.copyWith(color: context.scheme.onSurface),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.fallbackName,
            contentPadding: widget.padding,
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(4)),
            ),
          ),
          // Keep the composition/focus intact until we decide to submit.
          onEditingComplete: () {},
          onSubmitted: _submitted,
          onTapOutside: (_) => _finish(),
        ),
      ),
    );
  }
}
