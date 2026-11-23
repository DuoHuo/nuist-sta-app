// S2 专项回归测试：
// 1. 周视图垂直滚动期间 RepaintBoundary 复用光栅化图层，不触发静态课程/日程格重建或重绘；
// 2. CourseCell 消除内部多层 LayoutBuilder 嵌套并在各尺寸/徽标/开关组合下保持排版与语义一致。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
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
  String location = '明德楼A101',
  String teacher = '张老师',
  bool isLab = false,
  CourseKind? kind,
}) => Course(
  id: id,
  name: name,
  source: CourseSource.manual,
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

GridCell _gridCell(Course course, {bool active = true}) => GridCell(
  course: course,
  slot: course.slots.single,
  conflictCount: 0,
  activeThisWeek: active,
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_s2_week_grid_cell');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('WeekGrid 垂直滚动 RepaintBoundary 图层复用', () {
    testWidgets('含早/中/晚课程、非本周课与日程格：反复垂直滚动不触发静态格重建与图层重绘，点击命中准确', (tester) async {
      tester.view.physicalSize = const Size(375, 340);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final eveningExam = ScheduleEvent(
        id: 'ev_night',
        kind: ScheduleKind.exam,
        source: ScheduleSource.manual,
        title: '晚间期末考试',
        date: DateTime(2026, 9, 1), // 第 1 周周二
        start: const TimeOfDayMinutes(18, 30),
        end: const TimeOfDayMinutes(20, 10),
        location: '明德楼S201',
      );
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showNonCurrentWeek: true,
            showTeacher: true,
          ),
        ),
        viewingWeek: 1,
        manualCourses: [
          _course('morning', '高等数学（1）', day: 1, start: 1, end: 2),
          _course(
            'off_mid',
            '双周物理实验',
            day: 1,
            start: 5,
            end: 6,
            weeks: '01' * 10,
            isLab: true,
          ),
          _course(
            'night_course',
            '晚间选修课',
            day: 1,
            start: 9,
            end: 11,
            location: '气象楼B302',
          ),
        ],
      );
      late ScheduleEvent savedExam;
      await tester.runAsync(() async {
        savedExam = await _c.addScheduleEvent(eveningExam);
      });

      final tappedCourses = <String>[];
      final tappedEvents = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekGrid(
              week: 1,
              controller: _c,
              onCourseTap: (cell) => tappedCourses.add(cell.course.id),
              onEventTap: (event) => tappedEvents.add(event.id),
            ),
          ),
        ),
      );
      await tester.pump();

      final morningFinder = find.widgetWithText(CourseCell, '高等数学（1）');
      final offMidFinder = find.widgetWithText(CourseCell, '双周物理实验');
      final nightFinder = find.widgetWithText(CourseCell, '晚间选修课');
      final eventFinder = find.byType(ScheduleEventCell);
      expect(morningFinder, findsOneWidget);
      expect(offMidFinder, findsOneWidget);
      expect(nightFinder, findsOneWidget);
      expect(eventFinder, findsOneWidget);

      final morningWidget = tester.widget<CourseCell>(morningFinder);
      final offMidWidget = tester.widget<CourseCell>(offMidFinder);
      final nightWidget = tester.widget<CourseCell>(nightFinder);
      final eventWidget = tester.widget<ScheduleEventCell>(eventFinder);
      final morningElement = tester.element(morningFinder);
      final nightElement = tester.element(nightFinder);
      final eventElement = tester.element(eventFinder);

      final staticBoundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('week_grid_static_layer')),
      );
      final staticGrid = staticBoundary.child!;
      final staticStacks = tester
          .renderObjectList<RenderStack>(
            find.descendant(
              of: find.byKey(const Key('week_grid_static_layer')),
              matching: find.byType(Stack),
            ),
          )
          .map((stack) => stack.toStringShort())
          .toSet();

      final layouts = <String>[];
      final paints = <RenderObject>[];
      final origDebugPrint = debugPrint;
      final origPrintLayouts = debugPrintLayouts;
      final origProfilePaint = debugOnProfilePaint;

      Future<void> scrollBy(double dy) async {
        layouts.clear();
        paints.clear();
        try {
          debugPrint = (message, {wrapWidth}) {
            if (message != null && message.startsWith('Laying out')) {
              layouts.add(message);
            }
          };
          debugPrintLayouts = true;
          debugOnProfilePaint = paints.add;
          // 从右侧空列拖动，避免落到第 1/2 列格子上触发 InkWell 按下水波纹。
          final rect = tester.getRect(find.byType(SingleChildScrollView));
          await tester.dragFrom(
            Offset(rect.right - 20, rect.center.dy),
            Offset(0, dy),
          );
          await tester.pumpAndSettle();
        } finally {
          debugPrint = origDebugPrint;
          debugPrintLayouts = origPrintLayouts;
          debugOnProfilePaint = origProfilePaint;
        }
      }

      // 分段向下滚动到底部：每一段都复用同一 RepaintBoundary 图层且不触发静态格子重建。
      await scrollBy(-280);
      expect(
        layouts.where((m) => staticStacks.any(m.contains)),
        isEmpty,
        reason: '中段滚动不触发布局',
      );
      expect(paints, isNot(contains(staticGrid)), reason: '中段滚动复用静态绘制层');

      await scrollBy(-500);
      expect(
        layouts.where((m) => staticStacks.any(m.contains)),
        isEmpty,
        reason: '滚动至底部不触发布局',
      );
      expect(paints, isNot(contains(staticGrid)), reason: '滚动至底部复用静态绘制层');

      expect(tester.widget<CourseCell>(morningFinder), same(morningWidget));
      expect(tester.widget<CourseCell>(offMidFinder), same(offMidWidget));
      expect(tester.widget<CourseCell>(nightFinder), same(nightWidget));
      expect(tester.widget<ScheduleEventCell>(eventFinder), same(eventWidget));
      expect(tester.element(morningFinder), same(morningElement));
      expect(tester.element(nightFinder), same(nightElement));
      expect(tester.element(eventFinder), same(eventElement));

      // 滚到可见区域后，晚间课程与晚间考试热区均可正常命中。
      await tester.tap(nightFinder);
      await tester.pumpAndSettle();
      await tester.tap(eventFinder);
      await tester.pumpAndSettle();
      expect(tappedCourses, ['night_course']);
      expect(tappedEvents, [savedExam.id]);

      // 滚回顶部后静态层仍不被重绘，早课点击正常。
      await scrollBy(800);
      expect(layouts.where((m) => staticStacks.any(m.contains)), isEmpty);
      expect(paints, isNot(contains(staticGrid)));
      expect(tester.element(morningFinder), same(morningElement));

      await tester.tap(morningFinder);
      await tester.pump();
      expect(tappedCourses, ['night_course', 'morning']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('PageView 中相邻两周同时挂载时独立滚动，不冲突 PrimaryScrollController', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
        ),
        viewingWeek: 1,
        manualCourses: [
          _course('w1', '第一周夜课', start: 9, end: 10, weeks: '1000000000000000'),
          _course('w2', '第二周早课', start: 1, end: 2, weeks: '0100000000000000'),
        ],
      );

      final pageController = PageController(viewportFraction: 0.9);
      addTearDown(pageController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView.builder(
              controller: pageController,
              itemCount: 2,
              itemBuilder: (context, index) =>
                  WeekGrid(week: index + 1, controller: _c),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(WeekGrid), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('CourseCell 精简 LayoutBuilder 与全场景排版回归', () {
    setUp(() {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showLocation: true,
            showTeacher: true,
            showNonCurrentWeek: true,
          ),
        ),
        viewingWeek: 1,
      );
    });

    testWidgets('周视图与单格常规场景下 CourseCell 内部零 LayoutBuilder 嵌套', (tester) async {
      tester.view.physicalSize = const Size(360 * 2, 800 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showLocation: true,
            showTeacher: true,
            showNonCurrentWeek: true,
          ),
        ),
        viewingWeek: 1,
        manualCourses: [
          // 单节常规课
          _course('single', '大学物理Ⅱ（2）', day: 1, start: 1, end: 1),
          // 两节实验 + 单周（触发双胶囊判断）
          _course(
            'lab_odd',
            '电路分析实验',
            day: 2,
            start: 1,
            end: 2,
            weeks: '10' * 10,
            isLab: true,
          ),
          // 非本周 + 实验（触发非本周与实验双胶囊判断）
          _course(
            'off_lab',
            '离散数学实验',
            day: 3,
            start: 1,
            end: 2,
            weeks: '01' * 10,
            isLab: true,
          ),
          // 多课程叠放（冲突点 + 2 门胶囊）
          _course('stack_a', '操作系统', day: 4, start: 3, end: 4),
          _course('stack_b', '编译原理', day: 4, start: 3, end: 4),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WeekGrid(week: 1, controller: _c)),
        ),
      );
      await tester.pump();

      expect(find.byType(CourseCell), findsNWidgets(4));
      // 所有 CourseCell 内部（含内容区、底部双胶囊、CourseNameText）均不再嵌套 LayoutBuilder。
      expect(
        find.descendant(
          of: find.byType(CourseCell),
          matching: find.byType(LayoutBuilder),
        ),
        findsNothing,
      );
      // 整个 WeekGrid 只保留最外层 1 个用于获取可用宽度的 LayoutBuilder。
      expect(
        find.descendant(
          of: find.byType(WeekGrid),
          matching: find.byType(LayoutBuilder),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsOneWidget);
      expect(find.byKey(const Key('course_cell_stack_badge')), findsOneWidget);
      expect(find.text('2 门'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('单节/两节/窄列/叠放/隐藏地点与教师场景下排版、截断优先级与语义完全一致', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        // 1. 窄列低高度（单节极端空间）：课名 1 行省略、字号缩到下限 ≥10sp，地点与教师完整不截断。
        final tightCourse = _course(
          'tight',
          '计算机组成原理与体系结构（2）',
          start: 1,
          end: 1,
          location: '明德楼A101东侧实验室',
          teacher: '张老师、李老师',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: CourseCell(
                controller: _c,
                cell: _gridCell(tightCourse),
                width: 46,
                height: 56,
                radius: TimetableTheme.cellRadius,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(CourseCell),
            matching: find.byType(LayoutBuilder),
          ),
          findsNothing,
        );
        final tightName = tester.widget<CourseNameText>(
          find.byType(CourseNameText),
        );
        expect(tightName.maxLines, 1);
        expect(
          tightName.style.fontSize,
          greaterThanOrEqualTo(kCellMinFontSize),
        );
        expect(tightName.laidOutText, isNotNull);
        final tightLoc = tester.widget<Text>(
          find.byKey(const Key('course_cell_location')),
        );
        expect(tightLoc.maxLines, isNull);
        expect(tightLoc.data!.replaceAll('\u200B', ''), '@明德楼A101东侧实验室');
        final tightTeacher = tester.widget<Text>(
          find.byKey(const Key('course_cell_teacher')),
        );
        expect(tightTeacher.maxLines, isNull);
        expect(tightTeacher.data, '张老师\n李老师');
        expect(tester.takeException(), isNull);

        // 2. 两节高 + 宽格（实验 + 单周）vs 窄格（降级只保留实验）。
        final oddLab = _course(
          'odd_lab',
          '大学物理实验',
          start: 1,
          end: 2,
          weeks: '10' * 10,
          isLab: true,
        );
        for (final (width, expectParity) in [(160.0, true), (48.0, false)]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topLeft,
                child: CourseCell(
                  controller: _c,
                  cell: _gridCell(oddLab),
                  width: width,
                  height: 124,
                  radius: TimetableTheme.cellRadius,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(
            find.descendant(
              of: find.byType(CourseCell),
              matching: find.byType(LayoutBuilder),
            ),
            findsNothing,
          );
          expect(find.byKey(const Key('course_cell_lab_pill')), findsOneWidget);
          expect(
            find.byKey(const Key('course_cell_parity_pill')),
            expectParity ? findsOneWidget : findsNothing,
          );
          final label = tester
              .getSemantics(find.byType(CourseCell))
              .getSemanticsData()
              .label;
          expect(label, contains('实验课'));
          expect(label, contains('单周'));
          expect(tester.takeException(), isNull);
        }

        // 3. 非本周 + 实验：宽格并排（「非本周」在前），窄格仅留「非本周」且语义只读一次。
        for (final (width, expectLab) in [(180.0, true), (50.0, false)]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topLeft,
                child: CourseCell(
                  controller: _c,
                  cell: _gridCell(oddLab, active: false),
                  width: width,
                  height: 124,
                  radius: TimetableTheme.cellRadius,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(
            find.descendant(
              of: find.byType(CourseCell),
              matching: find.byType(LayoutBuilder),
            ),
            findsNothing,
          );
          expect(
            find.byKey(const Key('course_cell_off_week_pill')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('course_cell_lab_pill')),
            expectLab ? findsOneWidget : findsNothing,
          );
          final label = tester
              .getSemantics(find.byType(CourseCell))
              .getSemanticsData()
              .label;
          expect('非本周'.allMatches(label).length, 1);
          expect(tester.takeException(), isNull);
        }

        // 4. 多课程叠放 + 自定义项数标签 + 隐藏地点与教师。
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: CourseCell(
                controller: _c,
                settingsOverride: TimetableSettings(
                  termStartDate: _termStart,
                  showLocation: false,
                  showTeacher: false,
                ),
                cell: _gridCell(oddLab),
                width: 58,
                height: 120,
                radius: TimetableTheme.cellRadius,
                stackCount: 3,
                stackLabel: '3 项',
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(CourseCell),
            matching: find.byType(LayoutBuilder),
          ),
          findsNothing,
        );
        expect(find.byKey(const Key('course_cell_location')), findsNothing);
        expect(find.byKey(const Key('course_cell_teacher')), findsNothing);
        expect(
          find.byKey(const Key('course_cell_conflict_dot')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('course_cell_stack_badge')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('course_cell_lab_pill')), findsNothing);
        expect(find.text('3 项'), findsOneWidget);
        final stackLabel = tester
            .getSemantics(find.byType(CourseCell))
            .getSemanticsData()
            .label;
        expect(stackLabel, contains('本时段 3 项'));
        expect(stackLabel, isNot(contains('单周')));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('CourseCell 传入非有限尺寸时仅退化为最外层单次 LayoutBuilder', (tester) async {
      final labOdd = _course(
        'inf_lab',
        '大学物理实验',
        start: 1,
        end: 2,
        weeks: '10' * 10,
        isLab: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 160,
              height: 120,
              child: CourseCell(
                controller: _c,
                cell: _gridCell(labOdd),
                width: double.infinity,
                height: 120,
                radius: TimetableTheme.cellRadius,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(CourseCell),
          matching: find.byType(LayoutBuilder),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('course_cell_lab_pill')), findsOneWidget);
      expect(find.byKey(const Key('course_cell_parity_pill')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CourseNameText 传入 maxWidth 不嵌套 LayoutBuilder，未传时保持向后兼容', (
      tester,
    ) async {
      final style = TimetableTheme.cellStyle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 60,
                  child: CourseNameText(
                    key: const Key('with_width'),
                    name: '大学物理Ⅱ（2）',
                    style: style,
                    maxWidth: 60,
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: CourseNameText(
                    key: const Key('without_width'),
                    name: '大学物理Ⅱ（2）',
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('with_width')),
          matching: find.byType(LayoutBuilder),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('without_width')),
          matching: find.byType(LayoutBuilder),
        ),
        findsOneWidget,
      );
      final textA = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('with_width')),
              matching: find.byType(Text),
            ),
          )
          .data;
      final textB = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('without_width')),
              matching: find.byType(Text),
            ),
          )
          .data;
      expect(textA, textB);
    });
  });
}
