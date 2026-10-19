// 第 1/5/7 条数据层 + 第 15 条剩余周判定 + 缺 day_swaps.json。全部虚构数据。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_apply_weeks_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_date_edits.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_day_swap_ui.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_delete_scope_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_remaining_weeks.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_color.dart';

const _settings = TimetableSettings(termCode: '2026-2027-1');
final _termStart = DateTime(2026, 8, 31);
final _mon2 = DateTime(2026, 9, 7);
final _tue2 = DateTime(2026, 9, 8);

Course _jwxt(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  String weeks = '1111111111111111',
  String teacher = '虚构老师',
  String location = '教一-101',
}) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: start + 1,
      weeks: weeks,
      teacher: teacher,
      location: location,
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

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  List<Course> nextFetch = const [];
  final origFetchExams = TimetableController.fetchExams;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_r2_data');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => _mon2;
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        _snap(nextFetch);
    TimetableController.fetchExams = (term) async => null;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    TimetableController.fetchExams = origFetchExams;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  Future<void> seed([List<Course>? courses]) async {
    nextFetch =
        courses ??
        [_jwxt('MATH|01', '高数'), _jwxt('ENG|01', '英语', day: 2, start: 3)];
    await c.ensureStarted();
    await c.syncFromJwxt();
  }

  GridCell cellOf(DateTime d, String id) => c
      .cellsForDay(c.weekOfDate(d), d.weekday)
      .firstWhere((x) => x.activeThisWeek && x.course.id == id);

  group('缺 day_swaps.json', () {
    test('文件不存在时读为空，可继续写入', () async {
      await seed();
      final f = File('${tmp.path}/${ScheduleStore.daySwapsFile}');
      expect(f.existsSync(), isFalse);
      await restart();
      expect(c.daySwaps, isEmpty);
      expect(await c.addDaySwap(_mon2, _tue2), isNotNull);
      expect(c.daySwaps, hasLength(1));
      expect(f.existsSync(), isTrue);
    });
  });

  group('第 15 条 remaining weeks', () {
    test('slot/course/exam helpers', () {
      const slot = CourseSlot(
        day: 1,
        startNode: 1,
        endNode: 2,
        weeks: '1111000000000000', // 1-4
      );
      expect(slotHasRemainingWeeks(slot, 2), isTrue);
      expect(slotHasRemainingWeeks(slot, 4), isFalse);
      expect(slotHasRemainingWeeks(slot, 8), isFalse);
      final course = _jwxt('x', 'x', weeks: '1111000000000000');
      expect(courseHasRemainingWeeks(course, 3), isTrue);
      expect(courseHasRemainingWeeks(course, 4), isFalse);
      expect(examHasRemainingWeeks(6, 5), isTrue);
      expect(examHasRemainingWeeks(5, 5), isFalse);
      expect(examHasRemainingWeeks(4, 5), isFalse);
    });

    test('非本周灰格：之后无课则隐藏', () async {
      nextFetch = [
        _jwxt('EARLY|01', '早课', weeks: '1100000000000000'), // 仅 1–2 周
      ];
      await c.ensureStarted();
      await c.syncFromJwxt();
      await c.updateSettings(c.settings.copyWith(showNonCurrentWeek: true));
      // 第 3 周周一：早课已无后续 → 不出现灰格
      final week3 = c.cellsForDay(3, 1);
      expect(week3.where((x) => x.course.id == 'EARLY|01'), isEmpty);
      // 第 1 周有课
      expect(
        c
            .cellsForDay(1, 1)
            .where((x) => x.activeThisWeek && x.course.id == 'EARLY|01'),
        isNotEmpty,
      );
    });
  });

  group('weeks 字段兼容', () {
    test('旧记录无 weeks/scope → oneDay；带 weeks 生效', () async {
      await seed();
      final legacy = CourseDateEdit.tryParse({
        'id': 'legacy',
        'courseId': 'MATH|01',
        'date': '2026-09-07',
        'origStart': 1,
        'origEnd': 2,
        'kind': 'edit',
        'name': '高数旧',
        'createdAt': '',
      })!;
      expect(legacy.scope, DateEditScope.oneDay);
      expect(legacy.weeks, isEmpty);

      final withWeeks = CourseDateEdit.tryParse({
        'id': 'w',
        'courseId': 'MATH|01',
        'date': '2026-09-07',
        'origStart': 1,
        'origEnd': 2,
        'kind': 'edit',
        'scope': 'weeks',
        'weeks': [3, 5, 7, 5],
        'location': '新地点',
        'createdAt': '',
      })!;
      expect(withWeeks.weeks, [3, 5, 7]);
      expect(withWeeks.isWeeksScoped, isTrue);

      final rec = await c.editOccurrenceWeeks(
        cellOf(_mon2, 'MATH|01'),
        weeks: [3, 5, 7],
        location: '操场',
      );
      expect(rec!.scope, DateEditScope.weeks);
      expect(rec.weeks, [3, 5, 7]);
      // 第 2 周（当前）未改
      expect(cellOf(_mon2, 'MATH|01').slot.location, '教一-101');
      // 第 3 周周一
      final mon3 = DateTime(2026, 9, 14);
      expect(cellOf(mon3, 'MATH|01').slot.location, '操场');
      expect(cellOf(mon3, 'MATH|01').dateEdit?.id, rec.id);
      // 恢复整条
      expect(await c.restoreDateEdit(rec.id), isTrue);
      expect(cellOf(mon3, 'MATH|01').slot.location, '教一-101');
    });

    test('单周等于当前周 → 退回 oneDay', () async {
      await seed();
      final rec = await c.editOccurrenceWeeks(
        cellOf(_mon2, 'MATH|01'),
        weeks: [2],
        name: '高数·当天',
      );
      expect(rec!.scope, DateEditScope.oneDay);
      expect(rec.weeks, isEmpty);
      expect(cellOf(_mon2, 'MATH|01').course.name, '高数·当天');
    });

    test('applyWeeksSummary / isAllSemesterWeeks', () {
      expect(applyWeeksSummary([1, 2, 3], 3), '全部 3 周');
      expect(applyWeeksSummary([3, 5, 8], 16), '第 3、5、8 周');
      expect(applyWeeksSummary([3, 5, 7], 16), '第 3–7 周（单）');
      expect(isAllSemesterWeeks([1, 2, 3, 4], 4), isTrue);
      expect(isAllSemesterWeeks([1, 2], 4), isFalse);
    });
  });

  group('删除范围', () {
    test('oneDay / weekdayMatch / 文案', () async {
      await seed([
        _jwxt('MATH|01', '高数', teacher: '甲', location: 'A'),
        _jwxt('MATH|02', '高数乙', day: 1, start: 5, teacher: '', location: ''),
      ]);
      expect(deleteScopeOneDayLabel(2, 1), '仅第 2 周周一的这节课');
      expect(deleteScopeWeekdayMatchLabel(1, relaxed: false), '全部周一同老师同地点的这节课');
      expect(deleteScopeWeekdayMatchLabel(1, relaxed: true), '全部周一同名课程的这节课');

      final d1 = await c.deleteOccurrence(cellOf(_mon2, 'MATH|01'));
      expect(d1!.scope, DateEditScope.oneDay);
      expect(d1.isDelete, isTrue);
      expect(
        c
            .cellsForDay(2, 1)
            .where((x) => x.activeThisWeek && x.course.id == 'MATH|01'),
        isEmpty,
      );
      // 下一周还在
      expect(cellOf(DateTime(2026, 9, 14), 'MATH|01').dateEdit, isNull);

      await c.restoreDateEdit(d1.id);
      final emptyCell = cellOf(_mon2, 'MATH|02');
      final wm = await c.deleteWeekdayMatch(emptyCell);
      expect(wm!.scope, DateEditScope.weekdayMatch);
      expect(wm.matchEmptyTeacherLocation, isTrue);
      expect(wm.weekday, 1);
      // 各周周一的 MATH|02 被藏
      expect(
        c
            .cellsForDay(2, 1)
            .where((x) => x.activeThisWeek && x.course.id == 'MATH|02'),
        isEmpty,
      );
      expect(
        c
            .cellsForDay(4, 1)
            .where((x) => x.activeThisWeek && x.course.id == 'MATH|02'),
        isEmpty,
      );
    });
  });

  group('整天调课页 keys', () {
    testWidgets('页面含原日期/目标日期/互换与空记录', (tester) async {
      c.debugSetSnapshot(_snap(const []), viewingWeek: 2);
      await tester.pumpWidget(
        MaterialApp(
          home: TimetableDaySwapsPage(controller: c, initialFrom: _mon2),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('day_swaps_page')), findsOneWidget);
      expect(find.byKey(const Key('day_swap_from')), findsOneWidget);
      expect(find.byKey(const Key('day_swap_to')), findsOneWidget);
      expect(find.byKey(const Key('day_swap_submit')), findsOneWidget);
      expect(find.byKey(const Key('day_swaps_empty')), findsOneWidget);
      expect(find.text('9月7日'), findsOneWidget); // prefilled 原日期
    });
  });

  group('自动色板 hueStepped', () {
    test('无 userColors 时 coursePairFor 走 autoCoursePair', () {
      c.debugSetSnapshot(_snap([_jwxt('MATH|01', '高数')]), viewingWeek: 2);
      expect(c.userColorOf(c.courses.single), isNull);
      final pair = coursePairFor(c, c.courses.single);
      final auto = TimetableTheme.autoCoursePair(
        c.colorIndexOf(c.courses.single),
      );
      expect(pair.bg.toARGB32(), auto.bg.toARGB32());
      expect(pair.fg.toARGB32(), auto.fg.toARGB32());
      // 与 A 柔和色板第 0 号不同（色相步进必与旧 soft 分离）。
      final soft0 = TimetableTheme.coursePair(0).bg.toARGB32();
      expect(TimetableTheme.autoCoursePair(0).bg.toARGB32() == soft0, isFalse);
    });
  });

  test('ScheduleStore version 写 3', () async {
    await seed();
    await c.editOccurrence(cellOf(_mon2, 'MATH|01'), note: 'x');
    final raw = jsonDecode(
      File('${tmp.path}/${ScheduleStore.courseEditsFile}').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(raw['version'], ScheduleStore.courseEditsVersion);
    expect(ScheduleStore.courseEditsVersion, 3);
  });
}
