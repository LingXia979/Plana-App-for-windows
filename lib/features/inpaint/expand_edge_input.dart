import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 桌面扩图的单边输入。画布实时使用校准后的值，输入草稿在失焦时归整。
/// 外部拖动、撤销、重置都通过 [value] 同步回来。
class ExpandEdgeInput extends StatefulWidget {
  const ExpandEdgeInput({
    super.key,
    required this.side,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String side;
  final String label;
  final int value;

  /// 返回按 64 对齐、并经过画布尺寸限制后的实际值。
  final int Function(int) onChanged;

  @override
  State<ExpandEdgeInput> createState() => _ExpandEdgeInputState();
}

class _ExpandEdgeInputState extends State<ExpandEdgeInput> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  late int _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
    _controller = TextEditingController(text: '$_value');
    _focus = FocusNode()..addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant ExpandEdgeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _value) {
      _value = widget.value;
      _showValue();
    }
  }

  void _showValue() {
    final text = '$_value';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _showValue();
  }

  void _step(int direction) {
    _value = widget.onChanged(_value + direction * 64);
    _showValue();
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget arrow(bool up) => SizedBox(
      width: 22,
      height: 20,
      child: IconButton(
        key: ValueKey('expand-${widget.side}-${up ? 'increase' : 'decrease'}'),
        padding: EdgeInsets.zero,
        tooltip: '${widget.label}${up ? '增加' : '减少'} 64 像素',
        onPressed: () => _step(up ? 1 : -1),
        icon: Icon(
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          size: 17,
        ),
      ),
    );
    return SizedBox(
      width: 106,
      child: Row(
        children: [
          Text(widget.label),
          const SizedBox(width: 6),
          Expanded(
            child: Listener(
              onPointerSignal: (event) {
                if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) {
                  return;
                }
                GestureBinding.instance.pointerSignalResolver.register(event, (
                  _,
                ) {
                  _step(event.scrollDelta.dy < 0 ? 1 : -1);
                });
              },
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _step(1),
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _step(-1),
                },
                child: TextField(
                  key: ValueKey('expand-${widget.side}'),
                  controller: _controller,
                  focusNode: _focus,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    suffixIconConstraints: const BoxConstraints.tightFor(
                      width: 22,
                      height: 40,
                    ),
                    suffixIcon: Column(children: [arrow(true), arrow(false)]),
                  ),
                  onChanged: (text) {
                    final parsed = int.tryParse(text);
                    if (parsed != null) _value = widget.onChanged(parsed);
                  },
                  onSubmitted: (_) => _showValue(),
                  onTapOutside: (_) => _focus.unfocus(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
