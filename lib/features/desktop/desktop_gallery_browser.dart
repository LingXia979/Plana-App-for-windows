import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/albums/album_ui.dart' show AlbumCoverImage, showAlbumName;
import '../gallery/gallery_date_filter.dart';
import '../gallery/gallery_search.dart';
import '../gallery/gallery_state.dart';
import '../gallery/widgets/gallery_date_sheet.dart';
import '../gallery/widgets/gallery_grid_sheet.dart';
import '../gallery/widgets/gallery_output_folder_button.dart';
import '../generate/generation_controller.dart';
import 'desktop_album_menu.dart';
import 'desktop_library_state.dart';
import 'desktop_image_viewer.dart';

typedef DesktopGalleryLocation = ({bool overview, String? albumId});

final desktopGalleryLocationProvider =
    NotifierProvider<DesktopGalleryLocationNotifier, DesktopGalleryLocation>(
      DesktopGalleryLocationNotifier.new,
    );

class DesktopGalleryLocationNotifier extends Notifier<DesktopGalleryLocation> {
  @override
  DesktopGalleryLocation build() => (overview: true, albumId: null);
  void open(String? albumId, {bool overview = false}) =>
      state = (overview: overview, albumId: albumId);
}

class DesktopGalleryBrowser extends ConsumerStatefulWidget {
  const DesktopGalleryBrowser({super.key});
  @override
  ConsumerState<DesktopGalleryBrowser> createState() =>
      _DesktopGalleryBrowserState();
}

class _DesktopGalleryBrowserState extends ConsumerState<DesktopGalleryBrowser>
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  final _dateAnchor = GlobalKey();
  var _date = const GalleryDateFilter.all();
  final _albumMenu = DesktopAlbumMenuController();
  @override
  bool get wantKeepAlive => true;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(String? albumId) {
    // 同一个图库选择仍同时用于浏览和保存新图片。
    if (ref.read(desktopLibraryProvider).albumId != albumId) {
      ref.read(desktopLibraryProvider.notifier).choose(albumId);
      ref.read(generationProvider.notifier).select(null);
      ref.read(galleryResultPreviewProvider.notifier).clear();
    }
    ref.read(desktopGalleryLocationProvider.notifier).open(albumId);
  }

  Future<void> _createAlbum() async {
    final id = await showAlbumName(context);
    if (id == null || !mounted) return;
    // Returning to the overview must also reveal the newly created library,
    // even if its name or creation date does not match the previous filters.
    setState(() {
      _search.clear();
      _date = const GalleryDateFilter.all();
    });
    _open(id);
  }

  Future<void> _pickDate() async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final button = _dateAnchor.currentContext!.findRenderObject() as RenderBox;
    final origin = button.localToGlobal(Offset.zero, ancestor: overlay);
    final date = await showGalleryDateFilter(
      context,
      _date,
      desktop: true,
      menuPosition: RelativeRect.fromRect(
        Rect.fromLTWH(
          origin.dx,
          origin.dy + button.size.height + 4,
          button.size.width,
          0,
        ),
        Offset.zero & overlay.size,
      ),
    );
    if (date != null && mounted) setState(() => _date = date);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final location = ref.watch(desktopGalleryLocationProvider);
    final albums = ref.watch(albumsProvider);
    final title =
        albums.album(location.albumId)?.name ??
        (isDailyAlbum(location.albumId)
            ? location.albumId!.substring(4)
            : albums.name(location.albumId));
    if (!location.overview) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Material(
          key: const ValueKey('desktop-gallery-grid'),
          color: context.scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
            child: GalleryGridContent(
              key: ValueKey(
                'desktop-gallery-content-${location.albumId ?? 'all'}',
              ),
              desktop: true,
              embedded: true,
              browser: GalleryGridBrowser(
                albumId: location.albumId,
                title: title,
                onBack: () => ref
                    .read(desktopGalleryLocationProvider.notifier)
                    .open(null, overview: true),
                onOpenImage: (images, index) => showDesktopImageViewer(
                  context,
                  images: images,
                  index: index,
                  libraryName: title,
                  sourceAlbum: location.albumId,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final all = ref.watch(galleryProvider).results;
    final now = DateTime.now();
    final terms = searchTerms(_search.text);
    final entries = [
      (id: null, name: '全部作品', createdAt: all.firstOrNull?.createdAt ?? 0),
      for (final album in albums.albums)
        (id: album.id, name: album.name, createdAt: album.createdAt),
    ];
    final libraries = entries.where((entry) {
      final images = all.where((r) => albums.contains(entry.id, r.id));
      final timeMatch =
          _date.kind == GalleryDateKind.all ||
          images.any((r) => _date.matches(r.createdAt, now)) ||
          (images.isEmpty && _date.matches(entry.createdAt, now));
      return timeMatch && searchMatch(normalizeSearchText(entry.name), terms);
    }).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Material(
        key: const ValueKey('desktop-gallery-libraries'),
        color: context.scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    '图库',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${libraries.length} 个图库',
                    style: TextStyle(
                      color: context.scheme.outline,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: math.min(440, constraints.maxWidth),
                      child: TextField(
                        key: const ValueKey('desktop-gallery-search'),
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 20),
                          hintText: '搜索图库名称…',
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除搜索',
                                  onPressed: () => setState(_search.clear),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          key: _dateAnchor,
                          child: OutlinedButton.icon(
                            key: const ValueKey('desktop-gallery-date'),
                            onPressed: _pickDate,
                            icon: const Icon(
                              Icons.calendar_month_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _date.active ? _date.label(now) : '全部时间',
                            ),
                          ),
                        ),
                        const GalleryOutputFolderButton(),
                        TextButton.icon(
                          key: const ValueKey('desktop-gallery-create'),
                          style: TextButton.styleFrom(
                            backgroundColor: context.scheme.primary.withValues(
                              alpha: .08,
                            ),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            minimumSize: const Size(0, 36),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _createAlbum,
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 18,
                          ),
                          label: const Text('新建图库'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Expanded(
                child: libraries.isEmpty
                    ? Center(
                        child: Text(
                          '没有符合条件的图库',
                          style: TextStyle(color: context.scheme.outline),
                        ),
                      )
                    : GridView.builder(
                        key: const PageStorageKey(
                          'desktop-library-grid-overview',
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 245,
                              childAspectRatio: .9,
                              mainAxisSpacing: 18,
                              crossAxisSpacing: 18,
                            ),
                        itemCount: libraries.length,
                        itemBuilder: (context, i) {
                          final entry = libraries[i];
                          final members = all
                              .where((r) => albums.contains(entry.id, r.id))
                              .toList();
                          return _GalleryTile(
                            key: ValueKey(
                              'desktop-library-card-${entry.id ?? 'all'}',
                            ),
                            albumId: entry.id,
                            title: entry.name,
                            detail: '${members.length} 张作品',
                            onTap: () => _open(entry.id),
                            onSecondaryTapDown: (details) => _albumMenu.show(
                              context,
                              entry.id,
                              details.globalPosition,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    super.key,
    this.albumId,
    required this.title,
    required this.detail,
    required this.onTap,
    required this.onSecondaryTapDown,
  });
  final String? albumId;
  final String title, detail;
  final VoidCallback onTap;
  final GestureTapDownCallback onSecondaryTapDown;
  @override
  Widget build(BuildContext context) => Material(
    color: context.scheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: context.scheme.outlineVariant.withValues(alpha: .6),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: AlbumCoverImage(
                albumId: albumId,
                fallbackFit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: context.scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              style: TextStyle(fontSize: 11, color: context.scheme.outline),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    ),
  );
}
