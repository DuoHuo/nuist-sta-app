import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_color_picker.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _controller = TimetableController.instance;
const _saveError = '课表保存失败，请检查设备剩余空间后重试';
const _nextDayChannel = MethodChannel('nuist/timetable_next_day');

class _FailingReminderActions extends ReminderActions {
  @override
  Future<NotifyPermissionStatus> permissionStatus() async =>
      NotifyPermissionStatus.unsupported;

  @override
  Future<NotifyPermissionStatus> setReminderEnabled(bool enabled) async {
    throw const TimetablePersistenceException();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late Directory blocked;
  var permissionRequests = 0;

  void setSnapshot({
    TimetableSettings settings = const TimetableSettings(),
    List<Course> courses = const [],
  }) {
    _controller.debugSetSnapshot(
      TimetableSnapshot(
        settings: settings,
        courses: courses,
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: 1,
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_settings_feedback');
    final file = File('${tmp.path}/unavailable')..writeAsStringSync('blocked');
    blocked = Directory(file.path);
    TimetableStore.debugDirectory = blocked;
    _controller.debugReset();
    setSnapshot();
    permissionRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nextDayChannel, (call) async {
          if (call.method == 'requestPermission') {
            permissionRequests++;
            return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nextDayChannel, null);
    TimetableStore.debugDirectory = null;
    _controller.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester, Widget page, {Size? size}) async {
    tester.view.physicalSize = size == null ? const Size(1080, 7000) : size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();
  }

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final target = find.byKey(Key(key));
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        240,
        scrollable: find.byType(Scrollable).last,
      );
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
  }

  void expectVisibleModalError(WidgetTester tester, Finder modal) {
    final error = find.descendant(of: modal, matching: find.text(_saveError));
    expect(error.hitTestable(), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final rect = tester.getRect(error);
    final visibleBottom =
        (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
        tester.view.devicePixelRatio;
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(visibleBottom));
  }

  testWidgets('设置保存失败提示并恢复开关，恢复存储后可直接重试', (tester) async {
    await pumpPage(
      tester,
      TimetableSettingsPage(controller: _controller, showReminderCard: false),
    );
    await tapKey(tester, 'tt_settings_show_tomorrow');
    await settleIo(tester);
    expect(find.text(_saveError), findsOneWidget);
    expect(_controller.settings.showTomorrowOnHome, isTrue);

    TimetableStore.debugDirectory = tmp;
    await tapKey(tester, 'tt_settings_show_tomorrow');
    await settleIo(tester);
    expect(_controller.settings.showTomorrowOnHome, isFalse);
    expect(find.byType(TimetableSettingsPage), findsOneWidget);
  });

  testWidgets('次日提醒开关保存失败不会继续请求权限', (tester) async {
    setSnapshot(
      settings: const TimetableSettings(nextDayReminderEnabled: false),
    );
    await pumpPage(
      tester,
      TimetableSettingsPage(controller: _controller, showReminderCard: false),
    );
    await tapKey(tester, 'tt_settings_next_day_reminder');
    await settleIo(tester);

    expect(find.text(_saveError), findsOneWidget);
    expect(_controller.settings.nextDayReminderEnabled, isFalse);
    expect(permissionRequests, 0);
  });

  testWidgets('次日提醒时间保存失败保留选择面板，重试成功才关闭并申请权限', (tester) async {
    setSnapshot(
      settings: const TimetableSettings(nextDayReminderEnabled: true),
    );
    await pumpPage(
      tester,
      TimetableSettingsPage(controller: _controller, showReminderCard: false),
      size: const Size(390, 844),
    );
    await tapKey(tester, 'tt_settings_next_day_time');
    await tester.pumpAndSettle();
    await tester.tap(find.text('21:00'));
    await settleIo(tester);

    expect(find.text('21:00'), findsOneWidget);
    expectVisibleModalError(tester, find.byType(BottomSheet));
    expect(_controller.settings.nextDayReminderMinute, 22 * 60);
    expect(permissionRequests, 0);

    TimetableStore.debugDirectory = tmp;
    await tester.tap(find.text('21:00'));
    await settleIo(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(_controller.settings.nextDayReminderMinute, 21 * 60);
    expect(permissionRequests, 1);
  });

  testWidgets('外观实时设置失败后恢复原值，页面继续可操作', (tester) async {
    await pumpPage(tester, TimetableAppearancePage(controller: _controller));
    await tapKey(tester, 'tt_settings_saturday');
    await settleIo(tester);

    expect(find.text(_saveError), findsOneWidget);
    expect(_controller.settings.showSaturday, isTrue);
    expect(find.byType(TimetableAppearancePage), findsOneWidget);

    TimetableStore.debugDirectory = tmp;
    await tapKey(tester, 'tt_settings_saturday');
    await settleIo(tester);
    expect(_controller.settings.showSaturday, isFalse);
  });

  testWidgets('考试颜色保存失败保留输入，重试成功后关闭选色面板', (tester) async {
    await pumpPage(
      tester,
      TimetableAppearancePage(controller: _controller),
      size: const Size(390, 844),
    );
    await tapKey(tester, 'tt_settings_exam_color');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '386F95');
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await settleIo(tester);

    expectVisibleModalError(tester, find.byType(BottomSheet));
    expect(_controller.settings.examColor, kDefaultExamColor);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tt_color_hex')))
          .controller!
          .text,
      '386F95',
    );

    TimetableStore.debugDirectory = tmp;
    await tester.ensureVisible(find.byKey(const Key('tt_color_custom_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await settleIo(tester);
    expect(find.byKey(const Key('tt_color_hex')), findsNothing);
    expect(_controller.settings.examColor, 0xFF386F95);
  });

  testWidgets('一周起始保存失败在对话框内提示，重试成功才关闭', (tester) async {
    await pumpPage(
      tester,
      TimetableAppearancePage(controller: _controller),
      size: const Size(390, 844),
    );
    await tapKey(tester, 'tt_settings_week_start');
    await tester.pumpAndSettle();
    final sunday = find.descendant(
      of: find.byType(SimpleDialog),
      matching: find.text('周日'),
    );
    await tester.tap(sunday);
    await settleIo(tester);

    expectVisibleModalError(tester, find.byType(SimpleDialog));
    expect(_controller.settings.weekStartsOnMonday, isTrue);

    TimetableStore.debugDirectory = tmp;
    await tester.tap(sunday);
    await settleIo(tester);
    expect(find.byType(SimpleDialog), findsNothing);
    expect(_controller.settings.weekStartsOnMonday, isFalse);
  });

  testWidgets('恢复教务课程失败在确认框内提示，重试成功后关闭', (tester) async {
    setSnapshot(
      courses: [
        Course(
          id: 'test-course',
          name: '测试课程',
          source: CourseSource.jwxt,
          slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1')],
        ),
      ],
    );
    TimetableStore.debugDirectory = tmp;
    await tester.runAsync(
      () => _controller.editJwxtCourse('test-course', note: '测试备注'),
    );
    TimetableStore.debugDirectory = blocked;
    await pumpPage(
      tester,
      TimetableManagementPage(controller: _controller),
      size: const Size(390, 844),
    );
    await tapKey(tester, 'tt_settings_restore_jwxt');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tt_restore_jwxt_confirm')));
    await settleIo(tester);

    expectVisibleModalError(tester, find.byType(AlertDialog));
    expect(_controller.isJwxtOverridden(courseId: 'test-course'), isTrue);

    TimetableStore.debugDirectory = tmp;
    await tester.tap(find.byKey(const Key('tt_restore_jwxt_confirm')));
    await settleIo(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(_controller.isJwxtOverridden(courseId: 'test-course'), isFalse);
    expect(find.text('已恢复教务课程'), findsOneWidget);
  });

  testWidgets('上课提醒保存失败被设置页接住，不显示启用说明', (tester) async {
    await pumpPage(
      tester,
      TimetableSettingsPage(
        controller: _controller,
        reminderActions: _FailingReminderActions(),
      ),
    );
    await tapKey(tester, 'tt_settings_reminder');
    await settleIo(tester);

    expect(find.text(_saveError), findsOneWidget);
    expect(find.text(TtSettingsText.reminderIntro), findsNothing);
    expect(_controller.settings.reminderEnabled, isFalse);
  });

  testWidgets('课程全局颜色保存失败有安全提示，详情按钮继续保留', (tester) async {
    final course = Course(
      id: 'test-course',
      name: '测试课程',
      slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1')],
    );
    await pumpPage(
      tester,
      Scaffold(
        body: CourseColorRow(controller: _controller, course: course),
      ),
    );
    await tapKey(tester, 'course_detail_color');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tt_color_hex')), '386F95');
    await tester.tap(find.byKey(const Key('tt_color_custom_apply')));
    await settleIo(tester);

    expect(find.text(_saveError), findsOneWidget);
    expect(find.byKey(const Key('course_detail_color')), findsOneWidget);
    expect(_controller.userColorOf(course), isNull);
  });
}
