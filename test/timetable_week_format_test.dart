import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_widget_layout.dart';

const _fx = 'test/fixtures/timetable';

void main() {
  group('formatWeeks (W01)', () {
    test('空 / 单周 / 两周', () {
      expect(formatWeeks(const []), '');
      expect(formatWeeks(const [5]), '第 5 周');
      expect(formatWeeks(const [2, 4]), '第 2、4 周');
    });

    test('连续段', () {
      expect(formatWeeks(const [2, 3, 4, 5, 6]), '第 2–6 周');
      expect(
        formatWeeks(const [1, 2, 3, 4, 7, 9, 10, 11, 12]),
        '第 1–4、7、9–12 周',
      );
    });

    test('单双周', () {
      expect(formatWeeks(const [2, 4, 6, 8, 10]), '第 2–10 周（双）');
      expect(formatWeeks(const [1, 3, 5, 7, 9]), '第 1–9 周（单）');
      // 全单但有缺口 → 不用（单），逐个列出（>3 段截断）。
      expect(formatWeeks(const [1, 3, 7]), '第 1、3、7 周');
    });

    test('超过 3 段：只取前 3 段，「周」后加「等」', () {
      final s = formatWeeks(const [1, 2, 4, 6, 9, 12]);
      expect(s, '第 1–2、4、6 周等');
      expect(s, endsWith('等'));
    });

    test('乱序 / 重复输入', () {
      expect(formatWeeks(const [6, 2, 4, 2, 3, 5, 6]), '第 2–6 周');
      expect(formatWeeks(const [9, 1, 5, 3, 7, 7]), '第 1–9 周（单）');
      expect(formatWeeks(const [5, 5]), '第 5 周');
    });

    test('从不输出半角 - 或 (单)', () {
      for (final w in const [
        [1, 2, 3],
        [1, 3, 5],
        [2, 4, 6],
        [1, 2, 5, 6, 9, 10, 13],
      ]) {
        final s = formatWeeks(w);
        expect(s, isNot(contains('-')));
        expect(s, isNot(contains('(')));
      }
    });

    test('weeksFromBits', () {
      expect(weeksFromBits('0101010000'), [2, 4, 6]);
      expect(formatWeekBits('0000'), '');
    });
  });

  group('合成课表 kb_mock.json（始终运行）：按 SKZC 格式化，不用 ZCMC', () {
    late Map<String, Course> byName;
    setUpAll(() {
      final raw = jsonDecode(
        File('$_fx/kb_mock.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final snap = TimetableParser.parseImportJson({
        'code': '0',
        'datas': raw['datas'],
      }, baseSettings: const TimetableSettings(maxWeeks: 30));
      byName = {for (final c in snap.courses) normalizeCourseName(c.name): c};
    });

    String fmt(String name, [int slot = 0]) =>
        formatWeekBits(byName[name]!.slots[slot].weeks);

    test('双周 2–16（SKZC 24 位）→「第 2–16 周（双）」，不是 ZCMC', () {
      final slot = byName['大学物理B']!.slots.single;
      expect(slot.weeks.length, 30); // 24 位按 maxWeeks 补齐
      final text = formatWeekBits(slot.weeks);
      expect(text, '第 2–16 周（双）');
      expect(text, isNot(contains('-')));
      expect(text, isNot(contains('(双)')));
      expect(slot.weeksLabel, '2-16周(双)');
      expect(text, isNot(slot.weeksLabel));
    });

    test('单周 1–15 / 1–17', () {
      expect(fmt('线性代数B'), '第 1–15 周（单）');
      expect(fmt('大学化学'), '第 1–17 周（单）');
    });

    test('连续段与多段（SKZC 30 位）', () {
      expect(fmt('高等数学A'), '第 1–16 周');
      expect(fmt('高等数学A', 1), '第 1–16 周');
      expect(fmt('概率论与数理统计'), '第 1–8 周');
      expect(fmt('数字逻辑'), '第 3–14 周');
      expect(fmt('电路分析'), '第 1–4、7、9–12 周');
      expect(byName['电路分析']!.slots.single.weeksLabel, '1-4周,7周,9-12周');
    });

    test('单个周 / 短双周', () {
      expect(fmt('形势与政策'), '第 9 周');
      expect(fmt('大学物理实验B'), '第 2–8 周（双）');
    });
  });

  test('mock 样例：大学英语Ⅰ 单周 →「第 1–15 周（单）」', () {
    final json = jsonDecode(
      File('test/fixtures/timetable/kb_mock_2026-1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final rows = (json['datas'] as Map)['cxxszhxqkb']['rows'] as List;
    final result = TimetableParser.parseKbRows(rows);
    final english = result.courses.firstWhere((c) => c.name == '大学英语Ⅰ');
    final slot = english.slots.firstWhere((s) => s.weeks.contains('1'));
    final text = formatWeekBits(slot.weeks);
    expect(text, '第 1–15 周（单）');
    expect(text, isNot(contains('(单)')));
    expect(text, isNot(slot.weeksLabel));
  });

  group('格内文案与周次字符串解析', () {
    test('parseOtherWeeksLabel 解析范围/单双周/多段/第N周及非法格式', () {
      expect(parseOtherWeeksLabel('1-16周'), {for (var i = 1; i <= 16; i++) i});
      expect(parseOtherWeeksLabel('2-17周(双)'), {2, 4, 6, 8, 10, 12, 14, 16});
      expect(parseOtherWeeksLabel('1-9周（单）'), {1, 3, 5, 7, 9});
      expect(parseOtherWeeksLabel('1-4,6~8；第10周 12–13周'), {
        1,
        2,
        3,
        4,
        6,
        7,
        8,
        10,
        12,
        13,
      });
      expect(parseOtherWeeksLabel('第3周'), {3});
      expect(parseOtherWeeksLabel(''), isNull);
      expect(parseOtherWeeksLabel('待定'), isNull);
      expect(parseOtherWeeksLabel('0-3周'), isNull);
      expect(parseOtherWeeksLabel('5-2周'), isNull);
      expect(parseOtherWeeksLabel('1-61周'), isNull);
    });

    test('cellTeacherText 按中英文分隔符拆分并过滤空白项', () {
      expect(cellTeacherText('张三, 李四，王五、赵六; 钱七；孙八'), '张三\n李四\n王五\n赵六\n钱七\n孙八');
      expect(cellTeacherText(' , 张三 ,,  李四 ; '), '张三\n李四');
      expect(cellTeacherText('   '), '');
    });

    test('cellLocationText 只在相邻非汉字之间插零宽空格，可见文字不变', () {
      expect(cellLocationText('揽江楼'), '@揽江楼');
      final s = cellLocationText('明德楼A101');
      expect(s.replaceAll('\u200B', ''), '@明德楼A101');
      expect(s, '@明德楼A\u200B1\u200B0\u200B1');
    });
  });

  group('周桌面微件规划与网格布局', () {
    NotifyClass widgetCourse(
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

    String twoDigits(int value) => value.toString().padLeft(2, '0');

    final periods = [
      for (var node = 1; node <= 12; node++)
        WeekWidgetPeriod(
          node: node,
          start: '${twoDigits(7 + node)}:00',
          end: '${twoDigits(7 + node)}:45',
        ),
    ];

    WeekWidgetWeek makeWeek(
      DateTime monday,
      Map<int, List<NotifyClass>> courses,
    ) => WeekWidgetWeek(
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

    final monday = DateTime(2026, 11, 23);
    final wednesday = DateTime(2026, 11, 25, 10);

    test('0.75dp 网格线按密度取整且至少保留一个物理像素', () {
      for (final (dpr, physicalPixels) in [
        (0.75, 1),
        (1.0, 1),
        (1.5, 1),
        (2.0, 2),
        (3.0, 2),
        (4.0, 3),
      ]) {
        expect(
          weekWidgetGridStroke(dpr) * dpr,
          closeTo(physicalPixels, 0.0001),
        );
      }
    });

    test('payload：本周与下周各七天，地点不裁剪', () {
      final payload = buildWeekWidgetPayload(
        now: wednesday,
        prefs: const WeekWidgetPrefs(showTeacher: false, showPeriod: false),
        periods: periods,
        weekOf: (date) => date == monday ? 13 : 14,
        itemsOn: (date) =>
            date.year == 2026 && date.month == 11 && date.day == 25
            ? [
                widgetCourse(
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
          widgetCourse(
            '课',
            DateTime(2026, 11, 23, 10),
            startNode: 3,
            endNode: 4,
          ),
          periods,
        ),
        (start: 3, end: 4),
      );
      expect(
        weekNodeRange(
          widgetCourse(
            '旧课',
            DateTime(2026, 11, 23, 10, 15),
            startNode: 0,
            endNode: 0,
          ),
          periods,
        ),
        (start: 3, end: 3),
      );
      expect(weekNodeRange(widgetCourse('无作息', wednesday), const []), (
        start: 1,
        end: 1,
      ));
    });

    test('planWeekWidget：相同课程的相邻节次合为一个块', () {
      final week = makeWeek(monday, {
        1: [
          widgetCourse(
            '高等数学',
            monday.add(const Duration(hours: 8)),
            courseId: 'math',
          ),
          widgetCourse(
            '高等数学',
            monday.add(const Duration(hours: 9)),
            startNode: 2,
            endNode: 2,
            courseId: 'math',
          ),
        ],
        3: [widgetCourse('大学物理', DateTime(2026, 11, 25, 13, 45), startNode: 5)],
      });
      final plan = planWeekWidget(
        week: week,
        periods: periods,
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

    test('planWeekWidget：周末开关只改变日列和可见日，不改变行高下限', () {
      final week = makeWeek(monday, {
        6: [widgetCourse('选修课', DateTime(2026, 11, 28, 10), startNode: 3)],
      });
      WeekWidgetPlan plan(bool weekends) => planWeekWidget(
        week: week,
        periods: periods,
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
      expect(weekend.geometry.rowHeight, weekdays.geometry.rowHeight);
      for (final geometry in [weekdays.geometry, weekend.geometry]) {
        expect(geometry.unit, closeTo(geometry.gridWidth / 7, 0.001));
        expect(geometry.rowHeight, greaterThanOrEqualTo(geometry.unit));
        expect(
          geometry.fontReferenceWidth(3),
          ((geometry.unit - 2 * geometry.cellMargin) * 3).ceil() / 3,
        );
      }
    });

    test('节次栏和两个表头各占八分之一，默认高度仍可截断', () {
      const width = 360.0;
      const height = 450.0;
      const w = width / 8;
      WeekWidgetGeometry geometry(int days, {bool showTimeColumn = true}) =>
          WeekWidgetGeometry(
            widthDp: width,
            heightDp: height,
            days: days,
            totalRows: 11,
            showTimeColumn: showTimeColumn,
          );
      for (final days in [5, 7]) {
        final layout = geometry(days);
        final noPeriod = geometry(days, showTimeColumn: false);
        expect(layout.headerHeight, w);
        expect(layout.weekdayHeight, w);
        expect(layout.timeColumnWidth, w);
        expect(layout.cellWidth, closeTo(7 * w / days, 0.001));
        expect(layout.unit, closeTo(w, 0.001));
        expect(layout.rowCount, 7);
        expect(noPeriod.headerHeight, layout.headerHeight);
        expect(noPeriod.weekdayHeight, layout.weekdayHeight);
        expect(noPeriod.timeColumnWidth, 0);
        expect(noPeriod.cellWidth, width / days);
        expect(layout.rowHeight, greaterThanOrEqualTo(layout.unit));
        expect(
          layout.headerHeight +
              layout.weekdayHeight +
              layout.rowCount * layout.rowHeight +
              WeekWidgetGeometry.bottomInset,
          closeTo(height, 0.001),
        );
      }
    });

    test('先截去放不下的末节，可见节次铺满表体', () {
      final week = makeWeek(monday, {
        1: [
          widgetCourse(
            '晚课',
            monday.add(const Duration(hours: 19)),
            startNode: 11,
          ),
          widgetCourse(
            '第十二节',
            monday.add(const Duration(hours: 20)),
            startNode: 12,
          ),
        ],
      });
      WeekWidgetPlan plan(double height) => planWeekWidget(
        week: week,
        periods: periods,
        prefs: const WeekWidgetPrefs(),
        widthDp: 314,
        heightDp: height,
        today: wednesday,
      );
      final short = plan(318);
      expect(short.rows.map((row) => row.node), [1, 2, 3, 4, 5, 6]);
      expect(
        short.geometry.rowHeight,
        greaterThanOrEqualTo(short.geometry.unit),
      );
      final fixedHeight =
          short.geometry.headerHeight +
          short.geometry.weekdayHeight +
          WeekWidgetGeometry.bottomInset;
      expect(
        short.geometry.rowHeight * short.rows.length + fixedHeight,
        closeTo(318, 0.001),
      );
      expect(short.blocks[1], isEmpty);
      expect(short.hasCourses, isTrue);

      const fullscreenHeight = 554.3;
      WeekWidgetPlan fullscreen({required bool showWeekend}) => planWeekWidget(
        week: week,
        periods: periods,
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
      expect(geometry.minimumTextSize, 8);
      expect(
        geometry.rowHeight * tall.rows.length +
            geometry.headerHeight +
            geometry.weekdayHeight +
            WeekWidgetGeometry.bottomInset,
        closeTo(fullscreenHeight, 0.01),
      );
      expect(tall.blocks[1]!.single.primary.name, '晚课');
      expect(plan(60).rows, isEmpty);
    });

    test('同列相交的课程按 App 的冲突规则共用一个块', () {
      final time = monday.add(const Duration(hours: 8));
      final a = widgetCourse('第一门', time, endNode: 3);
      final b = widgetCourse('第二门', time, endNode: 2);
      final c = widgetCourse(
        '第 2 节新课',
        time.add(const Duration(hours: 1)),
        startNode: 2,
        endNode: 3,
      );
      final plan = planWeekWidget(
        week: makeWeek(monday, {
          1: [a, b, c],
        }),
        periods: periods,
        prefs: const WeekWidgetPrefs(),
        widthDp: 256,
        heightDp: 320,
      );
      final block = plan.blocks[1]!.single;
      expect((block.startNode, block.endNode), (1, 3));
      expect(block.courses, [c, a, b]);
    });

    test('不在作息内的日程和考试进表头，不猜测节次', () {
      final event = widgetCourse(
        '晚间活动',
        monday.add(const Duration(hours: 21)),
        startNode: 0,
        endNode: 0,
        kind: WidgetItemKind.schedule,
      );
      final exam = widgetCourse(
        '考试',
        monday.add(const Duration(hours: 9)),
        startNode: 2,
        endNode: 3,
        kind: WidgetItemKind.exam,
      );
      final plan = planWeekWidget(
        week: makeWeek(monday, {
          1: [exam, event],
        }),
        periods: periods,
        prefs: const WeekWidgetPrefs(),
        widthDp: 256,
        heightDp: 448,
      );
      expect(weekNodeRange(event, periods), isNull);
      expect(plan.unplaced[1], [event]);
      final block = plan.blocks[1]!.single;
      expect((block.startNode, block.endNode), (2, 3));
      expect(block.primary, same(exam));
    });

    test('planWeekWidget：今天不在本周时不高亮，关闭节次隐藏时间列', () {
      final week = makeWeek(monday, {
        1: [widgetCourse('课', monday.add(const Duration(hours: 8)))],
      });
      final plan = planWeekWidget(
        week: week,
        periods: periods,
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
  });
}
