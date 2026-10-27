/// 考试列表合并去重：教务考试与课表里的考试（含手动添加）可能重复，
/// 按「归一化课名 + 同一天 + 时间有交集」判定为同一场。
///
/// 只用纯函数，不读写存储；调用方（`upcomingExams` / `pastExams`）负责筛选与排序。
library;

import 'timetable_schedule_event.dart';

/// 考试标题归一化：仅用于考试去重，**不**影响配色用的 `normalizeCourseName`。
///
/// trim 后去掉全部空白（普通空格、全角空格等），括号统一成全角 `（）`。
String normalizeExamTitle(String title) => title
    .replaceAll(RegExp(r'[\s\u3000]+'), '')
    .replaceAll('(', '（')
    .replaceAll(')', '）');

/// 两场考试的时间区间是否有交集。
///
/// 仅端点相接（如 9:00–11:00 与 11:00–13:00）不算重叠；
/// 零长度区间（开始 == 结束）与任何区间都不重叠。
bool examTimesOverlap(ScheduleEvent a, ScheduleEvent b) =>
    a.start.totalMinutes < b.end.totalMinutes &&
    b.start.totalMinutes < a.end.totalMinutes;

/// 是否同一场考试：归一化课名相同、同一天、时间有交集。
///
/// 不比较课程号：手动考试常常没有 `courseCode`。
bool isSameExam(ScheduleEvent a, ScheduleEvent b) {
  if (!_sameDay(a.date, b.date)) return false;
  if (normalizeExamTitle(a.title) != normalizeExamTitle(b.title)) {
    return false;
  }
  return examTimesOverlap(a, b);
}

/// 合并重复考试，返回新列表；不修改入参，输入顺序作为保留顺序。
///
/// 同一场考试只保留一条：
/// - 有条目来自教务时保留 `source == jwxt` 的那条；
/// - 都是手动时保留先出现的那条；
/// - 被保留条目的空字段（location / note / courseCode）用合并掉的条目补全。
///
/// 每条只与当前已保留的代表比较；调用方排序后再传入或传入后再排序均可，
/// 本函数不改变相对顺序。
List<ScheduleEvent> mergeExams(Iterable<ScheduleEvent> exams) {
  final merged = <ScheduleEvent>[];
  for (final e in exams) {
    final index = merged.indexWhere((kept) => isSameExam(kept, e));
    if (index < 0) {
      merged.add(e);
    } else {
      merged[index] = _mergePair(merged[index], e);
    }
  }
  return merged;
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 合并两条同一场考试：教务优先；保留条目的空字段由另一条补全。
ScheduleEvent _mergePair(ScheduleEvent kept, ScheduleEvent other) {
  final primary = kept.isFromJwxt || !other.isFromJwxt ? kept : other;
  final secondary = identical(primary, kept) ? other : kept;
  String fill(String mine, String theirs) =>
      mine.trim().isNotEmpty ? mine : theirs;
  final courseCode = (primary.courseCode?.trim().isNotEmpty ?? false)
      ? primary.courseCode
      : secondary.courseCode;
  return primary.copyWith(
    location: fill(primary.location, secondary.location),
    note: fill(primary.note, secondary.note),
    courseCode: courseCode,
  );
}
