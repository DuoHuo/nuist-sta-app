import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/app.dart';
import 'package:nuist_sta_app/core/theme_mode.dart';
import 'package:nuist_sta_app/shell/home/home_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_bridge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_plan.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_notify_service.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_timing.dart';

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

  testWidgets('周格不显示实际时刻，详情保留时刻并能定位原始记录', (tester) async {
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

  testWidgets('小组件重复打开课表不叠页，从详情点击复用已有课表', (tester) async {
    load(TimetableParser.parseKbRows([row(1, 2)]).courses);
    await tester.pumpWidget(const NuistApp());
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(MaterialApp));
    final router =
        (tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
            as GoRouter);
    Future<void> open(String route) async {
      final data = const StandardMethodCodec().encodeMethodCall(
        MethodCall('openRoute', route),
      );
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'dev.duohuo.nuist_sta_app/notify_widget',
        data,
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await open('/apps/timetable');
    await open('/apps/timetable');
    expect(
      _imperativeMatches(router.routerDelegate.currentConfiguration.matches),
      hasLength(1),
    );
    router.push('/settings');
    await tester.pumpAndSettle();
    await open('/apps/timetable');
    expect(
      _imperativeMatches(router.routerDelegate.currentConfiguration.matches),
      hasLength(1),
    );
    await open('/apps/timetable?focus=tomorrow');
    expect(
      _imperativeMatches(router.routerDelegate.currentConfiguration.matches),
      hasLength(1),
    );
    router.pop();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(context.mounted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('冷小组件初始路由首帧显示课表且不等待平台回执，${theme.name} 保留首页返回栈', (tester) async {
      final frameworkBack = _recordFrameworkBack(tester);
      AppThemeMode.instance.value = theme;
      tester.platformDispatcher.defaultRouteNameTestValue = '/apps/timetable';
      TimetableNotifyBridge.debugIsAndroid = true;
      const channel = MethodChannel('dev.duohuo.nuist_sta_app/notify_widget');
      final messenger = tester.binding.defaultBinaryMessenger;
      final launch = Completer<String?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        return call.method == 'takeLaunchRoute' ? launch.future : null;
      });
      addTearDown(() {
        if (!launch.isCompleted) launch.complete(null);
        messenger.setMockMethodCallHandler(channel, null);
        tester.platformDispatcher.clearDefaultRouteNameTestValue();
        AppThemeMode.instance.value = ThemeMode.system;
      });
      load(TimetableParser.parseKbRows([row(1, 2)]).courses);

      await tester.pumpWidget(const NuistApp());
      expect(launch.isCompleted, isFalse);
      expect(find.byType(TimetablePage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing, reason: '首页不能先暴露一帧再跳课表');
      final router =
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;
      expect(router.canPop(), isTrue, reason: '可信初始路由也应保留首页作为返回落点');
      final route =
          ModalRoute.of(tester.element(find.byType(TimetablePage)))!
              as PageRoute;
      expect(route.transitionDuration, Duration.zero);
      expect(route.animation!.value, 1);
      expect(route.popGestureEnabled, isTrue);
      expect(
        frameworkBack.last,
        isTrue,
        reason: 'Android 必须先把返回交给 Flutter，才能回到首页',
      );

      launch.complete('/apps/timetable');
      await tester.pumpAndSettle();
      expect(
        _imperativeMatches(router.routerDelegate.currentConfiguration.matches),
        hasLength(1),
        reason: '迟到的平台回执不能重复压入课表',
      );
      router.pop();
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
      expect(find.byType(HomePage), findsOneWidget);
      expect(frameworkBack.last, isFalse, reason: '回到根页后应恢复系统退出');
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('冷启动取走小组件路由直接显示，${theme.name} 取消返回保留课程且宫格仍有动画', (tester) async {
      final frameworkBack = _recordFrameworkBack(tester);
      AppThemeMode.instance.value = theme;
      addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
      TimetableNotifyBridge.debugIsAndroid = true;
      const channel = MethodChannel('dev.duohuo.nuist_sta_app/notify_widget');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var launches = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takeLaunchRoute') {
          launches++;
          return '/apps/timetable';
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      load(TimetableParser.parseKbRows([row(1, 2)]).courses);
      await tester.pumpWidget(const NuistApp());
      await tester.pumpAndSettle();
      expect(launches, 1);
      final router =
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;
      final context = tester.element(find.byType(TimetablePage));
      final route = ModalRoute.of(context)! as PageRoute;
      expect(route.transitionDuration, Duration.zero);
      expect(route.animation!.value, 1);
      expect(route.popGestureEnabled, isTrue);
      expect(frameworkBack.last, isTrue, reason: '隐藏学习分支不能取消课表的系统返回登记');
      expect(
        _imperativeMatches(router.routerDelegate.currentConfiguration.matches),
        hasLength(1),
      );
      Future<void> gesture(String method, [double progress = 0]) async {
        if (method == 'startBackGesture') {
          expect(
            frameworkBack.last,
            isTrue,
            reason: '平台未登记时 Android 不会发送页面返回手势',
          );
        }
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
      expect(route.animation!.value, closeTo(.6, .001));
      await gesture('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(route.isCurrent, isTrue);
      expect(find.byType(TimetablePage), findsOneWidget);
      expect(frameworkBack.last, isTrue);
      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', .4);
      await gesture('commitBackGesture');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
      expect(find.byType(HomePage), findsOneWidget);
      expect(frameworkBack.last, isFalse);
      await tester.ensureVisible(find.text('课表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('课表'));
      await tester.pumpAndSettle();
      final ordinary =
          ModalRoute.of(tester.element(find.byType(TimetablePage)))!
              as PageRoute;
      expect(ordinary.transitionDuration, isNot(Duration.zero));
      expect(ordinary.popGestureEnabled, isTrue);
      expect(frameworkBack.last, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('小组件直接进入课表不播放入场动画，${theme.name} 仍支持返回取消和完成', (tester) async {
      final frameworkBack = _recordFrameworkBack(tester);
      AppThemeMode.instance.value = theme;
      addTearDown(() => AppThemeMode.instance.value = ThemeMode.system);
      load(TimetableParser.parseKbRows([row(1, 2)]).courses);
      await tester.pumpWidget(const NuistApp());
      await tester.pumpAndSettle();
      final messenger = tester.binding.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'dev.duohuo.nuist_sta_app/notify_widget',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('openRoute', '/apps/timetable'),
        ),
        (_) {},
      );
      await tester.pump();
      await tester.pump();
      final context = tester.element(find.byType(TimetablePage));
      final route = ModalRoute.of(context)! as PageRoute;
      expect(route.transitionDuration, Duration.zero);
      expect(route.animation!.value, 1);
      expect(route.popGestureEnabled, isTrue);
      expect(frameworkBack.last, isTrue, reason: '热启动课表也必须保持平台返回登记');
      Future<void> gesture(String method, [double progress = 0]) async {
        if (method == 'startBackGesture') {
          expect(
            frameworkBack.last,
            isTrue,
            reason: '平台未登记时 Android 不会发送页面返回手势',
          );
        }
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
      await gesture('updateBackGestureProgress', 0.4);
      expect(route.animation!.value, closeTo(0.6, 0.001));
      await gesture('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(route.isCurrent, isTrue);
      expect(frameworkBack.last, isTrue);
      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', 0.4);
      await gesture('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.byType(TimetablePage), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);
      expect(frameworkBack.last, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  final samplePath =
      Platform.environment['TIMETABLE_REAL_SAMPLE'] ??
      'test/fixtures/timetable/kb_real_sample.json';
  test('本地真实样例：控制器→MethodChannel JSON 包含多门课程及倒计时边界', () async {
    final raw = jsonDecode(
      await File(samplePath).readAsString(),
    ) as Map<String, dynamic>;
    final rows = ((raw['datas'] as Map)['cxxszhxqkb'] as Map)['rows'] as List;
    final courses = TimetableParser.parseKbRows(rows).courses;
    load(courses);
    final report = <String>{};
    DateTime? busyDay;
    var maxClasses = 0;
    final svc = TimetableNotifyService(controller: ctl);
    for (var offset = 0; offset < 24 * 7; offset++) {
      final date = termStart.add(Duration(days: offset));
      final items = ctl.coursesOnDate(date);
      final classes = svc.classesOn(date);
      if (classes.length > maxClasses) {
        maxClasses = classes.length;
        busyDay = date;
      }
      for (var i = 0; i < items.length; i++) {
        final kind = timingKindOf(course: items[i].course, slot: items[i].slot);
        if (kind == CourseTimingKind.standard) continue;
        final s = items[i].slot;
        expect(classes[i].end.isAfter(classes[i].start), isTrue);
        report.add(
          '| ${items[i].course.name} | ${kind.name} | ${s.startNode}–${s.endNode} | ${classes[i].timeRange} |',
        );
      }
    }
    expect(maxClasses, greaterThanOrEqualTo(3));
    expect(report.any((s) => s.contains('| pe | 7–8 | 15:55-17:25')), isTrue);
    final now = busyDay!.add(const Duration(hours: 7, minutes: 30));
    ctl.debugSetSnapshot(ctl.snapshot.copyWith(syncedAt: now));
    TimetableController.bindingCheck = () async => true;
    await ctl.refreshPortalBound();
    const channel = MethodChannel('device_regression_notify');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    TimetableNotifyBridge.debugIsAndroid = true;
    final bridge = TimetableNotifyBridge(channel: channel);
    for (final count in [1, 2, 3]) {
      ctl.debugSetSnapshot(
        ctl.snapshot.copyWith(
          settings: ctl.settings.copyWith(widgetCourseCount: count),
        ),
      );
      final service = TimetableNotifyService(
        controller: ctl,
        bridge: bridge,
        clock: () => now,
      );
      await service.refreshWidget();
      final payload =
          jsonDecode((calls.last.arguments as Map)['payload'] as String) as Map;
      expect(payload['state'], 'ok');
      expect(payload['prefs']['courseCount'], count);
      expect(payload['prefs']['showCountdown'], isTrue);
      final items = payload['days'][0]['items'] as List;
      expect(items, hasLength(maxClasses));
      for (final item in items) {
        expect(
          DateTime.parse(item['end'] as String)
              .isAfter(DateTime.parse(item['start'] as String)),
          isTrue,
        );
        expect(item['startMs'], isA<int>());
        expect(item['endMs'], isA<int>());
        expect(item['staticBefore']['time'], isNotEmpty);
        expect(item['staticDuring']['time'], isNotEmpty);
      }
      final selected = selectWidgetRows(
        service.classesOn(busyDay),
        now,
        prefs: WidgetPrefs(courseCount: count),
      );
      expect(selected.rows.length, count - 1);
      final small = selectWidget2x2(service.classesOn(busyDay), now);
      expect(small.main, isNotNull);
      expect(small.after, isNotNull);
    }
    final out = Platform.environment['TIMETABLE_TIMING_RESULT'];
    if (out != null) {
      await File(out).writeAsString((report.toList()..sort()).join('\n'));
    }
  }, skip: !File(samplePath).existsSync() ? 'real sample not present' : false);
}
