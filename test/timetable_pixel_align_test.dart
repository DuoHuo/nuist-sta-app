// 周课表格子物理像素对齐 + 字号取整（防半像素发虚）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 8, 31);

Course _course(String id, String name, {String location = '明德楼B201'}) => Course(
  id: id,
  name: name,
  source: CourseSource.manual,
  slots: [
    CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '1' * 20,
      location: location,
      teacher: '张老师',
    ),
  ],
);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_pixel_align');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('snapDevicePx / snapFontSp 基础', () {
    expect(TimetableTheme.snapDevicePx(10.5, 2), 10.5);
    expect(TimetableTheme.snapDevicePx(10.2, 2), 10);
    expect(TimetableTheme.snapDevicePx(1.5, 2.75), 1.4545454545454546);
    final r = TimetableTheme.snapDeviceRect(
      left: 1.5,
      top: 1.5,
      width: 40.3,
      height: 58.7,
      dpr: 2.75,
    );
    expect(r.left * 2.75, closeTo((r.left * 2.75).roundToDouble(), 1e-9));
    expect(r.top * 2.75, closeTo((r.top * 2.75).roundToDouble(), 1e-9));
    expect(
      (r.left + r.width) * 2.75,
      closeTo(((r.left + r.width) * 2.75).roundToDouble(), 1e-9),
    );
    expect(
      (r.top + r.height) * 2.75,
      closeTo(((r.top + r.height) * 2.75).roundToDouble(), 1e-9),
    );
    expect(TimetableTheme.snapFontSp(10.8), 11);
    expect(TimetableTheme.snapFontSp(10.2), 10);
    expect(TimetableTheme.snapFontSp(10), 10);
  });

  test('CellFontScale.small 字号取整（12×0.9=10.8 → 11）', () {
    final v = CourseCell.cellFontSize(
      TimetableTheme.cellSize,
      CellFontScale.small.factor,
      TextScaler.noScaling,
    );
    expect(v, 11);
    expect(v, v.roundToDouble());
  });

  for (final dpr in [2.75, 3.0]) {
    for (final name in ['电子技术基础', '数据结构']) {
      testWidgets('DPR $dpr · $name：格子物理像素整数、字号整数', (tester) async {
        tester.view.physicalSize = Size(1080, 2400);
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.reset);

        _c.debugSetSnapshot(
          TimetableSnapshot(
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(
              termStartDate: _termStart,
              showSaturday: true,
              showSunday: true,
              fontScale: CellFontScale.small, // 触发 10.8 → 取整
            ),
          ),
          viewingWeek: 1,
          manualCourses: [_course('c1', name)],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: WeekGrid(week: 1, controller: _c)),
          ),
        );
        await tester.pumpAndSettle();

        final cell = find.byType(CourseCell);
        expect(cell, findsWidgets);
        final courseCell = tester.widget<CourseCell>(cell.first);
        // 逻辑尺寸 × dpr 应为整数（对齐后）。
        expect(
          courseCell.width * dpr,
          closeTo((courseCell.width * dpr).roundToDouble(), 1e-6),
          reason: 'width phys',
        );
        expect(
          courseCell.height * dpr,
          closeTo((courseCell.height * dpr).roundToDouble(), 1e-6),
          reason: 'height phys',
        );

        final positioned = find.ancestor(
          of: cell.first,
          matching: find.byType(Positioned),
        );
        expect(positioned, findsWidgets);
        final pos = tester.widget<Positioned>(positioned.first);
        for (final (label, v) in [
          ('left', pos.left),
          ('top', pos.top),
          ('width', pos.width),
          ('height', pos.height),
        ]) {
          expect(v, isNotNull, reason: label);
          final phys = v! * dpr;
          expect(
            phys,
            closeTo(phys.roundToDouble(), 1e-6),
            reason: '$label phys=$phys',
          );
        }

        // 课名 TextStyle.fontSize 为整数。
        final nameText = find.descendant(
          of: cell.first,
          matching: find.byType(CourseNameText),
        );
        expect(nameText, findsOneWidget);
        final style = tester.widget<CourseNameText>(nameText).style;
        expect(style.fontSize, isNotNull);
        expect(style.fontSize, style.fontSize!.roundToDouble());
        expect(style.height, 1.1);
      });
    }
  }

  testWidgets('青/橙底课程格：文字只画一层、全不透明、无阴影', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: _termStart),
      ),
      viewingWeek: 1,
    );

    final course = _course('c1', '电子技术基础');
    Widget cell(Color raw) => CourseCell(
      controller: _c,
      cell: GridCell(
        course: course,
        slot: course.slots.single,
        conflictCount: 0,
        activeThisWeek: true,
      ),
      width: 160,
      height: 110,
      radius: TimetableTheme.cellRadius,
      // 直接走真实配色管线：青 #00BCD4 / 橙 #FF9800。
      pairOverride: TimetableTheme.userCoursePair(raw),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(const Color(0xFF00BCD4)),
              cell(const Color(0xFFFF9800)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 两格各只画一次课名，没有第二层 Text / 阴影叠字。
    expect(find.text('电子技术基础'), findsNWidgets(2));
    final texts = tester.widgetList<Text>(
      find.descendant(of: find.byType(CourseCell), matching: find.byType(Text)),
    );
    expect(texts, isNotEmpty);
    for (final t in texts) {
      expect(t.style?.color?.a, 1.0, reason: '文字必须不透明：${t.data}');
      expect(t.style?.shadows, isNull, reason: '文字不得带阴影：${t.data}');
    }

    // 主线自选色保持原色；底色不透明。
    final inks = tester.widgetList<Ink>(
      find.descendant(of: find.byType(CourseCell), matching: find.byType(Ink)),
    );
    expect(inks, hasLength(2));
    final bgs = [
      for (final ink in inks) (ink.decoration! as BoxDecoration).color!,
    ];
    expect(bgs, [const Color(0xFF00BCD4), const Color(0xFFFF9800)]);
    for (final bg in bgs) {
      expect(bg.a, 1.0);
    }

    // 没有整格 Opacity（半透明栅格化会让文字发虚）。
    expect(
      find.ancestor(
        of: find.byType(CourseCell).first,
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });

  test('LC05 兼容：缩到 <12 且 ≥10，极端到 10 用省略不再继续缩', () {
    const width = 48.0;
    final nameStyle = TimetableTheme.cellStyle();
    final subStyle = TimetableTheme.cellSubStyle();
    final loc = cellLocationText('测试楼A101多媒体教室东侧很长很长');
    double h(String text, TextStyle st) {
      final p = TextPainter(
        text: TextSpan(text: text, style: st),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final v = p.height;
      p.dispose();
      return v;
    }

    final nameLine = h('课', nameStyle);
    final locH = h(loc, subStyle);
    final p = planCellContent(
      name: '测试课甲乙丙丁',
      location: loc,
      hasClass: true,
      hasTeacher: true,
      nameStyle: nameStyle,
      subStyle: subStyle,
      nameSize: 12,
      subSize: 11,
      maxWidth: width,
      maxHeight: nameLine + locH - 2,
    );
    expect(p.nameSize, lessThan(12));
    expect(p.nameSize, greaterThanOrEqualTo(10));
    expect(p.nameSize, p.nameSize.roundToDouble());

    final x = planCellContent(
      name: '测试课甲乙丙丁',
      location: loc,
      hasClass: true,
      hasTeacher: true,
      nameStyle: nameStyle,
      subStyle: subStyle,
      nameSize: 12,
      subSize: 11,
      maxWidth: width,
      maxHeight: 4,
    );
    expect(x.nameSize, 10);
    expect(x.nameLines, 1);
    expect(x.fits, isFalse);
  });
}
