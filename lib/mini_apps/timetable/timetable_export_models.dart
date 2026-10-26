import 'timetable_controller.dart';
import 'timetable_course_color.dart';
import 'timetable_date_edits.dart';
import 'timetable_schedule_event_layout.dart';

/// 导出准备或网络请求失败时可直接展示的提示。
class TimetableExportException implements Exception {
  const TimetableExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 去除身份和教务内部编号的导出快照；WakeUp 格式转换由服务端完成。
class TimetableExportSnapshot {
  const TimetableExportSnapshot({
    required this.payload,
    required this.courseCount,
    required this.examCount,
    required this.otherCount,
    required this.skippedSlots,
    required this.warnings,
  });

  final Map<String, Object?> payload;
  final int courseCount;
  final int examCount;
  final int otherCount;
  final int skippedSlots;
  final List<String> warnings;

  /// 从现有课表日期视图取实际安排，保留调课、单次编辑及删除的结果。
  static TimetableExportSnapshot fromController(TimetableController c) {
    if (c.settings.termStartDate == null) {
      throw const TimetableExportException('请先同步课表，确定学期开始日期后再导出');
    }
    if (c.periods.isEmpty) {
      throw const TimetableExportException('作息时间不完整，请同步课表后重试');
    }
    var firstWeek = 1;
    var lastWeek = c.totalWeeks;
    void includeDate(DateTime date) {
      final week = c.weekOfDate(date);
      if (week < firstWeek) firstWeek = week;
      if (week > lastWeek) lastWeek = week;
    }

    for (final swap in c.daySwaps) {
      includeDate(swap.dateA);
      includeDate(swap.dateB);
    }
    for (final edit in c.courseDateEdits) {
      includeDate(edit.date);
      includeDate(edit.targetDate);
      for (final week in edit.weeks) {
        if (week > lastWeek) lastWeek = week;
      }
    }
    for (final event in c.scheduleEvents) {
      includeDate(event.date);
    }
    if (lastWeek - firstWeek + 1 > 104) {
      throw const TimetableExportException('导出日期跨度超过 104 周，请检查课程和日程日期');
    }

    final items = <Map<String, Object?>>[];
    final keys = <String, int>{};
    final exportedCourses = <String>{};
    final nodes = {for (final period in c.periods) period.node};
    int keyOf(String localId) =>
        keys.putIfAbsent(localId, () => keys.length + 1);
    // 导出使用固定的浅色课程底色，避免设备当前明暗状态改变分享结果。
    String hexColor(int argb) =>
        '#${(argb & 0xffffff).toRadixString(16).padLeft(6, '0')}';

    for (var week = firstWeek; week <= lastWeek; week++) {
      for (var day = 1; day <= 7; day++) {
        for (final cell in c.cellsForDay(week, day)) {
          if (!cell.activeThisWeek || cell.course.hidden) continue;
          if (!nodes.contains(cell.slot.startNode) ||
              !nodes.contains(cell.slot.endNode)) {
            throw const TimetableExportException('课程引用了缺失的节次，请检查作息时间');
          }
          exportedCourses.add(cell.course.id);
          items.add({
            'key': keyOf('course:${cell.course.id}'),
            'kind': 'course',
            'title': cell.course.name,
            'date': dateKeyOf(c.dateOfColumn(week, day)),
            'startNode': cell.slot.startNode,
            'endNode': cell.slot.endNode,
            'location': cell.slot.location,
            'teacher': cell.slot.teacher,
            'note': cell.slot.note,
            'credit': cell.course.credit ?? 0,
            'color': hexColor(coursePairFor(c, cell.course).bg.toARGB32()),
          });
        }
      }
    }

    var exams = 0;
    var other = 0;
    // 使用全部有效日程，不受“显示考试”开关和当前浏览周影响。
    for (final event in c.scheduleEvents) {
      if (event.end.compareTo(event.start) <= 0) {
        throw TimetableExportException('“${event.title}”的结束时间必须晚于开始时间');
      }
      final range = scheduleNodeRange(c.periods, event.start, event.end);
      items.add({
        'key': keyOf('event:${event.id}'),
        'kind': event.isExam ? 'exam' : 'other',
        'title': event.title,
        'date': dateKeyOf(event.date),
        // 自定义时间不落在任何节次内时，给 WakeUp 一个有效的锚点节次。
        'startNode': range?.startNode ?? c.periods.first.node,
        'endNode': range?.endNode ?? c.periods.first.node,
        'startTime': event.start.format(),
        'endTime': event.end.format(),
        'location': event.location,
        'note': event.note,
        'color': hexColor(scheduleCellBg(c, event).toARGB32()),
      });
      if (event.isExam) {
        exams++;
      } else {
        other++;
      }
    }
    if (items.isEmpty) {
      throw const TimetableExportException('暂无可导出的课程、考试或日程');
    }
    if (items.length > 10000) {
      throw const TimetableExportException('课程和日程安排过多，请减少导出范围');
    }
    final skipped = c.courses
        .where((course) => !course.hidden)
        .expand((course) => course.slots)
        .where((slot) => !slot.hasFixedTime || !slot.weeks.contains('1'))
        .length;
    final warnings = <String>[
      if (firstWeek < 1)
        '包含学期开始前的安排，WakeUp 第 1 周将从 ${dateKeyOf(c.weekStartDate(firstWeek))} 开始；实际日期不变。',
    ];
    return TimetableExportSnapshot(
      payload: {
        'name': c.settings.scheduleName.trim().isEmpty
            ? '我的课表'
            : c.settings.scheduleName.trim(),
        'startDate': dateKeyOf(c.weekStartDate(firstWeek)),
        'maxWeeks': lastWeek - firstWeek + 1,
        'periods': [for (final period in c.periods) period.toJson()],
        'items': items,
      },
      courseCount: exportedCourses.length,
      examCount: exams,
      otherCount: other,
      skippedSlots: skipped,
      warnings: warnings,
    );
  }
}

/// 社团服务器返回的 WakeUp 分享结果。
class TimetableWakeupShare {
  const TimetableWakeupShare({required this.shareText});

  final String shareText;
}
