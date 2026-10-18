// 10/18 UI 修正：拖动落点纯函数、设置页分段/滑块、格内地点逐字换行。
// 全部为构造数据，不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

void main() {
  group('resolveDropSlot 松手落点', () {
    const days7 = [1, 2, 3, 4, 5, 6, 7];
    ({int column, int day, int startPeriod}) drop(
      double left,
      double top, {
      List<int> days = days7,
      int span = 2,
      int lastPeriod = 12,
      DropTieBreak tie = kDropTieBreak,
    }) => resolveDropSlot(
      left: left,
      top: top,
      dayWidth: 50,
      periodHeight: 60,
      visibleDays: days,
      span: span,
      lastPeriod: lastPeriod,
      tieBreak: tie,
    );

    test('星期 = 水平中心所在列', () {
      expect(drop(0, 0).day, 1);
      expect(drop(24, 0).day, 1); // 中心 49 → 第 1 列
      expect(drop(26, 0).day, 2); // 中心 51 → 第 2 列
      expect(drop(70, 0).day, 2); // 中心 95
      expect(drop(80, 0).day, 3); // 中心 105
    });

    test('起始节 = 离上沿最近的节次线（四舍五入）', () {
      expect(drop(0, 29).startPeriod, 1);
      expect(drop(0, 31).startPeriod, 2);
      expect(drop(0, 96).startPeriod, 3); // 1.6 节
      expect(drop(0, 140).startPeriod, 3); // 2.33 节
    });

    test('恰好平局：取左边一列、前一节（默认规则）', () {
      expect(kDropTieBreak, DropTieBreak.earlier);
      expect(drop(25, 0).day, 1); // 中心 50 = 第 1/2 列分界
      expect(drop(75, 0).day, 2); // 中心 100 = 第 2/3 列分界
      expect(drop(0, 30).startPeriod, 1); // 0.5 节
      expect(drop(0, 150).startPeriod, 3); // 2.5 节
      // 另一方向仅作对照。
      expect(drop(25, 30, tie: DropTieBreak.later), (
        column: 1,
        day: 2,
        startPeriod: 2,
      ));
    });

    test('夹紧：整门课放得下，列不越界', () {
      expect(drop(0, 60 * 20).startPeriod, 11); // 2 节课最晚第 11 节起
      expect(drop(0, 60 * 20, span: 3).startPeriod, 10);
      expect(drop(0, 60 * 20, span: 1).startPeriod, 12);
      expect(drop(0, -500).startPeriod, 1);
      expect(drop(-500, 0).day, 1);
      expect(drop(5000, 0).day, 7);
      // 课比作息还长：从第 1 节起。
      expect(drop(0, 300, span: 14).startPeriod, 1);
    });

    test('隐藏列落不到：只在可见列中取', () {
      const weekdays = [1, 2, 3, 4, 5];
      expect(drop(5000, 0, days: weekdays), (
        column: 4,
        day: 5,
        startPeriod: 1,
      ));
      // 周日开头（周日列显示、周六隐藏）：第 1 列是周日，最后一列是周五。
      const sundayFirst = [7, 1, 2, 3, 4, 5];
      expect(drop(0, 0, days: sundayFirst).day, 7);
      expect(drop(5000, 0, days: sundayFirst).day, 5);
      expect(drop(60, 0, days: sundayFirst).day, 1);
    });
  });

  test('cellLocationText：只在相邻非汉字之间插零宽空格，可见文字不变', () {
    expect(cellLocationText('揽江楼'), '@揽江楼');
    final s = cellLocationText('明德楼A101');
    expect(s.replaceAll('\u200B', ''), '@明德楼A101');
    expect(s, '@明德楼A\u200B1\u200B0\u200B1');
  });

  group('设置页', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_ui_fixes');
      TimetableStore.debugDirectory = tmp;
      _c.debugReset();
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 9, 7)),
        ),
        viewingWeek: 2,
      );
    });

    tearDown(() {
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorSchemeSeed: Colors.pink),
          home: TimetableSettingsPage(controller: _c),
        ),
      );
      await tester.pump();
    }

    testWidgets('分段选项：未选中灰描边 #D0D4DC + 正文灰字，选中浅蓝底蓝字无描边', (tester) async {
      await pumpPage(tester);
      ChoiceChip chip(String label) =>
          tester.widget<ChoiceChip>(find.byKey(ValueKey('seg_$label')));
      for (final (sel, unsel) in [
        ('周一', ['周日']),
        ('标准', ['小', '大']),
      ]) {
        final s = chip(sel);
        expect(s.selected, isTrue);
        expect(s.selectedColor, TimetableTheme.accentSoft);
        expect(s.labelStyle!.color, TimetableTheme.accent);
        expect(s.side!.color, Colors.transparent);
        for (final u in unsel) {
          final x = chip(u);
          expect(x.selected, isFalse);
          expect(x.side!.color, const Color(0xFFD0D4DC));
          expect(x.labelStyle!.color, TimetableTheme.labelText);
          expect(x.surfaceTintColor, Colors.transparent);
        }
      }
    });

    testWidgets('「不透明度」「格子高度」两个滑块左右边缘对齐', (tester) async {
      await pumpPage(tester);
      final a = find.byKey(const Key('tt_settings_opacity'));
      final b = find.byKey(const Key('tt_settings_period_height'));
      await tester.ensureVisible(b);
      await tester.pumpAndSettle();
      final ra = tester.getRect(a);
      final rb = tester.getRect(b);
      expect(ra.left, closeTo(rb.left, 0.01));
      expect(ra.right, closeTo(rb.right, 0.01));
      expect(ra.width, greaterThan(100));
    });
  });

  group('格内地点逐字换行', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_ui_fixes_cell');
      TimetableStore.debugDirectory = tmp;
      _c.debugReset();
    });

    tearDown(() {
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<void> pumpGrid(
      WidgetTester tester, {
      required double periodHeight,
      required int end,
      bool showTeacher = false,
    }) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 9, 7),
            periodHeight: periodHeight,
            fontScale: CellFontScale.large,
            showTeacher: showTeacher,
          ),
        ),
        viewingWeek: 1,
        manualCourses: [
          Course(
            id: 'm',
            name: '高数',
            slots: [
              CourseSlot(
                day: 1,
                startNode: 1,
                endNode: end,
                weeks: '1' * 16,
                location: '学而楼C303多媒体教室东侧',
                teacher: '教师A',
              ),
            ],
          ),
        ],
      );
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WeekGrid(week: 1, controller: _c)),
        ),
      );
      await tester.pump();
    }

    int locationLines(WidgetTester tester) {
      final p = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const Key('course_cell_location')),
          matching: find.byType(RichText),
        ),
      );
      final text = p.text.toPlainText();
      return {
        for (final b in p.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: text.length),
        ))
          b.top.round(),
      }.length;
    }

    // §13.9 / LC01（替代旧「地点最多 2 行、末行省略」）：地点永不截断，按字换多行。
    testWidgets('LC01 字号大 + 长地点：逐字换行完整显示，无省略，不溢出', (tester) async {
      await pumpGrid(tester, periodHeight: 64, end: 2);
      expect(tester.takeException(), isNull);
      final t = tester.widget<Text>(
        find.byKey(const Key('course_cell_location')),
      );
      expect(t.maxLines, isNull);
      expect(t.overflow, isNot(TextOverflow.ellipsis));
      expect(t.data!.replaceAll('\u200B', ''), '@学而楼C303多媒体教室东侧');
      expect(locationLines(tester), greaterThanOrEqualTo(2));
      final p = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const Key('course_cell_location')),
          matching: find.byType(RichText),
        ),
      );
      expect(p.didExceedMaxLines, isFalse);
      // 地点不越出格子。
      final cell = tester.getRect(find.byType(CourseCell));
      final loc = tester.getRect(find.byKey(const Key('course_cell_location')));
      expect(loc.bottom <= cell.bottom + 0.01, isTrue);
    });

    testWidgets('LC03 空间不够时老师先让位：地点完整优先于老师', (tester) async {
      await pumpGrid(tester, periodHeight: 64, end: 1, showTeacher: true);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('course_cell_location')), findsOneWidget);
      expect(find.byKey(const Key('course_cell_teacher')), findsNothing);
      expect(locationLines(tester), greaterThanOrEqualTo(2));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('course_cell_location')))
            .maxLines,
        isNull,
      );
    });
  });

  // §13.8（NW 系列，替代 V05 / 旧 NC 用例中的「[非本周]」前缀与灰色块）。
  group('NC 非本周格：「非本周」胶囊替代前缀', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_ui_fixes_nc');
      TimetableStore.debugDirectory = tmp;
      _c.debugReset();
    });

    tearDown(() {
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<void> pumpGrid(
      WidgetTester tester, {
      required int week,
      bool showNonCurrent = true,
      double periodHeight = 64,
      CellFontScale fontScale = CellFontScale.standard,
      List<Course>? courses,
    }) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 9, 7),
            showNonCurrentWeek: showNonCurrent,
            periodHeight: periodHeight,
            fontScale: fontScale,
            showTeacher: true,
          ),
        ),
        viewingWeek: week,
        manualCourses:
            courses ??
            [
              Course(
                id: 'o',
                name: '单周课',
                slots: [
                  CourseSlot(
                    day: 1,
                    startNode: 1,
                    endNode: 2,
                    weeks: '10' * 10,
                    location: '明德楼A101',
                  ),
                ],
              ),
            ],
      );
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => WeekGrid(
                week: week,
                controller: _c,
                onCourseTap: (cell) =>
                    showCourseDetailSheet(context, cell: cell, controller: _c),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    String cellLabel(WidgetTester tester) => tester
        .widget<Semantics>(
          find
              .descendant(
                of: find.byType(CourseCell),
                matching: find.byType(Semantics),
              )
              .first,
        )
        .properties
        .label!;

    Text nameText(WidgetTester tester) => tester.widget<Text>(
      find.descendant(
        of: find.byType(CourseNameText),
        matching: find.byType(Text),
      ),
    );

    testWidgets('NC01/NW03/NW04 设置开：课名无前缀、offWeekText 字；底部「非本周」胶囊替代'
        '单周胶囊；朗读「非本周，课名…」只读一次；详情标题不带前缀', (tester) async {
      await pumpGrid(tester, week: 2);
      expect(find.byType(CourseCell), findsOneWidget);
      final t = nameText(tester);
      expect(t.data, '单周课');
      expect(t.style!.color, TimetableTheme.offWeekText);
      expect(find.textContaining('[非本周]'), findsNothing);
      final label = cellLabel(tester);
      expect(label, startsWith('非本周，单周课，'));
      expect('非本周'.allMatches(label).length, 1);
      expect(label, isNot(contains('[非本周]')));
      // 单周课在双周显示为非本周：只显示「非本周」胶囊，不同时显示「单周」。
      expect(find.text('非本周'), findsOneWidget);
      expect(find.text('单周'), findsNothing);
      expect(
        tester.widget<Text>(find.text('非本周')).style!.color,
        TimetableTheme.offWeekText,
      );
      expect(find.byKey(const Key('course_cell_location')), findsOneWidget);
      // 点开详情：标题是课名本身。
      await tester.tap(find.byType(CourseCell));
      await tester.pumpAndSettle();
      expect(find.byType(CourseDetailSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CourseDetailSheet),
          matching: find.textContaining('非本周'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(CourseDetailSheet),
          matching: find.text('单周课'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('NC02 本周课无「非本周」胶囊，朗读不含「非本周」', (tester) async {
      await pumpGrid(tester, week: 1);
      final t = nameText(tester);
      expect(t.data, '单周课');
      expect(t.semanticsLabel, isNull);
      expect(find.textContaining('非本周'), findsNothing);
      expect(cellLabel(tester), isNot(contains('非本周')));
      expect(cellLabel(tester), startsWith('单周课，'));
    });

    testWidgets('NC03 设置关：非本周课不显示，自然没有前缀', (tester) async {
      await pumpGrid(tester, week: 2, showNonCurrent: false);
      expect(find.byType(CourseCell), findsNothing);
      expect(find.textContaining('非本周'), findsNothing);
    });

    for (final h in [52.0, 90.0]) {
      testWidgets('NC04/LC09 格高 $h + 字号大：非本周长课名不溢出', (tester) async {
        await pumpGrid(
          tester,
          week: 2,
          periodHeight: h,
          fontScale: CellFontScale.large,
          courses: [
            for (final (id, day, end, name) in [
              ('a', 1, 1, '单周课'),
              ('b', 2, 1, '马克思主义基本原理概论（2）'),
              ('c', 3, 2, '马克思主义基本原理概论与中国特色社会主义理论体系（2）'),
            ])
              Course(
                id: id,
                name: name,
                classId: '2026001',
                slots: [
                  CourseSlot(
                    day: day,
                    startNode: 1,
                    endNode: end,
                    weeks: '10' * 10,
                    location: '学而楼C303多媒体教室',
                    teacher: '教师A',
                  ),
                ],
              ),
          ],
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(CourseCell), findsNWidgets(3));
        for (final e in find.byType(CourseCell).evaluate()) {
          final cell = tester.getRect(find.byWidget(e.widget));
          final texts = find.descendant(
            of: find.byWidget(e.widget),
            matching: find.byType(Text),
          );
          for (final te in texts.evaluate()) {
            final r = tester.getRect(find.byWidget(te.widget));
            expect(r.top >= cell.top - 0.01, isTrue);
          }
          final name = tester.widget<Text>(
            find.descendant(
              of: find.byWidget(e.widget),
              matching: find.descendant(
                of: find.byType(CourseNameText),
                matching: find.byType(Text),
              ),
            ),
          );
          expect(name.data, isNot(contains('非本周')));
          expect(name.maxLines, greaterThanOrEqualTo(1));
          expect(
            find.descendant(
              of: find.byWidget(e.widget),
              matching: find.byKey(const Key('course_cell_off_week_pill')),
            ),
            findsOneWidget,
          );
        }
      });
    }
  });
}
