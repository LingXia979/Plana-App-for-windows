/// 图库展开页的时间工具:按天分组键/段头文案 + 缩略图时刻徽标。
/// 纯函数无 IO,now 一律显式传入(可测,也免得跨日瞬间各处读到不同"今天")。
library;

/// 本地日 → 分组键(yyyymmdd 数值)。0/负时间戳归 0(「更早」段)。
int galleryDayKey(int createdAtMs) {
  if (createdAtMs <= 0) return 0;
  final d = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  return d.year * 10000 + d.month * 100 + d.day;
}

/// 段头文案:今天 / 昨天 / M月d日(今年)/ yyyy年M月d日(跨年);0 = 更早。
String galleryDayLabel(int dayKey, DateTime now) {
  if (dayKey <= 0) return '更早';
  final today = now.year * 10000 + now.month * 100 + now.day;
  if (dayKey == today) return '今天';
  final y1 = now.subtract(const Duration(days: 1));
  if (dayKey == y1.year * 10000 + y1.month * 100 + y1.day) return '昨天';
  final y = dayKey ~/ 10000, m = (dayKey ~/ 100) % 100, d = dayKey % 100;
  return y == now.year ? '$m月$d日' : '$y年$m月$d日';
}

/// 缩略图右下角时刻(HH:mm)。段头已给出日期,逐张再标日期是纯重复,
/// 标时刻才是段内的增量信息。无时间戳返回空串(不画)。
String galleryTimeBadge(int createdAtMs) {
  if (createdAtMs <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}';
}

/// 使用本地日期的 UTC 对应日相减，夏令时切换仍按自然日计数。
int galleryDaysSince(int timestamp, DateTime now) {
  if (timestamp <= 0) return 0;
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final today = DateTime.utc(now.year, now.month, now.day);
  final then = DateTime.utc(date.year, date.month, date.day);
  return today.difference(then).inDays.clamp(0, 1000000);
}
