import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_widget_layout.dart';

NotifyClass _course(
  String name,
  DateTime start, {
  int startNode = 1,
  int endNode = 1,
  String courseId = '',
  WidgetItemKind kind = WidgetItemKind.course,
}) => NotifyClass(
  name: name,
  location: '示例教室',
  teachers: const ['示例教师'],
  start: start,
  end: start.add(const Duration(minutes: 45)),
  startNode: startNode,
  endNode: endNode,
  courseId: courseId,
  kind: kind,
);

String _two(int value) => value.toString().padLeft(2, '0');

final _periods = [
  for (var node = 1; node <= 12; node++)
    WeekWidgetPeriod(
      node: node,
      start: '${_two(7 + node)}:00',
      end: '${_two(7 + node)}:45',
    ),
];

WeekWidgetWeek _week(DateTime monday, Map<int, List<NotifyClass>> courses) =>
    WeekWidgetWeek(
      start: monday,
      week: 13,
      days: [
        for (var index = 0; index < 7; index++)
          WeekWidgetDay(
            date: DateTime(monday.year, monday.month, monday.day + index),
            weekday: index + 1,
            items: courses[index + 1] ?? const [],
          ),
      ],
    );

void main() {
  final monday = DateTime(2026, 11, 23);
  final wednesday = DateTime(2026, 11, 25, 10);

  test('payload：本周与下周各七天，地点不裁剪', () {
    final payload = buildWeekWidgetPayload(
      now: wednesday,
      prefs: const WeekWidgetPrefs(showTeacher: false, showPeriod: false),
      periods: _periods,
      weekOf: (date) => date == monday ? 13 : 14,
      itemsOn: (date) => date.year == 2026 && date.month == 11 && date.day == 25
          ? [
              _course(
                '高等数学',
                DateTime(2026, 11, 25, 10, 10),
                startNode: 3,
                endNode: 4,
              ),
            ]
          : const [],
    );
    final weeks = payload['weeks'] as List;
    expect(weeks, hasLength(2));
    final current = weeks.first as Map;
    expect(current['start'], '2026-11-23');
    expect(current['week'], 13);
    final days = current['days'] as List;
    expect(days, hasLength(7));
    expect((days[2] as Map)['date'], '2026-11-25');
    final item = ((days[2] as Map)['items'] as List).single as Map;
    expect(item['name'], '高等数学');
    expect(item['location'], '示例教室');
    expect(item['teacherFirst'], '');
    expect(item['nodes'], '');
    expect(item['startNode'], 3);
    expect(item['start'], '2026-11-25T10:10');
    final next = weeks.last as Map;
    expect(next['start'], '2026-11-30');
    expect(next['week'], 14);
    expect((payload['prefs'] as Map)['showWeekend'], false);
    expect((payload['prefs'] as Map)['showLocation'], true);
    expect(payload['periods'], hasLength(11));
    expect(payload['termStartMissing'], isFalse);
    expect(payload['today'], '2026-11-25');
  });

  test('weekNodeRange：有节次直接用，旧数据按开始时间匹配', () {
    expect(
      weekNodeRange(
        _course('课', DateTime(2026, 11, 23, 10), startNode: 3, endNode: 4),
        _periods,
      ),
      (start: 3, end: 4),
    );
    expect(
      weekNodeRange(
        _course('旧课', DateTime(2026, 11, 23, 10, 15), startNode: 0, endNode: 0),
        _periods,
      ),
      (start: 3, end: 3),
    );
    expect(weekNodeRange(_course('无作息', wednesday), const []), (
      start: 1,
      end: 1,
    ));
  });

  test('planWeekWidget：相同课程的相邻节次合为一个块', () {
    final week = _week(monday, {
      1: [
        _course('高等数学', monday.add(const Duration(hours: 8)), courseId: 'math'),
        _course(
          '高等数学',
          monday.add(const Duration(hours: 9)),
          startNode: 2,
          endNode: 2,
          courseId: 'math',
        ),
      ],
      3: [_course('大学物理', DateTime(2026, 11, 25, 13, 45), startNode: 5)],
    });
    final plan = planWeekWidget(
      week: week,
      periods: _periods,
      prefs: const WeekWidgetPrefs(),
      widthDp: 256,
      heightDp: 320,
      today: wednesday,
    );
    expect(plan.rows.map((row) => row.node), List.generate(7, (i) => i + 1));
    expect(plan.rows.first.period?.start, '08:00');
    expect(plan.todayWeekday, 3);
    expect(plan.dates[3], 25);
    expect(plan.month, 11);
    final math = plan.blocks[1]!.single;
    expect((math.startNode, math.endNode, math.courses.length), (1, 2, 1));
    expect(math.primary.teachers, ['示例教师']);
    expect(plan.blocks[3]!.single.primary.name, '大学物理');
    expect(plan.weekLabel, '第13周');
  });

  test('planWeekWidget：五列和七列共用行高下限，周末开关只改列宽和可见日', () {
    final week = _week(monday, {
      6: [_course('选修课', DateTime(2026, 11, 28, 10), startNode: 3)],
    });
    WeekWidgetPlan plan(bool weekends) => planWeekWidget(
      week: week,
      periods: _periods,
      prefs: WeekWidgetPrefs(showWeekend: weekends),
      widthDp: 360,
      heightDp: 450,
      today: wednesday,
    );
    final weekdays = plan(false);
    final weekend = plan(true);
    expect(weekdays.weekdays, [1, 2, 3, 4, 5]);
    expect(weekdays.hasCourses, isFalse);
    expect(weekend.weekdays, [1, 2, 3, 4, 5, 6, 7]);
    expect(weekend.blocks[6]!.single.primary.name, '选修课');
    expect(weekend.geometry.cellWidth, lessThan(weekdays.geometry.cellWidth));
    expect(weekdays.geometry.rowHeight, weekend.geometry.cellWidth);
    expect(weekend.geometry.rowHeight, weekend.geometry.cellWidth);
    expect(
      weekdays.geometry.fontReferenceWidth(3),
      weekend.geometry.fontReferenceWidth(3),
    );
  });

  test('高度富余时铺满，低于七列列宽时只截断末节', () {
    final week = _week(monday, {
      1: [
        _course('晚课', monday.add(const Duration(hours: 19)), startNode: 11),
        _course('第十二节', monday.add(const Duration(hours: 20)), startNode: 12),
      ],
    });
    WeekWidgetPlan plan(double height) => planWeekWidget(
      week: week,
      periods: _periods,
      prefs: const WeekWidgetPrefs(),
      widthDp: 314, // (314 - 34) / 7 = 40
      heightDp: height,
      today: wednesday,
    );
    final short = plan(318);
    expect(short.rows.map((row) => row.node), [1, 2, 3, 4, 5]);
    expect(short.geometry.rowHeight, 40);
    expect(short.blocks[1], isEmpty);
    expect(short.hasCourses, isTrue, reason: '截断不等于没有课');

    const fullscreenHeight = 554.3;
    WeekWidgetPlan fullscreen({required bool showWeekend}) => planWeekWidget(
      week: week,
      periods: _periods,
      prefs: WeekWidgetPrefs(showWeekend: showWeekend),
      widthDp: 307.4,
      heightDp: fullscreenHeight,
    );
    final weekdaysOnly = fullscreen(showWeekend: false);
    final tall = fullscreen(showWeekend: true);
    final geometry = tall.geometry;
    final nodes = List.generate(11, (index) => index + 1);
    expect(weekdaysOnly.rows.map((row) => row.node), nodes);
    expect(tall.rows.map((row) => row.node), nodes);
    expect(geometry.rowHeight, greaterThan(geometry.unit));
    expect(geometry.compactText, isTrue);
    expect(geometry.cellMargin, 1);
    expect(geometry.cellPadding, 2);
    expect(geometry.minimumTextSize, 9);
    expect(
      geometry.rowHeight * tall.rows.length +
          WeekWidgetGeometry.headerHeight +
          WeekWidgetGeometry.weekdayHeight +
          WeekWidgetGeometry.bottomInset,
      closeTo(fullscreenHeight, 0.01),
    );
    expect(tall.blocks[1]!.single.primary.name, '晚课');
    expect(plan(60).rows, isEmpty);
  });

  test('同列相交的课程按 App 的冲突规则共用一个块', () {
    final time = monday.add(const Duration(hours: 8));
    final a = _course('第一门', time, endNode: 3);
    final b = _course('第二门', time, endNode: 2);
    final c = _course(
      '第 2 节新课',
      time.add(const Duration(hours: 1)),
      startNode: 2,
      endNode: 3,
    );
    final plan = planWeekWidget(
      week: _week(monday, {
        1: [a, b, c],
      }),
      periods: _periods,
      prefs: const WeekWidgetPrefs(),
      widthDp: 256,
      heightDp: 320,
    );
    final block = plan.blocks[1]!.single;
    expect((block.startNode, block.endNode), (1, 3));
    expect(block.courses, [c, a, b]);
  });

  test('不在作息内的日程和考试进表头，不猜测节次', () {
    final event = _course(
      '晚间活动',
      monday.add(const Duration(hours: 21)),
      startNode: 0,
      endNode: 0,
      kind: WidgetItemKind.schedule,
    );
    final exam = _course(
      '考试',
      monday.add(const Duration(hours: 9)),
      startNode: 2,
      endNode: 3,
      kind: WidgetItemKind.exam,
    );
    final plan = planWeekWidget(
      week: _week(monday, {
        1: [exam, event],
      }),
      periods: _periods,
      prefs: const WeekWidgetPrefs(),
      widthDp: 256,
      heightDp: 448,
    );
    expect(weekNodeRange(event, _periods), isNull);
    expect(plan.unplaced[1], [event]);
    final block = plan.blocks[1]!.single;
    expect((block.startNode, block.endNode), (2, 3));
    expect(block.primary, same(exam));
  });

  test('planWeekWidget：今天不在本周时不高亮，关闭节次隐藏时间列', () {
    final week = _week(monday, {
      1: [_course('课', monday.add(const Duration(hours: 8)))],
    });
    final plan = planWeekWidget(
      week: week,
      periods: _periods,
      prefs: const WeekWidgetPrefs(showPeriod: false),
      widthDp: 360,
      heightDp: 450,
      today: DateTime(2026, 12, 7),
    );
    expect(plan.todayWeekday, isNull);
    expect(plan.geometry.showTimeColumn, isFalse);
    expect(plan.geometry.timeColumnWidth, 0);
    expect(plan.geometry.cellWidth, 72);
  });

  test('周一与分钟解析', () {
    expect(weekWidgetMonday(DateTime(2026, 11, 29)), DateTime(2026, 11, 23));
    expect(weekWidgetMonday(monday), DateTime(2026, 11, 23));
    expect(weekMinutesOf('10:10'), 610);
    expect(weekMinutesOf('bad'), 0);
  });
}
