String desktopDayKey(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

String dailyAlbumId(DateTime now) => 'day_${desktopDayKey(now)}';
bool isDailyAlbum(String? id) =>
    id != null && RegExp(r'^day_\d{4}-\d{2}-\d{2}$').hasMatch(id);
