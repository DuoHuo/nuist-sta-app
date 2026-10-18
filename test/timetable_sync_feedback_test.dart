import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;
final _termStart = DateTime(2026, 9, 7); // 周一

Course _course(String name, {int day = 1}) => Course(
  id: name,
  name: name,
  source: CourseSource.jwxt,
  slots: [CourseSlot(day: day, startNode: 1, endNode: 2, weeks: '1' * 20)],
);

TimetableSnapshot _snapshot({List<Course>? courses}) => TimetableSnapshot(
  courses: courses ?? [_course('数据结构')],
  periods: TimetableController.defaultPeriods(),
  settings: TimetableSettings(
    termStartDate: _termStart,
    periodHeight: TimetableTheme.periodHeight,
    cellRadius: TimetableTheme.cellRadius,
  ),
);

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_polish');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 14);
    _c.debugReset();
  });

  tearDown(() {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw UnimplementedError();
    _c.debugReset();
    TimetableController.bindingCheck = () async => false;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('同步提示', () {
    testWidgets('同步中顶栏小进度、网格不位移；SW03 本周同步成功只弹 2 秒「已同步」', (tester) async {
      _c.debugSetSnapshot(_snapshot());
      await _pumpPage(tester);
      final gridTop = tester.getTopLeft(find.byType(WeekGrid).first);

      final pending = Completer<TimetableSnapshot>();
      TimetableController.fetchSnapshot = (term, {baseSettings}) =>
          pending.future;
      unawaited(_c.syncFromJwxt());
      await tester.pump();
      expect(
        find.byKey(const Key('timetable_syncing_indicator')),
        findsOneWidget,
      );
      expect(find.text('正在同步教务课表…'), findsNothing);
      expect(tester.getTopLeft(find.byType(WeekGrid).first), gridTop);

      pending.complete(_snapshot());
      for (var i = 0; i < 20 && _c.loading; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(
        _c.syncStatus,
        TimetableSyncStatus.success,
        reason: _c.statusMessage,
      );
      await tester.pump(const Duration(milliseconds: 300));

      // SW03（产品 10/18）：本周同步成功也只弹 2 秒「已同步」（浮动，不占布局）。
      expect(find.byKey(const Key('timetable_sync_snackbar')), findsOneWidget);
      expect(find.text('已同步'), findsOneWidget);
      expect(
        find.byKey(const Key('timetable_syncing_indicator')),
        findsNothing,
      );
      expect(tester.getTopLeft(find.byType(WeekGrid).first), gridTop);
    });

    testWidgets('手动同步失败也用浮动 SnackBar，不占布局（AS-1）', (tester) async {
      _c.debugSetSnapshot(_snapshot());
      await _pumpPage(tester);
      final gridTop = tester.getTopLeft(find.byType(WeekGrid).first);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw StateError('网络错误');
      // AS-1：失败 SnackBar 只在手动同步（顶栏同步图标）失败时弹出。
      TimetableController.bindingCheck = () async => true;
      await tester.tap(find.byTooltip('同步'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      final bar = tester.widget<SnackBar>(
        find.byKey(const Key('timetable_sync_snackbar')),
      );
      expect(bar.behavior, SnackBarBehavior.floating);
      expect(find.textContaining('同步失败'), findsOneWidget);
      expect(tester.getTopLeft(find.byType(WeekGrid).first), gridTop);
    });
  });

  group('课程格课名', () {
    test('半角括号转全角并粘连末尾括注', () {
      final s = formatCellCourseName('学术英语(1)');
      expect(s.replaceAll('\u2060', ''), '学术英语（1）');
      expect(s, '学术英语\u2060（\u20601\u2060）');
      expect(formatCellCourseName('高等数学'), '高等数学');
      expect(
        formatCellCourseName('大学物理（上）').replaceAll('\u2060', ''),
        '大学物理（上）',
      );
    });

    testWidgets('课名按格高尽量多行，末行省略（S02）', (tester) async {
      final course = _course('非常非常长的课程名称用于测试省略效果(1)');
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: CourseCell(
              cell: GridCell(
                course: course,
                slot: course.slots.first,
                conflictCount: 0,
                activeThisWeek: true,
              ),
              width: 48,
              height: 120,
              radius: 6,
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(
        find.textContaining('非常非常长', findRichText: false),
      );
      // S02：不再固定 3 行，120dp 格可容纳更多行。
      expect(text.maxLines, greaterThanOrEqualTo(3));
      expect(text.overflow, TextOverflow.ellipsis);
      // 显示路径：normalizeCourseName 后不加隐藏字符（B02）。
      expect(text.data!.replaceAll('\n', ''), endsWith('（1）'));
      expect(text.data, isNot(contains('\u2060')));
      expect(tester.takeException(), isNull);
    });
  });

  group('明天预告周次', () {
    test('周日→周一跨周显示周次，周中不显示', () {
      // 2026-10-19 周一 = 第 7 周
      expect(tomorrowLabel(DateTime(2026, 10, 19), _termStart), '明天（周一·第 7 周）');
      expect(tomorrowLabel(DateTime(2026, 10, 15), _termStart), '明天（周四）');
      expect(tomorrowLabel(DateTime(2026, 10, 19), null), '明天（周一）');
    });

    testWidgets('首页卡片：周日显示下周周次', (tester) async {
      TimetableController.clock = () => DateTime(2026, 10, 18); // 周日
      _c.debugSetSnapshot(_snapshot(courses: [_course('线性代数', day: 1)]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetableHomeCard(now: TimetableController.clock),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('明天（周一·第 7 周）'), findsWidgets);
    });

    testWidgets('首页卡片：周中不显示周次', (tester) async {
      TimetableController.clock = () => DateTime(2026, 10, 14); // 周三
      _c.debugSetSnapshot(_snapshot(courses: [_course('线性代数', day: 4)]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetableHomeCard(now: TimetableController.clock),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('明天（周四）'), findsWidgets);
      expect(find.textContaining('第 7 周）'), findsNothing);
    });
  });

  group('手动同步失败 SnackBar（AS-1）', () {
    // AS-1：失败 SnackBar 只在手动同步（顶栏同步图标 / 重试）失败时弹出；
    // 自动同步失败只画圆点（见 timetable_top_bar_test 的 AS-1/AS03）。
    Future<void> failWith(WidgetTester tester, Object error) async {
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw error;
      TimetableController.bindingCheck = () async => true;
      await tester.tap(find.byTooltip('同步'));
      // 同步进行中（过期时写 sync_state.json）多等几轮真实 IO。
      for (var i = 0; i < 5 || (_c.loading && i < 100); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    SnackBar bar(WidgetTester tester) => tester.widget<SnackBar>(
      find.byKey(const Key('timetable_sync_snackbar')),
    );

    final retryCases = <String, (Object, String)>{
      'network': (const SocketException('offline'), '同步失败，请检查网络'),
      'server': (const JwxtHttpError('wdkb', 503), '同步超时，请稍后再试'),
    };

    for (final e in retryCases.entries) {
      testWidgets('${e.key}：文案 + 重试（4 秒），连点只触发一次同步', (tester) async {
        _c.debugSetSnapshot(_snapshot());
        await _pumpPage(tester);
        await failWith(tester, e.value.$1);

        expect(_c.syncFailure.name, e.key);
        expect(find.text(e.value.$2), findsOneWidget);
        final b = bar(tester);
        expect(b.behavior, SnackBarBehavior.floating);
        expect(b.duration, const Duration(seconds: 4));
        expect(b.action?.label, '重试');

        // QA：首次失败后顶栏转圈停止、同步图标恢复（页面按 syncStatus 推导）。
        await tester.pump();
        expect(_c.syncStatus, TimetableSyncStatus.failure);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.byKey(const Key('timetable_syncing_indicator')),
          findsNothing,
        );
        expect(find.byIcon(Icons.sync), findsOneWidget);

        var calls = 0;
        final pending = Completer<TimetableSnapshot>();
        TimetableController.fetchSnapshot = (term, {baseSettings}) {
          calls++;
          return pending.future;
        };
        // 重试走 syncIfBound：先声明已绑定门户。
        TimetableController.bindingCheck = () async => true;
        final retry = find.byKey(const Key('timetable_sync_retry'));
        await tester.tap(retry);
        if (retry.evaluate().isNotEmpty) {
          await tester.tap(retry, warnIfMissed: false);
        }
        await tester.pump();
        expect(calls, 1);
        // 同步挂起期间转圈动画不会停：不能 pumpAndSettle，用定长 pump。
        await tester.pump(const Duration(seconds: 1));
        expect(find.text(e.value.$2), findsNothing);
        expect(
          find.byKey(const Key('timetable_syncing_indicator')),
          findsOneWidget,
        );

        // 收尾：让同步以失败结束，避免悬挂的 Future。
        pending.completeError(StateError('done'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(_c.syncStatus, TimetableSyncStatus.failure);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.sync), findsOneWidget);
      });
    }

    testWidgets('sessionExpired：「重新登录」跳转登录页且不清缓存', (tester) async {
      _c.debugSetSnapshot(_snapshot());
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const TimetablePage(),
          ),
          GoRoute(
            path: '/portal-bind',
            builder: (context, state) =>
                const Scaffold(body: Text('PORTAL_BIND_PAGE')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await failWith(tester, const JwxtSessionExpiredError('expired'));

      expect(_c.syncFailure, TimetableSyncFailure.sessionExpired);
      expect(bar(tester).action?.label, '重新登录');
      expect(bar(tester).duration, const Duration(seconds: 6));
      await tester.tap(find.byKey(const Key('timetable_sync_relogin')));
      await tester.pumpAndSettle();
      expect(find.text('PORTAL_BIND_PAGE'), findsOneWidget);
      expect(_c.courses, isNotEmpty);
    });

    testWidgets('unknown：「同步失败，请稍后再试」无操作 4 秒', (tester) async {
      _c.debugSetSnapshot(_snapshot());
      await _pumpPage(tester);
      await failWith(tester, StateError('boom'));
      expect(_c.syncFailure, TimetableSyncFailure.unknown);
      expect(find.text('同步失败，请稍后再试'), findsOneWidget);
      expect(bar(tester).action, isNull);
      expect(bar(tester).duration, const Duration(seconds: 4));
      expect(bar(tester).behavior, SnackBarBehavior.floating);
    });

    testWidgets('SW03 本周同步成功：只弹「已同步」2 秒（无操作），到时自动消失', (tester) async {
      _c.debugSetSnapshot(_snapshot());
      await _pumpPage(tester);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          _snapshot();
      unawaited(_c.syncFromJwxt());
      for (var i = 0; i < 20 && _c.loading; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(_c.syncStatus, TimetableSyncStatus.success);
      final b = bar(tester);
      expect(b.action, isNull);
      expect(b.duration, const Duration(seconds: 2));
      expect(b.persist, isFalse);
      expect(find.text('已同步'), findsOneWidget);
      final week = _c.viewingWeek;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable_sync_snackbar')), findsNothing);
      expect(_c.viewingWeek, week);
    });

    for (final e in retryCases.entries) {
      testWidgets('AS-1 ${e.key}：带「重试」的 SnackBar 不常驻，4 秒后自动消失', (tester) async {
        _c.debugSetSnapshot(_snapshot());
        await _pumpPage(tester);
        await failWith(tester, e.value.$1);
        final b = bar(tester);
        expect(b.action?.label, '重试');
        expect(b.persist, isFalse);
        await tester.pump(const Duration(milliseconds: 3500));
        expect(find.text(e.value.$2), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('timetable_sync_snackbar')), findsNothing);
        expect(find.text(e.value.$2), findsNothing);
      });
    }

    testWidgets('AS-1 unknown：无操作 SnackBar 4 秒后自动消失', (tester) async {
      _c.debugSetSnapshot(_snapshot());
      await _pumpPage(tester);
      await failWith(tester, StateError('boom'));
      expect(bar(tester).persist, isFalse);
      await tester.pump(const Duration(milliseconds: 4500));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable_sync_snackbar')), findsNothing);
    });

    testWidgets('AS-1 登录过期：「重新登录」SnackBar 不常驻，6 秒后自动消失且不再弹', (tester) async {
      _c.debugSetSnapshot(_snapshot());
      await _pumpPage(tester);
      await failWith(tester, const JwxtSessionExpiredError('expired'));
      final b = bar(tester);
      expect(b.action?.label, '重新登录');
      expect(b.persist, isFalse);
      await tester.pump(const Duration(milliseconds: 5500));
      expect(find.text('登录已过期'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable_sync_snackbar')), findsNothing);
      // 同一次过期只提示一次：之后再刷新也不重新弹出。
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('登录已过期'), findsNothing);
    });
  });
}
