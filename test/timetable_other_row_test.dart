// spec-next-1019 item 7：周视图最后一节下方的「其他」行，只放没有节次的教务课。
// 全部为构造数据，不读真实样例。
// ignore_for_file: unused_element

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

/// 第 7 周（单周）：10/12–10/18；开学 2026-08-31。
const _week = 7;
final _termStart = DateTime(2026, 8, 31);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '11111111111111111111',
  String weeksLabel = '',
  String location = '测试楼 A101',
  String teacher = '张老师',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      weeksLabel: weeksLabel,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: _termStart),
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

Future<void> _io(WidgetTester tester, [int rounds = 3]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void _setUpController() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_next');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 10, 12, 9);
  });
  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });
}

void main() {
  _setUpController();

  Course unscheduled(String id, String name, String weeksLabel) => _course(
    id,
    name,
    day: 0,
    start: 0,
    end: 0,
    weeks: '',
    weeksLabel: weeksLabel,
    location: '测试楼 B202',
    source: CourseSource.jwxt,
  );

  final normal = _course('n', '测试课甲', source: CourseSource.jwxt);
  final row = find.byKey(const Key('week_grid_other_row'));

  Future<void> pumpGrid(WidgetTester tester, int week) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekGrid(key: ValueKey(week), week: week, controller: _c),
        ),
      ),
    );
    await tester.pump();
  }

  test('OR01 parseOtherWeeksLabel：范围 / 单双 / 多段 / 单周 / 读不出', () {
    expect(parseOtherWeeksLabel('1-16周'), containsAll([1, 8, 16]));
    expect(
      parseOtherWeeksLabel('2-17周(双)'),
      allOf(contains(4), isNot(contains(3))),
    );
    expect(parseOtherWeeksLabel('1-8,10-16周'), isNot(contains(9)));
    expect(parseOtherWeeksLabel('第3周'), {3});
    expect(parseOtherWeeksLabel('待定'), isNull);
  });

  testWidgets('OR02 本周有无节次教务课：「其他」行在网格最下方，滚到底才看到', (tester) async {
    _load(jwxt: [normal, unscheduled('o1', '测试实践课', '2-5周')], week: 3);
    await pumpGrid(tester, 3);
    expect(row, findsOneWidget);
    expect(find.text('测试实践课'), findsOneWidget);
    // 11 节 × 64dp 超出 600 高的屏幕：初始在屏幕外。
    expect(tester.getTopLeft(row).dy, greaterThan(600));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(row).dy, lessThanOrEqualTo(600));
    await tester.tap(find.byKey(const ValueKey('other_course_o1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('other_course_sheet')), findsOneWidget);
    expect(find.text('2-5周'), findsOneWidget);
    expect(find.text('张老师'), findsOneWidget);
  });

  testWidgets('OR03 查看周不在该课周次内：不显示「其他」行', (tester) async {
    _load(jwxt: [normal, unscheduled('o1', '测试实践课', '2-5周')], week: 7);
    await pumpGrid(tester, 7);
    expect(row, findsNothing);
  });

  testWidgets('OR04 没有无节次课：不显示；手动的无节次课也不进「其他」', (tester) async {
    _load(
      jwxt: [normal],
      manual: [_course('m', '测试手动无时间', day: 0, start: 0, end: 0, weeks: '')],
    );
    await pumpGrid(tester, _week);
    expect(row, findsNothing);
  });

  testWidgets('OR05 周次读不出（空 / 中文描述）：每周都显示', (tester) async {
    _load(jwxt: [normal, unscheduled('o2', '测试毕业实习', '')]);
    await pumpGrid(tester, _week);
    expect(row, findsOneWidget);
    expect(find.text('测试毕业实习'), findsOneWidget);
  });
}
