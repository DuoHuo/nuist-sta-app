import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 8, 31); // 周一

DateTime _mondayOf(int week) => _termStart.add(Duration(days: (week - 1) * 7));

void main() {
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;

  setUp(() {
    TimetableController.bindingCheck = () async => false;
    _c.debugReset();
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    _c.debugReset();
  });

  void seed({required DateTime today, int? viewing}) {
    TimetableController.clock = () => today;
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: _termStart,
        ),
        // 位串覆盖到第 20 周，避免 totalWeeks 把 18 钳回去。
        courses: [
          Course(
            id: 'c1',
            name: '示例课',
            source: CourseSource.jwxt,
            slots: [
              CourseSlot(day: 2, startNode: 1, endNode: 2, weeks: '1' * 20),
            ],
          ),
        ],
      ),
      viewingWeek: viewing,
    );
  }

  test('日期从第 14 周推进到第 18 周时 follow 把 viewingWeek 拉到 18', () {
    seed(today: _mondayOf(14), viewing: 14);
    expect(_c.currentWeek, 14);
    expect(_c.viewingWeek, 14);
    // 模拟已观察过第 14 周（debugSetSnapshot 已写入 _lastSeenCurrentWeek）。
    expect(_c.followCurrentWeekIfChanged(), isFalse);

    TimetableController.clock = () => DateTime(2026, 12, 29); // 第 18 周周二
    expect(_c.currentWeek, 18);
    expect(_c.followCurrentWeekIfChanged(), isTrue);
    expect(_c.viewingWeek, 18);
  });

  test('同一本周内手动翻周后再 follow 不会被拉回', () {
    seed(today: DateTime(2026, 12, 29), viewing: 18);
    expect(_c.currentWeek, 18);
    expect(_c.viewingWeek, 18);
    expect(_c.followCurrentWeekIfChanged(), isFalse);

    _c.setViewingWeek(10);
    expect(_c.viewingWeek, 10);

    // 同周内再检查：不打断用户。
    expect(_c.followCurrentWeekIfChanged(), isFalse);
    expect(_c.viewingWeek, 10);

    // 回前台路径也一样。
    expect(_c.followCurrentWeekIfChanged(), isFalse);
    expect(_c.viewingWeek, 10);
  });
}
