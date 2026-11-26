import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

const _w16 = '1111111111111111';
const _week = 7;

Course _manual(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = _w16,
}) => Course(
  id: id,
  name: name,
  slots: [CourseSlot(day: day, startNode: start, endNode: end, weeks: weeks)],
);

Course _jwxt(String id, String name, {int day = 1, int start = 1}) => Course(
  id: id,
  name: name,
  code: id,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: start + 1,
      weeks: _w16,
      weeksLabel: '1-16周',
    ),
  ],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final origClock = TimetableController.clock;
  final settings = TimetableSettings(
    termCode: '2026-2027-1',
    termStartDate: DateTime(2026, 8, 31),
    termStartFromJwxt: true,
  );

  void load({
    List<Course> jwxt = const [],
    List<Course> manual = const [],
    bool showNonCurrentWeek = false,
  }) {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: jwxt,
        settings: settings.copyWith(showNonCurrentWeek: showNonCurrentWeek),
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: _week,
      manualCourses: manual,
    );
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tt_drag_ui');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 12);
    c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = origClock;
    c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  var taps = <String>[];

  Future<void> pumpGrid(WidgetTester tester) async {
    taps = [];
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) => WeekGrid(
              week: _week,
              controller: c,
              onCourseTap: (cell) => taps.add(cell.course.name),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Size cellStep(WidgetTester tester) {
    final w = tester.getSize(find.byType(WeekGrid)).width;
    return Size((w - 34) / 7, 64);
  }

  Finder cellOf(String name) => find.ancestor(
    of: find.textContaining(name.substring(0, 2)),
    matching: find.byType(CourseCell),
  );

  Future<void> longDrag(
    WidgetTester tester,
    Finder target, {
    Duration hold = const Duration(milliseconds: 850),
    List<Offset> moves = const [],
  }) async {
    final g = await tester.startGesture(tester.getCenter(target.first));
    await tester.pump(hold);
    for (final m in moves) {
      await g.moveBy(m);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('长按拖动改本周拆出独立时段，改所有周遇冲突弹浮动提示', (tester) async {
    load(manual: [_manual('m1', '甲课程'), _manual('m2', '丙课程', day: 2)]);
    await pumpGrid(tester);
    final step = cellStep(tester);

    await longDrag(
      tester,
      cellOf('甲课程'),
      moves: [Offset(step.width * 2, step.height * 2)],
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag_scope_sheet')), findsOneWidget);
    await tester.tap(find.textContaining('只改'));
    await tester.pump();
    await settleIo(tester);
    final splitSlots = c.manualCourseById('m1')!.slots;
    expect(splitSlots, hasLength(2));
    final moved = splitSlots.firstWhere((s) => s.day == 3);
    expect((moved.startNode, moved.endNode), (3, 4));
    expect(weeksOf(moved), [_week]);
    expect(find.text('撤销'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    load(manual: [_manual('m1', '甲课程'), _manual('m2', '丙课程', day: 2)]);
    await pumpGrid(tester);
    await longDrag(tester, cellOf('甲课程'), moves: [Offset(step.width, 0)]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有周'));
    await tester.pump();
    await settleIo(tester);
    expect(find.text('与丙课程时间冲突'), findsOneWidget);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).action, isNull);
    expect(find.byKey(const Key('course_cell_stack_badge')), findsOneWidget);
  });

  testWidgets('短按打开详情、拖动取消或回原位不变，非本周灰格不可拖起', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    final step = cellStep(tester);

    await longDrag(
      tester,
      cellOf('甲课程'),
      hold: const Duration(milliseconds: 500),
    );
    expect(taps, ['甲课程']);
    expect(find.byKey(const Key('drag_scope_sheet')), findsNothing);

    await longDrag(
      tester,
      cellOf('甲课程'),
      moves: [
        Offset(step.width, step.height),
        Offset(-step.width, -step.height),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag_scope_sheet')), findsNothing);

    await longDrag(tester, cellOf('甲课程'), moves: [Offset(step.width, 0)]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    expect(c.manualCourses.single.slots.single.day, 1);
    expect(c.slotOverrides, isEmpty);

    load(
      manual: [_manual('m1', '丙课程', weeks: '01' * 8)],
      showNonCurrentWeek: true,
    );
    await pumpGrid(tester);
    expect(find.text('非本周'), findsOneWidget);
    final g = await tester.startGesture(tester.getCenter(cellOf('丙课程').first));
    await tester.pump(const Duration(milliseconds: 900));
    await g.moveBy(Offset(step.width * 1.2, step.height * 2.2));
    await tester.pump();
    expect(find.byKey(const Key('week_grid_dragging_cell')), findsNothing);
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('drag_scope_sheet')), findsNothing);
  });

  testWidgets('详情页恢复已调教务课原位置、手动课无恢复入口，拖出边界限制在网格内', (tester) async {
    load(manual: [_manual('m1', '甲课程')]);
    await pumpGrid(tester);
    final g = await tester.startGesture(tester.getCenter(cellOf('甲课程').first));
    await tester.pump(const Duration(milliseconds: 850));
    await g.moveBy(const Offset(2000, 3000));
    await tester.pump();
    final grid = tester.getRect(find.byType(WeekGrid));
    final dragging = tester.getRect(
      find.byKey(const Key('week_grid_dragging_cell')),
    );
    expect(dragging.right <= grid.right + 0.5, isTrue);
    expect(dragging.bottom <= grid.bottom + 0.5, isTrue);
    await g.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag_scope_sheet')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    Future<void> pumpDetail(GridCell cell) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      showCourseDetailSheet(context, cell: cell, controller: c),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    load(jwxt: [_jwxt('K1|01', '乙课程')]);
    await tester.runAsync(
      () => c.moveSlot(
        c.courses.single,
        0,
        toDay: 3,
        toStartPeriod: 5,
        week: _week,
        scope: MoveScope.thisWeek,
      ),
    );
    await pumpDetail(c.cellsForDay(_week, 3).single);
    await tester.tap(find.byKey(const Key('course_detail_override')));
    await tester.pumpAndSettle();
    expect(find.text('已调课：原 周一 第 1–2 节'), findsOneWidget);
    await tester.tap(find.byKey(const Key('course_detail_restore')));
    await tester.pump();
    await settleIo(tester);
    await tester.pumpAndSettle();
    expect(c.slotOverrides, isEmpty);
    expect(c.cellsForDay(_week, 1), hasLength(1));

    load(manual: [_manual('m1', '甲课程')]);
    await tester.runAsync(
      () => c.moveSlot(
        c.manualCourses.single,
        0,
        toDay: 3,
        toStartPeriod: 5,
        week: _week,
        scope: MoveScope.thisWeek,
      ),
    );
    await pumpDetail(c.cellsForDay(_week, 3).single);
    expect(find.textContaining('已调课'), findsNothing);
    expect(find.text('恢复原位置'), findsNothing);
  });
}
