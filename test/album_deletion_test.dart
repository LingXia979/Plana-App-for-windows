import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_deletion.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_search.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/generate/gen_jobs.dart';
import 'package:plana_app/features/generate/generation_controller.dart';

class _Search extends GallerySearchNotifier {
  @override
  GallerySearchState build() => const GallerySearchState(byId: {});
}

class _Jobs extends GenerationNotifier {
  @override
  GenPool build() => const GenPool();

  void target(String albumId) => state = GenPool(
    jobs: [
      GenJob(
        id: 'pending',
        kind: GenJobKind.normal,
        stage: GenJobStage.saving,
        width: 64,
        height: 64,
        seq: 1,
        galleryTarget: GallerySaveTarget.album(albumId),
      ),
    ],
  );
}

class _Gallery extends GalleryNotifier {
  bool pauseBefore = false, pauseAfter = false;
  int deleteCalls = 0;
  final before = Completer<void>(), resumeBefore = Completer<void>();
  final after = Completer<void>(), resumeAfter = Completer<void>();

  @override
  Future<Set<String>> deleteResultsVerified(
    List<String> ids, {
    bool Function(String id)? canDelete,
  }) async {
    deleteCalls++;
    if (pauseBefore) {
      before.complete();
      await resumeBefore.future;
    }
    final deleted = await super.deleteResultsVerified(
      ids,
      canDelete: canDelete,
    );
    if (pauseAfter) {
      after.complete();
      await resumeAfter.future;
    }
    return deleted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStores stores;
  late ProviderContainer container;
  late _Gallery gallery;
  late _Jobs jobs;
  final png = Uint8List.fromList(
    img.encodePng(img.Image(width: 64, height: 64)),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana_album_delete_');
    stores = await AppStores.open(rootOverride: root);
    final images = [
      for (final id in ['one', 'second', 'shared', 'other'])
        ResultImage(id: id, width: 64, height: 64, seed: 1, bytes: png),
    ];
    for (final image in images) {
      await stores.gallery.persistResult(image);
    }
    stores.gallery.scheduleIndex(results: images, selectedId: 'one', seq: 10);
    await stores.gallery.flushIndex();
    await stores.albums.update(
      (_) => AlbumsData(
        albums: const [
          GalleryAlbum(id: 'a', name: 'Target', createdAt: 1),
          GalleryAlbum(id: 'b', name: 'Other', createdAt: 1),
          GalleryAlbum(id: 'empty', name: 'Empty', createdAt: 1),
        ],
        memberships: {
          'one': {'a'},
          'second': {'a'},
          'shared': {'a', 'b'},
          'other': {'b'},
        },
      ),
    );
    gallery = _Gallery();
    jobs = _Jobs();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        galleryProvider.overrideWith(() => gallery),
        gallerySearchProvider.overrideWith(_Search.new),
        generationProvider.overrideWith(() => jobs),
      ],
    );
    container.read(galleryProvider);
    container.read(generationProvider);
  });

  tearDown(() async {
    container.dispose();
    stores.flushNow();
    await Future.wait([
      stores.gallery.idle,
      stores.albums.idle,
      stores.workspace.idle,
      stores.assistant.idle,
      stores.prefs.write(key: 'test_fixture_drained', value: 'true'),
    ]);
    await root.delete(recursive: true);
  });

  AlbumDeletionPlan plan([String album = 'a']) => AlbumDeletionPlan.capture(
    albumId: album,
    albums: container.read(albumsProvider),
    images: container.read(galleryProvider).results,
  );
  bool exists(String id) =>
      File('${root.path}/gallery/images/$id.png').existsSync();

  Future<String> addImage() async {
    final image = gallery.addResult(
      bytes: png,
      width: 64,
      height: 64,
      seed: 22,
    );
    await stores.gallery.idle;
    await container.read(albumsProvider.notifier).organize({image.id}, {'a'});
    await stores.gallery.flushIndex();
    return image.id;
  }

  test(
    'deletes every exclusive image while retaining shared images and the base view',
    () async {
      final confirmed = plan();
      expect(confirmed.exclusiveIds, {'one', 'second'});
      expect(confirmed.sharedIds, {'shared'});
      final result = await deleteGalleryAlbum(container, confirmed);
      expect(result.status, AlbumDeletionStatus.deleted);
      expect(result.deletedIds, {'one', 'second'});
      expect(exists('one'), isFalse);
      expect(exists('second'), isFalse);
      expect(exists('shared'), isTrue);
      expect(exists('other'), isTrue);
      expect(container.read(galleryProvider).results.map((r) => r.id), [
        'shared',
        'other',
      ]);
      expect(container.read(albumsProvider).exists('a'), isFalse);
      expect(container.read(albumsProvider).exists(null), isTrue);
      expect(container.read(albumsProvider).ofImage('shared'), {'b'});
      final restored = await AppStores.open(rootOverride: root);
      expect(restored.gallery.initialResults.map((r) => r.id), [
        'shared',
        'other',
      ]);
      expect(restored.albums.data.exists('a'), isFalse);
    },
  );

  test(
    'a failed second file retains the album and its failed and shared members',
    () async {
      final original = File('${root.path}/gallery/images/second.png');
      await original.delete();
      await Directory(original.path).create();
      final result = await deleteGalleryAlbum(container, plan());
      expect(result.status, AlbumDeletionStatus.filesRemain);
      expect(result.deletedIds, {'one'});
      expect(container.read(albumsProvider).exists('a'), isTrue);
      expect(container.read(albumsProvider).ofImage('second'), {'a'});
      expect(container.read(albumsProvider).ofImage('shared'), {'a', 'b'});
      expect(container.read(galleryProvider).results.map((r) => r.id), [
        'second',
        'shared',
        'other',
      ]);
    },
  );

  test('an empty album may be removed without deleting any picture', () async {
    final result = await deleteGalleryAlbum(container, plan('empty'));
    expect(result.albumDeleted, isTrue);
    expect(result.deletedIds, isEmpty);
    expect(container.read(galleryProvider).results, hasLength(4));
    expect(container.read(albumsProvider).exists('empty'), isFalse);
  });

  test(
    'a new shared membership after confirmation prevents destructive work',
    () async {
      final confirmed = plan();
      await container.read(albumsProvider.notifier).organize({'one'}, {'b'});
      final result = await deleteGalleryAlbum(container, confirmed);
      expect(result.status, AlbumDeletionStatus.contentsChanged);
      expect(result.deletedIds, isEmpty);
      expect(gallery.deleteCalls, 0);
      expect(exists('one'), isTrue);
      expect(container.read(albumsProvider).ofImage('one'), {'a', 'b'});
    },
  );

  test(
    'a formerly shared image never becomes a newly authorized deletion candidate',
    () async {
      final confirmed = plan();
      await container.read(albumsProvider.notifier).delete('b');
      final result = await deleteGalleryAlbum(container, confirmed);
      expect(result.status, AlbumDeletionStatus.contentsChanged);
      expect(result.deletedIds, isEmpty);
      expect(exists('shared'), isTrue);
      expect(container.read(albumsProvider).exists('a'), isTrue);
    },
  );

  test(
    'new images after confirmation are preserved with their container',
    () async {
      final confirmed = plan();
      final added = await addImage();
      final result = await deleteGalleryAlbum(container, confirmed);
      expect(result.status, AlbumDeletionStatus.contentsChanged);
      expect(result.deletedIds, isEmpty);
      expect(exists(added), isTrue);
      expect(container.read(albumsProvider).contains('a', added), isTrue);
    },
  );

  test(
    'targeted saving jobs protect the album while unrelated jobs do not',
    () async {
      jobs.target('a');
      final blocked = await deleteGalleryAlbum(container, plan());
      expect(blocked.status, AlbumDeletionStatus.generationPending);
      expect(gallery.deleteCalls, 0);
      jobs.target('b');
      final allowed = await deleteGalleryAlbum(container, plan());
      expect(allowed.albumDeleted, isTrue);
      expect(exists('other'), isTrue);
    },
  );

  test(
    'membership queued while the captured idle tail runs is never treated as a settled baseline',
    () async {
      final confirmed = plan();
      final entered = Completer<void>();
      final firstWrite = stores.albums.update((data) {
        entered.complete();
        return data.copyWith();
      });
      final deleting = deleteGalleryAlbum(container, confirmed);
      await entered.future;
      final sharing = container
          .read(albumsProvider.notifier)
          .organize({'one'}, {'b'});
      await firstWrite;
      final result = await deleting;
      await sharing;
      expect(result.status, AlbumDeletionStatus.contentsChanged);
      expect(gallery.deleteCalls, 0);
      expect(exists('one'), isTrue);
      expect(container.read(albumsProvider).ofImage('one'), {'a', 'b'});
    },
  );

  test(
    'a pending membership write invalidates the final file deletion guard',
    () async {
      gallery.pauseBefore = true;
      final deleting = deleteGalleryAlbum(container, plan());
      await gallery.before.future;
      final revision = stores.albums.editRevision;
      final sharing = container
          .read(albumsProvider.notifier)
          .organize({'one'}, {'b'});
      expect(stores.albums.editRevision, revision + 1);
      gallery.resumeBefore.complete();
      final result = await deleting;
      await sharing;
      expect(result.status, AlbumDeletionStatus.contentsChanged);
      expect(result.deletedIds, isEmpty);
      expect(exists('one'), isTrue);
      expect(exists('second'), isTrue);
      expect(container.read(albumsProvider).exists('a'), isTrue);
    },
  );

  test(
    'late results after PNG deletion keep the target container and their new files',
    () async {
      gallery.pauseAfter = true;
      final deleting = deleteGalleryAlbum(container, plan());
      await gallery.after.future;
      final added = await addImage();
      gallery.resumeAfter.complete();
      final result = await deleting;
      expect(result.status, AlbumDeletionStatus.contentsChanged);
      expect(result.deletedIds, {'one', 'second'});
      expect(exists(added), isTrue);
      expect(container.read(albumsProvider).contains('a', added), isTrue);
      expect(container.read(albumsProvider).ofImage('shared'), {'a', 'b'});
    },
  );

  test(
    'a generation started during deletion keeps the still-needed album',
    () async {
      gallery.pauseAfter = true;
      final deleting = deleteGalleryAlbum(container, plan());
      await gallery.after.future;
      jobs.target('a');
      gallery.resumeAfter.complete();
      final result = await deleting;
      expect(result.status, AlbumDeletionStatus.generationPending);
      expect(container.read(albumsProvider).exists('a'), isTrue);
      expect(exists('shared'), isTrue);
    },
  );

  test(
    'container deletion guard observes preceding queued memberships and reports rejection',
    () async {
      final confirmed = plan('empty');
      final sharing = container
          .read(albumsProvider.notifier)
          .organize({'other'}, {'empty'});
      final deleting = container
          .read(albumsProvider.notifier)
          .delete(
            'empty',
            canDelete: (current) => confirmed.matches(
              current,
              container.read(galleryProvider).results,
            ),
          );
      await sharing;
      expect(await deleting, isFalse);
      expect(container.read(albumsProvider).contains('empty', 'other'), isTrue);
      expect(exists('other'), isTrue);
    },
  );

  test(
    'read-only album storage prevents any original image deletion',
    () async {
      final confirmed = plan();
      stores.albums.readOnly = true;
      await expectLater(
        deleteGalleryAlbum(container, confirmed),
        throwsStateError,
      );
      expect(gallery.deleteCalls, 0);
      expect(exists('one'), isTrue);
      expect(exists('second'), isTrue);
    },
  );
}
