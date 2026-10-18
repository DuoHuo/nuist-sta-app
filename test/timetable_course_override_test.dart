import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
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
  group('jwxt course edit / delete', () {
    test('edit shows new fields; delete hides; restore clears all', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      expect(
        await c.editJwxtCourse('j1', name: '高数（改）', location: '教三-303'),
        isTrue,
      );
      final j1 = shown('j1');
      expect(j1.name, '高数（改）');
      expect(j1.slots.single.location, '教三-303');
      expect(j1.slots.single.teacher, '张老师');
      expect(c.isJwxtOverridden(courseId: 'j1'), isTrue);
      expect(c.jwxtCourses.firstWhere((x) => x.id == 'j1').name, '高等数学');

      expect(await c.deleteJwxtCourse('j2'), isTrue);
      expect(c.courses.any((x) => x.id == 'j2'), isFalse);
      expect(c.cellsForDay(2, 2), isEmpty);
      expect(c.deletedJwxtCourses.map((x) => x.id), ['j2']);

      await restart();
      expect(shown('j1').name, '高数（改）');
      expect(c.courses.any((x) => x.id == 'j2'), isFalse);

      expect(await c.restoreJwxtCourse('j2'), isTrue);
      expect(shown('j2').name, '大学物理');
      expect(c.isJwxtOverridden(courseId: 'j2'), isFalse);
      expect(await c.restoreJwxtCourse('j2'), isFalse);
    });

    test('restoreJwxtCourse also clears move overrides', () async {
      await seed([_jwxt('j1', '高等数学')]);
      final r = await c.moveSlot(
        shown('j1'),
        0,
        toDay: 4,
        toStartPeriod: 3,
        week: 2,
        scope: MoveScope.thisWeek,
      );
      expect(r.status, MoveStatus.moved);
      await c.editJwxtCourse('j1', note: '带计算器');
      expect(c.slotOverrides, isNotEmpty);
      expect(await c.restoreJwxtCourse('j1'), isTrue);
      expect(c.slotOverrides, isEmpty);
      expect(c.courseEditOf('j1'), isNull);
      expect(shown('j1').slots.single.note, '');
    });

    test(
      'EX22 restoreAllJwxt clears moves, edits, deletes and exam overrides',
      () async {
        await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
        await c.moveSlot(
          shown('j1'),
          0,
          toDay: 4,
          toStartPeriod: 3,
          week: 2,
          scope: MoveScope.fromThisWeek,
        );
        await c.editJwxtCourse('j1', name: '高数（改）');
        await c.deleteJwxtCourse('j2');
        await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
        await c.deleteScheduleEvent('e1');
        expect(c.scheduleEvents, isEmpty);

        expect(await c.restoreAllJwxt(), isTrue);
        expect(c.slotOverrides, isEmpty);
        expect(c.courseEditOf('j1'), isNull);
        expect(c.courseEditOf('j2'), isNull);
        expect(shown('j1').name, '高等数学');
        expect(shown('j2').name, '大学物理');
        expect(c.scheduleEvents.map((e) => e.id), ['e1']);
        expect(await c.restoreAllJwxt(), isFalse);
        await restart();
        expect(c.slotOverrides, isEmpty);
        expect(c.courses.length, 2);
        expect(c.scheduleEvents.map((e) => e.id), ['e1']);
      },
    );

    test('renaming keeps the colour (original name lookup)', () async {
      await seed([
        _jwxt('j1', '高等数学'),
        _jwxt('j2', '大学物理', day: 2),
        _jwxt('j3', '线性代数', day: 3),
      ]);
      final before = c.colorIndexOf(shown('j1'));
      final colorsFile = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final colorsBefore = colorsFile.readAsStringSync();
      await c.editJwxtCourse('j1', name: '线性代数');
      expect(shown('j1').name, '线性代数');
      expect(c.colorIndexOf(shown('j1')), before);
      expect(colorsFile.readAsStringSync(), colorsBefore);
      await restart();
      expect(c.colorIndexOf(shown('j1')), before);
    });

    test('JE10 edit invalidated after sync when SKZC weeks change', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      await c.editJwxtCourse('j1', name: 'A');
      await c.editJwxtCourse('j2', name: 'B');
      nextFetch = [
        _jwxt('j1', '高等数学', weeks: '1111111100000000'),
        _jwxt('j2', '大学物理', day: 2),
      ];
      await c.syncFromJwxt();
      expect(c.courseEditOf('j1'), isNull);
      expect(shown('j1').name, '高等数学');
      expect(shown('j2').name, 'B', reason: 'unchanged course keeps edit');
      expect((await ScheduleStore.readCourseEdits()).keys, ['j2']);
    });

    test(
      'JE11 edit invalidated after sync when slot time changes or course gone',
      () async {
        await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
        await c.deleteJwxtCourse('j1');
        await c.editJwxtCourse('j2', teacher: '李老师');
        nextFetch = [_jwxt('j1', '高等数学', start: 3, end: 4)];
        await c.syncFromJwxt();
        expect(c.courseEditOf('j1'), isNull);
        expect(c.courseEditOf('j2'), isNull);
        expect(c.courses.any((x) => x.id == 'j1'), isTrue);
      },
    );

    test('edits survive a failed sync', () async {
      await seed([_jwxt('j1', '高等数学')]);
      await c.editJwxtCourse('j1', name: 'A');
      TimetableController.fetchSnapshot = (t, {baseSettings}) async =>
          throw const SocketException('offline');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(shown('j1').name, 'A');
    });
  });

  group('JE 教务课编辑 / 删除（§24.8 单测）', () {
    test(
      'JE05 deleted jwxt course stays hidden after a successful sync',
      () async {
        await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
        await c.deleteJwxtCourse('j2');
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(c.courses.any((x) => x.id == 'j2'), isFalse);
        expect(c.cellsForDay(2, 2), isEmpty);
        await restart();
        expect(c.courses.any((x) => x.id == 'j2'), isFalse);
        expect(c.courseEditOf('j2')?.deleted, isTrue);
      },
    );

    test('JE09 EX22 restore all clears edits/deletes/moves/exam overrides; manual data untouched', () async {
      await seed(
        [_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)],
        manual: [_manual('m1', '自习')],
      );
      await c.addScheduleEvent(manualExam());
      await c.addScheduleEvent(_other('o1'));
      await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
      final r = await c.moveSlot(
        shown('j1'),
        0,
        toDay: 4,
        toStartPeriod: 3,
        week: 2,
        scope: MoveScope.thisWeek,
      );
      expect(r.status, MoveStatus.moved);
      await c.editJwxtCourse('j1', name: 'A');
      await c.deleteJwxtCourse('j2');
      await c.updateScheduleEvent(eventById('e1').copyWith(location: '体育馆'));
      final k1 = c.jwxtExamKeyOf('e1')!;
      final manualEvents = manualEventsJson();
      final manualCourses = jsonEncode([
        for (final m in c.manualCourses) m.toJson(),
      ]);

      expect(await c.restoreAllJwxt(), isTrue);
      Future<void> check() async {
        expect(c.slotOverrides, isEmpty);
        expect(c.courseEditOf('j1'), isNull);
        expect(c.courseEditOf('j2'), isNull);
        expect(shown('j1').name, '高等数学');
        expect(shown('j2').name, '大学物理');
        expect(c.isJwxtOverridden(examKey: k1), isFalse);
        expect(eventById('e1').location, '教二-201');
        expect(await ScheduleStore.readExamOverrides(), isEmpty);
        expect(await ScheduleStore.readCourseEdits(), isEmpty);
        expect(manualEventsJson(), manualEvents);
        expect(
          jsonEncode([for (final m in c.manualCourses) m.toJson()]),
          manualCourses,
        );
      }

      await check();
      await restart();
      await check();
    });

    test('JE12 EX29 records survive failed sync, unbind and failed re-sync; apply again on success', () async {
      nextExams = [_exam('e1', 'MATH01')];
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      await c.editJwxtCourse('j1', name: 'A');
      await c.deleteJwxtCourse('j2');
      await c.updateScheduleEvent(eventById('e1').copyWith(location: '体育馆'));
      final k1 = c.jwxtExamKeyOf('e1')!;
      void expectApplied() {
        expect(shown('j1').name, 'A');
        expect(c.courses.any((x) => x.id == 'j2'), isFalse);
        expect(eventById('e1').location, '体育馆');
      }

      Future<void> expectStored() async {
        expect((await ScheduleStore.readCourseEdits()).keys.toSet(), {
          'j1',
          'j2',
        });
        expect((await ScheduleStore.readExamOverrides()).keys, [k1]);
      }

      final ok = TimetableController.fetchSnapshot;
      TimetableController.fetchSnapshot = (t, {baseSettings}) async =>
          throw const SocketException('offline');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expectApplied();
      await expectStored();

      await c.handleLogout();
      expect(c.courses, isEmpty);
      expect(c.scheduleEvents.where((e) => e.isFromJwxt), isEmpty);
      await expectStored();

      // 重新绑定后同步失败：记录仍在，无教务数据可套用，不崩溃。
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.courses, isEmpty);
      await expectStored();
      await restart();
      await expectStored();

      TimetableController.fetchSnapshot = ok;
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expectApplied();
    });

    test(
      'JE13 colour index stays through edit/restore and delete/restore all',
      () async {
        await seed([
          _jwxt('j1', '高等数学'),
          _jwxt('j2', '大学物理', day: 2),
          _jwxt('j3', '线性代数', day: 3),
        ]);
        final idx = c.colorIndexOf(shown('j1'));
        await c.editJwxtCourse('j1', name: '测试课乙', teacher: '李老师');
        expect(c.colorIndexOf(shown('j1')), idx);
        await c.restoreJwxtCourse('j1');
        expect(c.colorIndexOf(shown('j1')), idx);
        await c.deleteJwxtCourse('j1');
        await c.restoreAllJwxt();
        expect(c.colorIndexOf(shown('j1')), idx);
        await restart();
        expect(c.colorIndexOf(shown('j1')), idx);
      },
    );

    test('JE14 old data without edit/delete files: no records, nothing written back', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      final newFiles = [
        ScheduleStore.scheduleEventsFile,
        ScheduleStore.courseEditsFile,
        ScheduleStore.examOverridesFile,
        ScheduleStore.syncStateFile,
      ];
      for (final n in newFiles) {
        final x = File('${tmp.path}/$n');
        if (x.existsSync()) x.deleteSync();
      }
      await restart();
      expect(c.courses.map((x) => x.id).toSet(), {'j1', 'j2'});
      expect(c.courseEditOf('j1'), isNull);
      expect(c.deletedJwxtCourses, isEmpty);
      expect(c.isJwxtOverridden(courseId: 'j1'), isFalse);
      expect(c.scheduleEvents, isEmpty);
      for (final n in newFiles) {
        expect(File('${tmp.path}/$n').existsSync(), isFalse, reason: n);
      }
    });

    test('JE20 rename/teacher edit never re-colours: across schemes, sync and restart', () async {
      await seed([
        _jwxt('j1', '高等数学'),
        _jwxt('j2', '大学物理', day: 2),
        _jwxt('j3', '线性代数', day: 3),
      ]);
      Map<String, int> colours() => {
        for (final x in c.courses) x.id: c.colorIndexOf(x),
      };
      final expected = <String, Map<String, int>>{};
      for (final s in ['B', 'C', 'A']) {
        await c.updateSettings(c.settings.copyWith(paletteScheme: s));
        expected[s] = colours();
      }
      // 改成与 j3 同名，并改老师。
      await c.editJwxtCourse('j1', name: '线性代数', teacher: '李老师');
      Future<void> check(String when) async {
        for (final s in ['B', 'C', 'A']) {
          await c.updateSettings(c.settings.copyWith(paletteScheme: s));
          expect(colours(), expected[s], reason: '$when / scheme $s');
        }
      }

      await check('after edit');
      await c.syncFromJwxt();
      expect(shown('j1').name, '线性代数');
      await check('after sync');
      await restart();
      await check('after restart');
    });

    test('JE21 restore course clears its edits and moves only; other course keeps its move', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      for (final (id, day) in [('j1', 4), ('j2', 5)]) {
        final r = await c.moveSlot(
          shown(id),
          0,
          toDay: day,
          toStartPeriod: 3,
          week: 2,
          scope: MoveScope.thisWeek,
        );
        expect(r.status, MoveStatus.moved, reason: id);
      }
      final j2Moves = [
        for (final o in c.slotOverrides)
          if (o.courseId == 'j2') o.id,
      ];
      expect(j2Moves, isNotEmpty);
      await c.editJwxtCourse('j1', name: 'A', location: '教三-303');

      expect(await c.restoreJwxtCourse('j1'), isTrue);
      expect(c.courseEditOf('j1'), isNull);
      expect(c.slotOverrides.any((o) => o.courseId == 'j1'), isFalse);
      expect([for (final o in c.slotOverrides) o.id], j2Moves);
      expect(c.isJwxtOverridden(courseId: 'j1'), isFalse);
      expect(c.isJwxtOverridden(courseId: 'j2'), isTrue);
      expect(shown('j1').name, '高等数学');
      expect(shown('j1').slots.single.location, '教一-101');
      expect(c.cellsForDay(2, 1).any((g) => g.course.id == 'j1'), isTrue);
      expect(c.cellsForDay(2, 4).any((g) => g.course.id == 'j1'), isFalse);
    });
  });
}
