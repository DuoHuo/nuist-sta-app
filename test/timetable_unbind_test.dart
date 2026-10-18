import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

// 全部为虚构数据。
const _settings = TimetableSettings(termCode: '2026-2027-1');
final _termStart = DateTime(2026, 8, 31); // 周一，第 1 周
final _monday = DateTime(2026, 9, 7); // 第 2 周周一

Course _jwxt(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '1111111111111111',
}) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      teacher: '张老师',
      location: '教一-101',
    ),
  ],
);

Course _manual(String id, String name) => Course(
  id: id,
  name: name,
  source: CourseSource.manual,
  slots: const [
    CourseSlot(day: 3, startNode: 5, endNode: 6, weeks: '1111111111111111'),
  ],
);

TimetableSnapshot _snap(List<Course> courses) => TimetableSnapshot(
  courses: courses,
  periods: TimetableController.defaultPeriods(),
  settings: _settings.copyWith(
    termStartDate: _termStart,
    termStartFromJwxt: true,
  ),
);

ScheduleEvent _exam(
  String id,
  String code, {
  DateTime? date,
  int startH = 9,
  int endH = 11,
  String title = '高等数学考试',
}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.exam,
  source: ScheduleSource.jwxt,
  title: title,
  date: date ?? _monday,
  start: TimeOfDayMinutes(startH, 0),
  end: TimeOfDayMinutes(endH, 0),
  location: '教二-201',
  courseCode: code,
);

ScheduleEvent _other(String id, {int endH = 21}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.other,
  source: ScheduleSource.manual,
  title: '社团活动',
  date: _monday,
  start: TimeOfDayMinutes(endH - 1, 0),
  end: TimeOfDayMinutes(endH, 0),
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  List<Course> nextFetch = const [];
  List<ScheduleEvent>? nextExams;
  final origFetchExams = TimetableController.fetchExams;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_data');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => _monday;
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        _snap(nextFetch);
    // 默认返回 null（本次不拉考试，与替换了 fetchSnapshot 时的默认钩子一致）。
    nextExams = null;
    TimetableController.fetchExams = (term) async => nextExams;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.syncClock = DateTime.now;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    TimetableController.fetchExams = origFetchExams;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 模拟重启：清内存，按同一目录重新读盘。
  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  Future<void> seed(List<Course> jwxt, {List<Course> manual = const []}) async {
    nextFetch = jwxt;
    await c.ensureStarted();
    for (final m in manual) {
      await c.addManualCourse(m);
    }
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
  }

  Course shown(String id) => c.courses.firstWhere((x) => x.id == id);

  // ===== §24 补充用例（FC / JE / EV / EX / SW01）=====

  group('unbind', () {
    test(
      'EX26 keeps overrides, colour map, manual courses and manual events',
      () async {
        await seed(
          [_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)],
          manual: [_manual('m1', '自习')],
        );
        await c.moveSlot(
          shown('j1'),
          0,
          toDay: 4,
          toStartPeriod: 3,
          week: 2,
          scope: MoveScope.thisWeek,
        );
        await c.editJwxtCourse('j1', name: 'A');
        await c.deleteJwxtCourse('j2');
        await c.addScheduleEvent(_other('o1'));
        await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
        await c.deleteScheduleEvent('e1');
        final colorsFile = File(
          '${tmp.path}/${TimetableStore.courseColorsFile}',
        );
        final colorsBefore = colorsFile.readAsStringSync();
        final manualColor = c.colorIndexOf(c.manualCourses.single);

        await c.handleLogout();
        expect(c.jwxtCourses, isEmpty);
        expect(c.settings.termStartDate, isNull);
        expect(c.scheduleEvents.map((e) => e.id), ['o1']);
        expect(c.slotOverrides, isNotEmpty);
        expect(c.courseEditOf('j1'), isNotNull);
        expect(c.courseEditOf('j2')?.deleted, isTrue);
        expect(c.manualCourses.map((m) => m.name), ['自习']);
        expect(colorsFile.readAsStringSync(), colorsBefore);

        await restart();
        expect(c.slotOverrides, isNotEmpty);
        expect(c.courseEditOf('j1')?.name, 'A');
        expect(c.colorIndexOf(c.manualCourses.single), manualColor);
        final key = ScheduleEvent.examKeyOf(
          'MATH01',
          _monday,
          const TimeOfDayMinutes(9, 0),
        );
        expect(c.isJwxtOverridden(examKey: key), isTrue);

        // 重新绑定后同步：编辑重新套用。
        await c.syncFromJwxt();
        expect(shown('j1').name, 'A');
        expect(c.courses.any((x) => x.id == 'j2'), isFalse);
      },
    );
  });
}
