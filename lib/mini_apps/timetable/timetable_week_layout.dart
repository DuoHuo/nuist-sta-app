// 周视图列顺序与首页「明天的课」的纯数据辅助（spec §13.3/§13.4/§13.6，jwxt §3.3）。
// 周次、单双周、今天/明天始终按教务「周一开头」从开学日推算；这里只决定显示。

import 'timetable_models.dart';

/// 周视图要显示的星期（1=周一 … 7=周日），按显示顺序。
///
/// - 周六/周日列：开关打开，或当周该天有课（[saturdayHasClass]/[sundayHasClass]）时显示。
/// - [weekStartsSunday] 且周日列显示：周日（本教学周的周日）放第一列；
///   周日列不显示时就是一到六（或一到五）。
List<int> weekColumnDays({
  required bool weekStartsSunday,
  required bool showSaturday,
  required bool showSunday,
  bool saturdayHasClass = false,
  bool sundayHasClass = false,
}) {
  final sat = showSaturday || saturdayHasClass;
  final sun = showSunday || sundayHasClass;
  final weekdays = [1, 2, 3, 4, 5, if (sat) 6];
  if (!sun) return weekdays;
  return weekStartsSunday ? [7, ...weekdays] : [...weekdays, 7];
}

/// 某列的日期：本教学周周一 + (day-1)。周日开头时第一列仍是本周周日（周一 + 6）。
DateTime weekColumnDate(DateTime teachingWeekMonday, int day) => DateTime(
  teachingWeekMonday.year,
  teachingWeekMonday.month,
  teachingWeekMonday.day + day - 1,
);

/// 月份列：取本教学周周一所在月份，不随列顺序改变。
int weekMonthLabel(DateTime teachingWeekMonday) => teachingWeekMonday.month;

/// 首页「明天」区域的状态。
enum HomeTomorrowKind {
  /// 设置关闭（学期进行中/明天开学时）：不显示明天一栏。
  disabled,

  /// 周次待同步（无开学日）：不显示明天一栏。
  unknown,

  /// 明天有课：[HomeTomorrowInfo.title] + [HomeTomorrowInfo.courses]。
  courses,

  /// 明天没课：[HomeTomorrowInfo.message] =「明天没课」。
  noClass,

  /// 学期已结束（今天 actualWeek > 总周数）：不显示明天一栏，
  /// 卡片主文案 [HomeTomorrowInfo.message] =「本学期已结束」。与开关无关。
  termEnded,

  /// 开学前且明天不是开学日：不显示明天一栏，
  /// [HomeTomorrowInfo.message] =「距开学 N 天」（N 见 [HomeTomorrowInfo.daysUntilTerm]）。
  beforeTerm,
}

class HomeTomorrowInfo {
  const HomeTomorrowInfo({
    required this.kind,
    this.title,
    this.message,
    this.courses = const [],
    this.daysUntilTerm,
    this.tomorrowWeek,
    this.todayFinished = false,
  });

  final HomeTomorrowKind kind;

  /// 「明天（周X）」或跨周时「明天（周一·第 N 周）」；仅 [HomeTomorrowKind.courses]/
  /// [HomeTomorrowKind.noClass]（开学日前一天）有值。
  final String? title;
  final String? message;
  final List<TodayCourseItem> courses;
  final int? daysUntilTerm;

  /// 明天的真实周（actualWeek，不钳制）。
  final int? tomorrowWeek;

  /// 今天的课已上完或今天没课（spec：此时才显示明天一栏）。
  final bool todayFinished;

  /// 是否有明天一栏（courses / noClass）。
  bool get hasTomorrowSection =>
      kind == HomeTomorrowKind.courses || kind == HomeTomorrowKind.noClass;
}

const _weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

/// 「明天（周X）」；明天的真实周 ≥1 且与今天不同（跨周）时「明天（周X·第 N 周）」。
String homeTomorrowTitle(DateTime tomorrow, int? tomorrowWeek, int? todayWeek) {
  final wd = _weekdayCn[tomorrow.weekday - 1];
  if (tomorrowWeek != null && tomorrowWeek >= 1 && tomorrowWeek != todayWeek) {
    return '明天（周$wd·第 $tomorrowWeek 周）';
  }
  return '明天（周$wd）';
}
