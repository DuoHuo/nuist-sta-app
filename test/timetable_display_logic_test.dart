import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_date_edits.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 8, 31); // 第 1 周周一

String _bits(List<int> weeks, {int length = 20}) => weeksToBits(weeks, length);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  required String weeks,
  bool isLab = false,
  String buildingDisplay = '',
  String projectName = '',
  String location = '测试楼A101',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  buildingDisplay: buildingDisplay,
  projectName: projectName,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      isLab: isLab,
      location: location,
    ),
  ],
);

ScheduleEvent _exam(
  String id,
  String title, {
  required DateTime date,
  TimeOfDayMinutes start = const TimeOfDayMinutes(8, 0),
  TimeOfDayMinutes end = const TimeOfDayMinutes(9, 40),
  String location = '考场B202',
}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.exam,
  source: ScheduleSource.manual,
  title: title,
  date: date,
  start: start,
  end: end,
  location: location,
);

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _pumpGrid(WidgetTester tester, {required int week}) async {
  _bigView(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WeekGrid(key: ValueKey(week), week: week, controller: _c),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_display_logic');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('课程类型与单双周判定', () {
    test('体育课即便带旧教务实验标记，courseKindOf 仍判为体育；显式设置仍优先', () {
      final pe = _course(
        'pe',
        '体育（1）',
        weeks: _bits([1, 2, 3]),
        isLab: true,
        buildingDisplay: '体育板块场地',
        projectName: '篮球',
      );
      expect(courseKindOf(course: pe, slot: pe.slots.single), CourseKind.pe);

      final explicitLab = pe.slots.single.copyWith(kind: CourseKind.lab);
      expect(
        courseKindOf(course: pe.forSlot(explicitLab), slot: explicitLab),
        CourseKind.lab,
      );
    });

    test('displayWeekParity 排除零散非连续周，保留法定节假日跳周的单双周', () {
      expect(displayWeekParity(_bits([3, 15])), WeekParity.all);
      expect(displayWeekParity(_bits([1])), WeekParity.all);
      expect(displayWeekParity(_bits([1, 3])), WeekParity.odd);
      expect(displayWeekParity(_bits([2, 4])), WeekParity.even);
      // 国庆跳过第 7 周的单周课仍应识别为单周。
      expect(displayWeekParity(_bits([1, 3, 5, 9, 11, 13])), WeekParity.odd);
      expect(displayWeekParity(_bits([1, 2, 3])), WeekParity.all);
    });

    testWidgets('编辑教务课周次后单双周标签跟随新周次，单日挪课不显示单双周', (tester) async {
      final jwxt = _course(
        'k1',
        '高等数学',
        weeks: '1' * 16,
        source: CourseSource.jwxt,
      );
      final editedOddSlot = CourseSlot(
        day: 1,
        startNode: 1,
        endNode: 2,
        weeks: _bits([1, 3, 5, 7, 9]),
      );
      tagSlotOrigin(
        editedOddSlot,
        SlotOrigin(
          courseId: jwxt.id,
          original: jwxt.slots.single,
          moved: false,
          weeksEdited: true,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CourseCell(
              controller: _c,
              cell: GridCell(
                course: jwxt,
                slot: editedOddSlot,
                conflictCount: 0,
                activeThisWeek: true,
              ),
              width: 120,
              height: 120,
              radius: 4,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('course_cell_parity_pill')), findsOneWidget);
      expect(find.text('单周'), findsOneWidget);

      // 单日挪课（「只改这一天」改了日期/节次）：不再显示单周胶囊。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CourseCell(
              controller: _c,
              cell: GridCell(
                course: jwxt,
                slot: editedOddSlot,
                conflictCount: 0,
                activeThisWeek: true,
                dateEdit: CourseDateEdit(
                  id: 'de1',
                  courseId: jwxt.id,
                  date: DateTime(2026, 8, 31),
                  origStart: 1,
                  origEnd: 2,
                  toDate: DateTime(2026, 9, 1),
                  toStart: 3,
                  toEnd: 4,
                ),
              ),
              width: 120,
              height: 120,
              radius: 4,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('course_cell_parity_pill')), findsNothing);
    });
  });

  group('周视图零误报冲突与当前/最近优先', () {
    testWidgets('未来周幽灵考试不把本周正常课变成「2 门 / 2 项」冲突', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showNonCurrentWeek: true,
            showExams: true,
          ),
        ),
        viewingWeek: 5,
        manualCourses: [_course('m1', '高等数学', day: 1, weeks: '1' * 16)],
      );
      // 第 17 周周一（2026-12-21）08:00–09:40 期末考试。
      await tester.runAsync(
        () => _c.addScheduleEvent(
          _exam('ex17', '大学英语期末考', date: DateTime(2026, 12, 21)),
        ),
      );
      await _pumpGrid(tester, week: 5);

      expect(find.widgetWithText(CourseCell, '高等数学'), findsOneWidget);
      expect(find.byType(ScheduleEventCell), findsNothing);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
      expect(find.byKey(const Key('course_cell_stack_badge')), findsNothing);
      expect(find.textContaining('门'), findsNothing);
      expect(find.textContaining('项'), findsNothing);
    });

    testWidgets('多场不同周的幽灵考试不合并成「2 门」，只显示最近的一场', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showNonCurrentWeek: true,
            showExams: true,
          ),
        ),
        viewingWeek: 5,
        manualCourses: [
          // 占位课程放在周三，周一 1–2 节留空给未来考试。
          _course('m1', '占位课', day: 3, weeks: '1' * 16),
        ],
      );
      // 第 17 周考试先写入且字典序更靠前，第 16 周考试更近。
      await tester.runAsync(() async {
        await _c.addScheduleEvent(
          _exam('ex17', 'A更晚期末考', date: DateTime(2026, 12, 21)),
        );
        await _c.addScheduleEvent(
          _exam('ex16', 'Z更近期末考', date: DateTime(2026, 12, 14)),
        );
      });
      await _pumpGrid(tester, week: 5);

      expect(find.widgetWithText(ScheduleEventCell, 'Z更近期末考'), findsOneWidget);
      expect(find.widgetWithText(ScheduleEventCell, 'A更晚期末考'), findsNothing);
      expect(find.byKey(const Key('schedule_cell_conflict_dot')), findsNothing);
      expect(find.byKey(const Key('schedule_cell_stack_badge')), findsNothing);
      expect(find.byKey(const Key('schedule_cell_exam_pill')), findsOneWidget);
      expect(
        find.byKey(const Key('schedule_cell_off_week_pill')),
        findsOneWidget,
      );
    });

    testWidgets('多门非本周课在同一节次：按距离当前周最近择一，不按课名字典序，也不标「N 门」', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showNonCurrentWeek: true,
          ),
        ),
        viewingWeek: 1,
        manualCourses: [
          // 字典序靠前但第 9 周才上。
          _course('c1', 'C语言', day: 1, weeks: _bits([9, 10, 11, 12])),
          // 字典序靠后但第 2 周就上（最近）。
          _course('c2', '高等数学', day: 1, weeks: _bits([2, 3, 4, 5])),
        ],
      );
      await _pumpGrid(tester, week: 1);

      expect(find.widgetWithText(CourseCell, '高等数学'), findsOneWidget);
      expect(find.widgetWithText(CourseCell, 'C语言'), findsNothing);
      expect(
        find.byKey(const Key('course_cell_off_week_pill')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
      expect(find.textContaining('门'), findsNothing);
    });

    testWidgets('考试跨两段不重叠本周课程（非定位态）：连通合并成一格，无重叠遮挡与重复计数', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showExams: true,
          ),
        ),
        viewingWeek: 1,
        manualCourses: [
          _course('a', '早课甲', day: 1, start: 1, end: 2, weeks: '1' * 16),
          _course('b', '早课乙', day: 1, start: 3, end: 4, weeks: '1' * 16),
        ],
      );
      // 第 1 周周一 09:00–10:30（覆盖第 2–3 节），同时碰到 1–2 与 3–4 两门课。
      await tester.runAsync(
        () => _c.addScheduleEvent(
          _exam(
            'bridge',
            '跨段期中考',
            date: _termStart,
            start: const TimeOfDayMinutes(9, 0),
            end: const TimeOfDayMinutes(10, 30),
          ),
        ),
      );
      await _pumpGrid(tester, week: 1);

      // 连通后只画 1 格（考试优先），显示「3 项」，两门普通课不会再另画重叠格子。
      expect(find.byType(ScheduleEventCell), findsOneWidget);
      expect(find.byType(CourseCell), findsNothing);
      expect(find.text('跨段期中考'), findsOneWidget);
      expect(find.text('3 项'), findsOneWidget);

      await tester.tap(find.byType(ScheduleEventCell));
      await tester.pumpAndSettle();
      expect(find.text('本时段 3 项'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stack_item_event_bridge')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stack_item_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('stack_item_b')), findsOneWidget);
    });
  });

  group('日程格自适应、详情调课来源与首页实验标', () {
    testWidgets('ScheduleEventCell 超长考试标题在矮格下截断标题并保住考场地点', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
        ),
        viewingWeek: 1,
      );
      final exam = _exam(
        'long',
        '马克思主义基本原理概论与中国特色社会主义理论体系期末闭卷考试',
        date: _termStart,
        location: '明德楼N101',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ScheduleEventCell(
                controller: _c,
                event: exam,
                width: 60,
                height: 92,
                radius: 4,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final cellRect = tester.getRect(find.byType(ScheduleEventCell));
      final locFinder = find.text('@明德楼N101');
      expect(locFinder, findsOneWidget);
      final locRect = tester.getRect(locFinder);
      final badgeRect = tester.getRect(
        find.byKey(const Key('schedule_cell_exam_pill')),
      );
      expect(locRect.bottom, lessThanOrEqualTo(badgeRect.top + 0.5));
      expect(locRect.bottom, lessThanOrEqualTo(cellRect.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('「其他」日程格同样遵守文字颜色（白/黑）设置', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            cellTextColor: CellTextColorMode.white,
          ),
        ),
        viewingWeek: 1,
      );
      final other = ScheduleEvent(
        id: 'o1',
        kind: ScheduleKind.other,
        source: ScheduleSource.manual,
        title: '社团例会',
        date: _termStart,
        start: const TimeOfDayMinutes(8, 0),
        end: const TimeOfDayMinutes(9, 40),
        location: '活动中心',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleEventCell(
              controller: _c,
              event: other,
              width: 100,
              height: 120,
              radius: 4,
            ),
          ),
        ),
      );
      await tester.pump();
      final title = tester.widget<Text>(find.text('社团例会'));
      expect(title.style?.color, TimetableTheme.forcedWhiteText);
    });

    testWidgets('CourseDetailSheet 显示整天调课来源日期标签', (tester) async {
      final course = _course('m1', '数据结构', day: 7, weeks: '1' * 16);
      final cell = GridCell(
        course: course,
        slot: course.slots.single,
        conflictCount: 0,
        activeThisWeek: true,
        date: DateTime(2026, 9, 6),
        swappedFrom: DateTime(2026, 9, 2),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CourseDetailSheet(cell: cell, controller: _c),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('course_detail_swapped_from')),
        findsOneWidget,
      );
      expect(find.text('由 9月2日 调入'), findsOneWidget);
    });

    testWidgets('TimetableHomeCard 实验课行轻标「实验」胶囊', (tester) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
        ),
        viewingWeek: 1,
        manualCourses: [
          _course('lab1', '物理实验', day: 1, weeks: '1' * 16, isLab: true),
        ],
      );
      final now = DateTime(2026, 8, 31, 7, 30);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => now)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('home_course_lab_pill')), findsOneWidget);
      expect(find.text('实验'), findsOneWidget);
    });
  });
}
