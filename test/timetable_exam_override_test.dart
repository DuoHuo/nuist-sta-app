import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
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

  ScheduleEvent eventById(String id) =>
      c.scheduleEvents.firstWhere((e) => e.id == id);

  group('jwxt exam overrides', () {
    test(
      'EX20 edit override survives sync; dropped when key disappears',
      () async {
        await c.ensureStarted();
        await c.replaceJwxtExams([_exam('e1', 'MATH01'), _exam('e2', 'PHY01')]);
        final key1 = c.jwxtExamKeyOf('e1')!;
        expect(
          key1,
          ScheduleEvent.examKeyOf(
            'MATH01',
            _monday,
            const TimeOfDayMinutes(9, 0),
          ),
        );
        final moved = _exam('e1', 'MATH01').copyWith(
          date: DateTime(2026, 9, 8),
          start: const TimeOfDayMinutes(14, 0),
          end: const TimeOfDayMinutes(16, 0),
          location: '体育馆',
        );
        expect(await c.updateScheduleEvent(moved), isTrue);
        expect(c.isJwxtOverridden(examKey: key1), isTrue);
        expect(c.jwxtExamKeyOf('e1'), key1, reason: 'original key stays');
        await c.deleteScheduleEvent('e2');
        final key2 = c.jwxtExamKeyOf('e2')!;

        // 同步：e1 仍在（同 key），e2 消失。
        await c.replaceJwxtExams([
          _exam('e1-new', 'MATH01'),
          _exam('e3', 'CHEM01', startH: 14, endH: 16),
        ]);
        final e1 = c.scheduleEvents.firstWhere((e) => e.id == 'e1-new');
        expect(e1.date, DateTime(2026, 9, 8));
        expect(e1.start, const TimeOfDayMinutes(14, 0));
        expect(e1.location, '体育馆');
        expect(c.isJwxtOverridden(examKey: key1), isTrue);
        expect(c.isJwxtOverridden(examKey: key2), isFalse);
        expect((await ScheduleStore.readExamOverrides()).keys, [key1]);

        await restart();
        expect(c.isJwxtOverridden(examKey: key1), isTrue);
        expect(await c.restoreJwxtExam(key1), isTrue);
        final restored = c.scheduleEvents.firstWhere((e) => e.id == 'e1-new');
        expect(restored.date, _monday);
        expect(await c.restoreJwxtExam(key1), isFalse);

        await c.replaceJwxtExams(const []);
        expect(c.scheduleEvents, isEmpty);
      },
    );

    test('EX13 replaceJwxtExams leaves manual events untouched', () async {
      await c.ensureStarted();
      final manualExam = ScheduleEvent(
        id: 'm1',
        kind: ScheduleKind.exam,
        source: ScheduleSource.manual,
        title: '自加小测',
        date: _monday,
        start: const TimeOfDayMinutes(8, 0),
        end: const TimeOfDayMinutes(9, 0),
      );
      await c.addScheduleEvent(manualExam);
      await c.addScheduleEvent(_other('o1'));
      await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
      await c.replaceJwxtExams([_exam('e2', 'PHY01')]);
      expect(c.scheduleEvents.map((e) => e.id).toSet(), {'m1', 'o1', 'e2'});
      final m1 = c.scheduleEvents.firstWhere((e) => e.id == 'm1');
      expect(m1.title, '自加小测');
      expect(m1.source, ScheduleSource.manual);
    });
  });

  test('EX28 rebind + successful sync: matching overrides apply again, stale ones are dropped', () async {
    nextExams = [
      _exam('e1', 'MATH01'),
      _exam('e2', 'PHY01', startH: 14, endH: 16),
      _exam('e3', 'CHEM01', date: DateTime(2026, 9, 8)),
    ];
    await seed([
      _jwxt('j1', '高等数学'),
      _jwxt('j2', '大学物理', day: 2),
      _jwxt('j3', '线性代数', day: 3),
    ]);
    expect(c.scheduleEvents.where((e) => e.isFromJwxt), hasLength(3));
    final k1 = c.jwxtExamKeyOf('e1')!;
    final k2 = c.jwxtExamKeyOf('e2')!;
    final k3 = c.jwxtExamKeyOf('e3')!;
    await c.editJwxtCourse('j1', name: 'A');
    await c.editJwxtCourse('j2', name: 'B');
    await c.deleteJwxtCourse('j3');
    await c.updateScheduleEvent(eventById('e1').copyWith(location: '体育馆'));
    await c.updateScheduleEvent(eventById('e2').copyWith(location: '操场'));
    await c.deleteScheduleEvent('e3');

    await c.handleLogout();
    // EX26：解绑后记录都还在存储里，但不作用于界面。
    expect((await ScheduleStore.readCourseEdits()).keys.toSet(), {
      'j1',
      'j2',
      'j3',
    });
    expect((await ScheduleStore.readExamOverrides()).keys.toSet(), {
      k1,
      k2,
      k3,
    });
    expect(c.courses, isEmpty);
    expect(c.scheduleEvents.where((e) => e.isFromJwxt), isEmpty);

    // 重新绑定：j2 的 SKZC 变了、j3 没了；e2 改了时间、e3 没了。
    nextFetch = [
      _jwxt('j1', '高等数学'),
      _jwxt('j2', '大学物理', day: 2, weeks: '1111111100000000'),
    ];
    nextExams = [
      _exam('e1', 'MATH01'),
      _exam('e2b', 'PHY01', startH: 15, endH: 17),
    ];
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
    expect(shown('j1').name, 'A');
    expect(c.courseEditOf('j2'), isNull);
    expect(shown('j2').name, '大学物理');
    expect(c.courseEditOf('j3'), isNull);
    expect((await ScheduleStore.readCourseEdits()).keys, ['j1']);
    expect((await ScheduleStore.readExamOverrides()).keys, [k1]);
    expect(eventById('e1').location, '体育馆');
    expect(eventById('e2b').location, '教二-201');
    expect(eventById('e2b').start, const TimeOfDayMinutes(15, 0));
    expect(c.scheduleEvents.any((e) => e.id == 'e3'), isFalse);
  });
}
