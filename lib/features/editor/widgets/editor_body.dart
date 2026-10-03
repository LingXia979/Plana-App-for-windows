import 'package:flutter/material.dart';

/// Full-page editors scroll internally; sidebar editors grow with their content.
class EditorBody extends StatelessWidget {
  const EditorBody({
    super.key,
    required this.child,
    required this.padding,
    this.scrollable = true,
    this.controller,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool scrollable;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => scrollable
      ? SingleChildScrollView(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: padding,
          child: child,
        )
      : Padding(padding: padding, child: child);
}
