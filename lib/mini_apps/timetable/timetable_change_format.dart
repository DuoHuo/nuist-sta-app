import 'timetable_sync_diff.dart';
import 'timetable_week_format.dart';

/// 课程详情中本地修改对应的恢复范围。
enum CourseDetailChangeScope { occurrence, position, course }

/// 一个已变化字段的旧值与新值，颜色额外保留原始色值供界面预览。
class CourseDetailChange {
  const CourseDetailChange({
    required this.field,
    required this.before,
    required this.after,
    this.beforeColor,
    this.afterColor,
  });

  final String field;
  final String before;
  final String after;
  final int? beforeColor;
  final int? afterColor;
}

/// 课程详情中的差异分组，影响范围与对应恢复操作保持一致。
class CourseDetailChangeGroup {
  const CourseDetailChangeGroup({
    required this.scope,
    required this.title,
    required this.affectedScope,
    required this.changes,
  });

  final CourseDetailChangeScope scope;
  final String title;
  final String affectedScope;
  final List<CourseDetailChange> changes;
}

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

  static String zcmcOf(Map<String, dynamic>? snap) =>
      '${snap?['ZCMC'] ?? ''}'.trim();

  static bool _isExam(TimetableChangeRecord r) =>
      (r.after ?? r.before)?['KIND'] == 'exam';

  static bool _isUnscheduled(TimetableChangeRecord r) {
    if (_isExam(r)) return false;
    final snap = r.after ?? r.before;
    if (snap == null) return false;
    final day = snap['SKXQ'];
    final dayInt = day is int ? day : int.tryParse('$day') ?? 0;
    final weeks = '${snap['SKZC'] ?? ''}'.trim();
    return dayInt == 0 && weeks.isEmpty;
  }

  static String _examTimeOf(Map<String, dynamic>? snap) {
    if (snap == null) return '';
    final rawDate = '${snap['KSRQ'] ?? ''}'.trim();
    var dateLabel = rawDate;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(rawDate);
    if (m != null) {
      dateLabel = '${int.parse(m.group(2)!)}月${int.parse(m.group(3)!)}日';
    }
    final start = '${snap['KSKSSJ'] ?? ''}'.trim();
    final end = '${snap['KSJSSJ'] ?? ''}'.trim();
    final range = start.isNotEmpty && end.isNotEmpty
        ? '$start–$end'
        : (start.isNotEmpty ? start : end);
    return [dateLabel, range].where((s) => s.isNotEmpty).join(' ');
  }

  static Set<int> _weeks(Map<String, dynamic>? snap) =>
      weeksFromBits('${snap?['SKZC'] ?? ''}').toSet();

  /// 具体受影响的周次和时段，不含「影响范围」前缀。
  ///
  /// 有课程周次上下文时标明「全部周次」。
  static String scopeBodyOf(TimetableChangeRecord r) {
    if (_isExam(r)) {
      final beforeTime = _examTimeOf(r.before);
      final afterTime = _examTimeOf(r.after);
      if (r.type == TimetableChangeType.timeChanged &&
          beforeTime.isNotEmpty &&
          afterTime.isNotEmpty &&
          beforeTime != afterTime) {
        return '考试 · $beforeTime → $afterTime';
      }
      final t = r.type == TimetableChangeType.added
          ? afterTime
          : _examTimeOf(r.before ?? r.after);
      return t.isEmpty ? '考试' : '考试 · $t';
    }
    if (_isUnscheduled(r)) {
      final beforeZ = zcmcOf(r.before);
      final afterZ = zcmcOf(r.after);
      if (r.type == TimetableChangeType.timeChanged &&
          beforeZ.isNotEmpty &&
          afterZ.isNotEmpty &&
          beforeZ != afterZ) {
        return '其他课程 · $beforeZ → $afterZ';
      }
      final z = r.type == TimetableChangeType.added
          ? afterZ
          : zcmcOf(r.before ?? r.after);
      return z.isEmpty ? '其他课程' : '其他课程 · $z';
    }
    final before = _weeks(r.before);
    final after = _weeks(r.after);
    final sameTime = timeOf(r.before) == timeOf(r.after);
    final onlyWeeksChanged =
        r.type == TimetableChangeType.timeChanged &&
        sameTime &&
        locationOf(r.before) == locationOf(r.after) &&
        teacherOf(r.before) == teacherOf(r.after) &&
        istkOf(r.before) == istkOf(r.after);
    final affected = switch (r.type) {
      TimetableChangeType.added => after,
      TimetableChangeType.removed => before,
      _ when onlyWeeksChanged => {
        ...before.difference(after),
        ...after.difference(before),
      },
      _ => {...before, ...after},
    };
    final all = weeksFromBits(r.courseWeeks).toSet();
    final isAll =
        affected.length > 1 &&
        all.length == affected.length &&
        all.containsAll(affected);
    final weeks = formatWeeks(affected, maxSegments: null);
    var time = r.type == TimetableChangeType.added
        ? timeOf(r.after)
        : timeOf(r.before ?? r.after);
    final beforeTime = timeOf(r.before);
    final afterTime = timeOf(r.after);
    if (r.type == TimetableChangeType.timeChanged &&
        beforeTime.isNotEmpty &&
        afterTime.isNotEmpty &&
        beforeTime != afterTime) {
      time = '$beforeTime → $afterTime';
    }
    if (weeks.isEmpty && time.isEmpty) return '未知';
    final parts = [
      if (weeks.isEmpty) '周次未知' else if (isAll) '全部周次（$weeks）' else weeks,
      if (time.isNotEmpty) time,
    ];
    return parts.join(' · ');
  }

  /// 带「影响范围」前缀的完整文案。
  static String scopeOf(TimetableChangeRecord r) => '影响范围：${scopeBodyOf(r)}';

  static String _timeChangeDetail(TimetableChangeRecord r) {
    final beforeWeeks = _weeks(r.before);
    final afterWeeks = _weeks(r.after);
    final weeksChanged =
        beforeWeeks.length != afterWeeks.length ||
        !beforeWeeks.containsAll(afterWeeks);
    if (!weeksChanged) {
      final beforeTime = timeOf(r.before);
      final afterTime = timeOf(r.after);
      if (beforeTime.isEmpty && afterTime.isEmpty) return '';
      return '$beforeTime → $afterTime';
    }
    String schedule(Map<String, dynamic>? snap) => [
      formatWeeks(_weeks(snap), maxSegments: null),
      timeOf(snap),
    ].where((part) => part.isNotEmpty).join(' · ');
    return '${schedule(r.before)} → ${schedule(r.after)}';
  }

  /// 弹窗单行摘要（不含类型胶囊）。
  static String alertBody(TimetableChangeRecord r) {
    final name = r.courseName.trim();
    if (_isExam(r)) {
      final label = name.isEmpty ? '考试' : '$name（考试）';
      switch (r.type) {
        case TimetableChangeType.added:
          return [
            label,
            if (_examTimeOf(r.after).isNotEmpty) _examTimeOf(r.after),
            if (locationOf(r.after).isNotEmpty) locationOf(r.after),
          ].join(' · ');
        case TimetableChangeType.removed:
          return [
            label,
            if (_examTimeOf(r.before).isNotEmpty) _examTimeOf(r.before),
            if (locationOf(r.before).isNotEmpty) locationOf(r.before),
          ].join(' · ');
        case TimetableChangeType.timeChanged:
          final arrow = '${_examTimeOf(r.before)} → ${_examTimeOf(r.after)}';
          return '$label $arrow';
        case TimetableChangeType.locationChanged:
          return '$label ${locationOf(r.before)} → ${locationOf(r.after)}';
        case TimetableChangeType.teacherChanged:
        case TimetableChangeType.retakeFlagChanged:
          return label;
      }
    }
    if (_isUnscheduled(r)) {
      String unscheduledSummary(Map<String, dynamic>? snap) => [
        if (name.isNotEmpty) name,
        if (zcmcOf(snap).isNotEmpty) zcmcOf(snap),
        if (locationOf(snap).isNotEmpty)
          locationOf(snap)
        else if (teacherOf(snap).isNotEmpty)
          teacherOf(snap),
      ].join(' · ');

      switch (r.type) {
        case TimetableChangeType.added:
          return unscheduledSummary(r.after);
        case TimetableChangeType.removed:
          return unscheduledSummary(r.before);
        case TimetableChangeType.timeChanged:
          final arrow = '${zcmcOf(r.before)} → ${zcmcOf(r.after)}';
          return [
            if (name.isNotEmpty) name,
            if (arrow != ' → ') arrow,
          ].join(' ');
        case TimetableChangeType.locationChanged:
        case TimetableChangeType.teacherChanged:
        case TimetableChangeType.retakeFlagChanged:
          break;
      }
    }
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
        final arrow = _timeChangeDetail(r);
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
    if (_isExam(r)) {
      switch (r.type) {
        case TimetableChangeType.added:
          return [
            if (_examTimeOf(r.after).isNotEmpty) _examTimeOf(r.after),
            if (locationOf(r.after).isNotEmpty) locationOf(r.after),
          ].join(' · ');
        case TimetableChangeType.removed:
          return [
            if (_examTimeOf(r.before).isNotEmpty) _examTimeOf(r.before),
            if (locationOf(r.before).isNotEmpty) locationOf(r.before),
          ].join(' · ');
        case TimetableChangeType.timeChanged:
          return '${_examTimeOf(r.before)} → ${_examTimeOf(r.after)}';
        case TimetableChangeType.locationChanged:
          return '${locationOf(r.before)} → ${locationOf(r.after)}';
        case TimetableChangeType.teacherChanged:
        case TimetableChangeType.retakeFlagChanged:
          return '';
      }
    }
    if (_isUnscheduled(r)) {
      String unscheduledDetail(Map<String, dynamic>? snap) => [
        if (zcmcOf(snap).isNotEmpty) zcmcOf(snap),
        if (locationOf(snap).isNotEmpty)
          locationOf(snap)
        else if (teacherOf(snap).isNotEmpty)
          teacherOf(snap),
      ].join(' · ');

      switch (r.type) {
        case TimetableChangeType.added:
          return unscheduledDetail(r.after);
        case TimetableChangeType.removed:
          return unscheduledDetail(r.before);
        case TimetableChangeType.timeChanged:
          final arrow = '${zcmcOf(r.before)} → ${zcmcOf(r.after)}';
          return arrow == ' → ' ? '' : arrow;
        case TimetableChangeType.locationChanged:
        case TimetableChangeType.teacherChanged:
        case TimetableChangeType.retakeFlagChanged:
          break;
      }
    }
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
        return _timeChangeDetail(r);
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
