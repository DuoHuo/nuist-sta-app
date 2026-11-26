import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/theme_mode.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_lifecycle.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_service.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_timing.dart';
import 'package:nuist_sta_app/shell/home/home_page.dart';

Map<String, Object?> row(
  int start,
  int end, {
  String flag = '1',
  String weeks = '11',
}) => {
  'KCM': '测试实验课',
  'KCH': 'TEST-LAB',
  'KXH': '01',
  'SKXQ': 1,
  'KSJC': '$start',
  'JSJC': '$end',
  'SKZC': weeks,
  'SFSYK': flag,
  'SKJS': '教师甲',
  'JASMC': '测试楼',
};

Iterable<ImperativeRouteMatch> _imperativeMatches(
  List<RouteMatchBase> matches,
) sync* {
  for (final match in matches) {
    if (match is ShellRouteMatch) {
      yield* _imperativeMatches(match.matches);
    } else if (match is ImperativeRouteMatch) {
      yield match;
    }
  }
}

List<bool> _recordFrameworkBack(WidgetTester tester) {
  final requests = <bool>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  final previousLifecycle = tester.binding.lifecycleState;
  // 模拟 Activity 已恢复；Flutter 在未挂载／detached 状态不会向 Android 登记返回。
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
      requests.add(call.arguments as bool);
    }
    return null;
  });
  addTearDown(() {
    tester.binding.handleAppLifecycleStateChanged(
      previousLifecycle ?? AppLifecycleState.detached,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return requests;
}

class _FakeReachability implements NetworkReachability {
  _FakeReachability({required this.initial});

  final bool initial;
  final controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get onlineChanges => controller.stream;

  @override
  Future<bool> isOnline() async => initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ctl = TimetableController.instance;
  final originalBindingCheck = TimetableController.bindingCheck;
  final termStart = DateTime(2026, 8, 31);
  late Directory tmp;
  void load(List<Course> courses, {int count = 3}) => ctl.debugSetSnapshot(
    TimetableSnapshot(
      courses: courses,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: termStart,
        widgetCourseCount: count,
      ),
      syncedAt: termStart,
    ),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('timetable_device_');
    TimetableStore.debugDirectory = tmp;
    ctl.debugReset();
  });
  tearDown(() async {
    TimetableNotifyBridge.debugIsAndroid = null;
    TimetableController.bindingCheck = originalBindingCheck;
    TimetableStore.debugDirectory = null;
    ctl.debugReset();
    await tmp.delete(recursive: true);
  });

  test('逐条 SFSYK、相邻夜间连堂合并，周次不串联，单节独立不变', () {
    final courses = TimetableParser.parseKbRows([
      row(9, 10),
      row(11, 11, weeks: '10'),
      row(7, 8, flag: '0'),
    ]).courses;
    load(courses);
    final day = termStart;
    final items = ctl.coursesOnDate(day);
    expect(items.map((i) => (i.slot.startNode, i.slot.endNode)), [
      (7, 8),
      (9, 11),
    ]);
    final svc = TimetableNotifyService(controller: ctl);
    final classes = svc.classesOn(day);
    expect(classes.last.timeRange, '18:45-21:00');
    final alarms = planReminders(
      now: DateTime(2026, 8, 31, 18),
      leadMinutes: 15,
      days: 1,
      classesOn: svc.classesOn,
    );
    expect(alarms, hasLength(1));
    expect(alarms.single.fireAt, DateTime(2026, 8, 31, 18, 30));
    expect(classes.first.timeRange, '15:55-17:35');
    final records = ctl.cellsForDay(1, 1);
    final last = records.firstWhere((c) => c.slot.startNode == 11);
    expect(ctl.timeForSlot(last.course, last.slot, date: day), (
      start: '20:15',
      end: '21:00',
    ));
    expect(ctl.baseOccurrenceOf(last), isNotNull);
    expect(
      svc.classesOn(day.add(const Duration(days: 7))).last.timeRange,
      '18:45-20:15',
    );
    load(TimetableParser.parseKbRows([row(11, 11)]).courses);
    expect(svc.classesOn(day).single.timeRange, '20:35-21:20');
  });

  test('相邻记录先合并，大课间保留，理论记录不被实验标记污染', () {
    load(
      TimetableParser.parseKbRows([row(1, 2), row(3, 4), row(5, 6, flag: '0')])
          .courses,
    );
    final items = ctl.coursesOnDate(termStart);
    expect(items, hasLength(3));
    expect((items.first.slot.startNode, items.first.slot.endNode), (1, 2));
    final svc = TimetableNotifyService(controller: ctl);
    expect(svc.classesOn(termStart).map((c) => c.timeRange), [
      '08:00-09:30',
      '10:10-11:40',
      '13:45-15:25',
    ]);
    expect(
      ctl.todayCourses(now: DateTime(2026, 8, 31, 9, 45))[1].status,
      TodayCourseStatus.upcoming,
    );
    final alarms = planReminders(
      now: DateTime(2026, 8, 31, 9, 45),
      leadMinutes: 15,
      days: 1,
      classesOn: svc.classesOn,
    );
    expect(alarms.first.fireAt, DateTime(2026, 8, 31, 9, 55));
    final segs = resolveTimingSegments(
      periods: ctl.periods,
      startNode: 1,
      endNode: 4,
      kind: CourseTimingKind.lab,
    );
    expect(segs.map((s) => s.label), ['08:00-09:30', '10:10-11:40']);
    expect(
      ctl.todayCourses(now: DateTime(2026, 8, 31, 11, 45)).first.status,
      TodayCourseStatus.done,
    );
  });

  testWidgets(
    '小组件冷热启动路由（?open=widgetSettings/?focus=tomorrow/防叠页）、未知 URI 与 Android 返回',
    (tester) async {
      final frameworkBack = _recordFrameworkBack(tester);
      final messenger = tester.binding.defaultBinaryMessenger;
      const channel = MethodChannel('dev.duohuo.nuist_sta_app/notify_widget');
      TimetableController.bindingCheck = () async => false;

      // 1. 冷启动 ?open=widgetSettings 直达当周小组件设置，依次退回课表与首页
      const settingsRoute = '/apps/timetable?open=widgetSettings';
      tester.platformDispatcher.defaultRouteNameTestValue = settingsRoute;
      TimetableNotifyBridge.debugIsAndroid = true;
      final launch1 = Completer<String?>();
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'takeLaunchRoute' ? launch1.future : null,
      );
      addTearDown(() {
        if (!launch1.isCompleted) launch1.complete(null);
        messenger.setMockMethodCallHandler(channel, null);
        tester.platformDispatcher.clearDefaultRouteNameTestValue();
      });
      load(TimetableParser.parseKbRows([row(1, 2)]).courses);
      await tester.pumpWidget(const NuistApp());
      await tester.pumpAndSettle();
      final settings = find.byType(TimetableWidgetSettingsPage);
      expect(
        tester.widget<TimetableWidgetSettingsPage>(settings).initialSize,
        WidgetPinSize.week,
      );
      launch1.complete(settingsRoute);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(settings)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(TimetablePage), findsOneWidget);
      Navigator.of(tester.element(find.byType(TimetablePage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // 2. 冷启动 /apps/timetable 首帧不等待回执且保留首页栈，Android 返回手势可取消与完成；热启动重复/tomorrow 防叠页
      ctl.debugReset();
      load(TimetableParser.parseKbRows([row(1, 2)]).courses);
      AppThemeMode.instance.value = ThemeMode.dark;
      addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
      tester.platformDispatcher.defaultRouteNameTestValue = '/apps/timetable';
      final launch2 = Completer<String?>();
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'takeLaunchRoute' ? launch2.future : null,
      );
      addTearDown(() {
        if (!launch2.isCompleted) launch2.complete(null);
      });
      await tester.pumpWidget(const NuistApp());
      expect(launch2.isCompleted, isFalse);
      expect(find.byType(TimetablePage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
      launch2.complete('/apps/timetable');
      await tester.pumpAndSettle();
      final appRouter =
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;
      expect(
        _imperativeMatches(
          appRouter.routerDelegate.currentConfiguration.matches,
        ),
        hasLength(1),
      );

      Future<void> gesture(String method, [double progress = 0]) async {
        await messenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'touchOffset': [5.0, 300.0],
              'progress': progress,
              'swipeEdge': 0,
            }),
          ),
          (_) {},
        );
        await tester.pump();
      }

      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', .4);
      await gesture('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(find.byType(TimetablePage), findsOneWidget);
      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', .4);
      await gesture('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      expect(frameworkBack.last, isFalse);

      // ?focus=tomorrow 热启动打开、翻页后再次推送仍重新聚焦而不叠页
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final tomorrowMon = tomorrow.subtract(
        Duration(days: tomorrow.weekday - DateTime.monday),
      );
      ctl.debugSetSnapshot(
        TimetableSnapshot(
          courses: TimetableParser.parseKbRows([row(1, 2, weeks: '11111')])
              .courses,
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: tomorrowMon.subtract(const Duration(days: 7)),
          ),
          syncedAt: now,
        ),
      );
      Future<void> openRoute(String route) async {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('openRoute', route),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await openRoute('/apps/timetable?focus=tomorrow');
      expect(ctl.viewingWeek, 2);
      final directRoute =
          ModalRoute.of(tester.element(find.byType(TimetablePage)))!
              as PageRoute;
      expect(directRoute.animation!.value, 1.0);
      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', .4);
      expect(directRoute.animation!.value, closeTo(.6, .001));
      await messenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('cancelBackGesture', {
            'touchOffset': [5.0, 300.0],
            'progress': 0.4,
            'swipeEdge': 0,
          }),
        ),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(directRoute.animation!.value, lessThan(1.0));
      await tester.pumpAndSettle();
      expect(directRoute.animation!.value, 1.0);
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(ctl.viewingWeek, 3);
      await openRoute('/apps/timetable?focus=tomorrow');
      expect(ctl.viewingWeek, 2);
      expect(
        _imperativeMatches(
          appRouter.routerDelegate.currentConfiguration.matches,
        ),
        hasLength(1),
      );

      // 3. 未知 URI 与自定义 scheme 安全回落首页
      appRouter.go('nuist://timetable/today?focus=tomorrow');
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      appRouter.go('/nonexistent/invalid/path?foo=bar');
      await tester.pumpAndSettle();
      expect(find.text('页面不存在'), findsOneWidget);
      await tester.tap(find.text('返回首页'));
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('NetworkRestoreDetector：只有无网 → 有网算恢复', () {
    final d = NetworkRestoreDetector();
    expect(d.update(true), isFalse);
    expect(d.update(true), isFalse);
    expect(d.update(false), isFalse);
    expect(d.update(true), isTrue);
    expect(d.update(true), isFalse);
    final s = NetworkRestoreDetector()..seed(false);
    expect(s.update(true), isTrue);
  });

  testWidgets('TimetableLifecycleScope 生命周期与断网恢复触发，以及实验课网格隐时间/详情显时间', (
    tester,
  ) async {
    // 1. 生命周期与网络恢复监听（含一开始就在线不误触，卸载取消监听）
    final net = _FakeReachability(initial: false);
    var start = 0, resumed = 0, restored = 0;
    await tester.pumpWidget(
      TimetableLifecycleScope(
        reachability: net,
        onAppStart: () async => ++start > 0,
        onAppResumed: () async => ++resumed > 0,
        onNetworkRestored: () async => ++restored > 0,
        child: const SizedBox(),
      ),
    );
    await tester.pump();
    expect(start, 1);
    expect(net.controller.hasListener, isTrue);
    net.controller.add(true);
    await tester.pump();
    expect(restored, 1);
    net.controller.add(true);
    await tester.pump();
    expect(restored, 1);
    net.controller.add(false);
    await tester.pump();
    net.controller.add(true);
    await tester.pump();
    expect(restored, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(resumed, 1);
    await tester.pumpWidget(const SizedBox());
    expect(net.controller.hasListener, isFalse);

    final onlineNet = _FakeReachability(initial: true);
    var spuriousRestored = 0;
    await tester.pumpWidget(
      TimetableLifecycleScope(
        reachability: onlineNet,
        onAppStart: () async => false,
        onAppResumed: () async => false,
        onNetworkRestored: () async => ++spuriousRestored > 0,
        child: const SizedBox(),
      ),
    );
    await tester.pump();
    onlineNet.controller.add(true);
    await tester.pump();
    expect(spuriousRestored, 0);

    // 2. 周格不显示实际时刻，详情保留实际时刻
    load(TimetableParser.parseKbRows([row(1, 2)]).courses);
    final cell = ctl.cellsForDay(1, 1).single;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 180,
            child: CourseCell(
              cell: cell,
              controller: ctl,
              width: 200,
              height: 180,
              radius: 4,
            ),
          ),
        ),
      ),
    );
    expect(find.text('08:00–09:30'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseDetailSheet(cell: cell, controller: ctl),
        ),
      ),
    );
    expect(find.textContaining('08:00–09:30'), findsOneWidget);
  });
}
