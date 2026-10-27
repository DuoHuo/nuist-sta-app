import 'timetable_sync_diff.dart';
import 'timetable_week_format.dart';

/// 变动记录展示文案（弹窗摘要 / 变动记录页明细）。
abstract final class TimetableChangeFormat {
  static const _weekdays = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  /// SKXQ 1–7 → 「周一」…；非法返回空。
  static String weekdayZh(Object? day) {
    final n = day is int ? day : int.tryParse('$day');
    if (n == null || n < 1 || n > 7) return '';
    return _weekdays[n];
  }

  /// 「周三 5–6节」；缺字段时尽量拼出可用片段。
  static String timeOf(Map<String, dynamic>? snap) {
    if (snap == null) return '';
    final day = weekdayZh(snap['SKXQ']);
    final start = snap['KSJC'];
    final end = snap['JSJC'];
    if (start == null || end == null) return day;
    final nodes = start == end ? '$start节' : '$start–$end节';
    if (day.isEmpty) return nodes;
    return '$day $nodes';
  }

  static String locationOf(Map<String, dynamic>? snap) =>
      '${snap?['JASMC'] ?? ''}'.trim();

  static String teacherOf(Map<String, dynamic>? snap) =>
      '${snap?['SKJS'] ?? ''}'.trim();

  static String weeksOf(Map<String, dynamic>? snap) {
    final bits = '${snap?['SKZC'] ?? ''}';
    if (bits.isEmpty) return '';
    return formatWeekBits(bits);
  }

  static String istkOf(Map<String, dynamic>? snap) {
    final v = snap?['ISTK'];
    final n = v is int ? v : int.tryParse('$v') ?? 0;
    return n == 0 ? '否' : '是';
  }

  /// 弹窗单行摘要（不含类型胶囊）。
  static String alertBody(TimetableChangeRecord r) {
    final name = r.courseName.trim();
    switch (r.type) {
      case TimetableChangeType.added:
        final parts = <String>[
          if (name.isNotEmpty) name,
          if (timeOf(r.after).isNotEmpty) timeOf(r.after),
          if (locationOf(r.after).isNotEmpty) locationOf(r.after),
        ];
        return parts.join(' · ');
      case TimetableChangeType.removed:
        final parts = <String>[
          if (name.isNotEmpty) name,
          if (timeOf(r.before).isNotEmpty) timeOf(r.before),
          if (locationOf(r.before).isNotEmpty) locationOf(r.before),
        ];
        return parts.join(' · ');
      case TimetableChangeType.timeChanged:
        final b = timeOf(r.before);
        final a = timeOf(r.after);
        final arrow = (b.isEmpty && a.isEmpty) ? '' : '$b → $a';
        return [
          if (name.isNotEmpty) name,
          if (arrow.isNotEmpty) arrow,
        ].join(' ');
      case TimetableChangeType.locationChanged:
        return [
          if (name.isNotEmpty) name,
          '${locationOf(r.before)} → ${locationOf(r.after)}',
        ].join(' ');
      case TimetableChangeType.teacherChanged:
        return [
          if (name.isNotEmpty) name,
          '${teacherOf(r.before)} → ${teacherOf(r.after)}',
        ].join(' ');
      case TimetableChangeType.retakeFlagChanged:
        return [
          if (name.isNotEmpty) name,
          '${istkOf(r.before)} → ${istkOf(r.after)}',
        ].join(' ');
    }
  }

  /// 记录页明细行（课程名下方灰字）。
  static String detailOf(TimetableChangeRecord r) {
    switch (r.type) {
      case TimetableChangeType.added:
        final parts = <String>[
          if (timeOf(r.after).isNotEmpty) timeOf(r.after),
          if (locationOf(r.after).isNotEmpty) locationOf(r.after),
        ];
        return parts.join(' · ');
      case TimetableChangeType.removed:
        final parts = <String>[
          if (timeOf(r.before).isNotEmpty) timeOf(r.before),
          if (locationOf(r.before).isNotEmpty) locationOf(r.before),
        ];
        return parts.join(' · ');
      case TimetableChangeType.timeChanged:
        return '${timeOf(r.before)} → ${timeOf(r.after)}';
      case TimetableChangeType.locationChanged:
        return '${locationOf(r.before)} → ${locationOf(r.after)}';
      case TimetableChangeType.teacherChanged:
        return '${teacherOf(r.before)} → ${teacherOf(r.after)}';
      case TimetableChangeType.retakeFlagChanged:
        return '${istkOf(r.before)} → ${istkOf(r.after)}';
    }
  }

  /// 分组标题：今天 HH:mm / M月D日 HH:mm（相对 [now]）。
  static String groupTitle(DateTime time, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final local = time.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final sameDay =
        local.year == n.year && local.month == n.month && local.day == n.day;
    if (sameDay) return '今天 $hh:$mm';
    return '${local.month}月${local.day}日 $hh:$mm';
  }
}
