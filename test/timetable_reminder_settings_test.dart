// 设置页「提醒」「小组件」卡片与后台运行引导页（接口文档 §1–§2）。全部为构造数据。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  @override
  Future<NotifyPermissionStatus> setReminderEnabled(bool enabled) async {
    calls.add('enabled:$enabled');
    unawaited(
      _c.updateSettings(_c.settings.copyWith(reminderEnabled: enabled)),
    );
    return perm;
  }

  @override
  Future<void> setReminderLeadMinutes(int minutes) async {
    calls.add('lead:$minutes');
    unawaited(
      _c.updateSettings(_c.settings.copyWith(reminderLeadMinutes: minutes)),
    );
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
    final a = _FakeActions(_perm());
    await pump(tester, a);
    expect(find.text(TtSettingsText.reminderSevenDayHint), findsOneWidget);
    expect(sw(tester, 'tt_settings_reminder'), isFalse);
    await tester.tap(find.byKey(const Key('tt_settings_reminder')));
    await tester.pumpAndSettle();
    expect(a.calls, ['enabled:true']);
    expect(sw(tester, 'tt_settings_reminder'), isTrue);
    final lead = find.byKey(const Key('tt_settings_reminder_lead'));
    Finder seg(int m) =>
        find.descendant(of: lead, matching: find.byKey(ValueKey('seg_$m')));
    for (final m in kReminderLeadChoices) {
      expect(seg(m), findsOneWidget);
    }
    expect(
      find.descendant(of: lead, matching: find.text('20 分钟')),
      findsNothing,
    );
    expect(tester.widget<ChoiceChip>(seg(15)).selected, isTrue);
    await tester.tap(seg(30));
    await tester.pumpAndSettle();
    expect(a.calls.last, 'lead:30');
    // 提醒卡片底部是 7 天页脚。
    expect(
      tester.getTopLeft(find.text(TtSettingsText.reminderSevenDayHint)).dy,
      greaterThan(
        tester
            .getTopLeft(find.byKey(const Key('tt_settings_keepalive_entry')))
            .dy,
      ),
    );
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
    await tester.pumpAndSettle();
    expect(find.text(TtSettingsText.permissionNotification), findsOneWidget);
    await tester.tap(find.byKey(const Key('tt_settings_reminder_goto')));
    expect(a.calls.last, 'notif');
  });

  testWidgets('精确闹钟被拒：提示 + 去设置打开闹钟授权页；回前台刷新', (tester) async {
    final a = _FakeActions(_perm(exact: false));
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_reminder')));
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('tt_settings_reminder_permission')),
      findsNothing,
    );
  });

  testWidgets('小组件卡片：5 个开关默认全开、每行带说明，可切换', (tester) async {
    final a = _FakeActions(_perm());
    await pump(tester, a);
    expect(find.text(TtSettingsText.widgetCard), findsOneWidget);
    expect(WidgetDisplayOption.values.map((o) => o.field), [
      'widgetShowTeacher',
      'widgetShowLocation',
      'widgetShowPeriod',
      'widgetShowCountdown',
      'widgetShowCount',
    ]);
    expect(
      WidgetDisplayOption.countdown.subtitle,
      TtSettingsText.showCountdownSub,
    );
    expect(WidgetDisplayOption.count.subtitle, TtSettingsText.showCountSub);
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
    final a = _FakeActions(_perm());
    await pump(tester, a);
    final row = find.byKey(const Key('tt_settings_widgetCourseCount'));
    expect(
      find.descendant(of: row, matching: find.text(TtSettingsText.courseCount)),
      findsOneWidget,
    );
    Finder seg(int n) => find.descendant(
      of: row,
      matching: find.byKey(ValueKey('seg_${TtSettingsText.courses(n)}')),
    );
    for (final n in kWidgetCourseCountOptions) {
      expect(seg(n), findsOneWidget);
    }
    expect(tester.widget<ChoiceChip>(seg(2)).selected, isTrue);
    await tester.tap(seg(3));
    await settleIo(tester);
    expect(_c.settings.widgetCourseCount, 3);
    expect(tester.widget<ChoiceChip>(seg(3)).selected, isTrue);
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
