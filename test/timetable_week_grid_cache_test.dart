// 课表周视图列分组复用、跨周行高 LRU 缓存、胶囊测量缓存及正则/分组缓存回归测试。
// 全部为构造数据，不读真实样例。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 8, 31);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '11111111111111111111',
  String location = '测试楼 A101',
  String teacher = '张老师',
  bool isLab = false,
  CourseKind? kind,
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
      location: location,
      teacher: teacher,
      isLab: isLab,
      kind: kind,
    ),
  ],
);

Future<void> _pumpWeekGrid(
  WidgetTester tester, {
  required int week,
  bool keyedByWeek = true,
  TimetableSettings? settingsOverride,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WeekGrid(
          key: keyedByWeek ? ValueKey(week) : null,
          week: week,
          controller: _c,
          settingsOverride: settingsOverride,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpCourseCell(
  WidgetTester tester,
  GridCell cell, {
  double width = 240,
  double height = 120,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: CourseCell(
            controller: _c,
            cell: cell,
            width: width,
            height: height,
            radius: 4,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_week_grid_cache');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    WeekGrid.debugResetPeriodHeightCache();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 9, 1, 9);
  });

  tearDown(() {
    WeekGrid.debugResetPeriodHeightCache();
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('WeekGrid 跨周行高 LRU 缓存与列分组复用', () {
    testWidgets('第 1 周 ↔ 第 2 周来回切换命中缓存，行高与位置完全一致', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // 第 1 周有超长单节叠放课程拉高行高；第 2 周为短课保持默认行高。
      final w1Only = '1${'0' * 19}';
      final w2Only = '01${'0' * 18}';
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            periodHeight: 54,
            showTeacher: true,
          ),
        ),
        viewingWeek: 1,
        manualCourses: [
          _course(
            'w1_long_a',
            '高阶分布式系统与大规模并行计算导论实验课程甲',
            day: 1,
            start: 1,
            end: 1,
            weeks: w1Only,
            location: '气象楼南阶梯教室A205',
            teacher: '张老师、李老师、王老师',
          ),
          _course(
            'w1_stack_b',
            '编译原理',
            day: 2,
            start: 1,
            end: 1,
            weeks: w1Only,
          ),
          _course(
            'w1_stack_a',
            '操作系统',
            day: 2,
            start: 1,
            end: 1,
            weeks: w1Only,
          ),
          _course('w2_short', '离散数学', start: 1, end: 1, weeks: w2Only),
        ],
      );

      // 首次进入第 1 周：触发测量。
      await _pumpWeekGrid(tester, week: 1);
      expect(tester.takeException(), isNull);
      expect(WeekGrid.debugPeriodHeightMeasureCount, 1);
      expect(WeekGrid.debugPeriodHeightCacheHitCount, 0);
      expect(find.text('2 门'), findsOneWidget);
      final w1RectFirst = tester.getRect(
        find.widgetWithText(CourseCell, '操作系统'),
      );
      expect(w1RectFirst.height, greaterThan(54));

      // 翻到第 2 周（新建 State）：触发第 2 周测量。
      await _pumpWeekGrid(tester, week: 2);
      expect(tester.takeException(), isNull);
      expect(WeekGrid.debugPeriodHeightMeasureCount, 2);
      expect(WeekGrid.debugPeriodHeightCacheHitCount, 0);
      final w2RectFirst = tester.getRect(
        find.widgetWithText(CourseCell, '离散数学'),
      );
      expect(w2RectFirst.height, lessThan(w1RectFirst.height));

      // 滑回第 1 周（再次新建 State）：直接命中跨周 LRU 缓存，零重测且几何完全一致。
      await _pumpWeekGrid(tester, week: 1);
      expect(tester.takeException(), isNull);
      expect(WeekGrid.debugPeriodHeightMeasureCount, 2);
      expect(WeekGrid.debugPeriodHeightCacheHitCount, 1);
      expect(find.text('2 门'), findsOneWidget);
      final w1RectSecond = tester.getRect(
        find.widgetWithText(CourseCell, '操作系统'),
      );
      expect(w1RectSecond, w1RectFirst);

      // 再回到第 2 周（同 key 原地切周也命中缓存）。
      await _pumpWeekGrid(tester, week: 2, keyedByWeek: false);
      await _pumpWeekGrid(tester, week: 1, keyedByWeek: false);
      expect(WeekGrid.debugPeriodHeightMeasureCount, 2);
      expect(WeekGrid.debugPeriodHeightCacheHitCount, 3);
      expect(
        tester.getRect(find.widgetWithText(CourseCell, '操作系统')),
        w1RectFirst,
      );
    });

    testWidgets('缓存容量上限为 32 条并按 LRU 淘汰最久未访问项', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
        ),
        viewingWeek: 1,
        manualCourses: [_course('c1', '高等数学')],
      );

      // 使用 20 周 × 2 种行高 = 40 个不同输入，超过 32 条上限。
      for (var w = 1; w <= 20; w++) {
        await _pumpWeekGrid(
          tester,
          week: w,
          settingsOverride: TimetableSettings(
            termStartDate: _termStart,
            periodHeight: 54,
          ),
        );
      }
      for (var w = 1; w <= 15; w++) {
        await _pumpWeekGrid(
          tester,
          week: w,
          settingsOverride: TimetableSettings(
            termStartDate: _termStart,
            periodHeight: 60,
          ),
        );
      }

      expect(WeekGrid.debugPeriodHeightCacheLength, 32);
      expect(WeekGrid.debugPeriodHeightMeasureCount, 35);
      expect(WeekGrid.debugPeriodHeightCacheHitCount, 0);

      // 最近访问的第 15 周（height: 60）仍命中缓存。
      await _pumpWeekGrid(
        tester,
        week: 15,
        settingsOverride: TimetableSettings(
          termStartDate: _termStart,
          periodHeight: 60,
        ),
      );
      expect(WeekGrid.debugPeriodHeightCacheHitCount, 1);
      expect(WeekGrid.debugPeriodHeightMeasureCount, 35);

      // 最早被淘汰的第 1 周（height: 54）需重新测量，总容量仍保持 32。
      await _pumpWeekGrid(
        tester,
        week: 1,
        settingsOverride: TimetableSettings(
          termStartDate: _termStart,
          periodHeight: 54,
        ),
      );
      expect(WeekGrid.debugPeriodHeightMeasureCount, 36);
      expect(WeekGrid.debugPeriodHeightCacheLength, 32);
    });

    testWidgets('系统字体变化时清空跨周行高缓存并重新测量', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
        ),
        viewingWeek: 1,
        manualCourses: [_course('c1', '程序设计基础')],
      );

      await _pumpWeekGrid(tester, week: 1);
      await _pumpWeekGrid(tester, week: 1);
      expect(WeekGrid.debugPeriodHeightMeasureCount, 1);
      expect(WeekGrid.debugPeriodHeightCacheHitCount, 1);
      expect(WeekGrid.debugPeriodHeightCacheLength, 1);

      // 模拟系统字体变更通知。
      final fontsChanged = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'flutter/system',
            const JSONMessageCodec().encodeMessage({'type': 'fontsChange'}),
            (_) => fontsChanged.complete(),
          );
      await fontsChanged.future;
      expect(WeekGrid.debugPeriodHeightCacheLength, 0);
      await tester.pump();
      expect(WeekGrid.debugPeriodHeightMeasureCount, 2);
      expect(WeekGrid.debugPeriodHeightCacheLength, 1);
    });
  });

  group('静态正则与分组缓存回归', () {
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

    test('SlotCellGroup.primary 缓存首次排序结果且冲突计数正确', () {
      final courseB = _course('b', '编译原理');
      final courseA = _course('a', '操作系统');
      final group = SlotCellGroup([
        GridCell(
          course: courseB,
          slot: courseB.slots.first,
          conflictCount: 99,
          activeThisWeek: true,
        ),
        GridCell(
          course: courseA,
          slot: courseA.slots.first,
          conflictCount: 99,
          activeThisWeek: true,
        ),
      ]);

      final first = group.primary;
      final second = group.primary;
      expect(identical(first, second), isTrue);
      expect(first.course.id, 'a');
      expect(first.conflictCount, 1);

      final offGroup = SlotCellGroup([
        GridCell(
          course: courseB,
          slot: courseB.slots.first,
          conflictCount: 5,
          activeThisWeek: false,
        ),
      ]);
      expect(offGroup.primary.conflictCount, 0);
    });
  });

  group('CourseCell 胶囊宽度缓存与实验/单双周排版回归', () {
    testWidgets('宽格同时展示「实验」与「单周」胶囊，窄格降级只保留「实验」且无溢出', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
        ),
        viewingWeek: 1,
      );

      final oddLabCourse = _course(
        'lab_odd',
        '物理实验',
        weeks: '1010101010101010',
        isLab: true,
      );
      final cell = GridCell(
        course: oddLabCourse,
        slot: oddLabCourse.slots.first,
        conflictCount: 0,
        activeThisWeek: true,
      );

      // 宽格：两个胶囊并排居中且无异常。
      await _pumpCourseCell(tester, cell, width: 240, height: 120);
      expect(tester.takeException(), isNull);
      final lab = find.byKey(const Key('course_cell_lab_pill'));
      final parity = find.byKey(const Key('course_cell_parity_pill'));
      expect(lab, findsOneWidget);
      expect(parity, findsOneWidget);
      expect(find.text('实验'), findsOneWidget);
      expect(find.text('单周'), findsOneWidget);

      final labRect = tester.getRect(lab);
      final parityRect = tester.getRect(parity);
      expect(labRect.center.dy, closeTo(parityRect.center.dy, 0.01));
      expect(parityRect.left - labRect.right, closeTo(4, 0.01));

      // 窄格：总宽不足以放下两个胶囊时降级保留「实验」胶囊，不溢出。
      await _pumpCourseCell(tester, cell, width: 52, height: 120);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('course_cell_lab_pill')), findsOneWidget);
      expect(find.byKey(const Key('course_cell_parity_pill')), findsNothing);

      // 非实验双周课：仅显示「双周」胶囊（命中同一宽度缓存逻辑）。
      final evenCourse = _course(
        'even_course',
        '信号与系统',
        weeks: '0101010101010101',
      );
      await _pumpCourseCell(
        tester,
        GridCell(
          course: evenCourse,
          slot: evenCourse.slots.first,
          conflictCount: 0,
          activeThisWeek: true,
        ),
        width: 240,
        height: 120,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('course_cell_lab_pill')), findsNothing);
      expect(find.byKey(const Key('course_cell_parity_pill')), findsOneWidget);
      expect(find.text('双周'), findsOneWidget);
    });
  });
}
