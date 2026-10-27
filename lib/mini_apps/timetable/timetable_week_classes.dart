import '../../core/schedule/weekly_classes.dart';
import 'timetable_controller.dart';

/// 课表对外提供「本周课程」：按本教学周的实际格子（已套用调课、单日修改）导出，
/// 只保留本周真的要上、且写了地点的课。
class TimetableWeeklyClasses implements WeeklyClassSource {
  const TimetableWeeklyClasses();

  @override
  Future<List<WeeklyClass>> thisWeek() async {
    final controller = TimetableController.instance;
    await controller.ensureStarted();
    final week = controller.currentWeek;
    if (week < 1) return const [];
    final classes = <WeeklyClass>[];
    for (var day = 1; day <= 7; day++) {
      for (final cell in controller.cellsForDay(week, day)) {
        final location = cell.slot.location.trim();
        if (!cell.activeThisWeek || location.isEmpty) continue;
        classes.add(
          WeeklyClass(
            courseName: cell.course.displayName,
            location: location,
            weekday: day,
            startNode: cell.slot.startNode,
            endNode: cell.slot.endNode,
            date: cell.date,
          ),
        );
      }
    }
    classes.sort(
      (a, b) => a.weekday != b.weekday
          ? a.weekday.compareTo(b.weekday)
          : a.startNode.compareTo(b.startNode),
    );
    return classes;
  }
}
