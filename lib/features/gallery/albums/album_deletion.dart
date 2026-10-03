import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../generate/generation_controller.dart';
import '../gallery_state.dart';
import '../models.dart';
import 'album_models.dart';
import 'album_state.dart';

class AlbumDeletionPlan {
  AlbumDeletionPlan._(this.albumId, this.name, Map<String, Set<String>> members)
    : memberships = Map.unmodifiable({
        for (final entry in members.entries)
          entry.key: Set<String>.unmodifiable(entry.value),
      });

  factory AlbumDeletionPlan.capture({
    required String albumId,
    required AlbumsData albums,
    required Iterable<ResultImage> images,
  }) {
    if (!albums.exists(albumId)) throw StateError('图库已被删除');
    return AlbumDeletionPlan._(albumId, albums.name(albumId), {
      for (final image in images)
        if (albums.contains(albumId, image.id))
          image.id: albums.ofImage(image.id).where(albums.exists).toSet(),
    });
  }

  final String albumId, name;
  final Map<String, Set<String>> memberships;
  Set<String> get imageIds => memberships.keys.toSet();
  Set<String> get exclusiveIds => {
    for (final entry in memberships.entries)
      if (entry.value.length == 1) entry.key,
  };
  Set<String> get sharedIds => imageIds.difference(exclusiveIds);

  bool matches(
    AlbumsData albums,
    Iterable<ResultImage> images, {
    Set<String> deletedIds = const {},
  }) {
    if (!albums.exists(albumId)) return false;
    final expected = imageIds.difference(deletedIds);
    final current = {
      for (final image in images)
        if (albums.contains(albumId, image.id)) image.id,
    };
    if (!setEquals(expected, current)) return false;
    return expected.every(
      (id) => setEquals(
        memberships[id],
        albums.ofImage(id).where(albums.exists).toSet(),
      ),
    );
  }
}

enum AlbumDeletionStatus {
  deleted,
  contentsChanged,
  generationPending,
  filesRemain,
}

class AlbumDeletionResult {
  AlbumDeletionResult(this.status, Set<String> deletedIds)
    : deletedIds = Set.unmodifiable(deletedIds);

  final AlbumDeletionStatus status;
  final Set<String> deletedIds;
  bool get albumDeleted => status == AlbumDeletionStatus.deleted;
}

/// Deletes only the confirmed images that have no other real album membership.
/// A concurrent edit can reduce this operation, but never expand its scope.
Future<AlbumDeletionResult> deleteGalleryAlbum(
  ProviderContainer container,
  AlbumDeletionPlan plan,
) async {
  final stores = container.read(appStoresProvider);
  if (stores.albums.readOnly) throw StateError('图库数据需要恢复，暂时不能修改');
  bool hasGeneration() => container
      .read(generationProvider)
      .jobs
      .any((job) => job.galleryTarget.albumId == plan.albumId);
  bool matches({Set<String> deletedIds = const {}}) => plan.matches(
    stores.albums.data,
    container.read(galleryProvider).results,
    deletedIds: deletedIds,
  );
  final revision = stores.albums.editRevision;
  await stores.gallery.idle;
  await stores.albums.idle;
  if (hasGeneration()) {
    return AlbumDeletionResult(AlbumDeletionStatus.generationPending, {});
  }
  if (stores.albums.editRevision != revision || !matches()) {
    return AlbumDeletionResult(AlbumDeletionStatus.contentsChanged, {});
  }
  final exclusive = plan.exclusiveIds;
  var changedDuringDelete = false;
  final deleted = await container
      .read(galleryProvider.notifier)
      .deleteResultsVerified(
        exclusive.toList(),
        canDelete: (id) {
          final valid =
              exclusive.contains(id) &&
              !hasGeneration() &&
              stores.albums.editRevision == revision &&
              matches();
          if (!valid) changedDuringDelete = true;
          return valid;
        },
      );
  // The ordinary image-removal path queues membership writes without surfacing
  // errors. Explicitly commit them here before deciding the album may disappear.
  if (deleted.isNotEmpty) {
    await container.read(albumsProvider.notifier).removeImages(deleted);
  }
  await stores.gallery.flushIndex();
  await stores.albums.idle;
  if (hasGeneration()) {
    return AlbumDeletionResult(AlbumDeletionStatus.generationPending, deleted);
  }
  if (changedDuringDelete || !matches(deletedIds: deleted)) {
    return AlbumDeletionResult(AlbumDeletionStatus.contentsChanged, deleted);
  }
  if (!setEquals(deleted, exclusive)) {
    return AlbumDeletionResult(AlbumDeletionStatus.filesRemain, deleted);
  }
  final beforeCommit = stores.albums.editRevision;
  final removed = await container
      .read(albumsProvider.notifier)
      .delete(
        plan.albumId,
        canDelete: (current) =>
            !hasGeneration() &&
            stores.albums.editRevision == beforeCommit + 1 &&
            plan.matches(
              current,
              container.read(galleryProvider).results,
              deletedIds: deleted,
            ),
      );
  return AlbumDeletionResult(
    removed
        ? AlbumDeletionStatus.deleted
        : hasGeneration()
        ? AlbumDeletionStatus.generationPending
        : AlbumDeletionStatus.contentsChanged,
    deleted,
  );
}
