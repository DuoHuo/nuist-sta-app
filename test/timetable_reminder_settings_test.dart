import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/ui/miuix_dialog.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_color_picker.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;
const _saveError = '课表保存失败，请检查设备剩余空间后重试';
const _nextDayChannel = MethodChannel('nuist/timetable_next_day');

class _FakeActions extends ReminderActions {
  _FakeActions(this.perm) : super(controller: _c);

  NotifyPermissionStatus perm;
  final calls = <String>[];
  WidgetPinResult pinResult = WidgetPinResult.requested;
  Future<void>? pendingSave;
  bool saving = false;

  Future<void> _saveSettings(TimetableSettings settings) {
    saving = true;
    return pendingSave = _c
        .updateSettings(settings)
        .whenComplete(() => saving = false);
  }

  @override
  Future<WidgetPinResult> pinWidget({required WidgetPinSize size}) async {
    calls.add('pin:${size.name}');
    return pinResult;
  }

  @override
  Future<NotifyPermissionStatus> setReminderEnabled(bool enabled) async {
    calls.add('enabled:$enabled');
    await _saveSettings(_c.settings.copyWith(reminderEnabled: enabled));
    return perm;
  }

  @override
  Future<void> setReminderLeadMinutes(int minutes) async {
    calls.add('lead:$minutes');
    await _saveSettings(_c.settings.copyWith(reminderLeadMinutes: minutes));
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

class _FailingReminderActions extends ReminderActions {
  @override
  Future<NotifyPermissionStatus> permissionStatus() async =>
      NotifyPermissionStatus.unsupported;

  @override
  Future<NotifyPermissionStatus> setReminderEnabled(bool enabled) async {
    throw const TimetablePersistenceException();
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
  TestWidgetsFlutterBinding.ensureInitialized();
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nextDayChannel, null);
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
        home: MiuixPopupHostScope(
          child: TimetableSettingsPage(controller: _c, reminderActions: a),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> waitSaved(WidgetTester tester, _FakeActions actions) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    do {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    } while (actions.saving && DateTime.now().isBefore(deadline));
    expect(actions.saving, isFalse);
    await actions.pendingSave;
    await tester.pump();
  }

  bool sw(WidgetTester tester, String key) => tester
      .widget<Switch>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(Switch),
        ),
      )
      .value;

  test('提醒入口及非档位提前量与权限文案计算', () {
    expect(kShowReminderSettings, isTrue);
    expect(kReminderLeadChoices, [5, 10, 15, 30]);
    expect(displayReminderLead(20), 15);
    expect(displayReminderLead(30), 30);
    expect(
      reminderPermissionHint(
        _perm(notif: true, exact: false),
        false,
        nextDayEnabled: true,
      ),
      isNull,
    );
    expect(
      reminderPermissionHint(
        _perm(notif: false, exact: true),
        false,
        nextDayEnabled: true,
      ),
      TtSettingsText.permissionNotification,
    );
  });

  testWidgets('上课提醒开关、提前量设置与通知/闹钟权限被拒引导（含不支持平台隐藏）', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      // 不支持的平台不显示权限提示；首次开启弹出一次提醒说明
      await pump(tester, _FakeActions(NotifyPermissionStatus.unsupported));
      await tester.tap(find.byKey(const Key('tt_settings_reminder')));
      await settleIo(tester);
      expect(
        find.byKey(const Key('tt_settings_reminder_permission')),
        findsNothing,
      );
      expect(find.text(TtSettingsText.reminderIntro), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // 正常权限：切换开关与提前 30 分钟
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        ),
        viewingWeek: 7,
      );
      final a = _FakeActions(_perm());
      await pump(tester, a);
      await tester.tap(find.byKey(const Key('tt_settings_reminder')));
      await waitSaved(tester, a);
      expect(a.calls, ['enabled:true']);
      expect(sw(tester, 'tt_settings_reminder'), isTrue);
      await tester.ensureVisible(
        find.byKey(const Key('tt_settings_reminder_lead')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tt_settings_reminder_lead')));
      await tester.pumpAndSettle();
      final min30 = find.descendant(
        of: find.byType(MiuixPopupHost),
        matching: find.text('30 分钟'),
      );
      await tester.tap(min30);
      await tester.pumpAndSettle();
      await waitSaved(tester, a);
      expect(a.calls.last, 'lead:30');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // 精确闹钟权限缺失：提示跳转，回到前台自动刷新消失
      final exactDenied = _FakeActions(_perm(exact: false));
      await pump(tester, exactDenied);
      expect(find.text(TtSettingsText.permissionExactAlarm), findsOneWidget);
      await tester.tap(find.byKey(const Key('tt_settings_reminder_goto')));
      expect(exactDenied.calls.last, 'exact');
      exactDenied.perm = _perm();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tt_settings_reminder_permission')),
        findsNothing,
      );
      expect(ui.Tristate.isTrue, isNotNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('桌面小组件预览尺寸/开关切换、添加引导关闭及保活引导页', (tester) async {
    final a = _FakeActions(_perm())..pinResult = WidgetPinResult.manual;
    await pump(tester, a);
    await tester.tap(find.byKey(const Key('tt_settings_widget_entry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tt_widget_preview_4x2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tt_settings_widgetShowPeriod')));
    await settleIo(tester);
    expect(_c.settings.widgetShowPeriod, isFalse);

    await tester.tap(find.text('2×2 日课表'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_widget_preview_2x2')), findsOneWidget);
    expect(
      find.byKey(const Key('tt_settings_widgetCourseCount')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('tt_settings_widget_pin')));
    await tester.pumpAndSettle();
    expect(find.text('添加「当前/下一节」'), findsOneWidget);
    await tester.drag(find.byType(BottomSheet), const Offset(0, 700));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);

    // 重置树回到设置页进入保活引导页
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pump(tester, a);
    await tester.ensureVisible(
      find.byKey(const Key('tt_settings_keepalive_entry')),
    );
    await tester.tap(find.byKey(const Key('tt_settings_keepalive_entry')));
    await tester.pumpAndSettle();
    expect(find.text(TtSettingsText.keepAliveTitle), findsOneWidget);
    expect(find.text('· ${TtSettingsText.forceStopWarning}'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tt_keepalive_battery')));
    expect(a.calls.last, 'battery');
  });

  testWidgets('存储失败时提醒/次日时间/外观与恢复教务回滚且支持重试，格高 44 UI 钳制 52', (tester) async {
    final blockedFile = File('${tmp.path}/unavailable')
      ..writeAsStringSync('blocked');
    final blocked = Directory(blockedFile.path);
    var permissionRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nextDayChannel, (call) async {
          if (call.method == 'requestPermission') {
            permissionRequests++;
            return true;
          }
          return null;
        });

    // 上课提醒保存失败被接住且不显示说明
    await tester.pumpWidget(
      MaterialApp(
        home: MiuixPopupHostScope(
          child: TimetableSettingsPage(
            controller: _c,
            reminderActions: _FailingReminderActions(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_reminder')));
    await settleIo(tester);
    expect(find.text(_saveError), findsOneWidget);
    expect(_c.settings.reminderEnabled, isFalse);

    // 次日提醒时间保存失败保弹窗，存储恢复后重试成功才申请权限
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    TimetableStore.debugDirectory = blocked;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MiuixPopupHostScope(
          child: TimetableSettingsPage(controller: _c, showReminderCard: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('tt_settings_next_day_time')),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(
      find.byKey(const Key('tt_settings_next_day_time')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_next_day_time')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('21:00'));
    await settleIo(tester);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(_saveError),
      ),
      findsOneWidget,
    );
    expect(permissionRequests, 0);

    TimetableStore.debugDirectory = tmp;
    await tester.tap(find.text('21:00'));
    await settleIo(tester);
    expect(_c.settings.nextDayReminderMinute, 21 * 60);
    expect(permissionRequests, 1);

    // 磁盘存 periodHeight=44 → 启动钳制为 52，UI 展示 52 且不改写磁盘原值 44
    final settingsFile = File('${tmp.path}/settings.json');
    settingsFile.writeAsStringSync(
      jsonEncode({...const TimetableSettings().toJson(), 'periodHeight': 44}),
    );
    TimetableController.bindingCheck = () async => false;
    _c.debugReset();
    await tester.runAsync(_c.ensureStarted);
    expect(_c.settings.periodHeight, 52);
    await tester.pumpWidget(
      MaterialApp(home: TimetableAppearancePage(controller: _c)),
    );
    await tester.pump();
    final slider = find.byKey(const Key('tt_settings_period_height'));
    await tester.scrollUntilVisible(
      slider,
      200,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('tt_settings_period_height_value')),
          )
          .data,
      '52',
    );
    expect(
      (jsonDecode(settingsFile.readAsStringSync()) as Map)['periodHeight'],
      44,
    );
  });

  testWidgets('外观考试颜色与课程全局颜色保存失败在面板内报错，恢复存储后可重试', (tester) async {
    final blockedFile = File('${tmp.path}/unavailable')
      ..writeAsStringSync('blocked');
    final blocked = Directory(blockedFile.path);
    TimetableStore.debugDirectory = blocked;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MiuixPopupHostScope(
          child: TimetableAppearancePage(controller: _c),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('tt_settings_exam_color')),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.byKey(const Key('tt_settings_exam_color')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_settings_exam_color')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '386F95');
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await settleIo(tester);

    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(_saveError),
      ),
      findsOneWidget,
    );
    expect(_c.settings.examColor, kDefaultExamColor);

    TimetableStore.debugDirectory = tmp;
    await tester.ensureVisible(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await settleIo(tester);
    expect(find.byKey(const Key('tt_color_hex')), findsNothing);
    expect(_c.settings.examColor, 0xFF386F95);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();

    // 课程全局颜色保存失败回滚
    TimetableStore.debugDirectory = blocked;
    const course = Course(
      id: 'test-course',
      name: '测试课程',
      slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MiuixPopupHostScope(
          child: Scaffold(
            body: CourseColorRow(controller: _c, course: course),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course_detail_color')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '386F95');
    await tester.ensureVisible(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await settleIo(tester);
    expect(find.text(_saveError), findsOneWidget);
    expect(_c.userColorOf(course), isNull);
  });
}
