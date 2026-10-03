import 'package:flutter/material.dart';

import '../../generate/preset_manage_page.dart';

/// Opens the shared preset manager without leaving the prompt editor.
class PromptPresetMenuButton extends StatelessWidget {
  const PromptPresetMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('desktop-prompt-preset'),
      tooltip: '切换预设',
      icon: const Icon(Icons.bookmarks_outlined),
      iconSize: 18,
      padding: const EdgeInsets.all(5),
      onPressed: () => showPromptPresetManager(context),
    );
  }
}
