import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;
const _week = 7;
final _termStart = DateTime(2026, 8, 31);

Course _course(
  String id,
  String name, {
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: const [
    CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '11111111111111111111',
      location: '测试楼 A101',
      teacher: '张老师',
    ),
  ],
);

void _load({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
  DateTime? syncedAt,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: _termStart),
      syncedAt: syncedAt,
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 5 || (_c.loading && i < 100); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_top_bar');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => DateTime(2026, 10, 12, 9);
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> bind(WidgetTester tester, bool bound) async {
    TimetableController.bindingCheck = () async => bound;
    await tester.runAsync(_c.refreshPortalBound);
    await tester.pump();
  }

  test('纯格式化：半角括号转全角粘连', () {
    final s = formatCellCourseName('学术英语(1)');
    expect(s.replaceAll('\u2060', ''), '学术英语（1）');
    expect(s, '学术英语\u2060（\u20601\u2060）');
    expect(formatCellCourseName('高等数学'), '高等数学');
  });

  testWidgets('未绑定与已绑定状态下登录引导、设置入口及「+」添加菜单', (tester) async {
    _load();
    await bind(tester, false);
    await pumpPage(tester);
    expect(find.text('去登录'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TimetableHomeCard())),
    );
    await tester.pump();
    expect(find.text('去登录'), findsOneWidget);

    await bind(tester, true);
    _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
    await pumpPage(tester);
    expect(find.text('去登录'), findsNothing);
    expect(find.text('立即同步'), findsNothing);

    // 点「+」弹出课程 / 考试 / 其他三项
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add_entry_sheet')), findsOneWidget);
    for (final t in ['课程', '考试', '其他']) {
      expect(
        find.descendant(
          of: find.byType(MiuixPopupHost),
          matching: find.text(t),
        ),
        findsOneWidget,
      );
    }
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 点齿轮进入设置页，且不包含全局教务账号入口
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(TimetableSettingsPage), findsOneWidget);
    expect(find.byKey(const Key('tt_settings_account')), findsNothing);
  });

  testWidgets('手动同步进度条与成功反馈保留第 9 周；网络/超时失败重试与未知错误区分', (tester) async {
    _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now(), week: 9);
    await bind(tester, true);
    final pending = Completer<TimetableSnapshot>();
    var calls = 0;
    TimetableController.fetchSnapshot = (term, {baseSettings}) {
      calls++;
      return pending.future;
    };
    await pumpPage(tester);
    await _settleIo(tester);

    unawaited(_c.syncFromJwxt());
    await tester.pump();
    expect(
      find.byKey(const Key('timetable_syncing_indicator')),
      findsOneWidget,
    );
    pending.complete(
      TimetableSnapshot(
        courses: [_course('K1|01', '测试课乙', source: CourseSource.jwxt)],
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: _termStart,
          termStartFromJwxt: true,
        ),
      ),
    );
    await _settleIo(tester);
    expect(_c.syncStatus, TimetableSyncStatus.success);
    expect(_c.viewingWeek, 9);
    expect(find.text('已同步'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(TimetablePage)))
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();

    // 断网失败显示「重试」，不显示自动失败圆点；连点重试只发起一次
    TimetableController.fetchSnapshot = (term, {baseSettings}) async {
      calls++;
      throw const SocketException('offline (test)');
    };
    await tester.tap(find.byTooltip('同步'));
    await _settleIo(tester);
    expect(_c.syncFailure, TimetableSyncFailure.network);
    expect(find.text('同步失败，请检查网络'), findsOneWidget);
    expect(find.byKey(const Key('timetable_sync_error_dot')), findsNothing);
    expect(find.byKey(const Key('timetable_sync_retry')), findsOneWidget);

    final retryPending = Completer<TimetableSnapshot>();
    final callsBeforeRetry = calls;
    TimetableController.fetchSnapshot = (term, {baseSettings}) {
      calls++;
      return retryPending.future;
    };
    await tester.tap(find.byKey(const Key('timetable_sync_retry')));
    await tester.tap(
      find.byKey(const Key('timetable_sync_retry')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(calls - callsBeforeRetry, 1);
    retryPending.completeError(StateError('boom'));
    await _settleIo(tester);
    expect(find.text('同步失败，请稍后再试'), findsOneWidget);
    expect(
      tester
          .widget<SnackBar>(find.byKey(const Key('timetable_sync_snackbar')))
          .action,
      isNull,
    );
  });

  testWidgets('自动同步失败保留缓存与失败指示灯但不弹窗，手动成功后清除指示', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      _load(manual: [_course('a', '测试课甲')]);
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw TimeoutException('timeout (test)');
      await pumpPage(tester);
      await _settleIo(tester);

      expect(_c.syncStatus, TimetableSyncStatus.failure);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(CourseCell, '测试课甲'), findsWidgets);
      expect(find.byKey(const Key('timetable_sync_error_dot')), findsOneWidget);
      expect(find.bySemanticsLabel('同步，上次同步失败'), findsOneWidget);

      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_course('K1|01', '测试课乙', source: CourseSource.jwxt)],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(termStartDate: _termStart),
          );
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(_c.syncStatus, TimetableSyncStatus.success);
      expect(find.byKey(const Key('timetable_sync_error_dot')), findsNothing);
      expect(find.bySemanticsLabel('同步'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('登录过期提示仅弹一次，「重新登录」跳转登录页且保留缓存', (tester) async {
    _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
    await bind(tester, true);
    const expiredError = JwxtSessionExpiredError('expired (test)');
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw expiredError;

    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const TimetablePage()),
        GoRoute(
          path: '/portal-bind',
          builder: (_, _) => const Scaffold(body: Text('PORTAL_BIND_PAGE')),
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await _settleIo(tester);

    await tester.tap(find.byTooltip('同步'));
    await _settleIo(tester);
    expect(_c.portalSessionExpired, isTrue);
    expect(find.text('登录已过期'), findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable_sync_relogin')));
    await tester.pumpAndSettle();
    expect(find.text('PORTAL_BIND_PAGE'), findsOneWidget);
    expect(_c.courses, isNotEmpty);
  });

  testWidgets('横屏矮窗下空课表不溢出且可滚动操作', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 280);
    addTearDown(tester.view.reset);

    _load();
    await tester.pumpWidget(
      MaterialApp(theme: appDarkTheme(), home: const TimetablePage()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('还没有课程'), findsOneWidget);

    final loginBtn = find.byKey(const Key('timetable_empty_login'));
    await tester.ensureVisible(loginBtn);
    await tester.pumpAndSettle();
    expect(loginBtn.hitTestable(), findsOneWidget);

    final importBtn = find.byKey(const Key('timetable_empty_import_wakeup'));
    await tester.ensureVisible(importBtn);
    await tester.pumpAndSettle();
    expect(importBtn.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
