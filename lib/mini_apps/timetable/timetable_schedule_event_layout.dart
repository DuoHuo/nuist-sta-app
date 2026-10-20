import 'package:flutter/material.dart';

import 'timetable_schedule_event.dart';
import 'timetable_controller.dart';
import 'timetable_models.dart';
import 'timetable_theme.dart';
import 'timetable_week_layout.dart';
import 'timetable_course_color.dart';

/// 日程（考试 / 其他）在周视图、详情、首页卡片共用的纯逻辑与样式（spec §14.2–§14.4）。

/// 胶囊文字：考试 / 日程。
const String kExamPillLabel = '考试';
const String kOtherPillLabel = '日程';

String schedulePillLabel(ScheduleEvent e) =>
    e.isExam ? kExamPillLabel : kOtherPillLabel;

/// 日程覆盖的节次（spec §14.2 + EV-2，设计 10/18 定稿）：日程与哪些节次的时间段
/// 有重叠（哪怕只重叠一分钟），就覆盖哪些节次；取其中最小到最大节次。
///
/// - 08:50–09:40（第 1 节 08:00–08:45、第 2 节 08:55–09:40）→ 第 2 节；
///   08:30–09:00 → 第 1–2 节（两节都碰到）。
/// - 恰好在下课 / 上课时刻首尾相接不算重叠（08:45–08:55 不碰任何节）。
/// - 与任何节次都不重叠（整段在课间 / 午休，或整段在所有节次之外，如 21:30–22:30）
///   → null：不画进网格、不取整到最近节次，改在表头日期下画圆点（[scheduleUnplacedForColumn]）。
/// - 结束早于开始按开始处理（零时长：落在某节内才算覆盖该节）。
/// 作息为空（或时间无法解析）→ null。
({int startNode, int endNode})? scheduleNodeRange(
  List<PeriodTime> periods,
  TimeOfDayMinutes start,
  TimeOfDayMinutes end,
) {
  final st = start.totalMinutes;
  final en = end.totalMinutes < st ? st : end.totalMinutes;
  int? lo;
  int? hi;
  for (final p in periods) {
    final ps = TimeOfDayMinutes.tryParse(p.start)?.totalMinutes;
    final pe = TimeOfDayMinutes.tryParse(p.end)?.totalMinutes;
    if (ps == null || pe == null) continue;
    final overlaps = st == en ? (ps <= st && st < pe) : (ps < en && st < pe);
    if (!overlaps) continue;
    if (lo == null || p.node < lo) lo = p.node;
    if (hi == null || p.node > hi) hi = p.node;
  }
  if (lo == null || hi == null) return null;
  return (startNode: lo, endNode: hi);
}

/// 网格上的一格日程（已映射到节次）。
@immutable
class ScheduleGridItem {
  const ScheduleGridItem({
    required this.event,
    required this.startNode,
    required this.endNode,
    this.activeThisWeek = true,
  });

  final ScheduleEvent event;
  final int startNode;
  final int endNode;

  /// 考试：查看周 == 本周为 true；查看周 ≠ 本周时为 false（灰显 + 双胶囊）。
  /// 「其他」日程始终 true（不走考试非本周规则）。
  final bool activeThisWeek;

  bool overlapsNodes(int start, int end) =>
      startNode <= end && start <= endNode;
}

/// 第 [week] 周第 [day] 列要画的日程（只取该列日期；考试受 showExams 控制，
/// 由 [TimetableController.scheduleEventsOn] 过滤）。
///
/// 考试规则（PM 1020）：
/// 1. 日期落在查看周内的考试必画（不因「非本周」被滤掉）；
/// 2. 查看周 ≠ [TimetableController.currentWeek] 时 [ScheduleGridItem.activeThisWeek]
///    为 false → 灰显 +「考试」「非本周」双胶囊；
/// 4. showExams=false 仍隐藏全部考试（见 scheduleEventsOn）。
///
/// #3（未做）：本周视图下，「显示非本周」打开时把未来周考试幽灵到同星期列——待产品确认。
List<ScheduleGridItem> scheduleItemsForColumn(
  TimetableController controller,
  int week,
  int day,
) {
  final date = controller.dateOfColumn(week, day);
  // 查看周是否为本周：仅影响考试灰显，不影响「其他」日程。
  final viewingCurrent = week == controller.currentWeek;
  return [
    for (final e in controller.scheduleEventsOn(date))
      if (scheduleNodeRange(controller.periods, e.start, e.end) case final r?)
        ScheduleGridItem(
          event: e,
          startNode: r.startNode,
          endNode: r.endNode,
          activeThisWeek: e.isExam ? viewingCurrent : true,
        ),
  ];
}

/// 第 [week] 周第 [day] 列「不在节次内」的日程（与任何节次都不重叠，见
/// [scheduleNodeRange]），按开始时间排序。考试受 showExams 控制（同
/// [TimetableController.scheduleEventsOn]）。不进网格、不计冲突与「N 门」。
List<ScheduleEvent> scheduleUnplacedForColumn(
  TimetableController controller,
  int week,
  int day,
) {
  final date = controller.dateOfColumn(week, day);
  return [
    for (final e in controller.scheduleEventsOn(date))
      if (scheduleNodeRange(controller.periods, e.start, e.end) == null) e,
  ]..sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.end.compareTo(b.end);
  });
}

const _weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 1=周一 … 7=周日 →「周三」。
String scheduleWeekdayName(int day) => _weekdayNames[(day - 1) % 7];

/// 表头读屏文案：「周三，另有 2 项不在节次内」。
String scheduleUnplacedSemantics(int day, int count) =>
    '${scheduleWeekdayName(day)}，另有 $count 项不在节次内';

/// 表头圆点颜色：取最早一项（[events] 已按开始时间排序）——考试为 examColor，
/// 其他为该名称的固定色（白底强调色）。
Color scheduleUnplacedDotColor(
  TimetableController c,
  List<ScheduleEvent> events,
) => scheduleAccentOnWhite(c, events.first);

/// 周视图列：在 [TimetableController.visibleDays] 基础上，周六/周日有可见日程时
/// 也自动显示该列（与「当天有课自动显示」一致），避免日程落在隐藏列上看不到。
List<int> visibleDaysWithEvents(TimetableController controller, int week) {
  final base = controller.visibleDays(week);
  final sat =
      !base.contains(6) &&
      controller.scheduleEventsOn(controller.dateOfColumn(week, 6)).isNotEmpty;
  final sun =
      !base.contains(7) &&
      controller.scheduleEventsOn(controller.dateOfColumn(week, 7)).isNotEmpty;
  if (!sat && !sun) return base;
  final s = controller.settings;
  return weekColumnDays(
    weekStartsSunday: s.weekStartsSunday,
    showSaturday: s.showSaturday || base.contains(6) || sat,
    showSunday: s.showSunday || base.contains(7) || sun,
  );
}

/// 「其他」日程色号：按名称查 `schedule_events.json` 的固定表（产品经理 10/18：
/// 同名同色，分配一次后不变，见 [TimetableController.otherColorIndexOf]）。
int scheduleOtherColorIndex(TimetableController c, ScheduleEvent e) =>
    c.otherColorIndexOf(e);

/// 周视图格底色（考试：设置 examColor，不受不透明度影响；其他：配色底色按不透明度混合）。
/// [dark]：深色下考试色往 #121316 混 25%，其他按课程格的深色规则（item 12）。
/// [activeThisWeek] false（查看周≠本周的考试）→ 非本周灰底，不取 examColor。
Color scheduleCellBg(
  TimetableController c,
  ScheduleEvent e, {
  bool dark = false,
  bool activeThisWeek = true,
}) {
  if (e.isExam && !activeThisWeek) {
    return dark ? TimetableTheme.offWeekBgDark : TimetableTheme.offWeekBg;
  }
  if (e.isExam) {
    return TimetableTheme.examCellBg(Color(c.settings.examColor), dark: dark);
  }
  return TimetableTheme.blendCellBg(
    TimetableTheme.coursePair(
      scheduleOtherColorIndex(c, e),
      scheme: coursePaletteSchemeFor(c),
      dark: dark,
    ).bg,
    c.settings.cellOpacity,
    dark: dark,
  );
}

/// 周视图格文字 / 胶囊颜色（考试白字；其他取该色号文字色）。
/// [activeThisWeek] false 的考试 → [TimetableTheme.offWeekText]。
Color scheduleCellFg(
  TimetableController c,
  ScheduleEvent e, {
  bool dark = false,
  bool activeThisWeek = true,
}) {
  if (e.isExam && !activeThisWeek) {
    return dark ? TimetableTheme.offWeekTextDark : TimetableTheme.offWeekText;
  }
  if (e.isExam) return TimetableTheme.examText;
  return TimetableTheme.coursePair(
    scheduleOtherColorIndex(c, e),
    scheme: coursePaletteSchemeFor(c),
    dark: dark,
  ).fg;
}

/// 白底上（首页卡片色条、详情色条、首页胶囊）用的强调色：考试色 / 该色号文字色。
Color scheduleAccentOnWhite(TimetableController c, ScheduleEvent e) =>
    e.isExam ? Color(c.settings.examColor) : scheduleCellFg(c, e);

/// 与课程格「单周 / 非本周」相同样式的 Micro 胶囊（描边与文字同色、无填充）。
class SchedulePill extends StatelessWidget {
  const SchedulePill({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: TimetableTheme.badgeSize, color: color),
    ),
  );
}

const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

/// 「10月20日 周二」。
String scheduleDateText(DateTime d) =>
    '${d.month}月${d.day}日 周${_weekdayCn[d.weekday - 1]}';

/// 「08:00–09:40」。
String scheduleTimeText(ScheduleEvent e) =>
    '${e.start.format()}–${e.end.format()}';
