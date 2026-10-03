import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'inpaint_ops.dart';

/// 四个输入分别对应画布的四边；确认前只预览，不修改编辑器。
class ExpandCanvasDialog extends StatefulWidget {
  const ExpandCanvasDialog({
    super.key,
    required this.width,
    required this.height,
    this.image,
    this.existing = (left: 0, top: 0, right: 0, bottom: 0),
  });

  final int width, height;
  final ui.Image? image;
  final ExpandMargins existing;

  @override
  State<ExpandCanvasDialog> createState() => _ExpandCanvasDialogState();
}

class _ExpandCanvasDialogState extends State<ExpandCanvasDialog> {
  final _left = TextEditingController(text: '0');
  final _top = TextEditingController(text: '0');
  final _right = TextEditingController(text: '0');
  final _bottom = TextEditingController(text: '0');

  @override
  void dispose() {
    for (final ctl in [_left, _top, _right, _bottom]) {
      ctl.dispose();
    }
    super.dispose();
  }

  int? _value(TextEditingController ctl) {
    final value = int.tryParse(ctl.text.trim());
    return value == null || value < 0 ? null : alignExpandMargin(value);
  }

  ExpandMargins get _margins => (
    left: _value(_left) ?? 0,
    top: _value(_top) ?? 0,
    right: _value(_right) ?? 0,
    bottom: _value(_bottom) ?? 0,
  );

  String? get _error {
    if ([_left, _top, _right, _bottom].any((ctl) => _value(ctl) == null)) {
      return '请输入非负整数';
    }
    return expansionError(widget.width, widget.height, _margins);
  }

  void _step(TextEditingController ctl, int delta) {
    final next = math.max(0, (_value(ctl) ?? 0) + delta);
    setState(() {
      ctl.value = TextEditingValue(
        text: '$next',
        selection: TextSelection.collapsed(offset: '$next'.length),
      );
    });
  }

  Widget _field(String side, String name, TextEditingController ctl) =>
      TextField(
        key: ValueKey('expand-$side'),
        controller: ctl,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
          LengthLimitingTextInputFormatter(6),
        ],
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: name,
          suffixText: 'px',
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.fromLTRB(12, 15, 8, 15),
          suffixIconConstraints: const BoxConstraints.tightFor(
            width: 32,
            height: 46,
          ),
          suffixIcon: Column(
            children: [
              _stepButton(ctl, name, 64, Icons.keyboard_arrow_up),
              _stepButton(ctl, name, -64, Icons.keyboard_arrow_down),
            ],
          ),
        ),
      );

  Widget _stepButton(
    TextEditingController ctl,
    String name,
    int delta,
    IconData icon,
  ) => SizedBox(
    height: 23,
    child: IconButton(
      tooltip: '$name${delta > 0 ? '增加' : '减少'} 64 像素',
      padding: EdgeInsets.zero,
      iconSize: 18,
      onPressed: delta < 0 && (_value(ctl) ?? 0) == 0
          ? null
          : () => _step(ctl, delta),
      icon: Icon(icon),
    ),
  );

  Widget _preview(ExpandMargins margins) {
    final scheme = Theme.of(context).colorScheme;
    final width = widget.width + margins.left + margins.right;
    final height = widget.height + margins.top + margins.bottom;
    return SizedBox(
      height: 224,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = math.min(
            constraints.maxWidth / width,
            constraints.maxHeight / height,
          );
          final image = widget.image;
          return Center(
            child: SizedBox(
              key: const ValueKey('expand-preview'),
              width: width * scale,
              height: height * scale,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: .6),
                  border: Border.all(color: scheme.primary, width: 1.5),
                ),
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned(
                        left: margins.left * scale,
                        top: margins.top * scale,
                        width: widget.width * scale,
                        height: widget.height * scale,
                        child: ColoredBox(
                          color: scheme.surfaceContainerHighest,
                        ),
                      ),
                      if (image != null)
                        Positioned(
                          left: (margins.left + widget.existing.left) * scale,
                          top: (margins.top + widget.existing.top) * scale,
                          width: image.width * scale,
                          height: image.height * scale,
                          child: RawImage(image: image, fit: BoxFit.fill),
                        ),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          color: scheme.surface.withValues(alpha: .9),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${widget.width} × ${widget.height}\n↓\n$width × $height',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final margins = _margins;
    final error = _error;
    final changed =
        margins.left + margins.top + margins.right + margins.bottom > 0;
    return AlertDialog(
      key: const ValueKey('expand-canvas-dialog'),
      insetPadding: const EdgeInsets.all(20),
      title: const Text('扩图尺寸'),
      content: SizedBox(
        width: 620,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(120, MediaQuery.sizeOf(context).height - 210),
          ),
          child: SingleChildScrollView(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 480;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('向当前画布四周添加像素'),
                    const SizedBox(height: 18),
                    if (wide) ...[
                      Center(
                        child: SizedBox(
                          width: 170,
                          child: _field('top', '上', _top),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          SizedBox(
                            width: 130,
                            child: _field('left', '左', _left),
                          ),
                          const SizedBox(width: 14),
                          Expanded(child: _preview(margins)),
                          const SizedBox(width: 14),
                          SizedBox(
                            width: 130,
                            child: _field('right', '右', _right),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Center(
                        child: SizedBox(
                          width: 170,
                          child: _field('bottom', '下', _bottom),
                        ),
                      ),
                    ] else ...[
                      _preview(margins),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(child: _field('top', '上', _top)),
                          const SizedBox(width: 12),
                          Expanded(child: _field('bottom', '下', _bottom)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: _field('left', '左', _left)),
                          const SizedBox(width: 12),
                          Expanded(child: _field('right', '右', _right)),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    Text(
                      error ?? '每边向上取整到 64 像素；新增区域自动加蒙版。再次打开可继续添加。',
                      key: const ValueKey('expand-validation'),
                      style: TextStyle(
                        fontSize: 12,
                        color: error == null
                            ? scheme.onSurfaceVariant
                            : scheme.error,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('expand-apply'),
          onPressed: error != null || !changed
              ? null
              : () => Navigator.pop(context, margins),
          child: const Text('扩展画布'),
        ),
      ],
    );
  }
}
