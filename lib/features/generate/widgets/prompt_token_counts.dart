import 'package:flutter/material.dart';

/// Local positive/negative counts; the editor keeps its aggregate capacity too.
class PromptTokenCounts extends StatelessWidget {
  const PromptTokenCounts({
    super.key,
    required this.positive,
    required this.negative,
  });

  final int positive;
  // Medium keeps the High negative draft but does not send it.
  final int? negative;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label =
        '正向 $positive · ${negative == null ? 'Medium 使用固定负面' : '负面 $negative'}';
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.25,
      color: scheme.outline,
    );
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('$positive', style: style),
            Text(
              negative == null ? '—' : '$negative',
              style: style.copyWith(
                color: negative == null ? scheme.outline : scheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
