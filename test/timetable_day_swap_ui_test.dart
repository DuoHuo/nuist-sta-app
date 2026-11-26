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

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_swap_ui');
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

  /// 轮询等到 [done] 成立（最多约 2 秒）。文件 IO 跑在真实异步里，
  /// 固定轮数的 [settleIo] 在慢机器上不稳。
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpHost(
    WidgetTester tester,
    Widget child, {
    ThemeMode mode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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

  testWidgets('长按表头调课：取消不变、同一天/已调过课校验、互换角标及页内与设置记录恢复', (tester) async {
    // 1. 失败校验：同一天 / 对方已调过课
    load();
    await tester.runAsync(() => c.addDaySwap(_wed, _thu));
    await pumpHost(
      tester,
      TimetableDaySwapsPage(controller: c, initialFrom: _mon),
    );
    Future<void> attempt(int day, String msg) async {
      await tester.tap(find.byKey(const Key('day_swap_to')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$day'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('day_swap_submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('day_swap_confirm_dialog')), findsNothing);
      expect(find.text(msg), findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(TimetableDaySwapsPage)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    await attempt(12, '不能和同一天互换');
    await attempt(14, '10月14日已调过课，请先撤销');
    expect(c.daySwaps, hasLength(1));

    // 2. 取消确认不调课 → 确认互换显示两枚「调」角标 → 页内「恢复」还原为空
    c.debugReset();
    load();
    await pumpGrid(tester);
    expect(find.byKey(const Key('day_header_swap_badge')), findsNothing);
    await longPressHeader(tester, 1);
    expect(find.byKey(const Key('day_swaps_page')), findsOneWidget);
    expect(find.text('10月12日'), findsOneWidget);
    await tester.tap(find.byKey(const Key('day_swap_to')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('14'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('day_swap_submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('day_swap_cancel')));
    await settleIo(tester);
    expect(c.daySwaps, isEmpty);

    await tester.tap(find.byKey(const Key('day_swap_submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('day_swap_confirm')));
    await settleIo(tester);
    await tester.pumpAndSettle();
    expect(c.daySwaps, hasLength(1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day_header_swap_badge')), findsNWidgets(2));
    expect(find.text('已与10月14日互换'), findsOneWidget);

    await longPressHeader(tester, 3);
    final firstSwap = c.daySwaps.single;
    await tester.tap(find.byKey(Key('day_swap_restore_${firstSwap.id}')));
    await settleIo(tester);
    await tester.pumpAndSettle();
    expect(c.daySwaps, isEmpty);
    expect(find.byKey(const Key('day_swaps_empty')), findsOneWidget);

    // 3. 从设置 -> 课程管理 -> 调课记录查看空态、新增后一句话展示并恢复
    await pumpHost(tester, TimetableSettingsPage(controller: c));
    await tester.tap(find.byKey(const Key('tt_settings_management_entry')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('tt_settings_day_swaps')),
      200,
    );
    await tester.ensureVisible(find.byKey(const Key('tt_settings_day_swaps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_day_swaps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day_swaps_empty')), findsOneWidget);
    final s = (await tester.runAsync(() => c.addDaySwap(_wed, _mon)))!;
    await tester.pumpAndSettle();
    expect(find.text('10月12日与10月14日的课程互换'), findsOneWidget);
    await tester.tap(find.byKey(Key('day_swap_restore_${s.id}')));
    await settleUntil(
      tester,
      () => find.byKey(const Key('day_swaps_empty')).evaluate().isNotEmpty,
    );
    expect(c.daySwaps, isEmpty);
  });

  test('SWU05 学期范围与文字', () {
    load();
    final r = semesterRangeOf(c);
    expect(r.first, DateTime(2026, 8, 31));
    expect(r.last.weekday, DateTime.sunday);
    expect(daySwapErrorFor(c, _mon, _wed), isNull);
    expect(daySwapErrorFor(c, DateTime(2026, 8, 30), _wed), '日期不在本学期内');
  });

  GridCell cellOn(DateTime d, String id) => c
      .cellsForDay(c.weekOfDate(d), d.weekday)
      .firstWhere((x) => x.activeThisWeek && x.course.id == id);

  testWidgets('深色调课角标与记录、详情只删这一天及单日修改恢复与无标记圆点', (tester) async {
    // 1. 深色模式下调课记录页与表头角标正常渲染
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

    // 2. 详情只删这一天；单日修改无圆点且不波及下一周，可从详情恢复这一天
    c.debugReset();
    load();
    await pumpHost(
      tester,
      Scaffold(
        body: CourseDetailSheet(cell: cellOn(_mon, 'm1'), controller: c),
      ),
    );
    await tester.tap(find.byKey(const Key('course_detail_delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete_scope_sheet')), findsOneWidget);
    await tester.tap(find.textContaining('仅第'));
    await settleIo(tester);
    expect(
      c
          .cellsForDay(_week, 1)
          .where((x) => x.activeThisWeek && x.course.id == 'm1'),
      isEmpty,
    );
    expect(cellOn(DateTime(2026, 10, 19), 'm1').dateEdit, isNull);

    await tester.runAsync(() async {
      await c.restoreDateEdit(c.courseDateEdits.single.id);
      await c.editOccurrence(cellOn(_mon, 'm1'), name: '读书会·改');
    });
    await pumpHost(
      tester,
      Scaffold(
        body: WeekGrid(week: _week, controller: c, onCourseTap: (_) {}),
      ),
      mode: ThemeMode.dark,
    );
    expect(find.byKey(const Key('course_cell_date_edit_dot')), findsNothing);
    await pumpHost(
      tester,
      Scaffold(
        body: CourseDetailSheet(cell: cellOn(_mon, 'm1'), controller: c),
      ),
    );
    await tester.tap(find.byKey(const Key('course_detail_date_edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_detail_restore_day')));
    await settleIo(tester);
    expect(c.courseDateEdits, isEmpty);
    expect(cellOn(_mon, 'm1').dateEdit, isNull);
  });
}
