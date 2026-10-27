import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/gallery/gallery_date_filter.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/widgets/gallery_grid_logic.dart';

void main() {
  final now = DateTime(2026, 10, 21, 12);
  final images = [
    ResultImage(
      id: 'current',
      width: 1,
      height: 1,
      seed: 42,
      createdAt: now.millisecondsSinceEpoch,
      favorite: true,
    ),
    ResultImage(
      id: 'older',
      width: 1,
      height: 1,
      seed: 77,
      createdAt: now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
    ),
    ResultImage(
      id: 'unindexed',
      width: 1,
      height: 1,
      seed: 99,
      createdAt: now.millisecondsSinceEpoch,
    ),
  ];
  final byId = <String, GallerySearchMeta>{
    'current': (model: 'Model A', text: 'cat outdoors'),
    'older': (model: 'Model B', text: 'cat indoors'),
  };

  test('selection follows visible images and blocks actions while saving', () {
    final selection = GalleryGridSelection()..enter('current');
    selection.toggleGroup(['current', 'older']);
    expect(selection.picked, {'current', 'older'});
    selection.toggleGroup(['current', 'older']);
    expect(selection.picked, isEmpty);
    selection.toggleAll(images);
    selection.retainVisible([images.first]);
    expect(selection.picked, {'current'});
    expect(
      selection.canAct(
        saving: false,
        sharing: false,
        zipping: false,
        organizing: false,
      ),
      isTrue,
    );
    expect(
      selection.canAct(
        saving: true,
        sharing: false,
        zipping: false,
        organizing: false,
      ),
      isFalse,
    );
    selection.exit();
    expect(selection.selecting, isFalse);
    expect(selection.picked, isEmpty);
  });

  test('date, model, favorites and indexed search intersect', () {
    final filtered = filterGalleryImages(
      images: images,
      date: const GalleryDateFilter(GalleryDateKind.today),
      now: now,
      byId: byId,
      query: 'cat outdoors',
      model: 'Model A',
      favoritesOnly: true,
    );
    expect(filtered.map((image) => image.id), ['current']);
    expect(
      filterGalleryImages(
        images: images,
        date: const GalleryDateFilter.all(),
        now: now,
        byId: byId,
        query: 'unindexed 99',
        model: null,
      ),
      isEmpty,
    );
    expect(
      filterGalleryImages(
        images: images,
        date: const GalleryDateFilter.all(),
        now: now,
        byId: byId,
        query: 'unindexed 99',
        model: null,
        includeImageDetails: true,
      ).map((image) => image.id),
      ['unindexed'],
    );
  });

  test('model choices count the full collection including unknown models', () {
    expect(galleryModelFilterOptions(images, byId), [
      ('全部', null, null),
      ('Model A', 'Model A', 1),
      ('Model B', 'Model B', 1),
      ('未知', '', 1),
    ]);
  });
}
