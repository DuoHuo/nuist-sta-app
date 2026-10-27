import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

/// WeekGrid 的格宽推导：(屏宽 - 节次列) / 7 - 两侧边距。
double _cellWidthFor(double screenDp) =>
    (screenDp - TimetableTheme.periodColumnWidth) / 7 -
    TimetableTheme.cellMargin * 2;

void main() {
  testWidgets('体育项目在周课表格子共用显示名，有项目去序号、无项目保留原名', (tester) async {
    _c.debugReset();
    addTearDown(_c.debugReset);
    for (final project in ['射箭', '']) {
      final course = Course(
        id: 'pe',
        name: '体育（3）',
        projectName: project,
        slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 16)],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CourseCell(
              controller: _c,
              cell: GridCell(
                course: course,
                slot: course.slots.single,
                conflictCount: 0,
                activeThisWeek: true,
              ),
              width: 100,
              height: 120,
              radius: TimetableTheme.cellRadius,
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(CourseNameText),
          matching: find.byType(RichText),
        ),
      );
      expect(
        paragraph.text
            .toPlainText()
            .replaceAll('\n', '')
            .replaceAll('\u2060', ''),
        project.isEmpty ? '体育（3）' : '体育·射箭',
      );
      expect(tester.takeException(), isNull);
    }
  });

  group('B02 课名括注不拆行', () {
    // 模拟器 1080x2400 @420dpi ≈ 411dp；此前用的手机 1080/2.75 ≈ 392dp。
    final widths = <String, double>{
      'emulator 411dp': _cellWidthFor(1080 / (420 / 160)),
      'phone 392dp': _cellWidthFor(1080 / 2.75),
    };
    const names = ['学术英语（1）', '大学物理Ⅱ（2）', '学术英语(1)'];

    /// 按实际排版把段落文字切成行（以每个字符框的 top 归行）。
    List<String> linesOf(RenderParagraph p) {
      final text = p.text.toPlainText();
      final byTop = <int, StringBuffer>{};
      for (var i = 0; i < text.length; i++) {
        final ch = text[i];
        if (ch == '\n' || ch == '\u2060') continue;
        final boxes = p.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
        );
        if (boxes.isEmpty) continue;
        byTop.putIfAbsent(boxes.first.top.round(), StringBuffer.new).write(ch);
      }
      final keys = byTop.keys.toList()..sort();
      return [for (final k in keys) byTop[k].toString()];
    }

    for (final w in widths.entries) {
      for (final name in names) {
        testWidgets('${w.key} · $name', (tester) async {
          final course = Course(
            id: 'x',
            name: name,
            source: CourseSource.jwxt,
            slots: [
              CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20),
            ],
          );
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
                  width: w.value,
                  height: TimetableTheme.periodHeight * 2,
                  radius: TimetableTheme.cellRadius,
                ),
              ),
            ),
          );
          final p = tester
              .renderObjectList<RenderParagraph>(
                find.descendant(
                  of: find.byType(CourseNameText),
                  matching: find.byType(RichText),
                ),
              )
              .single;
          final raw = p.text.toPlainText();
          // 无重复/丢字：去掉 \n、U+2060 后与归一化课名完全相等。
          expect(
            raw.replaceAll('\n', '').replaceAll('\u2060', ''),
            normalizeCourseName(name),
          );
          final lines = linesOf(p);
          expect(lines.join(), normalizeCourseName(name), reason: '$lines');
          expect(lines.length, lessThanOrEqualTo(3), reason: '$lines');
          expect(lines.any((l) => l == '）'), isFalse, reason: '$lines');
          final parenLine = lines.where((l) => l.contains('（')).single;
          expect(parenLine, contains('）'), reason: '$lines');
          expect(tester.takeException(), isNull);
        });
      }
    }

    test('不再依赖 U+2060：输出无隐藏字符，按设计在「（」前自然断行', () {
      final style = TimetableTheme.cellStyle();
      final maxWidth = _cellWidthFor(1080 / 2.75) - 8; // CourseCell 左右各 4
      final out = layoutCellCourseName(
        '学术英语(1)',
        style: style,
        maxWidth: maxWidth,
      );
      expect(out, isNot(contains('\u2060')));
      final painter = TextPainter(
        text: TextSpan(text: out, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      final lines = painter.computeLineMetrics().length;
      final parenTops = painter
          .getBoxesForSelection(
            TextSelection(
              baseOffset: out.indexOf('（'),
              extentOffset: out.length,
            ),
          )
          .map((b) => b.top.round())
          .toSet();
      painter.dispose();
      expect(lines, 3); // 学术英 / 语 / （1）
      expect(parenTops, hasLength(1));
    });
  });

  group('B02b 真实 WeekGrid 排版：罗马数字+括注为一个单元、不重复', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_b02b');
      TimetableStore.debugDirectory = tmp;
      _c.debugReset();
    });
    tearDown(() {
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    // 屏幕：模拟器 1080x2400 @2.625（7 列文字宽 ≈43dp，5 列 ≈64dp）；
    // 手机 1080x2400 @2.75（7 列 ≈40dp）。
    // 字体：flutter_test 默认字体（每字 1em，Ⅱ（2）=48dp）与系统 Noto Sans CJK
    // （与 Android 一致，Ⅱ（2）≈42.7dp）。前者只断言不变量，后者再断言精确拆行。
    const configs = <(String, double, bool)>[
      ('emulator 7col 43dp', 2.625, true),
      ('emulator 5col 64dp', 2.625, false),
      ('phone 7col 40dp', 2.75, true),
    ];
    const names = ['大学物理Ⅱ（2）', '线性代数Ⅰ（1）', '学术英语（1）', '数据结构'];
    const notoPath = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
    final hasNoto = File(notoPath).existsSync();
    var notoLoaded = false;

    /// 精确期望（仅 Noto CJK，且仅在离边界足够远、与字体细节无关的情况）。
    /// 7 列 43dp 下 Ⅱ（2）≈42.7+字距 1.0 ≈43.7dp，与 42.9dp 只差 <1dp，
    /// 设备（模拟器实测 大学物 / 理 / Ⅱ（2））与测试字体结果可能不同，故不做精确断言。
    const notoExpected = <String, List<String>>{
      'emulator 5col 64dp · 大学物理Ⅱ（2）': ['大学物理', 'Ⅱ（2）'],
    };

    /// 用真实段落（RenderParagraph）每个字符框的 top 归行（不含 \n / U+2060）。
    List<String> renderedLines(RenderParagraph p) {
      final text = p.text.toPlainText();
      final byTop = <int, StringBuffer>{};
      for (var i = 0; i < text.length; i++) {
        final ch = text[i];
        if (ch == '\n' || ch == '\u2060') continue;
        final boxes = p.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
        );
        expect(boxes, isNotEmpty, reason: 'char $i ($ch) not laid out');
        byTop.putIfAbsent(boxes.first.top.round(), StringBuffer.new).write(ch);
      }
      final keys = byTop.keys.toList()..sort();
      return [for (final k in keys) byTop[k].toString()];
    }

    for (final font in <String?>[null, 'NotoCJK']) {
      for (final cfg in configs) {
        for (final name in names) {
          final label = '${cfg.$1} · $name';
          testWidgets(
            '${font ?? 'test font'} · $label',
            skip: font != null && !hasNoto,
            (tester) async {
              if (font != null && !notoLoaded) {
                await tester.runAsync(() async {
                  final bytes = File(notoPath).readAsBytesSync();
                  await (FontLoader(
                    font,
                  )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
                });
                notoLoaded = true;
              }
              tester.view.physicalSize = const Size(1080, 2400);
              tester.view.devicePixelRatio = cfg.$2;
              addTearDown(tester.view.reset);
              final course = Course(
                id: 'x',
                name: name,
                slots: [
                  CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20),
                ],
              );
              _c.debugSetSnapshot(
                TimetableSnapshot(
                  periods: TimetableController.defaultPeriods(),
                  settings: TimetableSettings(
                    termStartDate: DateTime(2026, 9, 7),
                    showSaturday: cfg.$3,
                    showSunday: cfg.$3,
                  ),
                ),
                viewingWeek: 1,
                manualCourses: [course],
              );
              await tester.pumpWidget(
                MaterialApp(
                  theme: ThemeData(fontFamily: font),
                  home: Scaffold(body: WeekGrid(week: 1, controller: _c)),
                ),
              );
              await tester.pump();
              final p = tester
                  .renderObjectList<RenderParagraph>(
                    find.descendant(
                      of: find.byType(CourseNameText),
                      matching: find.byType(RichText),
                    ),
                  )
                  .single;
              final textW = p.constraints.maxWidth;
              // 与 Text 实际排版一致的有效样式（含 DefaultTextStyle 的字距等）。
              final style = p.text.style!;
              double widthOf(String s) {
                final tp = TextPainter(
                  text: TextSpan(text: s, style: style),
                  textDirection: TextDirection.ltr,
                )..layout();
                final w = tp.width;
                tp.dispose();
                return w;
              }

              final expected = normalizeCourseName(name);
              final raw = p.text.toPlainText();
              // (a) 只允许插入换行：去掉 \n / U+2060 后与原名逐字相等。
              expect(
                raw.replaceAll('\n', '').replaceAll('\u2060', ''),
                expected,
              );
              final lines = renderedLines(p);
              expect(lines.join(), expected, reason: '$lines @ $textW');
              // (b) 没有任何一行以上一行的末字开头（不重复）。
              for (var i = 1; i < lines.length; i++) {
                expect(
                  lines[i].characters.first,
                  isNot(lines[i - 1].characters.last),
                  reason: '$lines',
                );
              }
              expect(lines.length, lessThanOrEqualTo(3), reason: '$lines');
              // (c) 罗马数字+括注单元放得下 → Ⅱ 与「（」同行且单元独占末行；
              //     放不下 → 括注独占末行。不断言与字体有关的具体拆法。
              final roman = RegExp(r'([\u2160-\u217F]+（[^（）]*）)$')
                  .firstMatch(expected);
              if (roman != null) {
                final unit = roman.group(1)!;
                if (widthOf(unit) <= textW + 0.01) {
                  expect(lines.last, unit, reason: '$lines');
                } else {
                  expect(
                    lines.last,
                    unit.substring(unit.indexOf('（')),
                    reason: '$lines',
                  );
                }
                final head = expected.substring(
                  0,
                  expected.length - unit.length,
                );
                if (widthOf(head) <= textW + 0.01 &&
                    widthOf(unit) <= textW + 0.01) {
                  expect(lines, [head, unit]);
                }
              }
              if (expected.endsWith('）')) {
                expect(
                  lines.where((l) => l.contains('（')).single,
                  contains('）'),
                );
              }
              if (cfg.$1 == 'emulator 7col 43dp') {
                expect(textW, closeTo(43, 0.6));
              }
              if (font != null && notoExpected.containsKey(label)) {
                expect(lines, notoExpected[label]);
              }
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    test('纯函数：足够宽时 大学物理 / Ⅱ（2）；单元放不下才在「（」前断', () {
      final style = TimetableTheme.cellStyle();
      final cs = TimetableTheme.cellSize;
      expect(
        layoutCellCourseName('大学物理Ⅱ（2）', style: style, maxWidth: cs * 5),
        '大学物理\nⅡ（2）',
      );
      expect(
        layoutCellCourseName('大学物理Ⅱ（2）', style: style, maxWidth: cs * 3.5),
        // 单元（4em）放不下：在「（」前断，或行断器本就不在「（」后断时保持原样。
        isIn(['大学物理Ⅱ\n（2）', '大学物理Ⅱ（2）']),
      );
      expect(
        layoutCellCourseName('学术英语（1）', style: style, maxWidth: cs * 3.5),
        isIn(['学术英语\n（1）', '学术英语（1）']), // 渲染 学术英 / 语 / （1）
      );
    });
  });

  group('B01 同时段叠放', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_stack');
      TimetableStore.debugDirectory = tmp;
      _c.debugReset();
    });

    tearDown(() {
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Course manual(String id, String name, String weeks) => Course(
      id: id,
      name: name,
      slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
    );

    void setUpCourses(
      List<Course> manualCourses, {
      int week = 1,
      bool showNonCurrent = false,
    }) {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 9, 7),
            showNonCurrentWeek: showNonCurrent,
          ),
        ),
        viewingWeek: week,
        manualCourses: manualCourses,
      );
    }

    Future<void> pumpGrid(WidgetTester tester, int week) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: _c,
              builder: (context, _) => WeekGrid(
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

    Future<void> settleIo(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('本周两门同时段：一格 +「2 门」+ 冲突点；点开列表；各自打开详情；删一门恢复', (tester) async {
      setUpCourses([
        manual('a', '数据结构', '1' * 20),
        manual('b', '操作系统', '1' * 20),
      ]);
      await pumpGrid(tester, 1);

      expect(find.byType(CourseCell), findsOneWidget);
      expect(find.text('2 门'), findsOneWidget);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsOneWidget);
      // 按课名排序的第一门（操 < 数）。
      expect(
        find.descendant(
          of: find.byType(CourseCell),
          matching: find.text('操作系统'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byType(CourseCell));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stack_item_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('stack_item_b')), findsOneWidget);

      // 打开「操作系统」详情。
      await tester.tap(find.byKey(const ValueKey('stack_item_b')));
      await tester.pumpAndSettle();
      expect(find.byType(CourseDetailSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CourseDetailSheet),
          matching: find.text('操作系统'),
        ),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.byType(CourseDetailSheet))).pop();
      await tester.pumpAndSettle();

      // 打开「数据结构」详情并删除。
      await tester.tap(find.byType(CourseCell));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stack_item_a')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(CourseDetailSheet),
          matching: find.text('数据结构'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete_scope_sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete_scope_whole_course')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('course_delete_confirm')));
      await settleIo(tester);

      expect(_c.manualCourses.map((c) => c.id), ['b']);
      expect(find.byType(CourseCell), findsOneWidget);
      expect(find.text('2 门'), findsNothing);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
    });

    for (final week in [6, 7]) {
      testWidgets('单双周同节次：第 $week 周只画本周那门，正常格', (tester) async {
        final odd = '10' * 10;
        final even = '01' * 10;
        setUpCourses([
          manual('o', '单周课', odd),
          manual('e', '双周课', even),
        ], week: week);
        await pumpGrid(tester, week);
        expect(find.byType(CourseCell), findsOneWidget);
        expect(find.text('2 门'), findsNothing);
        expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
        expect(find.text(week.isEven ? '双周课' : '单周课'), findsOneWidget);
      });
    }

    testWidgets('显示非本周课程：本周一门 + 非本周灰格 → 只画本周课，无「2 门」', (tester) async {
      setUpCourses(
        [manual('a', '数据结构', '1' * 20), manual('o', '单周课', '10' * 10)],
        week: 2,
        showNonCurrent: true,
      );
      await pumpGrid(tester, 2);
      expect(find.byType(CourseCell), findsOneWidget);
      expect(find.text('数据结构'), findsOneWidget);
      expect(find.text('单周课'), findsNothing);
      expect(find.text('2 门'), findsNothing);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
    });

    testWidgets('显示非本周课程：只有非本周灰格时仍画灰格', (tester) async {
      setUpCourses(
        [manual('o', '单周课', '10' * 10)],
        week: 2,
        showNonCurrent: true,
      );
      await pumpGrid(tester, 2);
      expect(find.byType(CourseCell), findsOneWidget);
      // §13.8：课名不带前缀，底部「非本周」胶囊。
      expect(find.text('单周课'), findsOneWidget);
      expect(find.text('非本周'), findsOneWidget);
      expect(find.textContaining('[非本周]'), findsNothing);
      expect(find.text('2 门'), findsNothing);
    });
  });
}
