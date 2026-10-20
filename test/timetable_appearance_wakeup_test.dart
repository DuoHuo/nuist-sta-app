import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_appearance_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_appearance_wakeup');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: DateTime(2026, 9, 7),
          // 2026-10-20 在第 7 周附近；固定开学日便于本周预览。
        ),
        courses: [
          Course(
            id: 'a',
            name: '高等数学',
            slots: [
              CourseSlot(
                day: 1,
                startNode: 1,
                endNode: 2,
                weeks: '1' * 16,
                location: '教1-101',
              ),
            ],
          ),
        ],
      ),
      viewingWeek: 1,
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

  Future<void> pumpAppearance(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TimetableAppearancePage(controller: _c)),
    );
    await tester.pump();
  }

  testWidgets('AW01 上半为本周真实 WeekGrid，非示例格', (tester) async {
    await pumpAppearance(tester);
    expect(find.byKey(const Key('tt_appearance_preview_grid')), findsOneWidget);
    expect(find.byType(WeekGrid), findsOneWidget);
    expect(find.text('示例课程'), findsNothing);
    expect(find.text('高等数学'), findsWidgets);
  });

  testWidgets('AW02 改不透明度 / 字色 / 周末开关即时反映到预览', (tester) async {
    await pumpAppearance(tester);
    expect(_c.settings.cellOpacity, 100);
    await tester.drag(
      find.byKey(const Key('tt_settings_opacity')),
      const Offset(-2000, 0),
    );
    await settleIo(tester);
    expect(_c.settings.cellOpacity, 30);

    await tester.tap(find.text('黑字'));
    await settleIo(tester);
    expect(_c.settings.cellTextColor, CellTextColorMode.black);

    expect(find.text('六'), findsWidgets);
    await tester.tap(find.byKey(const Key('tt_settings_saturday')));
    await settleIo(tester);
    expect(_c.settings.showSaturday, isFalse);
  });

  testWidgets('AW03 表头字号与节数时间开关写入 settings', (tester) async {
    await pumpAppearance(tester);
    expect(_c.settings.headerTextSize, 11);
    expect(_c.settings.showPeriodTimes, isTrue);

    await tester.drag(
      find.byKey(const Key('tt_settings_header_text_size')),
      const Offset(2000, 0),
    );
    await settleIo(tester);
    expect(_c.settings.headerTextSize, 14);

    await tester.tap(find.byKey(const Key('tt_settings_show_period_times')));
    await settleIo(tester);
    expect(_c.settings.showPeriodTimes, isFalse);

    final stored = (await tester.runAsync(TimetableStore.readSettings))!;
    expect(stored.headerTextSize, 14);
    expect(stored.showPeriodTimes, isFalse);
  });

  testWidgets('AW04 选色盘网格无 HSV；点「+」弹出 HSV；预设点选即返回', (tester) async {
    await pumpAppearance(tester);
    final exam = find.byKey(const Key('tt_settings_exam_color'));
    await tester.ensureVisible(exam);
    await tester.pumpAndSettle();
    await tester.tap(exam);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_color_picker')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_custom_plus')), findsOneWidget);
    // 网格 alone：HSV 对话框 / 色相条不可见。
    expect(find.byKey(const Key('tt_color_hsv_dialog')), findsNothing);
    expect(find.byKey(const Key('tt_color_hue')), findsNothing);
    expect(find.byKey(const Key('tt_color_sv_panel')), findsNothing);
    // 点「+」弹出 WakeUp 式 HSV 对话框。
    await tester.tap(find.byKey(const Key('tt_color_custom_plus')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_color_hsv_dialog')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_sv_panel')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_hue')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_hex')), findsOneWidget);
    // 取消关闭对话框，网格仍在、HSV 不再可见。
    await tester.tap(find.byKey(const Key('tt_color_hsv_cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_color_hsv_dialog')), findsNothing);
    expect(find.byKey(const Key('tt_color_picker')), findsOneWidget);
    // 预设点选仍直接返回。
    await tester.tap(find.byKey(const Key('tt_color_preset_2')));
    await settleIo(tester);
    expect(_c.settings.examColor, isNot(kDefaultExamColor));
  });

  testWidgets('AW05 预览左右滑切周，不改 viewingWeek', (tester) async {
    await pumpAppearance(tester);
    await settleIo(tester);
    final beforeView = _c.viewingWeek;
    final pager = find.byKey(const Key('tt_appearance_preview_pager'));
    expect(pager, findsOneWidget);
    final grid = tester.widget<WeekGrid>(
      find.byKey(const Key('tt_appearance_preview_grid')),
    );
    final startWeek = grid.week;
    await tester.fling(pager, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    final after = tester.widget<WeekGrid>(
      find.byKey(const Key('tt_appearance_preview_grid')),
    );
    if (startWeek < _c.totalWeeks) {
      expect(after.week, startWeek + 1);
    }
    expect(_c.viewingWeek, beforeView);
  });
}
