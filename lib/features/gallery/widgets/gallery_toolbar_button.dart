import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Shared controls for quick browse, library filters and the library overview.
class GalleryToolbarButton extends StatelessWidget {
  const GalleryToolbarButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.active = false,
    this.dropdown = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool active;
  final bool dropdown;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Semantics(
      selected: active,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: active
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
          backgroundColor: active
              ? scheme.secondaryContainer
              : scheme.surfaceContainer,
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: context.texts.bodyMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (dropdown) ...[
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ],
        ),
      ),
    );
  }
}
