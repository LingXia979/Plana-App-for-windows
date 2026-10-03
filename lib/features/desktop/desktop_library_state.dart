import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/store/date_album.dart';
import '../gallery/albums/album_models.dart';
export '../../core/store/date_album.dart';

class DesktopLibrarySelection {
  const DesktopLibrarySelection({this.choice = 'auto', required this.day});

  /// auto = follow local calendar; empty = all pictures; otherwise album ID.
  final String choice;
  final String day;
  bool get automatic => choice == 'auto';
  String? get albumId => automatic
      ? 'day_$day'
      : choice.isEmpty
      ? null
      : choice;

  GallerySaveTarget capture(DateTime now) {
    final id = automatic ? dailyAlbumId(now) : albumId;
    return id == null
        ? const GallerySaveTarget.all()
        : GallerySaveTarget.album(id);
  }
}

final desktopLibraryProvider =
    NotifierProvider<DesktopLibraryNotifier, DesktopLibrarySelection>(
      DesktopLibraryNotifier.new,
    );

class DesktopLibraryNotifier extends Notifier<DesktopLibrarySelection> {
  Timer? _midnight;
  @override
  DesktopLibrarySelection build() {
    final choice =
        ref.read(prefsStoreProvider).get('desktop_gallery_choice') ?? 'auto';
    _scheduleMidnight();
    ref.onDispose(() => _midnight?.cancel());
    return DesktopLibrarySelection(
      choice: choice,
      day: desktopDayKey(DateTime.now()),
    );
  }

  void _scheduleMidnight() {
    _midnight?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now) + const Duration(seconds: 1), () {
      if (!ref.mounted) return;
      refreshDay();
      _scheduleMidnight();
    });
  }

  void refreshDay() {
    final day = desktopDayKey(DateTime.now());
    if (day != state.day) {
      state = DesktopLibrarySelection(choice: state.choice, day: day);
    }
  }

  void choose(String? albumId, {bool automatic = false}) {
    final choice = automatic ? 'auto' : albumId ?? '';
    state = DesktopLibrarySelection(
      choice: choice,
      day: desktopDayKey(DateTime.now()),
    );
    unawaited(
      ref
          .read(prefsStoreProvider)
          .write(key: 'desktop_gallery_choice', value: choice),
    );
  }
}

String desktopLibraryLabel(
  DesktopLibrarySelection selection,
  AlbumsData albums,
) {
  final album = albums.album(selection.albumId);
  if (album != null) return album.name;
  if (isDailyAlbum(selection.albumId)) return selection.albumId!.substring(4);
  return albums.name(selection.albumId);
}
