// 第 15 条：「之后还有没有安排」判定。纯 Dart，不依赖 Flutter。
//
// 非本周课只在查看周之后还有安排时显示为灰格，之后没有了就不显示。
// 考试（PM 1020）：日期落在查看周内必画；查看周≠本周时灰显，并同时显示
// 「考试」与「非本周」胶囊（见 ScheduleEventCell）。不在本周列幽灵未来考试（#3 未做）。

import 'timetable_models.dart';

/// 时段在 [viewedWeek] 之后还有没有课。
bool slotHasRemainingWeeks(CourseSlot slot, int viewedWeek) {
  for (var w = viewedWeek + 1; w <= slot.weeks.length; w++) {
    if (slot.hasClassInWeek(w)) return true;
  }
  return false;
}

/// 课程任一时段在 [viewedWeek] 之后还有课。
bool courseHasRemainingWeeks(Course course, int viewedWeek) =>
    course.slots.any((s) => slotHasRemainingWeeks(s, viewedWeek));

/// 考试所在教学周 [examWeek] 是否在 [viewedWeek] 之后（之后才灰显，已过则隐藏）。
bool examHasRemainingWeeks(int examWeek, int viewedWeek) =>
    examWeek > viewedWeek;
