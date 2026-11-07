// 设置页「提醒」「小组件」卡片与后台运行引导页（接口文档 §1–§2）。全部为构造数据。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

class _FakeActions extends ReminderActions {
  _FakeActions(this.perm) : super(controller: _c);

  NotifyPermissionStatus perm;
  final calls = <String>[];
  WidgetPinResult pinResult = WidgetPinResult.requested;
  Completer<WidgetPinResult>? pendingPin;
  bool shortcutSettingsOpened = true;

  @override
  Future<bool> openWidgetShortcutSettings() async {
    calls.add('shortcut-settings');
    return shortcutSettingsOpened;
  }

  @override
  Future<WidgetPinResult> pinWidget({required bool square}) async {
    calls.add('pin:$square');
    return pendingPin == null ? pinResult : await pendingPin!.future;
  }

  @override
  Future<NotifyPermissionStatus> setReminderEnabled(bool enabled) async {
    calls.add('enabled:$enabled');
    await _c.updateSettings(_c.settings.copyWith(reminderEnabled: enabled));
    return perm;
  }

  @override
  Future<void> setReminderLeadMinutes(int minutes) async {
    calls.add('lead:$minutes');
    await _c.updateSettings(_c.settings.copyWith(reminderLeadMinutes: minutes));
  }

  @override
  Future<NotifyPermissionStatus> permissionStatus() async => perm;

  @override
  Future<bool> openNotificationSettings() async {
    calls.add('notif');
    return true;
  }

  @override
  Future<bool> openExactAlarmSettings() async {
    calls.add('exact');
    return true;
  }

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    calls.add('battery');
    return true;
  }
}

NotifyPermissionStatus _perm({bool notif = true, bool exact = true}) =>
    NotifyPermissionStatus(
      supported: true,
      notificationsGranted: notif,
      exactAlarmGranted: exact,
      ignoringBatteryOptimizations: false,
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_reminder_settings');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    _c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
      ),
      viewingWeek: 7,
    );
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, _FakeActions a) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TimetableSettingsPage(controller: _c, reminderActions: a),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  bool sw(WidgetTester tester, String key) => tester
      .widget<Switch>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(Switch),
        ),
      )
      .value;

  test('提醒入口已打开', () => expect(kShowReminderSettings, isTrue));

  testWidgets('开关走 setReminderEnabled，提前时间走 setReminderLeadMinutes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final a = _FakeActions(_perm());
      await pump(tester, a);
      expect(find.text(TtSettingsText.reminderIntro), findsNothing);
      expect(sw(tester, 'tt_settings_reminder'), isFalse);
      await tester.tap(find.byKey(const Key('tt_settings_reminder')));
      await settleIo(tester);
      expect(a.calls, ['enabled:true']);
      expect(sw(tester, 'tt_settings_reminder'), isTrue);
      final lead = find.byKey(const Key('tt_settings_reminder_lead'));
      await tester.tap(lead);
      await tester.pumpAndSettle();
      Finder seg(int m) => find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(TextButton, '$m 分钟'),
      );
      for (final m in kReminderLeadChoices) {
        expect(seg(m), findsOneWidget);
      }
      expect(
        find.descendant(of: lead, matching: find.text('20 分钟')),
        findsNothing,
      );
      expect(
        tester.getSemantics(seg(15)).flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      await tester.tap(seg(30));
      await tester.pumpAndSettle();
      expect(a.calls.last, 'lead:30');
      await settleIo(tester);
      expect(find.text(TtSettingsText.reminderIntro), findsOneWidget);
      expect(
        (await tester.runAsync(TimetableStore.readReminderIntroSeen))!,
        isTrue,
      );
      ScaffoldMessenger.of(tester.element(find.byType(TimetableSettingsPage)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_settings_reminder')));
      await settleIo(tester);
      await tester.tap(find.byKey(const Key('tt_settings_reminder')));
      await settleIo(tester);
      expect(sw(tester, 'tt_settings_reminder'), isTrue);
      expect(find.text(TtSettingsText.reminderIntro), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  test('不在档位的提前量按 15 显示', () {
    expect(kReminderLeadChoices, [5, 10, 15, 30]);
    expect(displayReminderLead(20), 15);
    expect(displayReminderLead(7), 15);
    expect(displayReminderLead(30), 30);
  });

  testWidgets('通知权限被拒：提示 + 去设置打开通知设置', (tester) async {
    final a = _FakeActions(_perm(notif: false));
    await pump(tester, a);
    // 提醒关着不提示。
    expect(
      find.byKey(const Key('tt_settings_reminder_permission')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('tt_settings_reminder')));
    await settleIo(tester);
    expect(find.text(TtSettingsText.permissionNotification), findsOneWidget);
    await tester.tap(find.byKey(const Key('tt_settings_reminder_goto')));
    expect(a.calls.last, 'notif');
  });

  testWidgets('精确闹钟被拒：提示 + 去设置打开闹钟授权页；回前台刷新', (tester) async {
    final a = _FakeActions(_perm(exact: false));
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_reminder')));
    await settleIo(tester);
    expect(find.text(TtSettingsText.permissionExactAlarm), findsOneWidget);
    await tester.tap(find.byKey(const Key('tt_settings_reminder_goto')));
    expect(a.calls.last, 'exact');
    a.perm = _perm();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('tt_settings_reminder_permission')),
      findsNothing,
    );
  });

  testWidgets('不支持的平台不显示权限提示', (tester) async {
    final a = _FakeActions(NotifyPermissionStatus.unsupported);
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_reminder')));
    await settleIo(tester);
    expect(
      find.byKey(const Key('tt_settings_reminder_permission')),
      findsNothing,
    );
  });

  testWidgets('小组件卡片：5 个开关默认全开、无冗余说明，可切换', (tester) async {
    final a = _FakeActions(_perm());
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(AppBar, TtSettingsText.widgetCard),
      findsOneWidget,
    );
    expect(WidgetDisplayOption.values.map((o) => o.field), [
      'widgetShowTeacher',
      'widgetShowLocation',
      'widgetShowPeriod',
      'widgetShowCountdown',
      'widgetShowCount',
    ]);
    expect(WidgetDisplayOption.countdown.subtitle, isNull);
    expect(WidgetDisplayOption.count.subtitle, isNull);
    expect(WidgetDisplayOption.teacher.subtitle, isNull);
    // 「同时显示」在开关之上。
    expect(
      tester
          .getTopLeft(find.byKey(const Key('tt_settings_widgetCourseCount')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('tt_settings_widgetShowTeacher')))
            .dy,
      ),
    );
    for (final o in WidgetDisplayOption.values) {
      expect(find.text(o.title), findsOneWidget);
      if (o.subtitle != null) {
        expect(find.text(o.subtitle!), findsOneWidget);
      }
      expect(sw(tester, 'tt_settings_${o.field}'), isTrue, reason: o.field);
    }
    await tester.tap(find.byKey(const Key('tt_settings_widgetShowPeriod')));
    await settleIo(tester);
    expect(sw(tester, 'tt_settings_widgetShowPeriod'), isFalse);
    expect(_c.settings.widgetShowPeriod, isFalse);
    expect(sw(tester, 'tt_settings_widgetShowCount'), isTrue);
  });

  testWidgets('小组件「同时显示」1/2/3 节：默认 2，可切换', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final a = _FakeActions(_perm());
      await pump(tester, a);
      await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('tt_settings_widgetCourseCount'));
      expect(
        find.descendant(
          of: row,
          matching: find.text(TtSettingsText.courseCount),
        ),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      Finder seg(int n) => find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(TextButton, '$n'),
      );
      for (final n in kWidgetCourseCountOptions) {
        expect(seg(n), findsOneWidget);
      }
      expect(
        tester.getSemantics(seg(2)).flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      await tester.tap(seg(3));
      await settleIo(tester);
      expect(_c.settings.widgetCourseCount, 3);
      expect(
        find.descendant(of: row, matching: find.text('3')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tt_widget_preview_course_2')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('tt_widget_preview_course_1')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('tt_widget_preview_time_1')),
            )
            .data,
        contains('20:30–21:20'),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('4×2 同日课程均分高度、固定间距，详情变少也不在底部堆积留白', (tester) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: TimetableWidgetSettingsPage(controller: _c),
        ),
      );
      await tester.pumpAndSettle();
      for (final showDetails in [true, false]) {
        for (final (field, enabled) in [
          ('widgetShowLocation', _c.settings.widgetShowLocation),
          ('widgetShowTeacher', _c.settings.widgetShowTeacher),
        ]) {
          if (enabled == showDetails) continue;
          final row = find.byKey(Key('tt_settings_$field'));
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          await tester.tap(row);
          await settleIo(tester);
        }
        final main = tester.getRect(
          find.byKey(const Key('tt_widget_preview_main_area')),
        );
        final after = tester.getRect(
          find.byKey(const Key('tt_widget_preview_after_area')),
        );
        expect(after.top - main.bottom, closeTo(5, 0.1));
        expect(main.height, closeTo(after.height, 0.1));
        final card = tester.getRect(
          find.byKey(const Key('tt_widget_preview_4x2')),
        );
        expect(card.bottom - after.bottom, closeTo(10, 0.1));
        for (final (index, area) in [(0, main), (1, after)]) {
          final data = tester.getRect(
            find.byKey(ValueKey('tt_widget_preview_course_data_$index')),
          );
          expect(data.center.dy, closeTo(area.center.dy, 0.1));
        }
        expect(
          find.byKey(const Key('tt_widget_preview_after_divider')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('2×2 预览只展示适用选项，切换尺寸保留偏好', (tester) async {
    final a = _FakeActions(_perm());
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2×2 当前与下一节'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_widget_preview_2x2')), findsOneWidget);
    expect(
      find.byKey(const Key('tt_settings_widgetCourseCount')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('tt_settings_widgetShowCountdown')),
      findsNothing,
    );
    expect(find.byKey(const Key('tt_settings_widgetShowPeriod')), findsNothing);
    expect(find.byKey(const Key('tt_settings_widgetShowCount')), findsNothing);
    for (final (areaKey, dataKey) in [
      ('tt_widget_preview_main_area', 'tt_widget_preview_course_data_0'),
      ('tt_widget_preview_after_area', 'tt_widget_preview_course_data_1'),
    ]) {
      final area = tester.getRect(find.byKey(Key(areaKey)));
      final data = tester.getRect(find.byKey(ValueKey(dataKey)));
      expect(data.center.dy, closeTo(area.center.dy, 0.1));
    }
    final main = tester.getRect(
      find.byKey(const Key('tt_widget_preview_main_area')),
    );
    final after = tester.getRect(
      find.byKey(const Key('tt_widget_preview_after_area')),
    );
    expect(after.top - main.bottom, closeTo(5, 0.1));
    final card = tester.getRect(find.byKey(const Key('tt_widget_preview_2x2')));
    // 表头 16dp、与正文间距 4dp、外边距 10dp，课程组两侧留白应相等。
    expect(
      main.top - (card.top + 10 + 16 + 4),
      closeTo(card.bottom - 10 - after.bottom, 0.1),
    );
    expect(
      find.byKey(const Key('tt_widget_preview_after_divider')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('tt_settings_widgetShowLocation')));
    await settleIo(tester);
    expect(_c.settings.widgetShowLocation, isFalse);
    await tester.tap(find.text('4×2 今日课表'));
    await tester.pumpAndSettle();
    expect(sw(tester, 'tt_settings_widgetShowLocation'), isFalse);
    expect(find.byKey(const Key('tt_widget_preview_4x2')), findsOneWidget);
  });

  testWidgets('两种小组件预览在窄屏与大字号下没有溢出', (tester) async {
    void checkTimeBounds(bool square) {
      final card = tester.getRect(
        find.byKey(
          Key(square ? 'tt_widget_preview_2x2' : 'tt_widget_preview_4x2'),
        ),
      );
      for (final index in [0, 1]) {
        final text = find.byKey(ValueKey('tt_widget_preview_time_$index'));
        if (text.evaluate().isEmpty) continue;
        final box = tester.renderObject<RenderParagraph>(text);
        expect(box.didExceedMaxLines, isFalse, reason: '课程 $index 的时间不能被截断');
        final rect = tester.getRect(text);
        expect(rect.left, greaterThanOrEqualTo(card.left + 10));
        expect(rect.right, lessThanOrEqualTo(card.right - 10));
        expect(rect.top, greaterThanOrEqualTo(card.top + 10));
        expect(rect.bottom, lessThanOrEqualTo(card.bottom - 10));
      }
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(320, 800), const Size(600, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final dark in [false, true]) {
        for (final scale in [1.0, 1.3, 1.5, 2.0]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? appDarkTheme() : appLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: TimetableWidgetSettingsPage(controller: _c),
            ),
          );
          await tester.pumpAndSettle();
          checkTimeBounds(false);
          expect(
            tester.takeException(),
            isNull,
            reason: '$size / $dark / $scale / 4×2',
          );
          await tester.tap(find.text('最后一节'));
          await tester.pumpAndSettle();
          checkTimeBounds(false);
          expect(
            tester.takeException(),
            isNull,
            reason: '$size / $dark / $scale / 4×2 最后一节',
          );
          await tester.tap(find.text('2×2 当前与下一节'));
          await tester.pumpAndSettle();
          checkTimeBounds(true);
          expect(
            tester.takeException(),
            isNull,
            reason: '$size / $dark / $scale / 2×2',
          );
          await tester.tap(find.text('有后续课程'));
          await tester.pumpAndSettle();
          checkTimeBounds(true);
          expect(
            tester.takeException(),
            isNull,
            reason: '$size / $dark / $scale / 2×2 后续课程',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('最后一节课程靠上且提示独立贴底，星期使用强调色', (tester) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: TimetableWidgetSettingsPage(controller: _c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('最后一节'));
      await tester.pumpAndSettle();
      for (final square in [false, true]) {
        if (square) {
          await tester.tap(find.text('2×2 当前与下一节'));
          await tester.pumpAndSettle();
        }
        final last = find.byKey(const Key('tt_widget_preview_last'));
        final name = find.byKey(const ValueKey('tt_widget_preview_course_0'));
        final weekday = tester.widget<Text>(
          find.byKey(const Key('tt_widget_preview_weekday')),
        );
        expect(
          weekday.style!.color,
          (dark ? appDarkTheme() : appLightTheme()).colorScheme.primary,
        );
        expect(
          tester.getTopLeft(last).dx,
          lessThan(tester.getTopLeft(name).dx),
        );
        expect(
          tester.getTopLeft(last).dy,
          greaterThan(tester.getBottomLeft(name).dy),
        );
        expect(tester.widget<Text>(last).style!.fontSize, 10);
        final preview = find.byKey(
          Key(square ? 'tt_widget_preview_2x2' : 'tt_widget_preview_4x2'),
        );
        final data = find.byKey(
          const ValueKey('tt_widget_preview_course_data_0'),
        );
        final area = tester.getRect(
          find.byKey(const Key('tt_widget_preview_main_area')),
        );
        final content = tester.getRect(data);
        expect(content.top - area.top, closeTo(square ? 0 : 2, 0.1));
        expect(area.height - content.height, closeTo(square ? 0 : 4, 0.1));
        expect(
          tester.getBottomLeft(preview).dy - tester.getBottomLeft(last).dy,
          closeTo(10, 0.1),
        );
        expect(
          tester.getTopLeft(last).dy,
          greaterThan(tester.getBottomLeft(data).dy),
        );
        expect(
          tester.getTopLeft(data).dy - tester.getTopLeft(preview).dy,
          lessThan(40),
        );
        expect(
          find.byKey(const Key('tt_widget_preview_after_divider')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('4×2 设置只显示一节时课程靠上，有后续课程也不居中', (tester) async {
    await tester.runAsync(
      () => _c.updateSettings(_c.settings.copyWith(widgetCourseCount: 1)),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme(),
        home: TimetableWidgetSettingsPage(controller: _c),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byKey(const Key('tt_widget_preview_4x2')));
    final data = tester.getRect(
      find.byKey(const ValueKey('tt_widget_preview_course_data_0')),
    );
    expect(data.top - card.top, closeTo(32, 0.1));
    expect(find.byKey(const Key('tt_widget_preview_after_area')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('2×2 表头标题、日期与星期在不同字号下共用文字基线', (tester) async {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? appDarkTheme() : appLightTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: TimetableWidgetSettingsPage(controller: _c),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('2×2 当前与下一节'));
        await tester.pumpAndSettle();
        final baselines = [
          for (final key in [
            'tt_widget_preview_header_title',
            'tt_widget_preview_header_date',
            'tt_widget_preview_weekday',
          ])
            () {
              final box = tester.renderObject<RenderBox>(find.byKey(Key(key)));
              return box.localToGlobal(Offset.zero).dy +
                  box.getDryBaseline(box.constraints, TextBaseline.alphabetic)!;
            }(),
        ];
        expect(baselines[1], closeTo(baselines[0], 0.1));
        expect(baselines[2], closeTo(baselines[0], 0.1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('添加请求保留选中尺寸，等待时不重复请求，也不把请求发出当作成功', (tester) async {
    final a = _FakeActions(_perm())..pendingPin = Completer<WidgetPinResult>();
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
    await tester.pumpAndSettle();
    expect(a.calls, isEmpty);
    expect(find.byKey(const Key('tt_settings_widget_guide')), findsNothing);
    expect(find.text(TtSettingsText.pinWidgetGuideTitle), findsNothing);
    await tester.tap(find.text('2×2 当前与下一节'));
    await tester.pumpAndSettle();
    final pin = find.byKey(const Key('tt_settings_widget_pin'));
    await tester.tap(pin);
    await tester.tap(pin);
    expect(a.calls, ['pin:true']);
    a.pendingPin!.complete(WidgetPinResult.requested);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('小米先说明权限，确认后才跳转，返回提示并允许重新添加', (tester) async {
    final a = _FakeActions(_perm())
      ..pinResult = WidgetPinResult.permissionRequired;
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
    await tester.pumpAndSettle();
    final pin = find.byKey(const Key('tt_settings_widget_pin'));
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(a.calls, ['pin:false']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('允许添加桌面快捷方式'), findsOneWidget);
    expect(find.text(TtSettingsText.pinWidgetOpenSettings), findsOneWidget);
    expect(find.text(TtSettingsText.pinWidgetPermissionHint), findsNothing);
    await tester.tap(find.text(TtSettingsText.pinWidgetOpenSettings));
    await tester.pumpAndSettle();
    expect(a.calls, ['pin:false', 'shortcut-settings']);
    expect(find.byType(BottomSheet), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(TtSettingsText.pinWidgetPermissionHint), findsOneWidget);
    a.pinResult = WidgetPinResult.requested;
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(a.calls, ['pin:false', 'shortcut-settings', 'pin:false']);
  });

  testWidgets('取消权限说明不跳设置；跳转失败时改为手动权限步骤', (tester) async {
    final a = _FakeActions(_perm())
      ..pinResult = WidgetPinResult.permissionRequired
      ..shortcutSettingsOpened = false;
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
    await tester.pumpAndSettle();
    final pin = find.byKey(const Key('tt_settings_widget_pin'));
    await tester.tap(pin);
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂不开启'));
    await tester.pumpAndSettle();
    expect(a.calls, ['pin:false']);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    await tester.tap(find.text(TtSettingsText.pinWidgetOpenSettings));
    await tester.pumpAndSettle();
    expect(a.calls, ['pin:false', 'pin:false', 'shortcut-settings']);
    expect(
      find.text(TtSettingsText.pinWidgetSettingsUnavailable),
      findsOneWidget,
    );
    expect(find.text('系统设置 → 应用管理 → NUIST++。'), findsOneWidget);
    expect(find.text(TtSettingsText.pinWidgetOpenSettings), findsNothing);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
  });

  for (final (result, step) in [
    (WidgetPinResult.permissionRequired, '允许添加桌面快捷方式'),
    (WidgetPinResult.miuiManual, '点击搜索，再进入「安卓小部件」列表。'),
    (WidgetPinResult.originOsManual, '打开原子组件'),
    (WidgetPinResult.manual, '进入桌面编辑'),
  ]) {
    testWidgets('添加结果 ${result.name} 显示对应指引', (tester) async {
      final a = _FakeActions(_perm())..pinResult = result;
      await pump(tester, a);
      await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_settings_widget_pin')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(step), findsOneWidget);
      await tester.tap(
        find.text(
          result == WidgetPinResult.permissionRequired ? '暂不开启' : '知道了',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });
  }

  testWidgets('只在添加分流后打开面板，明暗、横屏与大字体下确认按钮始终可见', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final dark in [false, true]) {
      for (final size in [const Size(375, 600), const Size(800, 375)]) {
        for (final result in [
          WidgetPinResult.originOsManual,
          WidgetPinResult.permissionRequired,
        ]) {
          tester.view.physicalSize = size;
          final a = _FakeActions(_perm())..pinResult = result;
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? appDarkTheme() : appLightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: TimetableWidgetSettingsPage(controller: _c, actions: a),
            ),
          );
          await tester.pumpAndSettle();
          expect(a.calls, isEmpty);
          expect(
            find.byKey(const Key('tt_settings_widget_guide')),
            findsNothing,
          );
          final pin = find.byKey(const Key('tt_settings_widget_pin'));
          await tester.ensureVisible(pin);
          await tester.pumpAndSettle();
          await tester.tap(pin);
          await tester.pumpAndSettle();
          expect(a.calls, ['pin:false']);
          expect(
            find.text(
              result == WidgetPinResult.permissionRequired
                  ? '允许添加桌面快捷方式'
                  : '打开原子组件',
            ),
            findsOneWidget,
          );
          final close = find.byKey(const Key('tt_widget_pin_guide_close'));
          final rect = tester.getRect(close);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
          await tester.tap(
            result == WidgetPinResult.permissionRequired
                ? find.text('暂不开启')
                : close,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });

  testWidgets('指引只展示此次选择的尺寸，并支持下拉关闭', (tester) async {
    final a = _FakeActions(_perm())..pinResult = WidgetPinResult.manual;
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2×2 当前与下一节'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_widget_pin')));
    await tester.pumpAndSettle();
    expect(find.text('添加「当前/下一节」'), findsOneWidget);
    expect(find.text('添加「今日课表」'), findsNothing);
    await tester.drag(find.byType(BottomSheet), const Offset(0, 700));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('保活引导页：品牌说明、强行停止与 7 天提示、电池优化按钮', (tester) async {
    final a = _FakeActions(_perm());
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_keepalive_entry')));
    await tester.pumpAndSettle();
    expect(find.text(TtSettingsText.keepAliveTitle), findsOneWidget);
    for (final (brand, _) in TtSettingsText.brandTips) {
      expect(find.text(brand), findsOneWidget, reason: brand);
    }
    // 品牌覆盖：小米 / 华为荣耀 / OPPO / vivo / 三星。
    final brands = TtSettingsText.brandTips.map((e) => e.$1).join();
    for (final b in ['小米', '华为', '荣耀', 'OPPO', 'vivo', '三星']) {
      expect(brands, contains(b));
    }
    expect(find.text('· ${TtSettingsText.forceStopWarning}'), findsOneWidget);
    expect(TtSettingsText.forceStopWarning, contains('强行停止'));
    expect(TtSettingsText.forceStopWarning, contains('提醒会失效'));
    expect(find.text('· ${TtSettingsText.sevenDayWarning}'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tt_keepalive_battery')));
    expect(a.calls.last, 'battery');
  });
}
