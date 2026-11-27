import 'timetable_models.dart';
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

  static int? _weekdayInt(Map<String, dynamic>? snap) {
    if (snap == null) return null;
    final day = snap['SKXQ'];
    final n = day is int ? day : int.tryParse('$day');
    if (n == null || n < 1 || n > 7) return null;
    return n;
  }

  /// 解析变动记录对应的第 1 周周一日期。
  ///
  /// 仅当记录自带 [TimetableChangeRecord.termStartDate] 或调用方传入可靠的
  /// [fallbackTermStart]（或命中内置学期配置 [kBuiltinTermStartDates]）时才返回日期；
  /// 开学日未知时返回 `null`，绝不用今天兜底以免算出错误日期。
  static DateTime? resolveRecordTermStart(
    TimetableChangeRecord r, {
    DateTime? fallbackTermStart,
  }) {
    final raw = r.termStartDate.trim();
    if (raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return mondayOfWeek(parsed);
    }
    if (fallbackTermStart != null) {
      return mondayOfWeek(fallbackTermStart);
    }
    final term = r.xnxqdm.trim();
    if (term.isNotEmpty) {
      final builtin = kBuiltinTermStartDates[term];
      if (builtin != null) {
        final parsed = DateTime.tryParse(builtin);
        if (parsed != null) return mondayOfWeek(parsed);
      }
    }
    return null;
  }

  /// 判断一组教学周是否属于「非重复循环」的单独某周或多节分离周次：
  /// - 仅 1 周（如 `{5}`）；
  /// - 或 2..4 个彼此互不相邻（无连续段 `w+1`）且不构成 ≥3 周单双周等差循环的分离周次
  ///   （如 `{3, 7}`、`{2, 5, 9}`、`{2, 4}`）。
  ///
  /// 连续周段（如 `1–16`、`1–2`、`1–2、5–6`）、单双周循环（`1, 3, 5...`）或超过 4 次的集合
  /// 均视为重复循环或过长区间，不附带逐日列表。
  static bool isNonRepeatingDiscreteWeeks(Set<int> weeks) {
    if (weeks.isEmpty || weeks.length > 4) return false;
    if (weeks.length == 1) return true;
    final sorted = weeks.toList()..sort();
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] - sorted[i - 1] == 1) return false;
    }
    if (sorted.length >= 3) {
      final parity = sorted.first.isOdd;
      var stepTwo = true;
      for (var i = 0; i < sorted.length; i++) {
        if (sorted[i].isOdd != parity ||
            (i > 0 && sorted[i] - sorted[i - 1] != 2)) {
          stepTwo = false;
          break;
        }
      }
      if (stepTwo) return false;
    }
    return true;
  }

  /// 将「非重复循环」的周集合与星期换算为 `M月D日`（多日以 `、` 连接）；不适当或无法换算时返回空串。
  static String discreteDatesLabel({
    required Set<int> weeks,
    required int? weekday,
    required DateTime? termStartMonday,
  }) {
    if (termStartMonday == null || weekday == null) return '';
    if (!isNonRepeatingDiscreteWeeks(weeks)) return '';
    final sorted = weeks.toList()..sort();
    if (sorted.any((w) => w < 1)) return '';
    final labels = [
      for (final w in sorted)
        () {
          final d = DateTime(
            termStartMonday.year,
            termStartMonday.month,
            termStartMonday.day + (w - 1) * 7 + (weekday - 1),
          );
          return '${d.month}月${d.day}日';
        }(),
    ];
    return labels.join('、');
  }

  static String _appendDiscreteDates(
    String base, {
    required Set<int> weeks,
    required int? weekday,
    required DateTime? termStartMonday,
  }) {
    final dates = discreteDatesLabel(
      weeks: weeks,
      weekday: weekday,
      termStartMonday: termStartMonday,
    );
    if (dates.isEmpty) return base;
    return base.isEmpty ? '（$dates）' : '$base（$dates）';
  }

  static bool _onlyWeeksChanged(TimetableChangeRecord r) =>
      r.type == TimetableChangeType.timeChanged &&
      timeOf(r.before) == timeOf(r.after) &&
      locationOf(r.before) == locationOf(r.after) &&
      teacherOf(r.before) == teacherOf(r.after) &&
      istkOf(r.before) == istkOf(r.after);

  static Set<int> _affectedWeeksOf(TimetableChangeRecord r) {
    final before = _weeks(r.before);
    final after = _weeks(r.after);
    return switch (r.type) {
      TimetableChangeType.added => after,
      TimetableChangeType.removed => before,
      _ when _onlyWeeksChanged(r) => {
        ...before.difference(after),
        ...after.difference(before),
      },
      _ => {...before, ...after},
    };
  }

  /// 弹窗摘要中为非 `timeChanged` 的单次/分离课变动补充的紧凑范围后缀（如 `第 5 周（9月30日）`）。
  /// 常规多周重复课在新增/删除/换教室等弹窗摘要中保持原样不冗长；仅在非重复分离周次时点明。
  static String _discreteScopeSuffixForAlert(
    TimetableChangeRecord r, {
    required DateTime? termStartMonday,
  }) {
    final affected = _affectedWeeksOf(r);
    if (!isNonRepeatingDiscreteWeeks(affected)) return '';
    final snap = r.type == TimetableChangeType.added
        ? r.after
        : (r.before ?? r.after);
    final weekday = _weekdayInt(snap);
    final weeksText = formatWeeks(affected, maxSegments: null);
    final dates = discreteDatesLabel(
      weeks: affected,
      weekday: weekday,
      termStartMonday: termStartMonday,
    );
    if (dates.isNotEmpty) {
      return '$weeksText（$dates）';
    }
    return weeksText;
  }

  /// 具体受影响的周次和时段，不含「影响范围」前缀。
  ///
  /// 有课程周次上下文时标明「全部周次」；单周或分离周次且已知开学日时在末尾跟上具体日期。
  static String scopeBodyOf(
    TimetableChangeRecord r, {
    DateTime? fallbackTermStart,
  }) {
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
    final affected = _affectedWeeksOf(r);
    final all = weeksFromBits(r.courseWeeks).toSet();
    final isAll =
        affected.length > 1 &&
        all.length == affected.length &&
        all.containsAll(affected);
    final weeks = formatWeeks(affected, maxSegments: null);
    final termStart = resolveRecordTermStart(
      r,
      fallbackTermStart: fallbackTermStart,
    );
    var time = r.type == TimetableChangeType.added
        ? timeOf(r.after)
        : timeOf(r.before ?? r.after);
    final beforeTime = timeOf(r.before);
    final afterTime = timeOf(r.after);
    final beforeDay = _weekdayInt(r.before);
    final afterDay = _weekdayInt(r.after);
    if (r.type == TimetableChangeType.timeChanged &&
        beforeTime.isNotEmpty &&
        afterTime.isNotEmpty &&
        beforeTime != afterTime) {
      final bWeeks = _weeks(r.before);
      final aWeeks = _weeks(r.after);
      final bWithDate = beforeDay != afterDay
          ? _appendDiscreteDates(
              beforeTime,
              weeks: bWeeks,
              weekday: beforeDay,
              termStartMonday: termStart,
            )
          : beforeTime;
      final aWithDate = _appendDiscreteDates(
        afterTime,
        weeks: aWeeks,
        weekday: afterDay,
        termStartMonday: termStart,
      );
      time = '$bWithDate → $aWithDate';
    } else {
      final snap = r.type == TimetableChangeType.added
          ? r.after
          : (r.before ?? r.after);
      time = _appendDiscreteDates(
        time,
        weeks: affected,
        weekday: _weekdayInt(snap),
        termStartMonday: termStart,
      );
    }
    if (weeks.isEmpty && time.isEmpty) return '未知';
    final parts = [
      if (weeks.isEmpty) '周次未知' else if (isAll) '全部周次（$weeks）' else weeks,
      if (time.isNotEmpty) time,
    ];
    return parts.join(' · ');
  }

  /// 带「影响范围」前缀的完整文案。
  static String scopeOf(
    TimetableChangeRecord r, {
    DateTime? fallbackTermStart,
  }) => '影响范围：${scopeBodyOf(r, fallbackTermStart: fallbackTermStart)}';

  static String _timeChangeDetail(
    TimetableChangeRecord r, {
    DateTime? termStartMonday,
  }) {
    final beforeWeeks = _weeks(r.before);
    final afterWeeks = _weeks(r.after);
    final weeksChanged =
        beforeWeeks.length != afterWeeks.length ||
        !beforeWeeks.containsAll(afterWeeks);
    if (!weeksChanged) {
      final beforeTime = _appendDiscreteDates(
        timeOf(r.before),
        weeks: beforeWeeks,
        weekday: _weekdayInt(r.before),
        termStartMonday: termStartMonday,
      );
      final afterTime = _appendDiscreteDates(
        timeOf(r.after),
        weeks: afterWeeks,
        weekday: _weekdayInt(r.after),
        termStartMonday: termStartMonday,
      );
      if (beforeTime.isEmpty && afterTime.isEmpty) return '';
      return '$beforeTime → $afterTime';
    }
    String schedule(Map<String, dynamic>? snap) {
      final wSet = _weeks(snap);
      final base = [
        formatWeeks(wSet, maxSegments: null),
        timeOf(snap),
      ].where((part) => part.isNotEmpty).join(' · ');
      return _appendDiscreteDates(
        base,
        weeks: wSet,
        weekday: _weekdayInt(snap),
        termStartMonday: termStartMonday,
      );
    }

    var arrow = '${schedule(r.before)} → ${schedule(r.after)}';
    if (_onlyWeeksChanged(r)) {
      final symmetricDiff = {
        ...beforeWeeks.difference(afterWeeks),
        ...afterWeeks.difference(beforeWeeks),
      };
      // 诸如 1–4周 → 1–3周（仅第 4 周调走/取消）时，前后快照本身不是离散周，但在末尾点出受影响的具体日期。
      if (!isNonRepeatingDiscreteWeeks(beforeWeeks) &&
          !isNonRepeatingDiscreteWeeks(afterWeeks) &&
          isNonRepeatingDiscreteWeeks(symmetricDiff)) {
        final diffDates = discreteDatesLabel(
          weeks: symmetricDiff,
          weekday: _weekdayInt(r.after ?? r.before),
          termStartMonday: termStartMonday,
        );
        if (diffDates.isNotEmpty) {
          arrow = '$arrow（$diffDates）';
        }
      }
    }
    return arrow;
  }

  /// 弹窗单行摘要（不含类型胶囊）。
  static String alertBody(
    TimetableChangeRecord r, {
    DateTime? fallbackTermStart,
  }) {
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
          final locBefore = locationOf(r.before);
          final locAfter = locationOf(r.after);
          if (locBefore != locAfter &&
              (locBefore.isNotEmpty || locAfter.isNotEmpty)) {
            return '$label $arrow · $locBefore → $locAfter';
          }
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
    final termStart = resolveRecordTermStart(
      r,
      fallbackTermStart: fallbackTermStart,
    );
    switch (r.type) {
      case TimetableChangeType.added:
        final scopeSuffix = _discreteScopeSuffixForAlert(
          r,
          termStartMonday: termStart,
        );
        final parts = <String>[
          if (name.isNotEmpty) name,
          if (timeOf(r.after).isNotEmpty) timeOf(r.after),
          if (locationOf(r.after).isNotEmpty) locationOf(r.after),
          if (scopeSuffix.isNotEmpty) scopeSuffix,
        ];
        return parts.join(' · ');
      case TimetableChangeType.removed:
        final scopeSuffix = _discreteScopeSuffixForAlert(
          r,
          termStartMonday: termStart,
        );
        final parts = <String>[
          if (name.isNotEmpty) name,
          if (timeOf(r.before).isNotEmpty) timeOf(r.before),
          if (locationOf(r.before).isNotEmpty) locationOf(r.before),
          if (scopeSuffix.isNotEmpty) scopeSuffix,
        ];
        return parts.join(' · ');
      case TimetableChangeType.timeChanged:
        final arrow = _timeChangeDetail(r, termStartMonday: termStart);
        return [
          if (name.isNotEmpty) name,
          if (arrow.isNotEmpty) arrow,
        ].join(' ');
      case TimetableChangeType.locationChanged:
        final scopeSuffix = _discreteScopeSuffixForAlert(
          r,
          termStartMonday: termStart,
        );
        final head = [
          if (name.isNotEmpty) name,
          '${locationOf(r.before)} → ${locationOf(r.after)}',
        ].join(' ');
        return scopeSuffix.isEmpty ? head : '$head · $scopeSuffix';
      case TimetableChangeType.teacherChanged:
        final scopeSuffix = _discreteScopeSuffixForAlert(
          r,
          termStartMonday: termStart,
        );
        final head = [
          if (name.isNotEmpty) name,
          '${teacherOf(r.before)} → ${teacherOf(r.after)}',
        ].join(' ');
        return scopeSuffix.isEmpty ? head : '$head · $scopeSuffix';
      case TimetableChangeType.retakeFlagChanged:
        final scopeSuffix = _discreteScopeSuffixForAlert(
          r,
          termStartMonday: termStart,
        );
        final head = [
          if (name.isNotEmpty) name,
          '${istkOf(r.before)} → ${istkOf(r.after)}',
        ].join(' ');
        return scopeSuffix.isEmpty ? head : '$head · $scopeSuffix';
    }
  }

  /// 记录页明细行（课程名下方灰字）。
  static String detailOf(
    TimetableChangeRecord r, {
    DateTime? fallbackTermStart,
  }) {
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
          final arrow = '${_examTimeOf(r.before)} → ${_examTimeOf(r.after)}';
          final locBefore = locationOf(r.before);
          final locAfter = locationOf(r.after);
          if (locBefore != locAfter &&
              (locBefore.isNotEmpty || locAfter.isNotEmpty)) {
            return '$arrow · $locBefore → $locAfter';
          }
          return arrow;
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
    final termStart = resolveRecordTermStart(
      r,
      fallbackTermStart: fallbackTermStart,
    );
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
        return _timeChangeDetail(r, termStartMonday: termStart);
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
