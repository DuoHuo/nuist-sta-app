// 第 15 条：「之后还有没有安排」判定。纯 Dart，不依赖 Flutter。
//
// 非本周课 / 考试只在查看周之后还有安排时显示为灰格，之后没有了就不显示。
// 考试灰显时 UI 仍保留「考试」胶囊（见 ScheduleEventCell）。

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
