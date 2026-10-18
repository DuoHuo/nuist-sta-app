// 首页卡片「明天的课」UI（spec §13.3/§13.4；用例 23.9 TM 系列）。构造数据。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

Course _course(
  String id,
  String name,
  int day, {
  int start = 1,
  String weeks = '11111111111111111111',
}) => Course(
  id: id,
  name: name,
  slots: [
    CourseSlot(day: day, startNode: start, endNode: start + 1, weeks: weeks),
  ],
);

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;

  void load(List<Course> courses, {bool showTomorrow = true}) {
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: DateTime(2026, 8, 31),
          showTomorrowOnHome: showTomorrow,
        ),
      ),
      manualCourses: courses,
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_home_tm');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = origClock;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpHome(WidgetTester tester, DateTime now) async {
    TimetableController.clock = () => now;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TimetableHomeCard(now: () => now)),
      ),
    );
    await tester.pump();
  }

  final section = find.byKey(const Key('home_tomorrow_section'));

  // §13.13（HT03/HT06）：今天最后一项结束后整张卡切换为明天的课，样式与今天一致。
  testWidgets('TM01 开：今天上完 → 卡片切换为「明天（周二）」+ 课程；关：不显示', (tester) async {
    final courses = [_course('a', '今日课', 1), _course('b', '明日课', 2)];
    load(courses);
    await pumpHome(tester, DateTime(2026, 10, 12, 20));
    expect(section, findsOneWidget);
    expect(find.text('明天（周二）'), findsOneWidget);
    expect(find.text('今天的课已上完'), findsOneWidget);
    expect(find.descendant(of: section, matching: find.text('明日课')), findsOne);
    expect(find.text('今日课'), findsNothing);
    expect(find.text('今日课表'), findsNothing);

    load(courses, showTomorrow: false);
    await pumpHome(tester, DateTime(2026, 10, 12, 20));
    expect(find.text('已上完'), findsOneWidget);
    expect(section, findsNothing);
    expect(find.textContaining('明天'), findsNothing);
  });

  testWidgets('TM02 今天课没上完：不显示明天', (tester) async {
    load([_course('a', '今日课', 1, start: 5), _course('b', '明日课', 2)]);
    await pumpHome(tester, DateTime(2026, 10, 12, 8));
    expect(section, findsNothing);
  });

  testWidgets('TM03 周日看周一：「明天（周一·第 8 周）」只含双周课', (tester) async {
    load([
      _course('x', '双周课', 1, weeks: '01' * 10),
      _course('y', '单周课', 1, weeks: '10' * 10),
    ]);
    await pumpHome(tester, DateTime(2026, 10, 18, 20));
    expect(find.text('明天（周一·第 8 周）'), findsOneWidget);
    expect(find.descendant(of: section, matching: find.text('双周课')), findsOne);
    expect(find.textContaining('单周课'), findsNothing);
  });

  testWidgets('TM08 明天没课：「明天没课」', (tester) async {
    load([_course('a', '今日课', 1)]);
    await pumpHome(tester, DateTime(2026, 10, 12, 20));
    expect(find.text('明天没课'), findsOneWidget);
  });

  testWidgets('TM09 今天没课：显示明天这一栏', (tester) async {
    load([_course('b', '明日课', 3)]);
    await pumpHome(tester, DateTime(2026, 10, 13, 9));
    expect(find.text('今天没有课'), findsOneWidget);
    expect(find.text('明天（周三）'), findsOneWidget);
    expect(find.descendant(of: section, matching: find.text('明日课')), findsOne);
  });

  testWidgets('TM13 学期已结束：主文案「本学期已结束」，无明天栏', (tester) async {
    load([_course('a', '今日课', 3)]);
    await pumpHome(tester, DateTime(2027, 1, 20, 9));
    expect(find.text('本学期已结束'), findsOneWidget);
    expect(section, findsNothing);
    expect(find.text('今天没有课'), findsNothing);
  });

  testWidgets('TM07 开学前更早：不显示明天课程，显示「距开学 11 天」', (tester) async {
    load([_course('a', '周四课', 4)]);
    await pumpHome(tester, DateTime(2026, 8, 20, 9));
    expect(find.text('距开学 11 天'), findsOneWidget);
    expect(find.textContaining('周四课'), findsNothing);
  });
}
