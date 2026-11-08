// 10/18 UI 修正：拖动落点纯函数、设置页分段/滑块、格内地点逐字换行。
// 全部为构造数据，不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
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

    testWidgets('分段选项：32dp 可见底板、48dp 点击区域，选中状态可读屏', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
      await tester.pumpAndSettle();
      final group = find.byKey(const Key('tt_settings_cell_text_color'));
      final track = find.descendant(
        of: group,
        matching: find.byKey(const Key('tt_settings_segment_track')),
      );
      expect(tester.getSize(track).height, 32);
      for (final label in ['自动', '白', '黑']) {
        final option = find.descendant(
          of: group,
          matching: find.byKey(ValueKey('seg_$label')),
        );
        expect(tester.getSize(option).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
        final semantic = tester.widget<Semantics>(
          find.ancestor(of: option, matching: find.byType(Semantics)).first,
        );
        expect(semantic.properties.selected, label == '自动');
        final text = tester.widget<Text>(
          find.descendant(of: option, matching: find.text(label)),
        );
        expect(
          text.style!.color,
          label == '自动'
              ? TimetableTheme.settingsAccentText(tester.element(group))
              : TimetableTheme.labelText,
        );
      }
    });

    testWidgets('格子高度滑块可见；不透明度在外观页且宽度合理', (tester) async {
      // 格子高度与不透明度都在外观页。
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorSchemeSeed: Colors.pink),
          home: TimetableAppearancePage(controller: _c),
        ),
      );
      await tester.pump();
      final height = find.byKey(
        const Key('tt_settings_period_height'),
        skipOffstage: false,
      );
      await tester.scrollUntilVisible(
        height,
        300,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(find.byKey(const Key('tt_settings_period_height')))
            .width,
        greaterThan(100),
      );

      final opacity = find.byKey(
        const Key('tt_settings_opacity'),
        skipOffstage: false,
      );
      await tester.scrollUntilVisible(
        opacity,
        -300,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('tt_settings_opacity'))).width,
        greaterThan(100),
      );
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
      bool showLocation = true,
      String name = '高数',
      String location = '学而楼C303多媒体教室东侧',
      String teacher = '教师A',
      Brightness? brightness,
      double textScale = 1,
      double screenWidth = 1080 / 2.625,
      double dpr = 2.625,
      CellFontScale fontScale = CellFontScale.large,
      List<Course> extraCourses = const [],
    }) async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 9, 7),
            periodHeight: periodHeight,
            fontScale: fontScale,
            showTeacher: showTeacher,
            showLocation: showLocation,
          ),
        ),
        viewingWeek: 1,
        manualCourses: [
          Course(
            id: 'm',
            name: name,
            classId: '08',
            slots: [
              CourseSlot(
                day: 1,
                startNode: 1,
                endNode: end,
                weeks: '1' * 16,
                location: location,
                teacher: teacher,
              ),
            ],
          ),
          ...extraCourses,
        ],
      );
      tester.view.physicalSize = Size(screenWidth * dpr, 2400);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == null
              ? null
              : brightness == Brightness.dark
              ? appDarkTheme()
              : appLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
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

    testWidgets('LC03 单节长内容自动拉高：地点与教师保留完整且不裁剪', (tester) async {
      await pumpGrid(tester, periodHeight: 64, end: 1, showTeacher: true);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('course_cell_location')), findsOneWidget);
      final teacher = tester.widget<Text>(
        find.byKey(const Key('course_cell_teacher')),
      );
      expect(teacher.data, '教师A');
      expect(teacher.maxLines, isNull);
      expect(teacher.overflow, isNot(TextOverflow.ellipsis));
      final cellRect = tester.getRect(find.byType(CourseCell));
      expect(cellRect.height, greaterThan(64 - TimetableTheme.cellMargin * 2));
      expect(
        tester.getRect(find.byKey(const Key('course_cell_teacher'))).bottom,
        lessThanOrEqualTo(cellRect.bottom),
      );
      expect(_c.settings.periodHeight, 64);
      expect(locationLines(tester), greaterThanOrEqualTo(2));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('course_cell_location')))
            .maxLines,
        isNull,
      );
    });

    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('375dp · $brightness · 字号 ×$scale：长内容完整拉高，节次统一对齐', (
          tester,
        ) async {
          for (final (showLocation, showTeacher, locationValue) in [
            (true, true, '楼A1'),
            (false, true, '楼A1'),
            (true, true, ''),
            (true, false, '楼A1'),
          ]) {
            final hasLocation = showLocation && locationValue.isNotEmpty;
            await pumpGrid(
              tester,
              periodHeight: 52,
              end: 1,
              name: '测试课程名称很长(1)',
              location: locationValue,
              teacher: '教师甲、教师乙、教师丙',
              showLocation: showLocation,
              showTeacher: showTeacher,
              brightness: brightness,
              textScale: scale,
              screenWidth: 375,
              extraCourses: [
                for (final (id, day, start, end, name) in [
                  ('two', 1, 2, 3, '短课'),
                  ('one', 2, 3, 3, '单节课'),
                ])
                  Course(
                    id: id,
                    name: name,
                    slots: [
                      CourseSlot(
                        day: day,
                        startNode: start,
                        endNode: end,
                        weeks: '1' * 16,
                      ),
                    ],
                  ),
              ],
            );
            expect(tester.takeException(), isNull);
            expect(find.text('[08]'), findsNothing);
            expect(find.byKey(const Key('course_cell_class')), findsNothing);
            Finder cell(String id) => find.byWidgetPredicate(
              (widget) => widget is CourseCell && widget.cell.course.id == id,
            );
            final mainCell = cell('m');
            final mainRect = tester.getRect(mainCell);
            final twoRect = tester.getRect(cell('two'));
            final oneRect = tester.getRect(cell('one'));
            final periodH = twoRect.top - mainRect.top;
            expect(periodH, greaterThan(52));
            expect(_c.settings.periodHeight, 52);
            expect(oneRect.top - mainRect.top, closeTo(periodH * 2, 1));
            expect(
              twoRect.height,
              closeTo(periodH * 2 - TimetableTheme.cellMargin * 2, 1),
            );
            expect(oneRect.height, closeTo(mainRect.height, 0.5));
            final labels = [
              for (final node in ['1', '2'])
                find.byWidgetPredicate(
                  (widget) =>
                      widget is Text &&
                      widget.data == node &&
                      widget.style?.fontSize == 12 &&
                      widget.style?.fontWeight == FontWeight.w600,
                ),
            ];
            expect(
              tester.getCenter(labels[1]).dy - tester.getCenter(labels[0]).dy,
              closeTo(periodH, 0.5),
            );
            final nameWidget = find.descendant(
              of: mainCell,
              matching: find.byType(CourseNameText),
            );
            final name = find.descendant(
              of: nameWidget,
              matching: find.byType(Text),
            );
            final nameStyle = tester.widget<CourseNameText>(nameWidget).style;
            expect(nameStyle.fontWeight, FontWeight.w500);
            expect(
              nameStyle.fontVariations?.any(
                (variation) =>
                    variation.axis == 'wght' && variation.value == 450,
              ),
              isTrue,
            );
            expect(
              tester
                  .widget<Text>(name)
                  .data!
                  .replaceAll('\n', '')
                  .replaceAll('\u2060', ''),
              '测试课程名称很长（1）',
            );
            final nameParagraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: name, matching: find.byType(RichText)),
            );
            expect(nameParagraph.didExceedMaxLines, isFalse);
            final anchor = TextPainter(
              text: TextSpan(text: '课课课', style: nameParagraph.text.style),
              textDirection: nameParagraph.textDirection,
              textScaler: nameParagraph.textScaler,
            )..layout();
            expect(
              anchor.width,
              lessThanOrEqualTo(nameParagraph.constraints.maxWidth + 0.01),
            );
            anchor.dispose();
            final location = find.byKey(const Key('course_cell_location'));
            final teacher = find.byKey(const Key('course_cell_teacher'));
            expect(location, hasLocation ? findsOneWidget : findsNothing);
            expect(teacher, showTeacher ? findsOneWidget : findsNothing);
            if (hasLocation) {
              final locationStyle = tester.widget<Text>(location).style!;
              expect(locationStyle.fontWeight, FontWeight.w500);
              expect(
                locationStyle.fontVariations?.any(
                  (variation) =>
                      variation.axis == 'wght' && variation.value == 450,
                ),
                isTrue,
              );
              expect(
                tester.getRect(location).bottom,
                lessThanOrEqualTo(mainRect.bottom),
              );
            }
            final content = find.descendant(
              of: mainCell,
              matching: find.byType(OverflowBox),
            );
            expect(
              find.descendant(of: content, matching: find.byType(SizedBox)),
              showTeacher ? findsOneWidget : findsNothing,
            );
            if (showTeacher) {
              final teacherText = tester.widget<Text>(teacher);
              expect(teacherText.data, '教师甲\n教师乙\n教师丙');
              expect(teacherText.semanticsLabel, '教师甲、教师乙、教师丙');
              expect(teacherText.maxLines, isNull);
              expect(teacherText.overflow, isNot(TextOverflow.ellipsis));
              final paragraph = tester.renderObject<RenderParagraph>(
                find.descendant(of: teacher, matching: find.byType(RichText)),
              );
              expect(paragraph.didExceedMaxLines, isFalse);
              final tops = {
                for (final box in paragraph.getBoxesForSelection(
                  TextSelection(
                    baseOffset: 0,
                    extentOffset: teacherText.data!.length,
                  ),
                ))
                  box.top.round(),
              };
              expect(tops.length, 3);
              for (final name in RegExp(
                r'[^\n]+',
              ).allMatches(teacherText.data!)) {
                final boxes = paragraph.getBoxesForSelection(
                  TextSelection(baseOffset: name.start, extentOffset: name.end),
                );
                expect(
                  boxes.map((box) => box.top.round()).toSet(),
                  hasLength(1),
                );
              }
              final line = TextPainter(
                text: TextSpan(text: '课', style: paragraph.text.style),
                textDirection: paragraph.textDirection,
                textScaler: paragraph.textScaler,
              )..layout();
              final lineHeight = line.height;
              line.dispose();
              final teacherRect = tester.getRect(teacher);
              final previous = tester.getRect(hasLocation ? location : name);
              expect(
                teacherRect.top - previous.bottom,
                closeTo(lineHeight, 0.01),
              );
              expect(teacherRect.bottom, lessThanOrEqualTo(mainRect.bottom));
            }
          }
        });
      }
    }

    testWidgets('1200px / DPR3.25：修复周二少一像素，七列保持12sp与相同断行', (tester) async {
      const courseName = '测试课程名称很长（1）';
      const teachers = '教师甲、教师乙、教师丙';
      const dpr = 3.25;
      const screenWidth = 1200 / dpr;
      final dayWidth = (screenWidth - TimetableTheme.periodColumnWidth) / 7;
      final oldWidths = [
        for (var day = 0; day < 7; day++)
          ((day * dayWidth + dayWidth - TimetableTheme.cellMargin) * dpr)
                  .round() -
              ((day * dayWidth + TimetableTheme.cellMargin) * dpr).round(),
      ];
      expect(oldWidths.toSet(), {145, 146});
      expect(oldWidths[1], 145);
      expect(oldWidths[3], 146);
      expect(145 / dpr - 8, lessThan(36.75));
      expect(146 / dpr - 8, greaterThan(36.75));
      await pumpGrid(
        tester,
        periodHeight: 52,
        end: 1,
        name: courseName,
        location: '楼A1',
        teacher: teachers,
        showTeacher: true,
        screenWidth: screenWidth,
        dpr: dpr,
        fontScale: CellFontScale.standard,
        extraCourses: [
          for (var day = 2; day <= 7; day++)
            Course(
              id: 'same_$day',
              name: courseName,
              slots: [
                CourseSlot(
                  day: day,
                  startNode: 1,
                  endNode: 1,
                  weeks: '1' * 16,
                  location: '楼A1',
                  teacher: teachers,
                ),
              ],
            ),
        ],
      );
      expect(tester.takeException(), isNull);
      final cells = tester
          .widgetList<CourseCell>(find.byType(CourseCell))
          .toList();
      expect(cells, hasLength(7));
      final widths = cells.map((cell) => (cell.width * dpr).round()).toSet();
      expect(widths, {146});
      final nameSizes = <double?>{};
      final teacherSizes = <double?>{};
      final paragraphWidths = <double>{};
      final titleLines = <List<String>>[];
      for (final cell in cells) {
        final finder = find.byWidget(cell);
        final nameFinder = find.descendant(
          of: finder,
          matching: find.byType(CourseNameText),
        );
        final name = tester.widget<CourseNameText>(nameFinder);
        final titleFinder = find.descendant(
          of: nameFinder,
          matching: find.byType(RichText),
        );
        final title = tester.renderObject<RenderParagraph>(titleFinder);
        paragraphWidths.add(title.constraints.maxWidth);
        expect(title.constraints.maxWidth, closeTo(146 / dpr - 8, 0.01));
        final anchor = TextPainter(
          text: TextSpan(text: '课课课', style: title.text.style),
          textDirection: title.textDirection,
          textScaler: title.textScaler,
        )..layout();
        expect(anchor.width, closeTo(36.75, 0.01));
        anchor.dispose();
        expect(title.didExceedMaxLines, isFalse);
        final text = title.text.toPlainText();
        final rows = <int, StringBuffer>{};
        for (var i = 0; i < text.length; i++) {
          final character = text[i];
          if (character == '\n' || character == '\u2060') continue;
          final boxes = title.getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1),
          );
          expect(boxes, isNotEmpty);
          rows
              .putIfAbsent(boxes.first.top.round(), StringBuffer.new)
              .write(character);
        }
        final tops = rows.keys.toList()..sort();
        final lines = [for (final top in tops) rows[top].toString()];
        expect(lines.join(), courseName);
        if (titleLines.isNotEmpty) expect(lines, titleLines.first);
        titleLines.add(lines);
        final teacherFinder = find.descendant(
          of: finder,
          matching: find.byKey(const Key('course_cell_teacher')),
        );
        final teacher = tester.widget<Text>(teacherFinder);
        nameSizes.add(name.style.fontSize);
        teacherSizes.add(teacher.style!.fontSize);
        expect(teacher.data, '教师甲\n教师乙\n教师丙');
        expect(teacher.semanticsLabel, teachers);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: teacherFinder, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        for (final start in [0, 4, 8]) {
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 3),
          );
          expect(boxes.map((box) => box.top.round()).toSet(), hasLength(1));
        }
        expect(
          tester.getRect(teacherFinder).bottom,
          lessThanOrEqualTo(tester.getRect(finder).bottom),
        );
        final cellRect = tester.getRect(finder);
        final content = find.descendant(
          of: finder,
          matching: find.byType(OverflowBox),
        );
        for (final element
            in find
                .descendant(of: content, matching: find.byType(RichText))
                .evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.left, greaterThanOrEqualTo(cellRect.left - 0.01));
          expect(rect.right, lessThanOrEqualTo(cellRect.right + 0.01));
          expect(rect.top, greaterThanOrEqualTo(cellRect.top - 0.01));
          expect(rect.bottom, lessThanOrEqualTo(cellRect.bottom + 0.01));
        }
      }
      expect(nameSizes, {12.0});
      expect(teacherSizes, hasLength(1));
      expect(paragraphWidths, hasLength(1));
      expect(_c.settings.periodHeight, 52);
    });

    testWidgets('宽格短内容保持设置行高，不写回自动适应高度', (tester) async {
      await pumpGrid(
        tester,
        periodHeight: 52,
        end: 1,
        name: '短课',
        location: '',
        teacher: '',
        screenWidth: 840,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(CourseCell)).height,
        closeTo(52 - TimetableTheme.cellMargin * 2, 0.5),
      );
      expect(_c.settings.periodHeight, 52);
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
