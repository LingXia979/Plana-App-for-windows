import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../../core/platform/desktop.dart';
import '../../desktop/desktop_library_state.dart';
import '../../../core/store/ui_prefs.dart';
import '../../generate/generation_controller.dart';
import '../gallery_state.dart';
import 'album_models.dart';

final albumsProvider = NotifierProvider<AlbumsNotifier, AlbumsData>(
  AlbumsNotifier.new,
);

final galleryBrowseAlbumProvider = Provider<String?>((ref) {
  if (ref.watch(desktopModeProvider)) {
    final selection = ref.watch(desktopLibraryProvider);
    final id = selection.albumId;
    if (selection.automatic) return id;
    return ref.watch(albumsProvider).exists(id) ? id : null;
  }
  final id = ref.watch(uiPrefsProvider).galleryBrowseAlbum;
  return id.isEmpty || !ref.watch(albumsProvider).exists(id) ? null : id;
});

final gallerySaveTargetProvider = Provider<GallerySaveTarget>((ref) {
  if (ref.watch(desktopModeProvider)) {
    final selection = ref.watch(desktopLibraryProvider);
    final captured = selection.capture(DateTime.now());
    return selection.automatic ||
            ref.watch(albumsProvider).exists(captured.albumId)
        ? captured
        : const GallerySaveTarget.all();
  }
  final id = ref.watch(uiPrefsProvider).gallerySaveAlbum;
  return id.isEmpty || !ref.watch(albumsProvider).exists(id)
      ? const GallerySaveTarget.all()
      : GallerySaveTarget.album(id);
});

/// 全量结果留在 galleryProvider；这里只派生浏览集合。
final galleryViewProvider = Provider<GalleryState>((ref) {
  final all = ref.watch(galleryProvider);
  final scope = ref.watch(galleryBrowseAlbumProvider);
  final albums = ref.watch(albumsProvider);
  final images = scope == null
      ? all.results
      : all.results.where((r) => albums.contains(scope, r.id)).toList();
  final id = images.any((r) => r.id == all.selectedId)
      ? all.selectedId
      : images.firstOrNull?.id;
  return GalleryState(results: images, selectedId: id);
});

final albumCoverProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, key) => ref.watch(appStoresProvider).albums.readCover(key),
    );

class GalleryResultPreview {
  const GalleryResultPreview(this.imageId, this.target);
  final String imageId;
  final GallerySaveTarget target;
}

final galleryResultPreviewProvider =
    NotifierProvider<GalleryResultPreviewNotifier, GalleryResultPreview?>(
      GalleryResultPreviewNotifier.new,
    );

/// 后台结果的轻提示；点击查看才打开临时预览，不自动切库。
final gallerySavedNoticeProvider =
    NotifierProvider<GalleryResultPreviewNotifier, GalleryResultPreview?>(
      GalleryResultPreviewNotifier.new,
    );

class GalleryResultPreviewNotifier extends Notifier<GalleryResultPreview?> {
  @override
  GalleryResultPreview? build() => null;
  void show(String id, GallerySaveTarget target) =>
      state = GalleryResultPreview(id, target);
  void clear() => state = null;
}

class AlbumsNotifier extends Notifier<AlbumsData> {
  final _lastSelected = <String, String>{};
  @override
  AlbumsData build() => ref.watch(appStoresProvider).albums.data;
  Set<String> get _live => {
    for (final r in ref.read(galleryProvider).results) r.id,
  };

  /// Created only after the first successful image save. The store serializes
  /// updates, so parallel generations share one date album.
  Future<void> ensureDailyAlbum(String id) async {
    if (!isDailyAlbum(id)) throw ArgumentError.value(id, 'id');
    if (state.exists(id)) return;
    await _edit(
      (d) => d.exists(id)
          ? d
          : d.copyWith(
              albums: [
                GalleryAlbum(
                  id: id,
                  name: id.substring(4),
                  createdAt: DateTime.now().millisecondsSinceEpoch,
                ),
                ...d.albums,
              ],
            ),
    );
  }

  Future<void> _edit(
    AlbumsData Function(AlbumsData) change, {
    bool reset = false,
  }) async {
    final store = ref.read(appStoresProvider).albums;
    await store.update(change, reset: reset);
    if (ref.mounted) state = store.data;
  }

  void _validateName(String name, {String? except}) {
    if (name.isEmpty || name.characters.length > 40) {
      throw StateError('请输入 1–40 个字符的图库名称');
    }
    if (name == allPhotosName ||
        state.albums.any((a) => a.id != except && a.name == name)) {
      throw StateError('这个图库名称已存在');
    }
  }

  Future<String> create(String name) async {
    name = name.trim();
    _validateName(name);
    final id = ref.read(appStoresProvider).albums.newId();
    await _edit((d) {
      if (d.albums.any((a) => a.name == name)) throw StateError('这个图库名称已存在');
      return d.copyWith(
        albums: [
          GalleryAlbum(
            id: id,
            name: name,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
          ...d.albums,
        ],
      );
    });
    return id;
  }

  Future<void> rename(String id, String name) async {
    name = name.trim();
    _validateName(name, except: id);
    await _edit((d) {
      if (!d.exists(id)) throw StateError('图库已被删除');
      if (d.albums.any((a) => a.id != id && a.name == name)) {
        throw StateError('这个图库名称已存在');
      }
      return d.copyWith(
        albums: [
          for (final a in d.albums) a.id == id ? a.copyWith(name: name) : a,
        ],
      );
    });
  }

  Future<bool> delete(
    String id, {
    bool Function(AlbumsData current)? canDelete,
  }) async {
    var accepted = true;
    await _edit((d) {
      if (canDelete?.call(d) == false) {
        accepted = false;
        return d;
      }
      return d.deleteAlbum(id);
    });
    if (!accepted || !ref.mounted) return accepted;
    final prefs = ref.read(uiPrefsProvider);
    if (prefs.galleryBrowseAlbum == id) browse(null);
    if (prefs.gallerySaveAlbum == id) setSave(null);
    _lastSelected.remove(id);
    return true;
  }

  void browse(String? id, {bool alsoSave = false}) {
    if (!state.exists(id)) throw StateError('图库已被删除');
    if (ref.read(desktopModeProvider)) {
      ref.read(desktopLibraryProvider.notifier).choose(id);
    }
    final savedScope = ref.read(uiPrefsProvider).galleryBrowseAlbum;
    final old = savedScope.isEmpty || !state.exists(savedScope)
        ? null
        : savedScope;
    final all = ref.read(galleryProvider);
    final oldImages = all.results.where((r) => state.contains(old, r.id));
    final selected = oldImages.any((r) => r.id == all.selectedId)
        ? all.selectedId
        : oldImages.firstOrNull?.id;
    if (selected != null) _lastSelected[old ?? ''] = selected;
    final images = ref
        .read(galleryProvider)
        .results
        .where((r) => state.contains(id, r.id));
    final candidate = selected != null && state.contains(id, selected)
        ? selected
        : _lastSelected[id ?? ''];
    final next = images.any((r) => r.id == candidate)
        ? candidate
        : images.firstOrNull?.id;
    ref.read(generationProvider.notifier).select(null);
    ref.read(galleryResultPreviewProvider.notifier).clear();
    ref
        .read(uiPrefsProvider.notifier)
        .patch(
          (p) => p.copyWith(
            galleryBrowseAlbum: id ?? '',
            gallerySaveAlbum: alsoSave ? id ?? '' : null,
          ),
        );
    ref.read(galleryProvider.notifier).select(next);
  }

  void setSave(String? id) {
    if (!state.exists(id)) throw StateError('图库已被删除');
    if (ref.read(desktopModeProvider)) {
      browse(id, alsoSave: true);
      return;
    }
    ref
        .read(uiPrefsProvider.notifier)
        .patch((p) => p.copyWith(gallerySaveAlbum: id ?? ''));
  }

  GalleryImportOrigin origin(String imageId) {
    final savedScope = ref.read(uiPrefsProvider).galleryBrowseAlbum;
    final scope = savedScope.isEmpty || !state.exists(savedScope)
        ? null
        : savedScope;
    return GalleryImportOrigin(
      imageId: imageId,
      albumId: state.contains(scope, imageId) ? scope : null,
    );
  }

  List<GalleryAlbum> importCandidates(GalleryImportOrigin origin) {
    if (!_live.contains(origin.imageId)) return const [];
    return state.albums
        .where(
          (a) =>
              state.contains(a.id, origin.imageId) &&
              (origin.albumId == null || origin.albumId == a.id),
        )
        .toList();
  }

  String? applyImportChoice(
    GalleryImportOrigin? origin,
    ImportAlbumChoice choice, {
    bool canBrowse = true,
  }) {
    if (!choice.enabled || origin == null || choice.target == null) return null;
    if (!canBrowse) return '结束编辑后可切换图库，已沿用当前图库';
    final candidates = importCandidates(origin);
    final id = choice.target!.albumId;
    final allowed =
        _live.contains(origin.imageId) &&
        (id == null
            ? origin.albumId == null && candidates.isEmpty
            : candidates.any((a) => a.id == id));
    if (!allowed) return '图片所属图库已变化，已沿用当前图库';
    browse(id, alsoSave: choice.alsoSave);
    return '浏览图库：${state.name(id)}${choice.alsoSave ? ' · 新图也保存到这里' : ''}';
  }

  Future<AlbumChange> organize(
    Set<String> images,
    Set<String> targets, {
    Set<String>? sources,
  }) async {
    late AlbumChange change;
    await _edit((d) {
      final live = images.intersection(_live);
      final next = d.organize(live, targets, sources: sources);
      change = AlbumChange(d, next, live);
      return next;
    });
    return change;
  }

  Future<void> undo(AlbumChange change) => _edit((d) => change.undo(d, _live));

  Future<GalleryTransferChange> transfer(
    Set<String> images,
    Set<String> targets, {
    required bool copy,
    String? sourceAlbum,
  }) async {
    if (targets.isEmpty || (!copy && targets.length != 1)) {
      throw StateError('请选择目标图库');
    }
    if (copy) {
      return GalleryTransferChange.copied(
        await ref
            .read(galleryProvider.notifier)
            .copyResults(images, targets, sourceAlbum: sourceAlbum),
      );
    }
    final target = targets.single;
    late AlbumChange change;
    await _edit((d) {
      if (!d.exists(target) || !d.exists(sourceAlbum)) {
        throw StateError('图库已不存在，请重新选择');
      }
      if (target == sourceAlbum) throw StateError('请选择另一个图库');
      final live = images
          .intersection(_live)
          .where((id) => d.contains(sourceAlbum, id))
          .toSet();
      final memberships = {...d.memberships};
      for (final id in live) {
        final albums = {...d.ofImage(id)};
        // Moving keeps the image identity. Copying above creates new identities.
        sourceAlbum == null ? albums.clear() : albums.remove(sourceAlbum);
        albums.add(target);
        memberships[id] = albums;
      }
      final next = d.copyWith(memberships: memberships);
      change = AlbumChange(d, next, live);
      return next;
    });
    return GalleryTransferChange.moved(change);
  }

  Future<void> placeCopies(
    Map<String, String> destinations, {
    required Set<String> sources,
    required String? sourceAlbum,
  }) => _edit((d) {
    if (!d.exists(sourceAlbum) ||
        !destinations.values.every(d.exists) ||
        !sources.every(
          (id) => _live.contains(id) && d.contains(sourceAlbum, id),
        ) ||
        !destinations.keys.every(_live.contains)) {
      throw StateError('来源图片或目标图库已变化，请重新复制');
    }
    return d.copyWith(
      memberships: {
        ...d.memberships,
        for (final e in destinations.entries) e.key: {e.value},
      },
    );
  });

  Future<void> undoTransfer(GalleryTransferChange change) async {
    if (change.memberships case final AlbumChange memberships) {
      await undo(memberships);
    } else {
      final deleted = await ref
          .read(galleryProvider.notifier)
          .deleteResultsVerified(change.copiedIds.toList());
      if (ref.mounted &&
          change.copiedIds.difference(deleted).any(_live.contains)) {
        throw StateError('部分副本未能删除，请稍后重试');
      }
    }
  }

  Future<void> removeImages(Set<String> ids) =>
      _edit((d) => d.removeImages(ids));

  Future<void> clearAll() async {
    await _edit((_) => AlbumsData(), reset: true);
    if (!ref.mounted) return;
    _lastSelected.clear();
    ref.read(galleryResultPreviewProvider.notifier).clear();
    ref
        .read(uiPrefsProvider.notifier)
        .patch((p) => p.copyWith(galleryBrowseAlbum: '', gallerySaveAlbum: ''));
  }

  Future<void> setCover(
    String? id,
    Uint8List? png, {
    String? sourceImageId,
  }) async {
    final store = ref.read(appStoresProvider).albums;
    await store.setCover(
      id,
      png,
      sourceImageId: sourceImageId,
      imageExists: (image) => ref.mounted && _live.contains(image),
    );
    if (ref.mounted) state = store.data;
  }
}
