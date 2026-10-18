import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

Course _jwxt(String id, {String weeks = '1111111111111111'}) => Course(
  id: id,
  name: 'JWXT $id',
  source: CourseSource.jwxt,
  slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
);

Course _manual(String name, {String weeks = '11111111'}) => Course(
  id: '',
  name: name,
  slots: [CourseSlot(day: 3, startNode: 5, endNode: 6, weeks: weeks)],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_manual');
    TimetableStore.debugDirectory = tmp;
    c.debugReset();
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_jwxt('j1'), _jwxt('j2')],
          settings: baseSettings ?? const TimetableSettings(),
        );
    await c.ensureStarted();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('isManual flag', () {
    expect(_manual('x').isManual, isTrue);
    expect(_jwxt('j').isManual, isFalse);
  });

  test('CRUD on manual courses', () async {
    final a = await c.addManualCourse(_manual('自习'));
    expect(a.id, isNotEmpty);
    expect(a.isManual, isTrue);
    expect(c.manualCourses, hasLength(1));
    expect(c.combinedCourses.map((e) => e.name), contains('自习'));

    final upd = await c.updateManualCourse(a.copyWith(name: '自习2'));
    expect(upd.name, '自习2');
    expect(c.manualCourseById(a.id)!.name, '自习2');

    expect(await c.deleteManualCourse(a.id), isTrue);
    expect(c.manualCourses, isEmpty);
    expect(await c.deleteManualCourse(a.id), isFalse);
  });

  test('JWXT courses are read-only via manual API', () async {
    await c.syncFromJwxt();
    expect(c.jwxtCourses, hasLength(2));
    expect(
      () => c.updateManualCourse(_jwxt('j1').copyWith(name: 'hack')),
      throwsStateError,
    );
    expect(await c.deleteManualCourse('j1'), isFalse);
    expect(c.jwxtCourses, hasLength(2));
    // 新增时 source 被强制为 manual，且 id 不与教务冲突
    final added = await c.addManualCourse(_jwxt('j1'));
    expect(added.isManual, isTrue);
    expect(added.id, isNot('j1'));
  });

  test(
    'sync preserves manual courses and drops manual from JWXT payload',
    () async {
      await c.addManualCourse(_manual('社团'));
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_jwxt('j9'), _manual('stray')],
            settings: baseSettings ?? const TimetableSettings(),
          );
      await c.syncFromJwxt();
      expect(c.jwxtCourses.map((e) => e.id), ['j9']);
      expect(c.manualCourses.map((e) => e.name), ['社团']);
      expect(c.combinedCourses, hasLength(2));
      // 再同步一次仍保留
      await c.syncFromJwxt();
      expect(c.manualCourses.map((e) => e.name), ['社团']);
    },
  );

  test('logout clears JWXT by default, keeps manual', () async {
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_jwxt('j1'), _jwxt('j2')],
          settings: (baseSettings ?? const TimetableSettings()).copyWith(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 9, 7),
            termStartFromJwxt: true,
            maxWeeks: 25,
          ),
        );
    await c.updateSettings(
      const TimetableSettings(
        periodHeight: 72,
        showSaturday: false,
        showSunday: false,
        showNonCurrentWeek: true,
      ),
    );
    await c.syncFromJwxt();
    await c.addManualCourse(_manual('健身'));
    expect(File('${tmp.path}/snapshot.json').existsSync(), isTrue);
    expect(c.settings.termStartFromJwxt, isTrue);
    expect(c.settings.termCode, '2026-2027-1');
    expect(c.settings.maxWeeks, 25);

    await c.handleLogout();
    expect(c.portalBound, isFalse);
    expect(c.manualCourses, hasLength(1));
    expect(c.jwxtCourses, isEmpty);
    expect(c.settings.termStartFromJwxt, isFalse);
    expect(c.settings.termCode, isEmpty);
    expect(c.settings.maxWeeks, 30);
    expect(File('${tmp.path}/snapshot.json').existsSync(), isFalse);
    expect(File('${tmp.path}/manual_courses.json').existsSync(), isTrue);
    expect(File('${tmp.path}/settings.json').existsSync(), isTrue);

    // 重新读盘：教务空、手动在；展示设置保留；开学日可被内置 08-31 回填
    c.debugReset();
    await c.ensureStarted();
    expect(c.manualCourses.map((e) => e.name), ['健身']);
    expect(c.jwxtCourses, isEmpty);
    expect(c.settings.termStartFromJwxt, isFalse);
    expect(c.settings.periodHeight, 72);
    expect(c.settings.showSaturday, isFalse);
    expect(c.settings.showSunday, isFalse);
    expect(c.settings.showNonCurrentWeek, isTrue);
    expect(c.settings.termStartDate, DateTime(2026, 8, 31));

    // clearJwxt:false 时教务与手动都保留
    await c.syncFromJwxt();
    expect(c.jwxtCourses, hasLength(2));
    expect(File('${tmp.path}/snapshot.json').existsSync(), isTrue);
    await c.handleLogout(clearJwxt: false);
    expect(c.portalBound, isFalse);
    expect(c.jwxtCourses, hasLength(2));
    expect(c.manualCourses, hasLength(1));
    expect(File('${tmp.path}/snapshot.json').existsSync(), isTrue);
  });

  test('persistence reload', () async {
    await c.syncFromJwxt();
    final a = await c.addManualCourse(_manual('A'));
    await c.addManualCourse(_manual('B'));
    await c.updateManualCourse(a.copyWith(name: 'A2', colorIndex: 3));
    expect(File('${tmp.path}/manual_courses.json').existsSync(), isTrue);

    c.debugReset();
    expect(c.manualCourses, isEmpty);
    await c.ensureStarted();
    expect(c.manualCourses.map((e) => e.name), ['A2', 'B']);
    expect(c.manualCourses.first.colorIndex, 3);
    expect(c.manualCourses.every((e) => e.isManual), isTrue);
    expect(c.jwxtCourses.map((e) => e.id), ['j1', 'j2']);
  });

  test('totalWeeks = 所有课程最晚有课周（不看位串长度，无课 → 20）', () async {
    expect(c.totalWeeks, 20);
    // 30 位位串但最后有课在第 16 周 → 16（不看长度，也不再与 20 取大）
    await c.addManualCourse(_manual('m', weeks: '${'1' * 16}${'0' * 14}'));
    expect(c.totalWeeks, 16);
    // 无法解析（全 0）的课程不计入
    await c.addManualCourse(_manual('none', weeks: '0' * 30));
    expect(c.totalWeeks, 16);
    await c.syncFromJwxt();
    final latest = c.courses
        .map((x) => x.lastActiveWeek)
        .fold<int>(0, (a, b) => a > b ? a : b);
    expect(c.totalWeeks, latest > 0 ? latest : 20);
    await c.addManualCourse(_manual('late', weeks: '${'0' * 21}1${'0' * 8}'));
    expect(c.totalWeeks, 22);
  });
}
