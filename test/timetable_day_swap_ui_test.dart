// 第 5 条整天调课页 UI + 第 7 条删除范围 / 恢复这一天。全部为构造数据。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_day_swap_ui.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

const _w16 = '1111111111111111';
const _week = 7; // 2026-10-12 周一 = 第 7 周（开学 08-31）
final _mon = DateTime(2026, 10, 12);
final _wed = DateTime(2026, 10, 14);
final _thu = DateTime(2026, 10, 15);

Course _manual(String id, String name, {int day = 1}) => Course(
  id: id,
  name: name,
  slots: [CourseSlot(day: day, startNode: 1, endNode: 2, weeks: _w16)],
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

  void load() {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: const [],
        settings: settings,
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: _week,
      manualCourses: [_manual('m1', '读书会'), _manual('m2', '合唱', day: 3)],
    );
  }

  DateTime? picked;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_swap_ui');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 12);
    c.debugReset();
    picked = null;
    debugDaySwapDatePicker = (
      context, {
      required initial,
      required first,
      required last,
    }) async => picked;
  });

  tearDown(() {
    debugDaySwapDatePicker = null;
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

  Future<void> pumpHost(
    WidgetTester tester,
    Widget child, {
    ThemeMode mode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(),
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode: mode,
        home: child,
      ),
    );
    await tester.pump();
  }

  Future<void> pumpGrid(WidgetTester tester) => pumpHost(
    tester,
    Scaffold(
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) =>
            WeekGrid(week: _week, controller: c, onCourseTap: (_) {}),
      ),
    ),
  );

  Future<void> longPressHeader(WidgetTester tester, int day) async {
    await tester.longPress(find.byKey(ValueKey('day_header_$day')));
    await tester.pumpAndSettle();
  }

  testWidgets('SWU01 长按表头 → 整天调课页（原日期预填）→ 选目标 → 互换；两天都显示「调」', (tester) async {
    load();
    await pumpGrid(tester);
    expect(find.byKey(const Key('day_header_swap_badge')), findsNothing);
    await longPressHeader(tester, 1);
    expect(find.byKey(const Key('day_swaps_page')), findsOneWidget);
    expect(find.text('10月12日'), findsOneWidget); // 原日期预填
    picked = _wed;
    await tester.tap(find.byKey(const Key('day_swap_to')));
    await tester.pumpAndSettle();
    expect(find.text('10月14日'), findsOneWidget);
    await tester.tap(find.byKey(const Key('day_swap_submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day_swap_confirm_dialog')), findsOneWidget);
    expect(find.text('与10月14日互换'), findsOneWidget);
    await tester.tap(find.byKey(const Key('day_swap_confirm')));
    await settleIo(tester);
    await tester.pumpAndSettle();
    expect(c.daySwaps, hasLength(1));
    expect(c.isSwappedDate(_mon) && c.isSwappedDate(_wed), isTrue);
    // 回到网格看角标
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day_header_swap_badge')), findsNWidgets(2));
    expect(find.text('已与10月14日互换'), findsOneWidget);
  });

  testWidgets('SWU02 取消确认 / 取消选日期：不调课', (tester) async {
    load();
    await pumpGrid(tester);
    await longPressHeader(tester, 1);
    picked = null;
    await tester.tap(find.byKey(const Key('day_swap_to')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day_swap_confirm_dialog')), findsNothing);
    picked = _wed;
    await tester.tap(find.byKey(const Key('day_swap_to')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('day_swap_submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('day_swap_cancel')));
    await settleIo(tester);
    expect(c.daySwaps, isEmpty);
  });

  testWidgets('SWU03 已调课：页内记录可「恢复」', (tester) async {
    load();
    final s = (await tester.runAsync(() => c.addDaySwap(_mon, _wed)))!;
    await pumpGrid(tester);
    expect(find.byKey(const Key('day_header_swap_badge')), findsNWidgets(2));
    await longPressHeader(tester, 3);
    expect(find.byKey(const Key('day_swaps_page')), findsOneWidget);
    expect(find.text('10月12日与10月14日的课程互换'), findsOneWidget);
    await tester.tap(find.byKey(Key('day_swap_restore_${s.id}')));
    await settleIo(tester);
    await tester.pumpAndSettle();
    expect(c.daySwaps, isEmpty);
    expect(find.byKey(const Key('day_swaps_empty')), findsOneWidget);
  });

  testWidgets('SWU04 失败提示：同一天 / 学期外 / 对方已调过课', (tester) async {
    load();
    await tester.runAsync(() => c.addDaySwap(_wed, _thu));
    await pumpHost(
      tester,
      TimetableDaySwapsPage(controller: c, initialFrom: _mon),
    );

    Future<void> attempt(DateTime d, String msg) async {
      picked = d;
      await tester.tap(find.byKey(const Key('day_swap_to')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('day_swap_submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('day_swap_confirm_dialog')), findsNothing);
      expect(find.text(msg), findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(TimetableDaySwapsPage)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    await attempt(_mon, '不能和同一天互换');
    await attempt(DateTime(2027, 6, 1), '日期不在本学期内');
    await attempt(_wed, '10月14日已调过课，请先撤销');
    expect(c.daySwaps, hasLength(1));
  });

  test('SWU05 学期范围与文字', () {
    load();
    final r = semesterRangeOf(c);
    expect(r.first, DateTime(2026, 8, 31));
    expect(r.last.weekday, DateTime.sunday);
    expect(daySwapErrorFor(c, _mon, _wed), isNull);
    expect(daySwapErrorFor(c, DateTime(2026, 8, 30), _wed), '日期不在本学期内');
  });

  testWidgets('SWU06 设置 → 调课记录：空状态；有记录时一句话 +「恢复」', (tester) async {
    load();
    await pumpHost(tester, TimetableSettingsPage(controller: c));
    await tester.scrollUntilVisible(
      find.byKey(const Key('tt_settings_day_swaps')),
      200,
    );
    expect(find.byKey(const Key('tt_settings_day_swaps')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('tt_settings_day_swaps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_day_swaps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day_swaps_page')), findsOneWidget);
    expect(find.byKey(const Key('day_swaps_empty')), findsOneWidget);

    final s = (await tester.runAsync(() => c.addDaySwap(_wed, _mon)))!;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day_swaps_empty')), findsNothing);
    expect(find.text('10月12日与10月14日的课程互换'), findsOneWidget);
    await tester.tap(find.byKey(Key('day_swap_restore_${s.id}')));
    await settleIo(tester);
    await tester.pumpAndSettle();
    expect(c.daySwaps, isEmpty);
    expect(find.byKey(const Key('day_swaps_empty')), findsOneWidget);
  });

  testWidgets('SWU07 深色模式：调课记录页与表头角标正常渲染', (tester) async {
    load();
    await tester.runAsync(() => c.addDaySwap(_mon, _wed));
    await pumpHost(
      tester,
      TimetableDaySwapsPage(controller: c),
      mode: ThemeMode.dark,
    );
    expect(find.text('10月12日与10月14日的课程互换'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await pumpHost(
      tester,
      Scaffold(
        body: WeekGrid(week: _week, controller: c, onCourseTap: (_) {}),
      ),
      mode: ThemeMode.dark,
    );
    expect(find.byKey(const Key('day_header_swap_badge')), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  GridCell cellOn(DateTime d, String id) => c
      .cellsForDay(c.weekOfDate(d), d.weekday)
      .firstWhere((x) => x.activeThisWeek && x.course.id == id);

  testWidgets('SWU08 详情删除三档 → 只删这一天；「恢复这一天」→ 回来', (tester) async {
    load();
    await pumpHost(
      tester,
      Scaffold(
        body: CourseDetailSheet(cell: cellOn(_mon, 'm1'), controller: c),
      ),
    );
    expect(find.byKey(const Key('course_detail_restore_day')), findsNothing);
    expect(find.byKey(const Key('course_detail_delete_day')), findsNothing);
    await tester.tap(find.byKey(const Key('course_detail_delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete_scope_sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete_scope_one_day')));
    await settleIo(tester);
    expect(
      c
          .cellsForDay(_week, 1)
          .where((x) => x.activeThisWeek && x.course.id == 'm1'),
      isEmpty,
    );
    expect(cellOn(DateTime(2026, 10, 19), 'm1').dateEdit, isNull);
    expect(c.courseDateEdits, hasLength(1));

    await tester.runAsync(() async {
      await c.restoreDateEdit(c.courseDateEdits.single.id);
      await c.editOccurrence(cellOn(_mon, 'm1'), name: '读书会·改');
    });
    final edited = cellOn(_mon, 'm1');
    expect(edited.dateEdit, isNotNull);
    await pumpHost(
      tester,
      Scaffold(
        body: CourseDetailSheet(cell: edited, controller: c),
      ),
    );
    expect(find.byKey(const Key('course_detail_date_edit')), findsOneWidget);
    await tester.tap(find.byKey(const Key('course_detail_restore_day')));
    await settleIo(tester);
    expect(c.courseDateEdits, isEmpty);
    expect(cellOn(_mon, 'm1').dateEdit, isNull);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('SWU09 有单日修改的格子右上角 4dp 圆点（${mode.name}）', (tester) async {
      load();
      await pumpGrid(tester);
      expect(find.byKey(const Key('course_cell_date_edit_dot')), findsNothing);
      await tester.runAsync(
        () => c.editOccurrence(cellOn(_mon, 'm1'), location: '新地点'),
      );
      await pumpHost(
        tester,
        Scaffold(
          body: WeekGrid(week: _week, controller: c, onCourseTap: (_) {}),
        ),
        mode: mode,
      );
      final dot = find.byKey(const Key('course_cell_date_edit_dot'));
      expect(dot, findsOneWidget);
      expect(tester.getSize(dot), const Size(4, 4));
      final ctx = tester.element(dot);
      final deco = tester.widget<Container>(dot).decoration! as BoxDecoration;
      expect(deco.color, TimetableTheme.colorsOf(ctx).warning);
      expect(tester.takeException(), isNull);
      // 下一周同一门课没有圆点。
      await pumpHost(
        tester,
        Scaffold(
          body: WeekGrid(week: _week + 1, controller: c, onCourseTap: (_) {}),
        ),
        mode: mode,
      );
      expect(find.byKey(const Key('course_cell_date_edit_dot')), findsNothing);
    });
  }
}
