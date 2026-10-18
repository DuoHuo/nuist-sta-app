import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_settings');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: DateTime(2026, 9, 7)),
      ),
      viewingWeek: 2,
      manualCourses: [
        // 只在单周上：第 2 周为非本周课程。
        Course(
          id: 'o',
          name: '单周课',
          slots: [
            CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '10' * 10),
          ],
        ),
      ],
    );
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpPage(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: body));
    await tester.pump();
  }

  Widget grid() => Scaffold(
    body: ListenableBuilder(
      listenable: _c,
      builder: (context, _) => WeekGrid(week: 2, controller: _c),
    ),
  );

  testWidgets('原三项设置仍在（v0.4 卡片版），旧「M2 接入」骨架已移除；非本周课程默认关', (tester) async {
    expect(const TimetableSettings().showNonCurrentWeek, isFalse);
    await pumpPage(tester, TimetableSettingsPage(controller: _c));
    // §13.16 新名（卡片「显示」已给上下文）。
    expect(find.text('周六'), findsOneWidget);
    expect(find.text('周日'), findsWidgets); // 行名 + 一周起始的「周日」选项
    expect(find.text('非本周课程'), findsOneWidget);
    expect(find.text('格子高度'), findsOneWidget);
    expect(find.textContaining('M2'), findsNothing);
    // v0.4 改为自绘 52dp 行 + Switch（不再是 SwitchListTile）。
    final sw = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('tt_settings_non_current')),
        matching: find.byType(Switch),
      ),
    );
    expect(sw.value, isFalse);
  });

  testWidgets('周六/周日开关：持久化并增删网格列', (tester) async {
    await pumpPage(tester, grid());
    expect(find.text('六'), findsOneWidget);
    expect(find.text('日'), findsOneWidget);

    await pumpPage(tester, TimetableSettingsPage(controller: _c));
    await tester.tap(find.byKey(const Key('tt_settings_saturday')));
    await settleIo(tester);
    await tester.tap(find.byKey(const Key('tt_settings_sunday')));
    await settleIo(tester);
    expect(_c.settings.showSaturday, isFalse);
    expect(_c.settings.showSunday, isFalse);
    final stored = (await tester.runAsync(TimetableStore.readSettings))!;
    expect(stored.showSaturday, isFalse);
    expect(stored.showSunday, isFalse);

    await pumpPage(tester, grid());
    expect(find.text('六'), findsNothing);
    expect(find.text('日'), findsNothing);
    expect(find.text('五'), findsOneWidget);

    await pumpPage(tester, TimetableSettingsPage(controller: _c));
    await tester.tap(find.byKey(const Key('tt_settings_sunday')));
    await settleIo(tester);
    await pumpPage(tester, grid());
    expect(find.text('六'), findsNothing);
    expect(find.text('日'), findsOneWidget);
  });

  testWidgets('显示非本周课程开关：持久化并显示/隐藏灰格', (tester) async {
    await pumpPage(tester, grid());
    expect(find.byType(CourseCell), findsNothing);

    await pumpPage(tester, TimetableSettingsPage(controller: _c));
    await tester.tap(find.byKey(const Key('tt_settings_non_current')));
    await settleIo(tester);
    expect(_c.settings.showNonCurrentWeek, isTrue);
    final stored = (await tester.runAsync(TimetableStore.readSettings))!;
    expect(stored.showNonCurrentWeek, isTrue);

    await pumpPage(tester, grid());
    expect(find.byType(CourseCell), findsOneWidget);
    expect(
      tester.widget<CourseCell>(find.byType(CourseCell)).cell.activeThisWeek,
      isFalse,
    );

    await pumpPage(tester, TimetableSettingsPage(controller: _c));
    await tester.tap(find.byKey(const Key('tt_settings_non_current')));
    await settleIo(tester);
    await pumpPage(tester, grid());
    expect(find.byType(CourseCell), findsNothing);
  });

  testWidgets('格子高度滑块：写入 periodHeight 并持久化', (tester) async {
    await pumpPage(tester, TimetableSettingsPage(controller: _c));
    final slider = find.byKey(const Key('tt_settings_period_height'));
    await tester.drag(slider, const Offset(-2000, 0));
    await settleIo(tester);
    expect(_c.settings.periodHeight, 52);
    final stored = (await tester.runAsync(TimetableStore.readSettings))!;
    expect(stored.periodHeight, 52);
  });
}
