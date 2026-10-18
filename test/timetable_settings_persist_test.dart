import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

void main() {
  late Directory tmp;
  final c = TimetableController.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_persist');
    TimetableStore.debugDirectory = tmp;
    c.debugReset();
  });

  tearDown(() async {
    TimetableController.bindingCheck = () async => false;
    TimetableStore.debugDirectory = null;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test(
    'successful sync does not rewrite settings.json (periodHeight 44 kept)',
    () async {
      final settingsFile = File('${tmp.path}/settings.json');
      await settingsFile.writeAsString(jsonEncode({'periodHeight': 44}));
      final before = await settingsFile.readAsString();

      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(settings: baseSettings!);

      await c.ensureStarted();
      await c.syncFromJwxt();

      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.settings.periodHeight, 52);
      // 同步只可能合并学期四键；其余（periodHeight 原值 44）不动。
      final after = jsonDecode(await settingsFile.readAsString()) as Map;
      final orig = jsonDecode(before) as Map;
      after.removeWhere((k, _) => TimetableStore.termSettingKeys.contains(k));
      expect(after, orig);
      expect(after['periodHeight'], 44);
    },
  );

  Future<Map<String, dynamic>> readFile() async =>
      jsonDecode(await File('${tmp.path}/settings.json').readAsString())
          as Map<String, dynamic>;

  void fakeOkFetch() {
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(settings: baseSettings!);
  }

  test(
    'S03c: sync, unbind, re-login+sync keep periodHeight 44 and switches',
    () async {
      final stored = {
        'periodHeight': 44,
        'showSaturday': false,
        'showSunday': false,
        'showNonCurrentWeek': true,
        'showGridLines': false,
        'termCode': '2025-2026-2',
      };
      await File('${tmp.path}/settings.json').writeAsString(jsonEncode(stored));
      fakeOkFetch();

      void expectUserFields(Map<String, dynamic> f) {
        for (final k in [
          'periodHeight',
          'showSaturday',
          'showSunday',
          'showNonCurrentWeek',
          'showGridLines',
        ]) {
          expect(f[k], stored[k], reason: k);
        }
      }

      await c.ensureStarted();
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.settings.periodHeight, 52);
      expectUserFields(await readFile());

      final displayBefore = c.settings;
      await c.handleLogout();
      // 解绑后（不重启）内存展示设置不变，学期字段被重置。
      final m = c.settings;
      expect(m.periodHeight, displayBefore.periodHeight);
      expect(m.periodHeight, 52);
      expect(m.showSaturday, isFalse);
      expect(m.showSunday, isFalse);
      expect(m.showNonCurrentWeek, isTrue);
      expect(m.showGridLines, isFalse);
      expect(m.cellRadius, displayBefore.cellRadius);
      expect(m.nodesPerDay, displayBefore.nodesPerDay);
      expect(m.weekStartsOnMonday, displayBefore.weekStartsOnMonday);
      expect(m.scheduleName, displayBefore.scheduleName);
      expect(m.termStartFromJwxt, isFalse);
      final afterUnbind = await readFile();
      expectUserFields(afterUnbind);
      expect(afterUnbind.containsKey('termCode'), isFalse);

      c.debugReset();
      fakeOkFetch();
      await c.ensureStarted();
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expectUserFields(await readFile());
    },
  );

  test(
    'S03e: unknown key futureKey preserved through sync and unbind',
    () async {
      await File('${tmp.path}/settings.json').writeAsString(
        jsonEncode({
          'periodHeight': 44,
          'futureKey': {'a': 1},
        }),
      );
      fakeOkFetch();
      await c.ensureStarted();
      await c.syncFromJwxt();
      expect((await readFile())['futureKey'], {'a': 1});
      await c.handleLogout();
      final f = await readFile();
      expect(f['futureKey'], {'a': 1});
      expect(f['periodHeight'], 44);
    },
  );

  test('S03e: updateSettings merges only changed keys into raw file', () async {
    await File('${tmp.path}/settings.json')
        .writeAsString(jsonEncode({'periodHeight': 44, 'futureKey': 1}));
    await c.ensureStarted();
    expect(c.settings.showSaturday, isTrue);
    await c.updateSettings(c.settings.copyWith(showSaturday: false));
    final f = await readFile();
    expect(f['futureKey'], 1);
    expect(f['periodHeight'], 44);
    expect(f['showSaturday'], isFalse);
    expect(c.settings.showSaturday, isFalse);
  });

  group('term keys on sync', () {
    final termKeys = TimetableStore.termSettingKeys;
    final origClock = TimetableController.clock;
    tearDown(() => TimetableController.clock = origClock);

    Course jwxtCourse(String weeks) => Course(
      id: 'j1',
      name: '高数',
      source: CourseSource.jwxt,
      slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
    );

    void fakeTermFetch({required int maxWeeks, String? weeks}) {
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            settings: baseSettings!.copyWith(
              termCode: '2026-2027-1',
              termStartDate: DateTime(2026, 8, 31),
              termStartFromJwxt: true,
              maxWeeks: maxWeeks,
            ),
            courses: [if (weeks != null) jwxtCourse(weeks)],
          );
    }

    test(
      '(a) sync without changed term data keeps settings.json bytes',
      () async {
        TimetableController.clock = () => DateTime(2026, 10, 11);
        final file = File('${tmp.path}/settings.json');
        await file.writeAsString(
          jsonEncode({
            'periodHeight': 44,
            'showSaturday': false,
            'futureKey': 'x',
            'termCode': '2026-2027-1',
            'termStartDate': '2026-08-31',
            'maxWeeks': 30,
            'termStartFromJwxt': true,
          }),
        );
        final before = await file.readAsBytes();
        final mtime = await file.lastModified();
        fakeTermFetch(maxWeeks: 30);
        await c.ensureStarted();
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(await file.readAsBytes(), before);
        expect(await file.lastModified(), mtime);
      },
    );

    test('(b) sync with term data changes only the 4 term keys', () async {
      TimetableController.clock = () => DateTime(2026, 10, 11);
      final orig = {
        'periodHeight': 44,
        'showSaturday': false,
        'showSunday': false,
        'showNonCurrentWeek': true,
        'futureKey': {'n': 1},
      };
      await File('${tmp.path}/settings.json').writeAsString(jsonEncode(orig));
      fakeTermFetch(maxWeeks: 30);
      await c.ensureStarted();
      await c.syncFromJwxt();
      final f = await readFile();
      for (final e in orig.entries) {
        expect(f[e.key], e.value, reason: e.key);
      }
      expect(f.keys.toSet(), {...orig.keys, ...termKeys});
      expect(f['termCode'], '2026-2027-1');
      expect(f['termStartDate'], '2026-08-31');
      expect(f['maxWeeks'], 30);
      expect(f['termStartFromJwxt'], isTrue);
      expect(c.settings.termCode, '2026-2027-1');
      expect(c.settings.termStartFromJwxt, isTrue);
    });

    test('(c) unbind then re-sync: currentWeek 6, totalWeeks 18', () async {
      TimetableController.clock = () => DateTime(2026, 10, 11);
      await File('${tmp.path}/settings.json')
          .writeAsString(jsonEncode({'periodHeight': 44}));
      fakeTermFetch(maxWeeks: 30, weeks: '${'1' * 10}${'0' * 20}');
      await c.ensureStarted();
      await c.syncFromJwxt();
      await c.handleLogout();
      expect(c.settings.termStartFromJwxt, isFalse);
      expect(c.totalWeeks, 20); // 解绑后无课程 -> 20

      // SKZC 最高位 18
      fakeTermFetch(maxWeeks: 30, weeks: '${'0' * 17}1${'0' * 12}');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.settings.termStartDate, DateTime(2026, 8, 31));
      expect(c.settings.termStartFromJwxt, isTrue);
      expect(c.totalWeeks, 18);
      expect(c.currentWeek, 6);
      final f = await readFile();
      expect(f['termStartFromJwxt'], isTrue);
      expect(f['periodHeight'], 44);
    });
  });

  group('W02 totalWeeks', () {
    final origClock = TimetableController.clock;
    tearDown(() => TimetableController.clock = origClock);
    setUp(() => TimetableController.clock = () => DateTime(2026, 10, 11));

    String bits(int lastWeek) => '${'1' * lastWeek}${'0' * (30 - lastWeek)}';
    Course course(String id, String weeks, CourseSource src) => Course(
      id: id,
      name: id,
      source: src,
      slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
    );
    TimetableSnapshot snap(List<Course> courses) => TimetableSnapshot(
      settings: TimetableSettings(
        termCode: '2026-2027-1',
        termStartDate: DateTime(2026, 8, 31),
        termStartFromJwxt: true,
      ),
      periods: TimetableController.defaultPeriods(),
      courses: courses,
    );

    test('JWXT max 18 -> 18', () {
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: const [],
      );
      expect(c.totalWeeks, 18);
    });

    test('JWXT 18 + manual week 20 -> 20', () {
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: [course('m', bits(20), CourseSource.manual)],
      );
      expect(c.totalWeeks, 20);
    });

    test('no courses -> 20', () {
      c.debugSetSnapshot(snap(const []), manualCourses: const []);
      expect(c.totalWeeks, 20);
    });

    test('unparseable/unscheduled courses excluded', () {
      c.debugSetSnapshot(
        snap([
          course('j', bits(12), CourseSource.jwxt),
          const Course(
            id: 'other',
            name: '其他',
            source: CourseSource.jwxt,
            slots: [
              CourseSlot(
                day: 0,
                startNode: 0,
                endNode: 0,
                weeks: '',
                weeksLabel: '2-25周',
              ),
            ],
          ),
          const Course(id: 'noslot', name: 'x', source: CourseSource.jwxt),
        ]),
        manualCourses: const [],
      );
      expect(c.totalWeeks, 12);
      c.debugSetSnapshot(
        snap(const [
          Course(id: 'noslot', name: 'x', source: CourseSource.jwxt),
        ]),
        manualCourses: const [],
      );
      expect(c.totalWeeks, 20);
    });

    test('deleting week-20 manual course clamps viewingWeek to 18', () async {
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: [course('m', bits(20), CourseSource.manual)],
      );
      c.setViewingWeek(20);
      expect(c.viewingWeek, 20);
      expect(await c.deleteManualCourse('m'), isTrue);
      expect(c.totalWeeks, 18);
      expect(c.viewingWeek, 18);
      // 再加回第 20 周课：浏览周不被动改变，但可再翻到 20。
      await c.addManualCourse(course('m2', bits(20), CourseSource.manual));
      expect(c.totalWeeks, 20);
      expect(c.viewingWeek, 18);
    });

    test('unbind clamps viewingWeek; hasClassInWeek drives cells', () async {
      c.debugSetSnapshot(
        snap([course('j', bits(25), CourseSource.jwxt)]),
        manualCourses: const [],
      );
      c.setViewingWeek(25);
      expect(c.cellsForDay(25, 1).single.activeThisWeek, isTrue);
      expect(c.cellsForDay(26, 1), isEmpty);
      await c.handleLogout();
      expect(c.totalWeeks, 20);
      expect(c.viewingWeek, 20);
    });

    test('W02h-1: 08-30 (before term) today none, no reminders', () {
      TimetableController.clock = () => DateTime(2026, 8, 30);
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: const [],
      );
      expect(c.actualWeek(DateTime(2026, 8, 30)), 0);
      final items = c.todayCourses(now: DateTime(2026, 8, 30, 7));
      expect(items, isEmpty);
      expect(items.where((i) => i.minutesUntilStart != null), isEmpty);
    });

    test('W02h-2: 08-30 tomorrow shows week-1 Monday courses', () {
      TimetableController.clock = () => DateTime(2026, 8, 30);
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: const [],
      );
      final tomorrow = DateTime(2026, 8, 30).add(const Duration(days: 1));
      expect(c.actualWeek(tomorrow), 1);
      final items = c.coursesOnDate(tomorrow);
      expect(items.map((i) => i.course.id), ['j']);
      expect(items.single.slot.day, 1);
    });

    test('W02h-3: 08-24 no courses/reminders, currentWeek 1, paging ok', () {
      TimetableController.clock = () => DateTime(2026, 8, 24);
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: const [],
      );
      expect(c.actualWeek(DateTime(2026, 8, 24)), 0);
      expect(c.todayCourses(now: DateTime(2026, 8, 24, 7)), isEmpty);
      expect(c.coursesOnDate(DateTime(2026, 8, 24)), isEmpty);
      expect(c.currentWeek, 1);
      expect(c.viewingWeek, 1);
      c.setViewingWeek(0);
      expect(c.viewingWeek, 1);
      c.setViewingWeek(5);
      expect(c.viewingWeek, 5);
      c.goToCurrentWeek();
      expect(c.viewingWeek, 1);
    });

    test('W02f-2: actualWeek 19 with total 18 -> no courses/reminders', () {
      // 2027-01-04 是第 19 周周一
      TimetableController.clock = () => DateTime(2027, 1, 4);
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: const [],
      );
      expect(c.actualWeek(DateTime(2027, 1, 4)), 19);
      expect(c.totalWeeks, 18);
      expect(c.todayCourses(now: DateTime(2027, 1, 4, 7)), isEmpty);
      expect(c.coursesOnDate(DateTime(2027, 1, 4)), isEmpty);
      // 对照：第 18 周周一有课
      expect(c.coursesOnDate(DateTime(2026, 12, 28)), isNotEmpty);
    });

    test('today week 19 with total 18 -> currentWeek 19, viewing 18', () {
      // 2026-08-31 起第 19 周 = 2027-01-04 那周
      TimetableController.clock = () => DateTime(2027, 1, 6);
      c.debugSetSnapshot(
        snap([course('j', bits(18), CourseSource.jwxt)]),
        manualCourses: const [],
      );
      expect(c.totalWeeks, 18);
      expect(c.currentWeek, 19);
      expect(c.viewingWeek, 18);
      expect(() => c.goToCurrentWeek(), returnsNormally);
      expect(c.viewingWeek, 18);
      expect(() => c.todayCourses(), returnsNormally);
      expect(c.isViewingCurrentWeek, isFalse);
    });
  });
}
