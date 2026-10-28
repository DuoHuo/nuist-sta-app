import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_color.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';

final _c = TimetableController.instance;

Course _jwxt(
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String? weeks,
}) => Course(
  id: name,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks ?? '1' * 20,
    ),
  ],
);

void _setCourses(List<Course> courses, {List<Course> manual = const []}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: courses,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: DateTime(2026, 9, 7)),
    ),
    viewingWeek: 1,
    manualCourses: manual,
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Future<void> _openForm(WidgetTester tester, {Course? initial}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showManualCourseForm(
              context,
              controller: _c,
              initial: initial,
              initialSlot: initial?.slots.first,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_form2');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('颜色', () {
    test('courseColorIndex：自选优先，否则按课名哈希', () {
      const a = Course(id: 'a', name: '学术英语(1)');
      expect(courseColorIndex(_c, a), TimetableTheme.colorIndexFor(a.name));
      expect(courseColorIndex(_c, a.copyWith(colorIndex: 7)), 7);
    });

    testWidgets('表单：保存为 accent 胶囊；周次选中 accent 实底白字', (tester) async {
      _setCourses(const []);
      await _openForm(tester);
      final save = tester.widget<FilledButton>(
        find.byKey(const Key('manual_course_save')),
      );
      expect(
        save.style!.backgroundColor!.resolve(<WidgetState>{}),
        TimetableTheme.accent,
      );
      expect(
        save.style!.foregroundColor!.resolve(<WidgetState>{}),
        Colors.white,
      );
      expect(save.style!.shape!.resolve(<WidgetState>{}), isA<StadiumBorder>());

      final chip = tester.widget<FilterChip>(
        find.byKey(const Key('manual_course_week_1')),
      );
      expect(chip.selected, isTrue);
      expect(chip.selectedColor, TimetableTheme.accent);
      expect(chip.labelStyle!.color, Colors.white);
      await tester.tap(find.byKey(const Key('manual_course_week_1')));
      await tester.pump();
      final off = tester.widget<FilterChip>(
        find.byKey(const Key('manual_course_week_1')),
      );
      expect(off.selected, isFalse);
      expect(off.backgroundColor, const Color(0xFFF0F1F3));
    });

    testWidgets('暗色选色面板实时预览深色课程', (tester) async {
      _setCourses(const []);
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showManualCourseForm(context, controller: _c),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manual_course_color')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tt_color_sv_panel')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('tt_color_hex')), '3873A2');
      await tester.pump();
      final preview = tester.widget<Container>(
        find.byKey(const Key('tt_color_display_swatch')),
      );
      expect(
        (preview.decoration! as BoxDecoration).color,
        TimetableTheme.userCoursePair(const Color(0xFF3873A2), dark: true).bg,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('未选颜色保存 colorIndex = null；预览为哈希色', (tester) async {
      _setCourses(const []);
      await _openForm(tester);
      await tester.enterText(find.byKey(const Key('manual_course_name')), '体育');
      await tester.pump();
      expect(
        find.byKey(const Key('manual_course_color_preview')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('manual_course_color')));
      await tester.pumpAndSettle();
      final preview = tester.widget<Container>(
        find.byKey(const Key('tt_color_display_swatch')),
      );
      expect(
        (preview.decoration! as BoxDecoration).color,
        TimetableTheme.autoCoursePairForName('体育').bg,
      );
      await tester.tap(find.byKey(const Key('tt_color_cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manual_course_save')));
      await _settle(tester);
      expect(_c.manualCourses.single.colorIndex, isNull);
    });

    testWidgets('选色后保存写入 userColors；编辑预填', (tester) async {
      _setCourses(const []);
      await _openForm(tester);
      await tester.enterText(find.byKey(const Key('manual_course_name')), '体育');
      await tester.tap(find.byKey(const Key('manual_course_color')));
      await tester.pumpAndSettle();
      const preset = Color(0xFF3873A2);
      await tester.enterText(find.byKey(const Key('tt_color_hex')), '3873A2');
      await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manual_course_save')));
      await _settle(tester);
      final saved = _c.manualCourses.single;
      // item 9：自选写入 userColors，不再写 colorIndex。
      expect(saved.colorIndex, isNull);
      expect(_c.userColorOf(saved), preset.toARGB32() | 0xFF000000);

      await _openForm(tester, initial: saved);
      expect(find.text('编辑课程'), findsOneWidget);
      expect(
        find.byKey(const Key('manual_course_color_preview')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('manual_course_color')));
      await tester.pumpAndSettle();
      final preview = tester.widget<Container>(
        find.byKey(const Key('tt_color_display_swatch')),
      );
      expect(
        (preview.decoration! as BoxDecoration).color,
        TimetableTheme.userCoursePair(preset).bg,
      );
      await tester.tap(find.byKey(const Key('tt_color_cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manual_course_save')));
      await _settle(tester);
      expect(_c.manualCourses.single.colorIndex, isNull);
      expect(
        _c.userColorOf(_c.manualCourses.single),
        preset.toARGB32() | 0xFF000000,
      );
    });
  });

  group('冲突提示', () {
    test('提示文案基于 controller.conflictsFor', () {
      final courses = [
        _jwxt('A', weeks: '1010101010'),
        _jwxt('B', day: 2),
        _jwxt('C', start: 3, end: 4),
      ];
      _setCourses(courses);
      // 双周：与 A（单周）不相交。
      const even = CourseSlot(
        day: 1,
        startNode: 2,
        endNode: 3,
        weeks: '0101010101',
      );
      final evenHits = _c.conflictsFor(even);
      expect(evenHits.map((e) => e.name), ['C']);
      expect(describeManualConflicts(even, evenHits), '与「C」第 2–10 周（双）冲突');

      const first5 = CourseSlot(
        day: 1,
        startNode: 2,
        endNode: 3,
        weeks: '1111100000',
      );
      final both = _c.conflictsFor(first5);
      expect(both.map((e) => e.name), ['A', 'C']);
      expect(describeManualConflicts(first5, both), '与 2 门课冲突');
      expect(
        describeManualConflicts(first5, [courses.first]),
        '与「A」第 1–5 周（单）冲突',
      );

      final self = CourseSlot(
        day: 1,
        startNode: 3,
        endNode: 3,
        weeks: '1' * 20,
      );
      expect(_c.conflictsFor(self, excludeId: 'C'), isEmpty);
      expect(
        describeManualConflicts(self, _c.conflictsFor(self, excludeId: 'C')),
        isNull,
      );
    });

    testWidgets('表单实时显示冲突，不阻断保存；编辑时排除自身', (tester) async {
      _setCourses([
        _jwxt('数据结构', weeks: '1' * 16),
        _jwxt('大学物理', start: 2, end: 3, weeks: '0' * 8 + '1' * 8),
      ]);
      await _openForm(tester);
      // 默认：周一 第 1 节、全部周 → 与数据结构冲突（第 1 节不与物理重叠）。
      expect(find.text('与「数据结构」第 1–16 周冲突'), findsOneWidget);
      final defaultSlot = CourseSlot(
        day: 1,
        startNode: 1,
        endNode: 1,
        weeks: '1' * _c.totalWeeks,
      );
      expect(
        find.text(
          describeManualConflicts(defaultSlot, _c.conflictsFor(defaultSlot))!,
        ),
        findsOneWidget,
      );
      final hint = tester.widget<Text>(
        find.byKey(const Key('manual_course_conflict')),
      );
      expect(hint.style!.fontSize, 12);
      expect(hint.style!.color, TimetableTheme.warning);

      // 改结束节为第 2 节 → 两门。
      await tester.tap(find.byKey(const ValueKey('manual_course_end_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 2 节').last);
      await tester.pumpAndSettle();
      expect(find.text('与 2 门课冲突'), findsOneWidget);
      final twoNodes = CourseSlot(
        day: 1,
        startNode: 1,
        endNode: 2,
        weeks: '1' * _c.totalWeeks,
      );
      expect(_c.conflictsFor(twoNodes), hasLength(2));

      // 改到周二 → 无冲突。
      await tester.tap(find.byKey(const Key('manual_course_day')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('周二').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('manual_course_conflict')), findsNothing);

      // 改回周一，冲突也能保存。
      await tester.tap(find.byKey(const Key('manual_course_day')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('周一').last);
      await tester.pumpAndSettle();
      expect(find.text('与 2 门课冲突'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('manual_course_name')), '自习');
      await tester.tap(find.byKey(const Key('manual_course_save')));
      await _settle(tester);
      expect(_c.manualCourses, hasLength(1));

      // 编辑自身：只剩与教务课的冲突，不把自己算进去。
      await _openForm(tester, initial: _c.manualCourses.single);
      expect(find.text('与 2 门课冲突'), findsOneWidget);
    });
  });

  group('手动课详情', () {
    testWidgets('顶部操作不重复范围选项；手动标签使用主题描边与文字', (tester) async {
      final slot = CourseSlot(
        day: 1,
        startNode: 1,
        endNode: 2,
        weeks: '1' * 16,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CourseDetailSheet(
              cell: GridCell(
                course: Course(id: 'm', name: '自习', slots: [slot]),
                slot: slot,
                conflictCount: 0,
                activeThisWeek: true,
              ),
              controller: _c,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('course_detail_edit')), findsOneWidget);
      expect(find.byKey(const Key('course_detail_delete')), findsOneWidget);
      expect(find.text('仅本周'), findsNothing);
      expect(find.text('所有周'), findsNothing);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);

      final tagBox = tester.widget<Container>(
        find
            .ancestor(of: find.text('手动添加'), matching: find.byType(Container))
            .first,
      );
      final deco = tagBox.decoration! as BoxDecoration;
      expect(deco.color, isNull);
      expect(
        (deco.border! as Border).top.color,
        TimetableTheme.colorsOf(tester.element(find.text('手动添加'))).divider,
      );
      final tagText = tester.widget<Text>(find.text('手动添加'));
      expect(
        tagText.style!.color,
        TimetableTheme.colorsOf(tester.element(find.text('手动添加'))).labelText,
      );
    });
  });

  group('课名括注不拆行（真实格宽）', () {
    // 1080x2400 @2.75 ≈ 392dp 宽；周视图 7 列，减节次列，再减格边距。
    const screenW = 1080 / 2.75;
    final dayW = (screenW - TimetableTheme.periodColumnWidth) / 7;
    final cellW = dayW - TimetableTheme.cellMargin * 2;
    const name = '学术英语(1)';

    RenderParagraph nameParagraph(WidgetTester tester) => tester
        .renderObjectList<RenderParagraph>(
          find.descendant(
            of: find.byType(CourseNameText),
            matching: find.byType(RichText),
          ),
        )
        .single;

    bool parenOnOneLineWithText(RenderParagraph p) {
      final text = p.text.toPlainText();
      final open = text.lastIndexOf('（');
      final close = text.lastIndexOf('）');
      final boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: open, extentOffset: close + 1),
      );
      final tops = boxes.map((b) => b.top.round()).toSet();
      return open >= 0 && tops.length == 1;
    }

    testWidgets('「）」不单独成行', (tester) async {
      final course = _jwxt(name);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CourseCell(
              controller: _c,
              cell: GridCell(
                course: course,
                slot: course.slots.first,
                conflictCount: 0,
                activeThisWeek: true,
              ),
              width: cellW,
              height: TimetableTheme.periodHeight * 2,
              radius: TimetableTheme.cellRadius,
            ),
          ),
        ),
      );
      final p = nameParagraph(tester);
      final text = p.text.toPlainText();
      expect(text.replaceAll('\u2060', '').replaceAll('\n', ''), '学术英语（1）');
      expect(parenOnOneLineWithText(p), isTrue, reason: text);

      // 「）」所在行不能只有它自己。
      final close = text.lastIndexOf('）');
      final closeTop = p
          .getBoxesForSelection(
            TextSelection(baseOffset: close, extentOffset: close + 1),
          )
          .single
          .top;
      final sameLine = [
        for (var i = 0; i < close; i++)
          if (!'\u2060\n'.contains(text[i]))
            if (p
                    .getBoxesForSelection(
                      TextSelection(baseOffset: i, extentOffset: i + 1),
                    )
                    .first
                    .top ==
                closeTop)
              i,
      ];
      expect(sameLine, isNotEmpty, reason: text);
      expect(tester.takeException(), isNull);
    });

    test('根因：仅靠 U+2060 时「末字+括注」比格宽还宽，被强制逐字断开', () {
      final style = TimetableTheme.cellStyle();
      final textW = cellW - 8; // CourseCell 左右各 4 内边距
      final glued = formatCellCourseName(name);
      final painter = TextPainter(
        text: TextSpan(text: glued, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: textW);
      final open = glued.lastIndexOf('（');
      final tops = painter
          .getBoxesForSelection(
            TextSelection(baseOffset: open, extentOffset: glued.length),
          )
          .map((b) => b.top.round())
          .toSet();
      painter.dispose();
      expect(tops.length, greaterThan(1));

      final fixed = layoutCellCourseName(name, style: style, maxWidth: textW);
      // 修复后不加 U+2060，括注不再被强制拆开。
      expect(fixed, isNot(contains('\u2060')));
      final p2 = TextPainter(
        text: TextSpan(text: fixed, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: textW);
      final tops2 = p2
          .getBoxesForSelection(
            TextSelection(
              baseOffset: fixed.lastIndexOf('（'),
              extentOffset: fixed.length,
            ),
          )
          .map((b) => b.top.round())
          .toSet();
      p2.dispose();
      expect(tops2, hasLength(1));
    });
  });
}
