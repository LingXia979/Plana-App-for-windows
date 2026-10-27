import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_summary.dart';
import 'package:plana_app/features/gallery/models.dart';

void main() {
  const one = ResultImage(id: 'one', width: 1, height: 1, seed: 1);
  const two = ResultImage(id: 'two', width: 1, height: 1, seed: 2);
  final data = AlbumsData(
    albums: const [
      GalleryAlbum(
        id: 'a',
        name: 'A',
        createdAt: 1,
        cover: AlbumCover('cover-a', sourceImageId: 'one'),
      ),
      GalleryAlbum(
        id: 'b',
        name: 'B',
        createdAt: 1,
        cover: AlbumCover('cover-b', sourceImageId: 'two'),
      ),
      GalleryAlbum(
        id: 'empty',
        name: 'Empty',
        createdAt: 1,
        cover: AlbumCover('missing-cover', sourceImageId: 'missing'),
      ),
      GalleryAlbum(
        id: 'uploaded',
        name: 'Uploaded',
        createdAt: 1,
        cover: AlbumCover('uploaded-cover'),
      ),
    ],
    memberships: const {
      'one': {'a', 'b'},
      'two': {'a', 'deleted-album'},
    },
    allPhotosCover: const AlbumCover('all-cover', sourceImageId: 'one'),
  );

  test('summaries preserve shared images, empty albums and cover sources', () {
    final summaries = summarizeAlbums(data, [one, two]);
    expect(summaries[null]!.count, 2);
    expect(summaries[null]!.first, same(one));
    expect(summaries[null]!.cover!.key, 'all-cover');
    expect(summaries['a']!.count, 2);
    expect(summaries['b']!.count, 1);
    expect(summaries['b']!.first, same(one));
    // A pinned cover remains valid while its source is in the global library.
    expect(summaries['b']!.cover!.sourceImageId, 'two');
    expect(summaries['empty'], (count: 0, first: null, cover: null));
    expect(summaries['uploaded']!.first, isNull);
    expect(summaries['uploaded']!.cover!.key, 'uploaded-cover');
    expect(summaries.containsKey('deleted-album'), isFalse);
  });

  test('deleting an image changes the fallback and invalidates its covers', () {
    final summaries = summarizeAlbums(data, [two]);
    expect(summaries[null]!.cover, isNull);
    expect(summaries[null]!.first, same(two));
    expect(summaries['a']!.count, 1);
    expect(summaries['a']!.first, same(two));
    expect(summaries['a']!.cover, isNull);
    expect(summaries['b']!.count, 0);
    expect(summaries['b']!.first, isNull);
    expect(summaries['uploaded']!.cover!.key, 'uploaded-cover');
  });
}
