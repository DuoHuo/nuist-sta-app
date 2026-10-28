// 任务 D：设置首页重组并保留明日提醒 + 外观页四组 / 折叠预览（spec-settings-regroup §1–§3）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_settings_regroup');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
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
                teacher: '张老师',
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
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('RG01 设置首页顺序 外观→首页→小组件→提醒→课表管理→恢复', (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableSettingsPage(controller: _c, showReminderCard: true),
      ),
    );
    await tester.pump();
    final titles = [
      '首页与桌面',
      TtSettingsText.widgetCard,
      TtSettingsText.reminderCard,
      '课表管理',
    ];
    final ys = [
      for (final t in titles) tester.getTopLeft(find.text(t).first).dy,
    ];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i] > ys[i - 1], isTrue, reason: titles[i]);
    }
    final card = find.byKey(const Key('tt_settings_appearance_card'));
    expect(card, findsOneWidget);
    expect(
      tester.getTopLeft(card).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('tt_settings_group_home'))).dy,
      ),
    );
    // 顶部独立单行卡：无分组标题、无副标题。
    expect(find.text('外观'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('tt_settings_appearance_entry')),
        matching: find.byType(Text),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('tt_settings_group_display')), findsNothing);
    expect(find.byKey(const Key('tt_settings_group_exam')), findsNothing);
    expect(find.byKey(const Key('tt_settings_account')), findsNothing);
    for (final key in [
      'tt_settings_next_day_reminder',
      'tt_settings_next_day_time',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(const Key('tt_settings_group_reminder')),
          matching: find.byKey(Key(key)),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('RG02 周课表无「课表外观」菜单；设置首页外观卡为唯一入口', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: const TimetablePage()));
    await settleIo(tester);
    expect(find.byKey(const Key('timetable_week_menu')), findsNothing);
    expect(
      find.byKey(const Key('timetable_appearance_menu_entry')),
      findsNothing,
    );
    expect(find.text('课表外观'), findsNothing);
    await tester.tap(find.byKey(const Key('timetable_settings_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('tt_settings_appearance_entry')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('tt_settings_appearance_entry')));
    await tester.pumpAndSettle();
    expect(find.byType(TimetableAppearancePage), findsOneWidget);
    expect(find.widgetWithText(AppBar, '外观'), findsOneWidget);
  });

  testWidgets('RG03 外观四组顺序与行；改开关即时写 settings', (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TimetableAppearancePage(controller: _c)),
    );
    await tester.pump();
    final groups = [
      'tt_appearance_group',
      'tt_appearance_group_week',
      'tt_settings_group_exam',
      'tt_appearance_group_cell_info',
    ];
    for (final g in groups) {
      final f = find.byKey(Key(g), skipOffstage: false);
      await tester.scrollUntilVisible(
        f,
        400,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key(g)), findsOneWidget, reason: g);
    }
    final ys = [
      for (final g in groups) tester.getTopLeft(find.byKey(Key(g))).dy,
    ];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i] > ys[i - 1], isTrue, reason: groups[i]);
    }
    expect(_c.settings.showLocation, isTrue);
    await tester.tap(find.byKey(const Key('tt_settings_show_location')));
    await settleIo(tester);
    expect(_c.settings.showLocation, isFalse);
  });

  testWidgets('RG04 短屏折叠预览：栏可展开再收起，折叠态无 pager', (tester) async {
    // 360dp 宽 + 矮屏触发可折叠，默认收起。
    tester.view.physicalSize = const Size(360, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TimetableAppearancePage(controller: _c)),
    );
    await tester.pumpAndSettle();
    final bar = find.byKey(const Key('tt_appearance_preview_collapse_bar'));
    expect(bar, findsOneWidget);
    expect(find.byKey(const Key('tt_appearance_preview_pager')), findsNothing);
    expect(find.textContaining('预览'), findsWidgets);
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('tt_appearance_preview_expanded')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tt_appearance_preview_pager')),
      findsOneWidget,
    );
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_appearance_preview_pager')), findsNothing);
  });

  testWidgets('RG05 360dp 大字号：格子信息仍可滚到并可点', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: TimetableAppearancePage(controller: _c),
      ),
    );
    await tester.pumpAndSettle();
    final loc = find.byKey(
      const Key('tt_settings_show_location'),
      skipOffstage: false,
    );
    await tester.scrollUntilVisible(
      loc,
      200,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(_c.settings.showLocation, isTrue);
    await tester.tap(find.byKey(const Key('tt_settings_show_location')));
    await settleIo(tester);
    expect(_c.settings.showLocation, isFalse);
  });

  testWidgets('普通手机提前量保持同行和统一行高，开关及分组文字对齐', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [360.0, 390.0, 412.0]) {
      tester.view.physicalSize = Size(width, 1600);
      await tester.pumpWidget(
        MaterialApp(home: TimetableSettingsPage(controller: _c)),
      );
      await tester.pumpAndSettle();
      final lead = find.byKey(const Key('tt_settings_reminder_lead'));
      expect(
        find.descendant(of: lead, matching: find.text('15 分钟')),
        findsOneWidget,
      );
      expect(tester.getSize(lead).height, 52);
      final switches = [
        'tt_settings_show_tomorrow',
        'tt_settings_next_day_reminder',
        'tt_settings_reminder',
      ];
      final rightEdges = [
        for (final key in switches)
          tester
              .getRect(
                find.descendant(
                  of: find.byKey(Key(key)),
                  matching: find.byType(Switch),
                ),
              )
              .right,
      ];
      expect(rightEdges.toSet(), hasLength(1));
      expect(
        tester.getTopLeft(find.text('首页与桌面')).dx,
        tester.getTopLeft(find.text(TtSettingsText.homeMaxItems).first).dx,
      );
      final time = find.byKey(const Key('tt_settings_next_day_time'));
      expect(tester.getSize(time).height, 52);
      expect(
        tester
            .getCenter(
              find.descendant(
                of: time,
                matching: find.text(TtSettingsText.nextDayTime),
              ),
            )
            .dy,
        tester
            .getCenter(find.descendant(of: time, matching: find.text('22:00')))
            .dy,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('窄屏大字号保留当前值，提前量和明日时间都可在滚动弹层选择', (tester) async {
    _c.debugSetSnapshot(
      _c.snapshot.copyWith(
        settings: _c.settings.copyWith(reminderEnabled: true),
      ),
      viewingWeek: 1,
    );
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: TimetableSettingsPage(controller: _c),
      ),
    );
    final lead = find.byKey(
      const Key('tt_settings_reminder_lead'),
      skipOffstage: false,
    );
    await tester.scrollUntilVisible(
      lead,
      200,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: lead, matching: find.byType(ChoiceChip)),
      findsNothing,
    );
    expect(
      find.descendant(of: lead, matching: find.text('15 分钟')),
      findsOneWidget,
    );
    await tester.tap(lead);
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 分钟'));
    await settleIo(tester);
    expect(_c.settings.reminderLeadMinutes, 30);
    final time = find.byKey(
      const Key('tt_settings_next_day_time'),
      skipOffstage: false,
    );
    await tester.scrollUntilVisible(
      time,
      100,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(time);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('23:30'),
      100,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('23:30'));
    await settleIo(tester);
    expect(_c.settings.nextDayReminderMinute, 1410);
    expect(tester.takeException(), isNull);
  });
}
