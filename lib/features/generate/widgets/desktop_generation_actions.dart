import 'package:flutter/material.dart';

/// Keep the secondary controls square alongside the desktop generate button.
class DesktopGenerationActions extends StatelessWidget {
  const DesktopGenerationActions({
    super.key,
    required this.generateButton,
    required this.loopActive,
    required this.onLoop,
    required this.onImport,
  });

  final Widget generateButton;
  final bool loopActive;
  final VoidCallback onLoop;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: generateButton),
      const SizedBox(width: 6),
      SizedBox.square(
        dimension: 52,
        child: IconButton.filledTonal(
          tooltip: '循环生成',
          onPressed: onLoop,
          isSelected: loopActive,
          icon: const Icon(Icons.autorenew, size: 21),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox.square(
        dimension: 52,
        child: IconButton.outlined(
          tooltip: '导入图片',
          onPressed: onImport,
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 21),
        ),
      ),
    ],
  );
}
