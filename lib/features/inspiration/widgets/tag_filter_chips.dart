import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// 「我的」库的全部 / 收藏 / 用户标签筛选行，灵感页与角色选择器共用。
class TagFilterChips extends StatelessWidget {
  const TagFilterChips({
    super.key,
    required this.tags,
    required this.filter,
    required this.onChanged,
    required this.onManageTags,
    this.edge = 14,
  });

  static const favorites = ' fav';

  final List<String> tags;
  final String? filter;
  final ValueChanged<String?> onChanged;
  final VoidCallback onManageTags;
  final double edge;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    Widget chip(
      String label,
      bool selected,
      VoidCallback onTap, {
      IconData? icon,
    }) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: icon == null
            ? Text(label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: selected
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(label),
                ],
              ),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        shape: const StadiumBorder(),
        labelStyle: context.texts.labelMedium!.copyWith(
          fontWeight: FontWeight.w600,
          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
        selectedColor: scheme.primary,
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide.none,
        showCheckmark: false,
      ),
    );
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(edge, 4, 4, 4),
              children: [
                chip('全部', filter == null, () => onChanged(null)),
                chip(
                  '收藏',
                  filter == favorites,
                  () => onChanged(favorites),
                  icon: Icons.star_rounded,
                ),
                for (final tag in tags)
                  chip(
                    tag,
                    filter == tag,
                    () => onChanged(filter == tag ? null : tag),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '标签池管理',
            icon: Icon(
              Icons.settings_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: onManageTags,
          ),
          SizedBox(width: edge - 8),
        ],
      ),
    );
  }
}
