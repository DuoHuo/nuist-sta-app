import 'dart:convert';
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

  // ===== §24 补充用例（FC / JE / EV / EX / SW01）=====

  ScheduleEvent named(String id, String title, {DateTime? date}) =>
      ScheduleEvent(
        id: id,
        kind: ScheduleKind.other,
        source: ScheduleSource.manual,
        title: title,
        date: date ?? _monday,
        start: const TimeOfDayMinutes(19, 0),
        end: const TimeOfDayMinutes(20, 0),
      );

  ScheduleEvent manualExam() => ScheduleEvent(
    id: 'm1',
    kind: ScheduleKind.exam,
    source: ScheduleSource.manual,
    title: '测试手动考试',
    date: _monday,
    start: const TimeOfDayMinutes(8, 0),
    end: const TimeOfDayMinutes(9, 0),
  );

  ScheduleEvent eventById(String id) =>
      c.scheduleEvents.firstWhere((e) => e.id == id);

  String manualEventsJson() => jsonEncode([
    for (final e in c.scheduleEvents)
      if (!e.isFromJwxt) e.toJson(),
  ]);
  group('schedule events persistence', () {
    test('round trip: manual + jwxt events survive restart', () async {
      await seed([_jwxt('j1', '高等数学')]);
      await c.addScheduleEvent(_other('o1'));
      await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
      final f = File('${tmp.path}/${ScheduleStore.scheduleEventsFile}');
      expect(f.existsSync(), isTrue);
      await restart();
      expect(c.scheduleEvents.map((e) => e.id).toSet(), {'o1', 'e1'});
      final e1 = c.scheduleEvents.firstWhere((e) => e.id == 'e1');
      expect(e1.isFromJwxt, isTrue);
      expect(e1.isExam, isTrue);
      expect(e1.courseCode, 'MATH01');
    });

    test('corrupt files read as empty, no throw', () async {
      for (final n in [
        ScheduleStore.scheduleEventsFile,
        ScheduleStore.courseEditsFile,
        ScheduleStore.examOverridesFile,
        ScheduleStore.syncStateFile,
      ]) {
        File('${tmp.path}/$n').writeAsStringSync('{not json');
      }
      await c.ensureStarted();
      expect(c.scheduleEvents, isEmpty);
      expect(c.lastSyncSuccessAt, isNull);
      expect(await ScheduleStore.readCourseEdits(), isEmpty);
      expect(await ScheduleStore.readExamOverrides(), isEmpty);
    });

    test('manual add / update / delete change the event directly', () async {
      await c.ensureStarted();
      final saved = await c.addScheduleEvent(_other(''));
      expect(saved.id, isNotEmpty);
      expect(
        await c.updateScheduleEvent(saved.copyWith(title: '改过的活动')),
        isTrue,
      );
      expect(c.scheduleEvents.single.title, '改过的活动');
      expect(await c.deleteScheduleEvent(saved.id), isTrue);
      expect(c.scheduleEvents, isEmpty);
      await restart();
      expect(c.scheduleEvents, isEmpty);
    });
  });

  group('showExams filtering', () {
    test(
      'scheduleEventsOn hides exams only; last-item helper follows',
      () async {
        await seed([_jwxt('j1', '高等数学', start: 1, end: 2)]); // 08:00–09:40
        await c.replaceJwxtExams([_exam('e1', 'MATH01', startH: 18, endH: 22)]);
        await c.addScheduleEvent(_other('o1', endH: 21));
        final now = DateTime(2026, 9, 7, 7);

        expect(c.scheduleEventsOn(_monday).map((e) => e.id), [
          'e1',
          'o1',
        ], reason: 'sorted by start: exam 18:00, other 20:00');
        expect(
          c.lastVisibleItemEndToday(now: now),
          const TimeOfDayMinutes(22, 0),
        );

        await c.updateSettings(c.settings.copyWith(showExams: false));
        expect(c.scheduleEventsOn(_monday).map((e) => e.id), ['o1']);
        expect(c.scheduleEvents.length, 2, reason: 'data still kept');
        expect(
          c.lastVisibleItemEndToday(now: now),
          const TimeOfDayMinutes(21, 0),
        );

        await c.deleteScheduleEvent('o1');
        expect(
          c.lastVisibleItemEndToday(now: now),
          const TimeOfDayMinutes(9, 40),
        );

        // 别的一天什么都没有。
        expect(c.lastVisibleItemEndToday(now: DateTime(2026, 9, 9, 7)), isNull);
      },
    );
  });

  group('EV 「其他」日程配色与数据（§24.10 单测）', () {
    test('EV19 manual exam / other unchanged by exam sync, restore all, unbind and re-sync', () async {
      await seed([_jwxt('j1', '高等数学')]);
      await c.addScheduleEvent(manualExam());
      await c.addScheduleEvent(_other('o1'));
      final before = manualEventsJson();

      nextExams = [_exam('e1', 'MATH01')];
      await c.syncFromJwxt();
      expect(c.scheduleEvents.where((e) => e.isFromJwxt), hasLength(1));
      expect(manualEventsJson(), before);

      await c.deleteScheduleEvent('e1');
      expect(await c.restoreAllJwxt(), isTrue);
      expect(manualEventsJson(), before);

      await c.handleLogout();
      expect(manualEventsJson(), before);
      expect(c.scheduleEventsOn(_monday).map((e) => e.id).toSet(), {
        'm1',
        'o1',
      });
      await restart();
      expect(manualEventsJson(), before);

      await c.syncFromJwxt();
      expect(manualEventsJson(), before);
    });

    test('EV24 same name → same colour; map in schedule_events.json, fixed after restart; course_colors.json untouched', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      final colorsFile = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final colorsBefore = colorsFile.readAsStringSync();
      await c.addScheduleEvent(named('a', '测试日程甲'));
      await c.addScheduleEvent(named('b', '测试日程甲', date: DateTime(2026, 9, 9)));
      await c.addScheduleEvent(named('x', '测试日程乙'));
      int idx(String id) => c.otherColorIndexOf(eventById(id));
      final ia = idx('a');
      final ix = idx('x');
      expect(idx('b'), ia);
      final stored = await ScheduleStore.readOtherColors();
      expect(stored, {'测试日程甲': ia, '测试日程乙': ix});
      expect(colorsFile.readAsStringSync(), colorsBefore);
      expect(colorsFile.readAsStringSync(), isNot(contains('测试日程')));

      await restart();
      expect(idx('a'), ia);
      expect(idx('b'), ia);
      expect(idx('x'), ix);
      expect(await ScheduleStore.readOtherColors(), stored);
      expect(colorsFile.readAsStringSync(), isNot(contains('测试日程')));
    });

    test('EV26 adding/deleting 3 「其他」 events leaves course colours and course_colors.json unchanged', () async {
      await seed([
        _jwxt('j1', '高等数学'),
        _jwxt('j2', '大学物理', day: 2),
        _jwxt('j3', '线性代数', day: 3),
      ]);
      final file = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final bytes = file.readAsBytesSync();
      final before = {for (final x in c.courses) x.id: c.colorIndexOf(x)};
      for (var i = 0; i < 3; i++) {
        final e = await c.addScheduleEvent(named('o$i', '测试日程$i'));
        expect(await c.deleteScheduleEvent(e.id), isTrue);
      }
      expect({for (final x in c.courses) x.id: c.colorIndexOf(x)}, before);
      expect(file.readAsBytesSync(), bytes);
    });

    test(
      'EV27 courses use all 16 colours → 「其他」 falls back to the name hash',
      () async {
        await c.ensureStarted();
        for (var i = 0; i < kCoursePaletteSize; i++) {
          await c.addManualCourse(
            Course(
              id: 'm$i',
              name: '测试课$i',
              source: CourseSource.manual,
              colorIndex: i,
              slots: [
                CourseSlot(
                  day: i % 7 + 1,
                  startNode: i ~/ 7 * 2 + 1,
                  endNode: i ~/ 7 * 2 + 2,
                  weeks: '1' * 16,
                ),
              ],
            ),
          );
        }
        expect(
          {for (final x in c.courses) c.colorIndexOf(x)},
          {for (var i = 0; i < kCoursePaletteSize; i++) i},
        );
        final e = await c.addScheduleEvent(named('o1', '测试日程丙'));
        final idx = c.otherColorIndexOf(e);
        expect(idx, courseColorIndexForName('测试日程丙'));
        expect(idx, inInclusiveRange(0, kCoursePaletteSize - 1));
      },
    );

    test('EV29 renaming to an existing name takes that colour; no new map entry (restart)', () async {
      await c.ensureStarted();
      await c.addScheduleEvent(named('a', '测试日程甲'));
      await c.addScheduleEvent(named('b', '测试日程乙'));
      final ca = c.otherColorIndexOf(eventById('a'));
      expect(c.otherColorIndexOf(eventById('b')), isNot(ca));
      await c.updateScheduleEvent(eventById('b').copyWith(title: '测试日程甲'));
      expect(c.otherColorIndexOf(eventById('b')), ca);
      expect((await ScheduleStore.readOtherColors()).keys.toSet(), {
        '测试日程甲',
        '测试日程乙',
      });
      await restart();
      expect(c.otherColorIndexOf(eventById('b')), ca);
      expect(await ScheduleStore.readOtherColors(), hasLength(2));
    });

    test('EV30 renaming to a brand-new name keeps the colour; new name maps to it (restart)', () async {
      await c.ensureStarted();
      await c.addScheduleEvent(named('b', '测试日程乙'));
      final cb = c.otherColorIndexOf(eventById('b'));
      await c.updateScheduleEvent(eventById('b').copyWith(title: '测试日程丁'));
      expect(c.otherColorIndexOf(eventById('b')), cb);
      expect((await ScheduleStore.readOtherColors())['测试日程丁'], cb);
      await restart();
      expect(eventById('b').title, '测试日程丁');
      expect(c.otherColorIndexOf(eventById('b')), cb);
    });
  });
}
