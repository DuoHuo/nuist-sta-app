// 实验标签（周课表格子）：SFSYK/isLab 时段显示「实验」胶囊；
// 体育课不打标；与「非本周」同行时「实验」在前；1 节高省略格内标签并在详情标「实验课」。
// 全部为构造数据（课名「大学物理实验B」、地点「测试楼A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

/// 用教务行构造课程；[sfsyk] 对应 `SFSYK`，[building] 对应 `JXLDM_DISPLAY`。
Course _course({
  Object? sfsyk = '1',
  int start = 1,
  int end = 2,
  String name = '大学物理实验B',
  String building = '',
}) {
  final rows = <dynamic>[
    {
      'KCM': name,
      'KCH': '08010001',
      'KXH': '01',
      'SKZC': '1' * 16,
      'SKXQ': 1,
      'KSJC': start,
      'JSJC': end,
      'JASMC': '测试楼A101',
      'SKJS': '张老师',
      'SFSYK': sfsyk,
      if (building.isNotEmpty) 'JXLDM_DISPLAY': building,
    },
  ];
  return TimetableParser.parseKbRows(rows, maxWeeks: 16).courses.single;
}

GridCell _cell(Course course, {bool active = true}) => GridCell(
  course: course,
  slot: course.slots.first,
  conflictCount: 0,
  activeThisWeek: active,
);

Future<void> _pumpCell(
  WidgetTester tester,
  GridCell cell, {
  double width = 300,
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

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_lab_tag');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
      ),
      viewingWeek: 1,
    );
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('LAB01 SFSYK 实验时段：格内显示「实验」胶囊（10sp / 16dp / 同色 60% 描边、水平居中）', (
    tester,
  ) async {
    await _pumpCell(tester, _cell(_course()));
    final pill = find.byKey(const Key('course_cell_lab_pill'));
    expect(pill, findsOneWidget);
    expect(find.text('实验'), findsOneWidget);

    final container = tester.widget<Container>(pill);
    final decoration = container.decoration! as BoxDecoration;
    final border = decoration.border! as Border;
    final radius = decoration.borderRadius! as BorderRadius;
    final text = tester.widget<Text>(find.text('实验'));

    // 字号 10sp；高度 16dp；水平内边距 4dp；圆角 = 高度一半。
    expect(text.style!.fontSize, 10);
    expect(tester.getSize(pill).height, 16);
    expect((container.padding! as EdgeInsets).left, 4);
    expect((container.padding! as EdgeInsets).right, 4);
    expect(radius.topLeft.x, 8);
    expect(radius.bottomRight.x, 8);

    // 颜色跟格子文字色走（课名同色），描边同色 60% 透明、无填充。
    final nameColor = tester
        .widget<Text>(
          find.descendant(
            of: find.byType(CourseNameText),
            matching: find.byType(Text),
          ),
        )
        .style!
        .color!;
    expect(text.style!.color, nameColor);
    expect(border.top.width, 1);
    expect(border.top.color.a, closeTo(0.6, 0.01));
    expect(decoration.color, isNull);

    // 位置：格子底部、左对齐（离左边与内容内边距 4dp 对齐）。
    final cellRect = tester.getRect(find.byType(CourseCell));
    final pillRect = tester.getRect(pill);
    expect(cellRect.bottom - pillRect.bottom, closeTo(3, 0.01));
    expect(pillRect.center.dx, closeTo(cellRect.center.dx, 0.01));
  });

  testWidgets('LAB02 非实验时段不显示「实验」胶囊', (tester) async {
    await _pumpCell(tester, _cell(_course(sfsyk: '0')));
    expect(find.byKey(const Key('course_cell_lab_pill')), findsNothing);
    expect(find.text('实验'), findsNothing);
  });

  testWidgets('LAB03 体育课即使时段带 isLab 也不显示「实验」胶囊', (tester) async {
    final pe = _course(name: '大学体育（1）', building: '体育板块场地');
    expect(pe.isPe, isTrue);
    expect(pe.slots.first.isLab, isTrue);
    await _pumpCell(tester, _cell(pe));
    expect(find.byKey(const Key('course_cell_lab_pill')), findsNothing);
    expect(find.text('实验'), findsNothing);
  });

  testWidgets('LAB04 与「非本周」同行：「实验」在前、间距 4dp；行宽不够只保留「实验」', (tester) async {
    await _pumpCell(tester, _cell(_course(), active: false));
    final lab = find.byKey(const Key('course_cell_lab_pill'));
    final offWeek = find.byKey(const Key('course_cell_off_week_pill'));
    expect(lab, findsOneWidget);
    expect(offWeek, findsOneWidget);
    final labRect = tester.getRect(lab);
    final offRect = tester.getRect(offWeek);
    expect(labRect.center.dy, closeTo(offRect.center.dy, 0.01));
    expect(labRect.left, lessThan(offRect.left));
    expect(offRect.left - labRect.right, closeTo(4, 0.01));
    final groupCell = tester.getRect(find.byType(CourseCell));
    expect(
      (labRect.left + offRect.right) / 2,
      closeTo(groupCell.center.dx, 0.01),
    );
    expect(find.text('实验'), findsOneWidget);
    expect(find.text('非本周'), findsOneWidget);

    // 窄格（真实周视图约 50dp）：放不下两个胶囊时只保留「实验」。
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpCell(tester, _cell(_course(), active: false), width: 50);
    expect(find.byKey(const Key('course_cell_lab_pill')), findsOneWidget);
    expect(find.byKey(const Key('course_cell_off_week_pill')), findsNothing);
  });

  testWidgets('LAB05 1 节高：格内省略「实验」，课程详情显示「实验课」', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    final lab = _course(start: 3, end: 3);
    final cell = _cell(lab);
    await _pumpCell(tester, cell, height: 61);
    expect(find.byKey(const Key('course_cell_lab_pill')), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseDetailSheet(cell: cell, controller: _c),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('course_detail_lab_label')), findsOneWidget);
    expect(find.text('实验课'), findsOneWidget);

    // 普通时段、体育课的详情不显示「实验课」。
    for (final other in [
      _course(sfsyk: '0', start: 3, end: 3),
      _course(name: '大学体育（1）', building: '体育板块场地', start: 3, end: 3),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CourseDetailSheet(cell: _cell(other), controller: _c),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('course_detail_lab_label')), findsNothing);
      expect(find.text('实验课'), findsNothing);
    }
  });
}
