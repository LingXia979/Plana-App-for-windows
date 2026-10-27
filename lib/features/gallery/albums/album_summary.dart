import '../models.dart';
import 'album_models.dart';

typedef AlbumSummary = ({int count, ResultImage? first, AlbumCover? cover});

/// Resolve counts and covers together, including known empty albums.
Map<String?, AlbumSummary> summarizeAlbums(
  AlbumsData data,
  List<ResultImage> images,
) {
  final counts = {for (final album in data.albums) album.id: 0};
  final first = <String, ResultImage>{};
  final imageIds = <String>{};
  for (final image in images) {
    imageIds.add(image.id);
    for (final id in data.ofImage(image.id)) {
      if (!counts.containsKey(id)) continue;
      counts[id] = counts[id]! + 1;
      first[id] ??= image;
    }
  }

  AlbumCover? validCover(AlbumCover? cover) =>
      cover != null &&
          (cover.sourceImageId == null ||
              imageIds.contains(cover.sourceImageId))
      ? cover
      : null;

  return Map.unmodifiable(<String?, AlbumSummary>{
    null: (
      count: images.length,
      first: images.firstOrNull,
      cover: validCover(data.allPhotosCover),
    ),
    for (final album in data.albums)
      album.id: (
        count: counts[album.id]!,
        first: first[album.id],
        cover: validCover(album.cover),
      ),
  });
}
