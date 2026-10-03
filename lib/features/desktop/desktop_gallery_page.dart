import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/albums/album_ui.dart' show AlbumCoverImage, showAlbumName;
import '../gallery/gallery_state.dart';
import 'desktop_gallery_browser.dart';
import '../gallery/widgets/gallery_grid_sheet.dart';
import '../generate/generation_controller.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../inpaint/inpaint_overlay.dart' show inpaintSessionProvider;
import '../shell/shell_state.dart';
import 'desktop_album_menu.dart';
import 'desktop_library_state.dart';

void returnToDesktopCreation(WidgetRef ref) =>
    ref.read(shellIndexProvider.notifier).select(kTabCreate);

void openDesktopGallery(WidgetRef ref, {bool currentLibrary = false}) {
  ref.read(desktopLibraryProvider.notifier).refreshDay();
  ref
      .read(desktopGalleryLocationProvider.notifier)
      .open(
        currentLibrary ? ref.read(desktopLibraryProvider).albumId : null,
        overview: !currentLibrary,
      );
  ref.read(shellIndexProvider.notifier).select(kTabGallery);
}

Future<void> showDesktopLibraryPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  if (ref.read(inpaintSessionProvider) != null) {
    hintSnack(context, '结束重绘后可切换图库');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => const _DesktopLibraryPicker(),
  );
}

class DesktopGalleryPage extends StatelessWidget {
  const DesktopGalleryPage({super.key});
  @override
  Widget build(BuildContext context) => const DesktopGalleryBrowser();
}

class DesktopLibraryButton extends ConsumerWidget {
  const DesktopLibraryButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(desktopLibraryProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: TextButton.icon(
            key: const ValueKey('desktop-library-picker'),
            style: TextButton.styleFrom(
              backgroundColor: context.scheme.primary.withValues(alpha: .08),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 36),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => showDesktopLibraryPicker(context, ref),
            icon: Icon(
              selection.automatic
                  ? Icons.calendar_month_outlined
                  : Icons.photo_library_outlined,
              size: 16,
            ),
            label: Text(
              '切换图库',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelMedium!.copyWith(
                color: context.scheme.primary,
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('desktop-history-browse'),
          tooltip:
              '快速浏览与批量导出 · ${desktopLibraryLabel(selection, ref.watch(albumsProvider))}',
          onPressed: () => showGalleryGrid(
            context,
            desktop: true,
            onChooseAlbum: showDesktopLibraryPicker,
          ),
          icon: const Icon(Icons.expand_less, size: 18),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _DesktopLibraryPicker extends ConsumerStatefulWidget {
  const _DesktopLibraryPicker();

  @override
  ConsumerState<_DesktopLibraryPicker> createState() =>
      _DesktopLibraryPickerState();
}

class _DesktopLibraryPickerState extends ConsumerState<_DesktopLibraryPicker> {
  final _albumMenu = DesktopAlbumMenuController();

  void _choose(
    BuildContext context,
    WidgetRef ref,
    String? id, {
    bool automatic = false,
  }) {
    ref.read(desktopLibraryProvider.notifier).choose(id, automatic: automatic);
    ref.read(generationProvider.notifier).select(null);
    ref.read(galleryResultPreviewProvider.notifier).clear();
    final images = ref.read(galleryViewProvider).results;
    final selected = ref.read(galleryProvider).selectedId;
    if (!images.any((r) => r.id == selected)) {
      ref.read(galleryProvider.notifier).select(images.firstOrNull?.id);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(desktopLibraryProvider);
    final albums = ref.watch(albumsProvider);
    final all = ref.watch(galleryProvider).results;
    final choices = [
      (
        id: 'auto',
        name: '按日期自动',
        detail: selection.day,
        scope: 'day_${selection.day}',
      ),
      (id: '', name: '全部作品', detail: '查看所有图片', scope: null),
      for (final a in albums.albums)
        (id: a.id, name: a.name, detail: '浏览并保存到这里', scope: a.id),
    ];
    return Dialog(
      child: SizedBox(
        key: const ValueKey('desktop-library-dialog'),
        width: 740,
        height: 540,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择图库',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('desktop-new-album'),
                    onPressed: () async {
                      final id = await showAlbumName(context);
                      if (id != null && context.mounted) {
                        _choose(context, ref, id);
                      }
                    },
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('新建图库'),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('当前图库同时用于浏览和保存新图。', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 205,
                    childAspectRatio: .93,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: choices.length,
                  itemBuilder: (_, i) {
                    final entry = choices[i];
                    final images = all
                        .where((r) => albums.contains(entry.scope, r.id))
                        .toList();
                    final active = selection.choice == entry.id;
                    return Material(
                      color: active
                          ? context.scheme.primaryContainer
                          : context.scheme.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: active
                              ? context.scheme.primary
                              : context.scheme.outlineVariant,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: ValueKey('desktop-album-${entry.id}'),
                        onSecondaryTapDown: entry.id == 'auto'
                            ? null
                            : (details) => _albumMenu.show(
                                context,
                                entry.scope,
                                details.globalPosition,
                              ),
                        onTap: () => _choose(
                          context,
                          ref,
                          entry.scope,
                          automatic: entry.id == 'auto',
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child:
                                    entry.id == 'auto' &&
                                        images.isEmpty &&
                                        albums.cover(entry.scope) == null
                                    ? Icon(
                                        Icons.calendar_month_outlined,
                                        size: 36,
                                        color: context.scheme.primary,
                                      )
                                    : AlbumCoverImage(albumId: entry.scope),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${images.length} 张 · ${entry.detail}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
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
