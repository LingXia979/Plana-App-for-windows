import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import '../assistant/assistant_page.dart';
import '../gallery/gallery_page.dart';
import '../generate/gen_modules.dart';
import '../generate/generate_page.dart';
import '../generate/generate_state.dart';
import '../generate/generation_controller.dart';
import '../generate/models.dart';
import '../generate/widgets/bottom_action_bar.dart';
import '../generate/widgets/common.dart';
import '../generate/widgets/top_bar.dart';
import '../generate/widgets/desktop_prompt_card.dart';
import '../inspiration/inspiration_page.dart';
import '../import/desktop_image_drop.dart';
import '../shell/shell_state.dart';
import 'desktop_gallery_page.dart';
import 'desktop_canvas_state.dart';
import 'desktop_pane_divider.dart';

part 'desktop_controls.dart';
part 'desktop_prompt.dart';
part 'desktop_parameters.dart';

class DesktopWorkspace extends ConsumerStatefulWidget {
  const DesktopWorkspace({super.key});
  @override
  ConsumerState<DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends ConsumerState<DesktopWorkspace>
    with AutomaticKeepAliveClientMixin {
  int tool = 0;
  bool compactTool = false;
  final toolKey = GlobalKey();
  final shortcutFocus = FocusNode(debugLabel: 'Desktop workspace');
  static const _leftWidthKey = 'desktop_left_pane_width';
  static const _rightWidthKey = 'desktop_right_pane_width';
  static const _minLeft = 300.0;
  static const _minRight = 330.0;
  static const _minCanvas = 360.0;
  double? _leftWidth;
  double? _rightWidth;

  @override
  void initState() {
    super.initState();
    double? load(String key, double minimum) {
      final value = double.tryParse(
        ref.read(prefsStoreProvider).get(key) ?? '',
      );
      return value != null && value.isFinite && value >= minimum ? value : null;
    }

    _leftWidth = load(_leftWidthKey, _minLeft);
    _rightWidth = load(_rightWidthKey, _minRight);
  }

  void _saveWidth({required bool left}) {
    unawaited(
      ref
          .read(prefsStoreProvider)
          .write(
            key: left ? _leftWidthKey : _rightWidthKey,
            value: (left ? _leftWidth : _rightWidth)?.toString(),
          ),
    );
  }

  void _beginPaneResize(double left, double right, bool wide) {
    // A manual adjustment starts from the fitted, visible sizes. Otherwise an
    // older, larger preference makes the opposite pane jump during the drag.
    setState(() {
      _leftWidth = left;
      if (wide) _rightWidth = right;
    });
  }

  void _endPaneResize(bool wide) {
    _saveWidth(left: true);
    if (wide) _saveWidth(left: false);
  }

  // Window resizing may temporarily reduce both panes. Keep the user's saved
  // widths so returning to a larger window restores the chosen proportions.
  ({double left, double right}) _paneWidths(double width, bool wide) {
    var left = _leftWidth ?? (width * .24).clamp(_minLeft, 370.0);
    var right = wide
        ? _rightWidth ?? (width * .25).clamp(_minRight, 400.0)
        : 0.0;
    final room =
        width - _minCanvas - DesktopPaneDivider.extent * (wide ? 2 : 1);
    if (left + right > room) {
      if (wide) {
        final extra = left - _minLeft + right - _minRight;
        final scale = extra > 0
            ? math.max(0.0, room - _minLeft - _minRight) / extra
            : 0.0;
        left = _minLeft + (left - _minLeft) * scale;
        right = _minRight + (right - _minRight) * scale;
      } else {
        left = room.clamp(_minLeft, double.infinity);
      }
    }
    return (left: left, right: right);
  }

  @override
  bool get wantKeepAlive => true;
  @override
  void dispose() {
    shortcutFocus.dispose();
    super.dispose();
  }

  void _tool(int value) {
    shortcutFocus.requestFocus();
    setState(() {
      tool = value;
      compactTool = true;
    });
  }

  Widget _tabs({bool compact = false}) => SizedBox(
    height: 46,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          if (compact) ...[
            _tab('图片与历史', Icons.image_outlined, !compactTool, () {
              shortcutFocus.requestFocus();
              setState(() => compactTool = false);
            }, 'desktop-canvas-tab'),
            const SizedBox(width: 5),
          ],
          _tab(
            'AI 助手',
            Icons.auto_awesome_outlined,
            (!compact || compactTool) && tool == 0,
            () => _tool(0),
            'desktop-ai-tab',
          ),
          const SizedBox(width: 5),
          _tab(
            '灵感',
            Icons.lightbulb_outline,
            (!compact || compactTool) && tool == 1,
            () => _tool(1),
            'desktop-inspiration-tab',
          ),
        ],
      ),
    ),
  );

  Widget _tab(
    String text,
    IconData icon,
    bool selected,
    VoidCallback action,
    String id,
  ) => TextButton.icon(
    key: ValueKey(id),
    onPressed: action,
    style: TextButton.styleFrom(
      backgroundColor: selected ? context.scheme.primaryContainer : null,
      foregroundColor: selected
          ? context.scheme.primary
          : context.scheme.onSurfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    icon: Icon(icon, size: 16),
    label: Text(text, style: const TextStyle(fontSize: 12)),
  );

  Widget _tools() => LayoutBuilder(
    builder: (_, box) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(size: Size(box.maxWidth, box.maxHeight)),
      child: IndexedStack(
        key: toolKey,
        index: tool,
        children: const [
          AssistantPage(embedded: true),
          InspirationPage(embedded: true),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, alt: true): () =>
            _tool(0),
        const SingleActivator(LogicalKeyboardKey.keyI, alt: true): () =>
            _tool(1),
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (ref.read(shellIndexProvider) == kTabCreate) {
            ref.read(generationProvider.notifier).generate();
          }
        },
      },
      child: Focus(
        focusNode: shortcutFocus,
        autofocus: true,
        child: LayoutBuilder(
          builder: (_, box) {
            final wide = box.maxWidth >= 1100;
            final (:left, :right) = _paneWidths(box.maxWidth, wide);
            final paneBudget =
                box.maxWidth -
                _minCanvas -
                DesktopPaneDivider.extent * (wide ? 2 : 1);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const ValueKey('desktop-controls'),
                  width: left,
                  child: const DesktopImportRegion(child: _DesktopControls()),
                ),
                DesktopPaneDivider(
                  key: const ValueKey('desktop-left-divider'),
                  label: '左侧栏',
                  paneWidth: left,
                  onResizeStart: () => _beginPaneResize(left, right, wide),
                  onResize: (value) => setState(() {
                    _leftWidth = value.clamp(
                      _minLeft,
                      math.max(_minLeft, paneBudget - (wide ? _minRight : 0)),
                    );
                    if (wide) {
                      _rightWidth = math.min(right, paneBudget - _leftWidth!);
                    }
                  }),
                  onResizeEnd: () => _endPaneResize(wide),
                  onReset: () {
                    setState(() => _leftWidth = null);
                    _saveWidth(left: true);
                  },
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (!wide) _tabs(compact: true),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: IndexedStack(
                                index: !wide && compactTool ? 1 : 0,
                                children: [
                                  Column(
                                    key: const ValueKey('desktop-canvas'),
                                    children: [
                                      Expanded(
                                        child: const GalleryPage(
                                          desktop: true,
                                          libraryControl:
                                              DesktopLibraryButton(),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (!wide) _tools(),
                                ],
                              ),
                            ),
                            if (wide) ...[
                              DesktopPaneDivider(
                                key: const ValueKey('desktop-right-divider'),
                                label: '右侧栏',
                                paneWidth: right,
                                trailingPane: true,
                                onResizeStart: () =>
                                    _beginPaneResize(left, right, wide),
                                onResize: (value) => setState(() {
                                  _rightWidth = value.clamp(
                                    _minRight,
                                    math.max(_minRight, paneBudget - _minLeft),
                                  );
                                  _leftWidth = math.min(
                                    left,
                                    paneBudget - _rightWidth!,
                                  );
                                }),
                                onResizeEnd: () => _endPaneResize(wide),
                                onReset: () {
                                  setState(() => _rightWidth = null);
                                  _saveWidth(left: false);
                                },
                              ),
                              SizedBox(
                                width: right,
                                child: Material(
                                  key: const ValueKey('desktop-dock'),
                                  color: context.scheme.surfaceContainerLow,
                                  child: Column(
                                    children: [
                                      _tabs(),
                                      const Divider(height: 1),
                                      Expanded(child: _tools()),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
