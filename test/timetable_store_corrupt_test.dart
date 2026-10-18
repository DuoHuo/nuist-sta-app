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

  group('corrupt user-edit files are backed up before overwrite', () {
    Future<void> check(String name, Future<void> Function() save) async {
      final f = File('${tmp.path}/$name');
      f.writeAsStringSync('{broken user edits');
      await save();
      final backup = File('${tmp.path}/$name.corrupt');
      expect(backup.existsSync(), isTrue);
      expect(backup.readAsStringSync(), '{broken user edits');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), isNot('{broken user edits'));
    }

    test('course_edits.json: corrupt, then save, backup survives', () async {
      await check(
        ScheduleStore.courseEditsFile,
        () => ScheduleStore.saveCourseEdits({
          'j1': const CourseEdit(courseId: 'j1', origFingerprint: 'fp'),
        }),
      );
    });

    test('exam_overrides.json: corrupt, then save, backup survives', () async {
      await check(
        ScheduleStore.examOverridesFile,
        () => ScheduleStore.saveExamOverrides({
          'k1': const ExamOverride(key: 'k1', deleted: true),
        }),
      );
    });

    test('a second corruption does not overwrite the first backup', () async {
      final name = ScheduleStore.courseEditsFile;
      File('${tmp.path}/$name').writeAsStringSync('first');
      await ScheduleStore.readCourseEdits();
      File('${tmp.path}/$name').writeAsStringSync('second');
      await ScheduleStore.readCourseEdits();
      expect(File('${tmp.path}/$name.corrupt').readAsStringSync(), 'first');
      final extra = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('$name.corrupt.'))
          .toList();
      expect(extra, hasLength(1));
      expect(extra.single.readAsStringSync(), 'second');
    });
  });

  group('FC 本地存储文件损坏', () {
    final names = [
      ScheduleStore.scheduleEventsFile,
      ScheduleStore.courseEditsFile,
      ScheduleStore.examOverridesFile,
      ScheduleStore.syncStateFile,
    ];
    File f(String n) => File('${tmp.path}/$n');
    List<File> stamped(String n) => tmp
        .listSync()
        .whereType<File>()
        .where((x) => x.path.contains('$n.corrupt.'))
        .toList();

    test(
      'FC01 corrupt schedule_events.json → .corrupt, empty, new event saved',
      () async {
        final n = ScheduleStore.scheduleEventsFile;
        f(n).writeAsStringSync('{not json');
        await c.ensureStarted();
        expect(f('$n.corrupt').readAsStringSync(), '{not json');
        expect(f(n).existsSync(), isFalse);
        expect(c.scheduleEvents, isEmpty);
        await c.addScheduleEvent(_other('o1'));
        expect((await ScheduleStore.readEvents()).map((e) => e.id), ['o1']);
        await restart();
        expect(c.scheduleEvents.map((e) => e.id), ['o1']);
        expect(f('$n.corrupt').readAsStringSync(), '{not json');
      },
    );

    test(
      'FC02 corrupt course_edits.json → .corrupt; jwxt course shown as-is',
      () async {
        final n = ScheduleStore.courseEditsFile;
        await seed([_jwxt('j1', '高等数学')]);
        await c.editJwxtCourse('j1', name: 'A');
        f(n).writeAsStringSync('{"edits": [');
        await restart();
        expect(f('$n.corrupt').readAsStringSync(), '{"edits": [');
        expect(c.courseEditOf('j1'), isNull);
        expect(c.isJwxtOverridden(courseId: 'j1'), isFalse);
        expect(shown('j1').name, '高等数学');
      },
    );

    test(
      'FC03 corrupt exam_overrides.json → .corrupt; jwxt exam shown as-is',
      () async {
        final n = ScheduleStore.examOverridesFile;
        await seed([_jwxt('j1', '高等数学')]);
        await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
        await c.updateScheduleEvent(
          _exam('e1', 'MATH01').copyWith(location: '体育馆'),
        );
        expect(eventById('e1').location, '体育馆');
        f(n).writeAsStringSync('oops');
        await restart();
        expect(f('$n.corrupt').readAsStringSync(), 'oops');
        expect(c.isJwxtOverridden(examKey: c.jwxtExamKeyOf('e1')), isFalse);
        expect(eventById('e1').location, '教二-201');
      },
    );

    test('FC04 corrupt sync_state.json → .corrupt; no last success, start syncs once', () async {
      final n = ScheduleStore.syncStateFile;
      await seed([_jwxt('j1', '高等数学')]);
      var fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        return _snap(nextFetch);
      };
      f(n).writeAsStringSync('{"lastSuccessAt":');
      await restart();
      expect(f('$n.corrupt').readAsStringSync(), '{"lastSuccessAt":');
      expect(c.lastSyncSuccessAt, isNull);
      expect(await c.onAppStart(), isTrue);
      expect(fetches, 1);
      expect(c.lastSyncSuccessAt, isNotNull);
    });

    test(
      'FC05 existing .corrupt kept; new backup gets a timestamp (all 4 files)',
      () async {
        for (final n in names) {
          f('$n.corrupt').writeAsStringSync('old-$n');
          f(n).writeAsStringSync('new-$n');
        }
        await c.ensureStarted();
        for (final n in names) {
          expect(f('$n.corrupt').readAsStringSync(), 'old-$n', reason: n);
          final s = stamped(n);
          expect(s, hasLength(1), reason: n);
          expect(s.single.readAsStringSync(), 'new-$n');
          expect(RegExp(r'\.corrupt\.\d+$').hasMatch(s.single.path), isTrue);
        }
      },
    );

    test(
      'FC07 truncated file or wrong top-level type is treated as corrupt',
      () async {
        const variants = {
          'truncated': '{"schemaVersion": 1, "events": [{"id": "x"',
          'array': '[]',
          'array of objects': '[{"schemaVersion": 1}]',
          'string': '"text"',
        };
        for (final v in variants.entries) {
          for (final n in names) {
            for (final x in tmp.listSync().whereType<File>()) {
              if (x.path.contains('.corrupt')) x.deleteSync();
            }
            f(n).writeAsStringSync(v.value);
            await restart();
            expect(f('$n.corrupt').existsSync(), isTrue, reason: '${v.key} $n');
            expect(f('$n.corrupt').readAsStringSync(), v.value);
          }
        }
        expect(c.scheduleEvents, isEmpty);
        expect(c.lastSyncSuccessAt, isNull);
        expect(await ScheduleStore.readCourseEdits(), isEmpty);
        expect(await ScheduleStore.readExamOverrides(), isEmpty);
      },
    );

    test(
      'FC08 only the corrupt file is backed up; others read normally',
      () async {
        await seed([_jwxt('j1', '高等数学')]);
        await c.editJwxtCourse('j1', name: 'A');
        await c.addScheduleEvent(_other('o1'));
        await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
        final lastOk = c.lastSyncSuccessAt;
        expect(lastOk, isNotNull);
        f(ScheduleStore.examOverridesFile).writeAsStringSync('{broken');
        await restart();
        expect(
          f('${ScheduleStore.examOverridesFile}.corrupt').existsSync(),
          isTrue,
        );
        for (final n in names) {
          if (n == ScheduleStore.examOverridesFile) continue;
          expect(f('$n.corrupt').existsSync(), isFalse, reason: n);
          expect(stamped(n), isEmpty, reason: n);
        }
        expect(shown('j1').name, 'A');
        expect(c.scheduleEvents.map((e) => e.id).toSet(), {'o1', 'e1'});
        expect(c.lastSyncSuccessAt, lastOk);
      },
    );
  });
}
