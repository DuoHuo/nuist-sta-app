/// 时间显示的公共格式化，卡片右上角的「更新时间」等处共用。
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// 「09-19 14:32」，卡片右上角用。
String formatShortTime(DateTime t) =>
    '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// 「2026-09-19 14:32」。
String formatFullTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} '
    '${_two(t.hour)}:${_two(t.minute)}';

/// 「09-19」，只要月日的场合（如学期起止）。
String formatMonthDay(DateTime t) => '${_two(t.month)}-${_two(t.day)}';
