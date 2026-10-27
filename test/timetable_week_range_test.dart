import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 8, 31); // 周一

/// 第 [week] 周的周一。
DateTime _mondayOf(int week) => _termStart.add(Duration(days: (week - 1) * 7));

Course _course(String id, String weeks, {int day = 1, CourseSource? source}) =>
    Course(
      id: id,
      name: '课程$id',
      source: source ?? CourseSource.manual,
      slots: [CourseSlot(day: day, startNode: 1, endNode: 2, weeks: weeks)],
    );

void main() {
  group('Course/CourseSlot.hasClassInWeek', () {
    test('第 1 周 = 下标 0；第 length 周 = 最后一位（防差一）', () {
      final s = CourseSlot(day: 1, startNode: 1, endNode: 1, weeks: '1001');
      expect(s.hasClassInWeek(1), isTrue);
      expect(s.hasClassInWeek(2), isFalse);
      expect(s.hasClassInWeek(3), isFalse);
      expect(s.hasClassInWeek(4), isTrue);
      final c = _course('a', '0${'0' * 18}1'); // 长度 20，仅第 20 周
      expect(c.hasClassInWeek(20), isTrue);
      expect(c.hasClassInWeek(19), isFalse);
      expect(c.hasClassInWeek(1), isFalse);
    });

    test('0 / 负数 / 超出位串长度 → false', () {
      final c = _course('a', '1' * 20);
      for (final w in [0, -1, -100, 21, 25, 1000]) {
        expect(c.hasClassInWeek(w), isFalse, reason: 'week $w');
      }
      expect(_course('e', '').hasClassInWeek(1), isFalse);
    });

    test('手动课程（周次存位串）与教务课程同一判断；多节次任一有课即 true', () {
      final manual = Course(
        id: 'm',
        name: '手动',
        slots: [
          CourseSlot(day: 1, startNode: 1, endNode: 1, weeks: '10'),
          CourseSlot(day: 3, startNode: 1, endNode: 1, weeks: '0001'),
        ],
      );
      expect(manual.isManual, isTrue);
      expect(manual.hasClassInWeek(1), isTrue);
      expect(manual.hasClassInWeek(2), isFalse);
      expect(manual.hasClassInWeek(4), isTrue);
      expect(manual.hasClassInWeek(5), isFalse);
      final jwxt = _course('j', '01', source: CourseSource.jwxt);
      expect(jwxt.hasClassInWeek(2), isTrue);
      expect(jwxt.hasClassInWeek(1), isFalse);
    });
  });

  group('周次越界（W02f/g/h、反向收缩、表单周次）', () {
    late Directory tmp;
    final origClock = TimetableController.clock;
    final origBinding = TimetableController.bindingCheck;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_week_range');
      TimetableStore.debugDirectory = tmp;
      TimetableController.bindingCheck = () async => false;
      _c.debugReset();
    });

    tearDown(() {
      TimetableController.clock = origClock;
      TimetableController.bindingCheck = origBinding;
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    void setUpCourses(List<Course> manual, {DateTime? today, int? viewing}) {
      if (today != null) TimetableController.clock = () => today;
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termCode: '2026-2027-1',
            termStartDate: _termStart,
          ),
        ),
        viewingWeek: viewing,
        manualCourses: manual,
      );
    }

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> pumpHome(WidgetTester tester, DateTime now) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => now)),
        ),
      );
      await tester.pump();
    }

    testWidgets('W02f 本周 19、总 18：顶栏第 18 周 + 课程已结束；无回到本周；首页今天没有课', (
      tester,
    ) async {
      final today = _mondayOf(19);
      setUpCourses([_course('a', '${'1' * 18}00')], today: today);
      expect(_c.totalWeeks, 18);
      expect(_c.currentWeek, 19);
      expect(_c.viewingWeek, 18);

      await pumpPage(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('第 18 周', findRichText: true), findsOneWidget);
      expect(find.text('本周第 19 周 · 课程已结束'), findsOneWidget);
      expect(find.textContaining('非本周', findRichText: true), findsNothing);
      expect(find.text('回到本周'), findsNothing);
      expect(find.byType(WeekGrid), findsOneWidget);
      // PageView 停在第 18 周（下标 17），网格表头是第 18 周的日期（12/28 起）。
      final pv = tester.widget<PageView>(find.byType(PageView));
      expect(pv.controller!.page, 17);
      final grid = tester.widget<WeekGrid>(find.byType(WeekGrid));
      expect(grid.week, 18);
      expect(find.text('12月'), findsOneWidget);
      expect(find.text('28'), findsOneWidget);

      // 选周弹层：只有 1..18，不高亮越界的「本周」。
      await tester.tap(find.textContaining('第 18 周', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('18'), findsOneWidget);
      expect(find.text('19'), findsNothing);
      expect(tester.takeException(), isNull);

      await pumpHome(tester, today.add(const Duration(hours: 9)));
      expect(tester.takeException(), isNull);
      // TM13（§13.4）：学期已结束时卡片主文案「本学期已结束」，不再显示「今天没有课」。
      expect(find.text('本学期已结束'), findsOneWidget);
      expect(find.text('今天没有课'), findsNothing);
    });

    testWidgets('首页 08-30（周日，开学前一天）：今天没有课；明天（周一·第 1 周）+ 周一课', (tester) async {
      final today = DateTime(2026, 8, 30);
      setUpCourses([_course('a', '1' * 16)], today: today);
      expect(_c.actualWeek(today), 0);
      expect(_c.actualWeek(DateTime(2026, 8, 31)), 1);
      await pumpHome(tester, today.add(const Duration(hours: 9)));
      expect(tester.takeException(), isNull);
      expect(find.text('今天没有课'), findsOneWidget);
      // §13.13：今天没课 → 卡片直接切换为明天的课。
      expect(find.text('明天（周一·第 1 周）'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('home_tomorrow_section')),
          matching: find.text('课程a'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('第 0 周'), findsNothing);
    });

    testWidgets('W02g 位串长 20、本周 25：首页/周视图/预告均无异常', (tester) async {
      final today = _mondayOf(25).subtract(const Duration(days: 1)); // 周日
      setUpCourses([
        _course('a', '1' * 20),
        _course('b', '1' * 20, day: 1),
      ], today: today);
      expect(_c.currentWeek, greaterThan(_c.totalWeeks));
      expect(_c.coursesOnDate(today.add(const Duration(days: 1))), isEmpty);
      expect(_c.todayCourses(now: today), isEmpty);

      await pumpHome(tester, today.add(const Duration(hours: 9)));
      expect(tester.takeException(), isNull);
      // TM13：本周 25 > 总周数 → 「本学期已结束」，不显示明天一栏。
      expect(find.text('本学期已结束'), findsOneWidget);
      expect(find.byKey(const Key('home_tomorrow_section')), findsNothing);

      await pumpPage(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('第 20 周', findRichText: true), findsOneWidget);
      expect(find.byType(WeekGrid), findsOneWidget);
    });

    testWidgets('W02h 开学前：本周按第 1 周处理，无越界，无「课程已结束」', (tester) async {
      final today = _termStart.subtract(const Duration(days: 10));
      setUpCourses([_course('a', '1' * 16)], today: today);
      expect(_c.currentWeek, greaterThanOrEqualTo(1));
      expect(_c.viewingWeek, inInclusiveRange(1, _c.totalWeeks));

      await pumpPage(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('第 1 周', findRichText: true), findsOneWidget);
      expect(find.textContaining('课程已结束'), findsNothing);
      expect(find.byType(WeekGrid), findsOneWidget);

      await pumpHome(tester, today.add(const Duration(hours: 9)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('反向：浏览第 20 周时删掉第 20 周的课 → 总 18，自动回到第 18 周', (tester) async {
      setUpCourses(
        [_course('a', '${'1' * 18}00'), _course('b', '${'0' * 19}1', day: 2)],
        today: _mondayOf(3),
        viewing: 20,
      );
      expect(_c.totalWeeks, 20);
      await pumpPage(tester);
      expect(find.textContaining('第 20 周', findRichText: true), findsOneWidget);

      await tester.runAsync(() => _c.deleteManualCourse('b'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
      expect(_c.totalWeeks, 18);
      expect(_c.viewingWeek, 18);
      expect(find.textContaining('第 18 周', findRichText: true), findsOneWidget);
      expect(find.byType(WeekGrid), findsOneWidget);
      expect(find.text('课程a'), findsWidgets);
    });

    testWidgets('表单周次：totalWeeks 18 时仍列到第 20 周', (tester) async {
      setUpCourses([_course('a', '1' * 18)], today: _mondayOf(3));
      expect(_c.totalWeeks, 18);
      await tester.pumpWidget(
        MaterialApp(home: ManualCourseForm(controller: _c)),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('manual_course_week_20'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('manual_course_week_21'), skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
