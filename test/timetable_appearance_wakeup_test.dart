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
    // 设置保存包含多次异步文件操作，要在测试的 FakeAsync 尚运行时排空。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpAppearance(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
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

    await tester.ensureVisible(
      find.byKey(const Key('tt_settings_cell_text_color')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('tt_settings_cell_text_color')),
        matching: find.text('黑'),
      ),
    );
    await settleIo(tester);
    expect(_c.settings.cellTextColor, CellTextColorMode.black);

    expect(find.text('六'), findsWidgets);
    final sat = find.byKey(const Key('tt_settings_saturday'));
    await tester.ensureVisible(sat);
    await tester.pumpAndSettle();
    await tester.tap(sat);
    await settleIo(tester);
    expect(_c.settings.showSaturday, isFalse);
  });

  testWidgets('AW03 表头字号与节数时间开关写入 settings', (tester) async {
    await pumpAppearance(tester);
    expect(_c.settings.headerTextSize, 11);
    expect(_c.settings.showPeriodTimes, isTrue);

    // 滑块与开关位于下半滚动区靠下位置，CI 字体度量不同会被部分裁出视口，
    // 先滚入可见区并直接驱动 Slider.onChanged，不依赖像素拖动。
    final headerSlider = find.byKey(const Key('tt_settings_header_text_size'));
    await tester.ensureVisible(headerSlider);
    await tester.pumpAndSettle();
    tester.widget<Slider>(headerSlider).onChanged!(kHeaderTextSizeMax);
    await settleIo(tester);
    expect(_c.settings.headerTextSize, 14);

    final periodTimes = find.byKey(const Key('tt_settings_show_period_times'));
    await tester.ensureVisible(periodTimes);
    await tester.pumpAndSettle();
    await tester.tap(periodTimes);
    await settleIo(tester);
    expect(_c.settings.showPeriodTimes, isFalse);

    final stored = (await tester.runAsync(TimetableStore.readSettings))!;
    expect(stored.headerTextSize, 14);
    expect(stored.showPeriodTimes, isFalse);
  });

  testWidgets('AW04 直接连续选色：取消不保存，输入色号保存', (tester) async {
    await pumpAppearance(tester);
    // ListView 懒建元素：考试组在视口外时 skipOffstage 默认找不到。
    final exam = find.byKey(
      const Key('tt_settings_exam_color'),
      skipOffstage: false,
    );
    await tester.scrollUntilVisible(
      exam,
      300,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_exam_color')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_color_sv_panel')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_hue')), findsOneWidget);
    expect(find.byKey(const Key('tt_color_custom_plus')), findsNothing);
    await tester.tap(find.byKey(const Key('tt_color_cancel')));
    await tester.pumpAndSettle();
    expect(_c.settings.examColor, kDefaultExamColor);
    await tester.tap(exam);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '386F95');
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await settleIo(tester);
    expect(_c.settings.examColor, 0xFF386F95);
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
    // 按页面宽度拖动一页，避免 fling 惯性连续翻过两周。
    await tester.drag(pager, Offset(-tester.getSize(pager).width * 0.7, 0));
    await tester.pumpAndSettle();
    final after = tester.widget<WeekGrid>(
      find.byKey(const Key('tt_appearance_preview_grid')),
    );
    if (startWeek < _c.totalWeeks) {
      expect(after.week, startWeek + 1);
    }
    expect(_c.viewingWeek, beforeView);
  });

  /// 短屏触发可折叠预览；设置区经 ClipRect 裁在分界线下方。
  Future<void> pumpAppearanceCollapsible(
    WidgetTester tester, {
    required bool expandPreview,
  }) async {
    // constraints.maxHeight < 560 → collapsible；物理高需扣 AppBar。
    tester.view.physicalSize = const Size(1080, 1400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TimetableAppearancePage(controller: _c)),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('tt_appearance_preview_collapse_bar')),
      findsOneWidget,
    );
    final expanded = find.byKey(const Key('tt_appearance_preview_expanded'));
    if (expandPreview) {
      if (expanded.evaluate().isEmpty) {
        await tester.tap(
          find.byKey(const Key('tt_appearance_preview_collapse_bar')),
        );
        await tester.pumpAndSettle();
      }
      expect(expanded, findsOneWidget);
    } else {
      if (expanded.evaluate().isNotEmpty) {
        await tester.tap(
          find.byKey(const Key('tt_appearance_preview_collapse_bar')),
        );
        await tester.pumpAndSettle();
      }
      expect(expanded, findsNothing);
    }
  }

  Future<void> assertSettingsClippedBelowDivider(WidgetTester tester) async {
    expect(
      find.byKey(const Key('tt_appearance_settings_clip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tt_appearance_settings_list')),
      findsOneWidget,
    );
    expect(
      tester.widget(find.byKey(const Key('tt_appearance_settings_clip'))),
      isA<ClipRect>(),
    );
    final clipRect = tester.getRect(
      find.byKey(const Key('tt_appearance_settings_clip')),
    );
    final collapse = find.byKey(
      const Key('tt_appearance_preview_collapse_bar'),
    );
    final preview = find.byKey(const Key('tt_appearance_preview_expanded'));
    if (preview.evaluate().isNotEmpty) {
      expect(
        clipRect.top,
        greaterThanOrEqualTo(tester.getRect(preview).bottom - 0.5),
        reason: '展开态：设置裁切顶边应在预览底边下方',
      );
    } else {
      expect(
        clipRect.top,
        greaterThanOrEqualTo(tester.getRect(collapse).bottom - 0.5),
        reason: '折叠态：设置裁切顶边应在折叠条底边下方',
      );
    }

    // 用力上滚：裁切顶边仍贴分界线，预览/折叠条不被遮挡。
    await tester.drag(
      find.byKey(const Key('tt_appearance_settings_list')),
      const Offset(0, 2400),
    );
    await tester.pumpAndSettle();
    final clipAfter = tester.getRect(
      find.byKey(const Key('tt_appearance_settings_clip')),
    );
    if (preview.evaluate().isNotEmpty) {
      expect(
        find.byKey(const Key('tt_appearance_preview_expanded')),
        findsOneWidget,
      );
      expect(
        clipAfter.top,
        greaterThanOrEqualTo(tester.getRect(preview).bottom - 0.5),
      );
    } else {
      expect(
        find.byKey(const Key('tt_appearance_preview_collapse_bar')),
        findsOneWidget,
      );
      expect(
        clipAfter.top,
        greaterThanOrEqualTo(tester.getRect(collapse).bottom - 0.5),
      );
    }
  }

  testWidgets('AW06 展开预览时设置区 ClipRect 裁在分界线下方', (tester) async {
    await pumpAppearanceCollapsible(tester, expandPreview: true);
    await assertSettingsClippedBelowDivider(tester);
  });

  testWidgets('AW07 折叠预览时设置区仍只在分界线下方滚动', (tester) async {
    await pumpAppearanceCollapsible(tester, expandPreview: false);
    await assertSettingsClippedBelowDivider(tester);
  });
}
