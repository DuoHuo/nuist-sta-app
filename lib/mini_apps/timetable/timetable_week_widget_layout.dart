/// 当周课表小组件的周数据、配色和列布局。
///
/// 布局预算与原生端 TimetableWeekWidgetLayout 同步。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'timetable_colors.dart';
import 'timetable_models.dart';
import 'timetable_notify_plan.dart';
import 'timetable_theme.dart';
import 'timetable_week_layout.dart';

/// 桌面和 App 内周组件预览共用的浅色 / 深色网格线。
const kWeekWidgetGridLight = Color(0xFFD9DDE3);
const kWeekWidgetGridDark = Color(0xFF454851);

/// 与 Android 尺寸资源的 0.75dp 取整一致，至少保留一个物理像素。
double weekWidgetGridStroke(double devicePixelRatio) =>
    math.max(1, (0.75 * devicePixelRatio).round()) / devicePixelRatio;

/// 周课表的显示设置；地点常显，教师、节次开关与 4×2 共用。
@immutable
class WeekWidgetPrefs {
  const WeekWidgetPrefs({
    this.opacity = 100,
    this.widgetOpacity = 100,
    this.showWeekend = false,
    this.showTeacher = true,
    this.showPeriod = true,
    this.nodesPerDay,
    this.weekStartsSunday = false,
    this.showGridLines = true,
    this.headerTextSize = kDefaultHeaderTextSize,
    this.fontScale = CellFontScale.standard,
    this.cellTextColor = CellTextColorMode.auto,
    this.paletteScheme = kDefaultCoursePaletteScheme,
  });

  /// 从课表设置读取，兼容 v1 的固定字号、行高与紧凑行字段，但不再使用它们。
  factory WeekWidgetPrefs.fromSettings(TimetableSettings settings) =>
      WeekWidgetPrefs(
        opacity: settings.widgetWeekOpacity,
        widgetOpacity: settings.widgetWeekWidgetOpacity,
        showWeekend: settings.widgetWeekShowWeekend,
        showTeacher: settings.widgetShowTeacher,
        showPeriod: settings.widgetShowPeriod,
        nodesPerDay: settings.nodesPerDay,
        weekStartsSunday: settings.weekStartsSunday,
        showGridLines: settings.showGridLines,
        headerTextSize: settings.headerTextSize,
        fontScale: settings.fontScale,
        cellTextColor: settings.cellTextColor,
        paletteScheme: coursePaletteSchemeOf(settings.paletteScheme),
      );

  /// 课程格底色不透明度 30–100。
  final int opacity;

  /// 组件框架的不透明度，不影响课程块。
  final int widgetOpacity;

  /// 显示周六、周日两列。
  final bool showWeekend;

  /// 与 4×2 共用的显示开关。
  final bool showTeacher;
  final bool showPeriod;

  /// 复用 App 周视图的显示参数，不把旧的组件字号、格高或紧凑开关带回来。
  final int? nodesPerDay;
  final bool weekStartsSunday;
  final bool showGridLines;
  final double headerTextSize;
  final CellFontScale fontScale;
  final CellTextColorMode cellTextColor;
  final CoursePaletteScheme paletteScheme;

  double get componentAlpha => widgetOpacity.clamp(30, 100) / 100;

  /// 卡片底色和网格、表头等框架共用组件 alpha；课程配色独立。
  Color background(TimetableColors colors) => componentColor(colors.surface);
  Color componentColor(Color color) =>
      color.withValues(alpha: color.a * componentAlpha);

  /// 网格线与桌面一致按组件 alpha 显示，非线条区域不着色。
  Color gridLine(TimetableColors colors) => componentColor(
    colors.isDark ? kWeekWidgetGridDark : kWeekWidgetGridLight,
  );

  /// 写入 payload 的 week.prefs。
  Map<String, Object> toJson() => {
    'opacity': opacity,
    'widgetOpacity': widgetOpacity,
    'showWeekend': showWeekend,
    'showLocation': true,
    'showTeacher': showTeacher,
    'showPeriod': showPeriod,
    'nodesPerDay': ?nodesPerDay?.clamp(1, kWeekWidgetMaxRows),
    'weekStartsSunday': weekStartsSunday,
    'showGridLines': showGridLines,
    'headerTextSize': headerTextSize,
    'fontScale': fontScale.factor,
  };
}

/// 一节作息；start / end 为 HH:mm。
@immutable
class WeekWidgetPeriod {
  const WeekWidgetPeriod({
    required this.node,
    required this.start,
    required this.end,
  });

  final int node;
  final String start;
  final String end;

  /// 开始 / 结束时间的当日分钟数。
  int get startMinutes => weekMinutesOf(start);
  int get endMinutes => weekMinutesOf(end);

  /// 写入 payload 的 periods。
  Map<String, Object> toJson() => {'node': node, 'start': start, 'end': end};
}

/// HH:mm 转当日分钟数；无法解析时返回 0。
int weekMinutesOf(String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length < 2) return 0;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return 0;
  return hour * 60 + minute;
}

/// 一周中的一天；items 已按开始时间排序。
@immutable
class WeekWidgetDay {
  const WeekWidgetDay({
    required this.date,
    required this.weekday,
    required this.items,
  });

  final DateTime date;

  /// 周一 = 1，周日 = 7。
  final int weekday;
  final List<NotifyClass> items;
}

/// 一个教学周（周一至周日）。
@immutable
class WeekWidgetWeek {
  const WeekWidgetWeek({required this.start, required this.days, this.week});

  /// 周一（本地 0 点）。
  final DateTime start;

  /// 教学周；无法推算时为 null。
  final int? week;
  final List<WeekWidgetDay> days;
}

/// 周组件只显示学校标准的 11 节作息。
const int kWeekWidgetMaxRows = TimetableTheme.defaultNodesPerDay;

/// 周组件复用 App 的节次列与格子样式；表头和行高按桌面宿主尺寸计算。
@immutable
class WeekWidgetGeometry {
  const WeekWidgetGeometry({
    required double widthDp,
    required double heightDp,
    required this.days,
    required this.totalRows,
    required this._showTimeColumn,
  }) : _width = widthDp,
       _height = heightDp;

  static const double bottomInset = 2;

  final double _width;
  final double _height;
  final bool _showTimeColumn;
  final int days;
  final int totalRows;

  // W 固定按七列加节次栏计算；显示周末或节次栏的开关不改变基准。
  double get _baseWidth => _width / 8;
  double get headerHeight => _baseWidth;
  double get weekdayHeight => _baseWidth;
  double get timeColumnWidth => _showTimeColumn ? _baseWidth : 0;
  bool get showTimeColumn => timeColumnWidth > 0;
  double get gridWidth => math.max(0, _width - timeColumnWidth);
  double get cellWidth => gridWidth / days;

  /// 窄七列腾出横向文字空间，五列仍沿用 App 的格子内外距。
  bool get compactText => days == 7 && cellWidth < 46;
  double get cellMargin => compactText ? 1 : TimetableTheme.cellMargin;
  double get cellPadding => compactText ? 2 : 4;
  double get minimumTextSize => days == 7 ? 8 : 9;

  /// 扣除节次栏后，总按七列均分课程区宽度作为行高下限。
  double get unit => gridWidth / 7;

  /// 按七列的格面取整，只用于字号；换行仍用实际显示列的内容宽度。
  double fontReferenceWidth(double dpr) {
    final width = unit - cellMargin * 2;
    return (width * dpr).ceilToDouble() / dpr;
  }

  double get _available =>
      math.max(0, _height - headerHeight - weekdayHeight - bottomInset);

  /// 不足时先按最小行高截去末节，再由可见节次平分整个表体。
  int get rowCount =>
      unit > 0 ? math.min(totalRows, (_available / unit).floor()) : 0;
  double get rowHeight =>
      rowCount > 0 ? math.max(unit, _available / rowCount) : unit;
}

/// 一行节次及其起止作息。
@immutable
class WeekWidgetRow {
  const WeekWidgetRow({required this.node, this.period});

  final int node;
  final WeekWidgetPeriod? period;
}

/// 列内一个不可拆分的块；同课连堂先合并，重叠项共用一个冲突块。
@immutable
class WeekWidgetBlock {
  const WeekWidgetBlock({
    required this.startNode,
    required this.endNode,
    required this.courses,
  });

  final int startNode;
  final int endNode;
  final List<NotifyClass> courses;

  NotifyClass get primary => courses.first;
  int get span => endNode - startNode + 1;
}

/// 周课表的可见行列与课程块。
@immutable
class WeekWidgetPlan {
  const WeekWidgetPlan({
    required this.geometry,
    required this.weekdays,
    required this.dates,
    required this.month,
    required this.rows,
    required this.blocks,
    required this.unplaced,
    required this.todayWeekday,
    required this.hasCourses,
    required this.weekLabel,
  });

  final WeekWidgetGeometry geometry;
  final List<int> weekdays;
  final Map<int, int> dates;
  final int month;
  final List<WeekWidgetRow> rows;

  /// 星期 → 从上到下的连续块；两个块的节次不会重叠。
  final Map<int, List<WeekWidgetBlock>> blocks;

  /// 未落进作息的安排，仅在各天表头提示。
  final Map<int, List<NotifyClass>> unplaced;
  final int? todayWeekday;

  /// 可见星期有安排，即使安排位于被截断的节次。
  final bool hasCourses;
  final String weekLabel;
}

/// 规划完整作息；宿主高度不足时从最后一节向上截断。
WeekWidgetPlan planWeekWidget({
  required WeekWidgetWeek week,
  required List<WeekWidgetPeriod> periods,
  required WeekWidgetPrefs prefs,
  required double widthDp,
  required double heightDp,
  DateTime? today,
}) {
  final weekdays = weekColumnDays(
    weekStartsSunday: prefs.weekStartsSunday,
    showSaturday: prefs.showWeekend,
    showSunday: prefs.showWeekend,
  );
  final periodOf = {for (final period in periods) period.node: period};
  final totalRows =
      (prefs.nodesPerDay ??
              periodOf.keys
                  .where((node) => node > 0)
                  .fold<int?>(
                    null,
                    (max, node) => max == null ? node : math.max(max, node),
                  ) ??
              TimetableTheme.defaultNodesPerDay)
          .clamp(1, kWeekWidgetMaxRows);
  final geometry = WeekWidgetGeometry(
    widthDp: widthDp,
    heightDp: heightDp,
    days: weekdays.length,
    totalRows: totalRows,
    showTimeColumn: prefs.showPeriod,
  );
  final dayOf = {for (final day in week.days) day.weekday: day};
  final unplaced = <int, List<NotifyClass>>{};
  final blocks = <int, List<WeekWidgetBlock>>{};
  for (final day in weekdays) {
    final entries = <_WeekEntry>[];
    for (final course in dayOf[day]?.items ?? const <NotifyClass>[]) {
      final range = weekNodeRange(course, periods);
      if (range == null) {
        unplaced.putIfAbsent(day, () => []).add(course);
      } else if (range.start <= geometry.rowCount) {
        entries.add((
          course: course,
          start: range.start,
          end: math.min(range.end, geometry.rowCount),
        ));
      }
    }
    blocks[day] = _dayBlocks(entries);
  }
  return WeekWidgetPlan(
    geometry: geometry,
    weekdays: weekdays,
    dates: {
      for (final day in weekdays) day: weekColumnDate(week.start, day).day,
    },
    month: weekMonthLabel(week.start),
    rows: [
      for (var node = 1; node <= geometry.rowCount; node++)
        WeekWidgetRow(node: node, period: periodOf[node]),
    ],
    blocks: blocks,
    unplaced: unplaced,
    todayWeekday: today == null
        ? null
        : week.days
              .where((day) => _sameDate(day.date, today))
              .firstOrNull
              ?.weekday,
    hasCourses: weekdays.any((day) => dayOf[day]?.items.isNotEmpty ?? false),
    weekLabel: week.week == null || week.week! <= 0 ? '' : '第${week.week}周',
  );
}

typedef _WeekEntry = ({NotifyClass course, int start, int end});

List<WeekWidgetBlock> _dayBlocks(List<_WeekEntry> entries) {
  entries.sort((a, b) => a.start.compareTo(b.start));
  final runs = <_WeekEntry>[];
  for (final entry in entries) {
    final previous = runs.lastIndexWhere(
      (run) =>
          run.end + 1 == entry.start && _sameCourse(run.course, entry.course),
    );
    if (previous < 0) {
      runs.add(entry);
    } else {
      final first = runs[previous];
      runs[previous] = (
        course: _mergeCourse(first.course, entry.course),
        start: first.start,
        end: entry.end,
      );
    }
  }

  int priority(NotifyClass item) => switch (item.kind) {
    WidgetItemKind.exam => 0,
    WidgetItemKind.course => 1,
    WidgetItemKind.schedule => 2,
  };
  final blocks = <WeekWidgetBlock>[];
  for (var i = 0; i < runs.length;) {
    final first = runs[i++];
    var end = first.end;
    final group = [first.course];
    while (i < runs.length && runs[i].start <= end) {
      final next = runs[i++];
      end = math.max(end, next.end);
      group.add(next.course);
    }
    group.sort((a, b) {
      final byKind = priority(a).compareTo(priority(b));
      if (byKind != 0) return byKind;
      if (a.kind != WidgetItemKind.course) {
        final byTime = a.start.compareTo(b.start);
        if (byTime != 0) return byTime;
      }
      final byName = normalizeCourseName(a.name)
          .compareTo(normalizeCourseName(b.name));
      return byName == 0 ? a.start.compareTo(b.start) : byName;
    });
    blocks.add(
      WeekWidgetBlock(startNode: first.start, endNode: end, courses: group),
    );
  }
  return blocks;
}

bool _sameCourse(NotifyClass a, NotifyClass b) =>
    a.kind == WidgetItemKind.course &&
    b.kind == WidgetItemKind.course &&
    a.courseId == b.courseId &&
    normalizeCourseName(a.name) == normalizeCourseName(b.name) &&
    a.barColor == b.barColor &&
    a.barColorDark == b.barColorDark &&
    (a.courseId.isNotEmpty ||
        (a.location == b.location && listEquals(a.teachers, b.teachers)));

NotifyClass _mergeCourse(NotifyClass a, NotifyClass b) => NotifyClass(
  name: a.name,
  location: {
    for (final raw in [a.location, b.location])
      for (final part in raw.split(' / '))
        if (part.trim().isNotEmpty) part.trim(),
  }.join(' / '),
  teachers: {...a.teachers, ...b.teachers}.toList(),
  start: a.start,
  end: b.end,
  courseId: a.courseId,
  startNode: a.startNode,
  endNode: b.endNode,
  weekTag: a.weekTag == b.weekTag ? a.weekTag : '',
  barColor: a.barColor,
  barColorDark: a.barColorDark,
);

/// 落格范围：普通课兼容旧数据，未落格的考试 / 日程不从时间推测节次。
({int start, int end})? weekNodeRange(
  NotifyClass item,
  List<WeekWidgetPeriod> periods,
) {
  if (item.startNode > 0) {
    final start = item.startNode;
    final end = item.endNode > start ? item.endNode : start;
    return (start: start, end: end);
  }
  if (item.kind != WidgetItemKind.course) return null;
  if (periods.isEmpty) return (start: 1, end: 1);
  final sorted = [...periods]..sort((a, b) => a.node.compareTo(b.node));
  final startMinute = item.start.hour * 60 + item.start.minute;
  final endMinute = item.end.hour * 60 + item.end.minute;
  final containing = sorted
      .where(
        (period) =>
            period.startMinutes <= startMinute &&
            period.endMinutes > startMinute,
      )
      .firstOrNull;
  final first =
      containing ??
      sorted
          .where((period) => period.startMinutes >= startMinute)
          .firstOrNull ??
      sorted.last;
  final last = sorted.lastWhere(
    (period) => period.startMinutes < endMinute,
    orElse: () => first,
  );
  return (start: first.node, end: math.max(first.node, last.node));
}

/// 本周周一（本地 0 点）。
DateTime weekWidgetMonday(DateTime date) =>
    DateTime(date.year, date.month, date.day - (date.weekday - 1));

/// 构造 payload 的 week 段：本周与下周各一份，跨周后原生仍能自选。
Map<String, Object?> buildWeekWidgetPayload({
  required DateTime now,
  required WeekWidgetPrefs prefs,
  required List<WeekWidgetPeriod> periods,
  required int? Function(DateTime date) weekOf,
  required List<NotifyClass> Function(DateTime date) itemsOn,
  bool termStartMissing = false,
}) {
  final monday = weekWidgetMonday(now);
  Map<String, Object?> day(DateTime date) {
    final items = itemsOn(date).indexed.toList()
      ..sort((a, b) {
        final time = a.$2.start.compareTo(b.$2.start);
        return time == 0 ? a.$1.compareTo(b.$1) : time;
      });
    return {
      'date': formatDate(date),
      'weekday': date.weekday,
      'items': [for (final (_, item) in items) _weekItem(item, prefs)],
    };
  }

  Map<String, Object?> week(int offset) {
    final start = DateTime(monday.year, monday.month, monday.day + offset * 7);
    return {
      'start': formatDate(start),
      'week': weekOf(start),
      'days': [
        for (var index = 0; index < 7; index++)
          day(DateTime(start.year, start.month, start.day + index)),
      ],
    };
  }

  return {
    'today': formatDate(now),
    'termStartMissing': termStartMissing,
    'prefs': prefs.toJson(),
    'periods': [
      for (final period in periods)
        if (period.node >= 1 && period.node <= kWeekWidgetMaxRows)
          period.toJson(),
    ],
    'weeks': [week(0), week(1)],
  };
}

Map<String, Object?> _weekItem(NotifyClass item, WeekWidgetPrefs prefs) {
  final (light, dark) = _weekItemPairs(item, prefs.paletteScheme);
  CourseColorPair resolve(CourseColorPair pair, {required bool dark}) {
    final bg = item.kind == WidgetItemKind.exam
        ? pair.bg
        : TimetableTheme.blendCellBg(pair.bg, prefs.opacity, dark: dark);
    final preferred =
        item.kind == WidgetItemKind.course && item.barColor == item.barColorDark
        ? TimetableTheme.userCoursePair(bg).fg
        : pair.fg;
    return CourseColorPair(
      bg,
      TimetableTheme.cellTextFor(
        TimetableTheme.readableCellText(bg, preferred),
        prefs.cellTextColor,
      ),
    );
  }

  final lightCell = resolve(light, dark: false);
  final darkCell = resolve(dark, dark: true);
  return {
    'courseId': item.courseId,
    'name': item.name,
    'kind': item.kind.name,
    if (item.origin case final origin?) 'origin': origin.name,
    'location': item.location,
    'teacherFirst': prefs.showTeacher && item.teachers.isNotEmpty
        ? item.teachers.first
        : '',
    'teacher': prefs.showTeacher ? item.teachers.join('\n') : '',
    'nodes': prefs.showPeriod ? item.nodesLabel : '',
    if (item.weekTag.isNotEmpty) 'weekTag': item.weekTag,
    'startNode': item.startNode,
    'endNode': item.endNode,
    'start': formatLocal(item.start),
    'end': formatLocal(item.end),
    'color': item.barColor,
    'colorDark': item.barColorDark,
    'cellColor': lightCell.bg.toARGB32(),
    'cellColorDark': darkCell.bg.toARGB32(),
    'textColor': lightCell.fg.toARGB32(),
    'textColorDark': darkCell.fg.toARGB32(),
  };
}

(CourseColorPair, CourseColorPair) _weekItemPairs(
  NotifyClass item,
  CoursePaletteScheme scheme,
) {
  final light = Color(item.barColor);
  final dark = Color(item.barColorDark);
  if (item.kind == WidgetItemKind.exam) {
    return (
      CourseColorPair(light, TimetableTheme.examText),
      CourseColorPair(dark, TimetableTheme.examText),
    );
  }
  // 共用条目只携带原始色。按成对色值找回 App 的文字色，不改旧组件数据。
  for (var index = 0; index < kCoursePaletteSize; index++) {
    final source = item.kind == WidgetItemKind.course
        ? TimetableTheme.autoCoursePair(index)
        : TimetableTheme.coursePair(index, scheme: scheme);
    final sourceDark = item.kind == WidgetItemKind.course
        ? TimetableTheme.autoCoursePair(index, dark: true)
        : TimetableTheme.coursePair(index, scheme: scheme, dark: true);
    if (source.bg.toARGB32() == item.barColor &&
        sourceDark.bg.toARGB32() == item.barColorDark) {
      return (
        TimetableTheme.autoCoursePair(index),
        TimetableTheme.autoCoursePair(index, dark: true),
      );
    }
  }
  return (
    TimetableTheme.userCoursePair(light),
    TimetableTheme.userCoursePair(dark, dark: true),
  );
}

bool _sameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
