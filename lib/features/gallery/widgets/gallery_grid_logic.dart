import 'package:flutter/material.dart';

import '../gallery_date_filter.dart';
import '../gallery_search.dart';
import '../models.dart';

class GalleryGridSelection {
  bool selecting = false;
  final Set<String> picked = {};

  void enter([String? id]) {
    selecting = true;
    if (id != null) picked.add(id);
  }

  void exit() {
    selecting = false;
    picked.clear();
  }

  void toggle(String id) =>
      picked.contains(id) ? picked.remove(id) : picked.add(id);

  bool allSelected(Iterable<String> ids) => ids.every(picked.contains);

  void toggleGroup(Iterable<String> ids) {
    final group = ids.toSet();
    if (allSelected(group)) {
      picked.removeAll(group);
    } else {
      picked.addAll(group);
    }
  }

  void toggleAll(List<ResultImage> images) {
    if (picked.length == images.length) {
      picked.clear();
    } else {
      picked
        ..clear()
        ..addAll(images.map((image) => image.id));
    }
  }

  void retainVisible(Iterable<ResultImage> images) {
    final visible = {for (final image in images) image.id};
    picked.removeWhere((id) => !visible.contains(id));
  }

  bool canAct({
    required bool saving,
    required bool sharing,
    required bool zipping,
    required bool organizing,
  }) => picked.isNotEmpty && !saving && !sharing && !zipping && !organizing;
}

List<ResultImage> filterGalleryImages({
  required Iterable<ResultImage> images,
  required GalleryDateFilter date,
  required DateTime now,
  required Map<String, GallerySearchMeta> byId,
  required String query,
  required String? model,
  bool favoritesOnly = false,
  bool includeImageDetails = false,
}) {
  final terms = searchTerms(query);
  return [
    for (final image in images)
      if ((!favoritesOnly || image.favorite) &&
          date.matches(image.createdAt, now) &&
          (model == null || (byId[image.id]?.model ?? '') == model) &&
          (terms.isEmpty ||
              (includeImageDetails
                  ? searchMatch(
                      normalizeSearchText(
                        '${image.id} ${image.seed} ${byId[image.id]?.text ?? image.input?.prompt ?? ''}',
                      ),
                      terms,
                    )
                  : (byId[image.id] != null &&
                        searchMatch(byId[image.id]!.text, terms)))))
        image,
  ];
}

List<(String, String?, int?)> galleryModelFilterOptions(
  Iterable<ResultImage> images,
  Map<String, GallerySearchMeta> byId,
) {
  final counts = <String, int>{};
  for (final image in images) {
    counts.update(
      byId[image.id]?.model ?? '',
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  final models = [
    for (final model in counts.keys)
      if (model.isNotEmpty) model,
  ]..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  return [
    ('全部', null, null),
    for (final model in models) (model, model, counts[model]),
    if ((counts[''] ?? 0) > 0) ('未知', '', counts['']),
  ];
}

Future<bool> confirmGalleryBatchDelete(BuildContext context, int count) async {
  final scheme = Theme.of(context).colorScheme;
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('删除 $count 张作品?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;
}
