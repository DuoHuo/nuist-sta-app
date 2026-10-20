// 课表 UI 侧用例（design/timetable-spec.md §13.8–§13.16），
// 编号对齐课表测试用例 §24（NW / LC / SW / CD / TB / HT / HP / SN / AS / EV / EX）。
// 全部为构造数据（课名「测试课甲」、老师「张老师」、地点「测试楼 A101」），不读真实样例。
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
import 'package:nuist_sta_app/mini_apps/timetable/timetable_settings_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';

final _c = TimetableController.instance;

/// 第 7 周（单周）：10/12–10/18；开学 2026-08-31。
const _week = 7;
final _termStart = DateTime(2026, 8, 31);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '11111111111111111111',
  String location = '测试楼 A101',
  String teacher = '张老师',
  String classId = '',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  classId: classId,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  TimetableSettings? settings,
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
  DateTime? syncedAt,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: settings ?? TimetableSettings(termStartDate: _termStart),
      syncedAt: syncedAt,
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

Future<void> _settleIo(WidgetTester tester) async {
  // 同步进行中（成功时写盘、过期时写 sync_state.json）多等几轮真实 IO。
  for (var i = 0; i < 5 || (_c.loading && i < 100); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void _bigView(WidgetTester tester, {Size size = const Size(1080, 2400)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Finder _cell(String name) => find.widgetWithText(CourseCell, name);

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_ui');
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

  // ---------------------------------------------------------------- NW
  group('TB 顶栏 / 去登录 / 教务账号（§13.12、§13.16）', () {
    Future<void> pumpPage(WidgetTester tester) async {
      _bigView(tester);
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

    testWidgets('TB02 点齿轮直接进设置页（标题「设置」），不弹菜单；TB03 无「立即同步」', (tester) async {
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await pumpPage(tester);
      expect(find.text('立即同步'), findsNothing);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(TimetableSettingsPage), findsOneWidget);
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
      expect(find.text('立即同步'), findsNothing);
      expect(find.text('课表设置'), findsNothing);
    });

    testWidgets('TB08 未绑定：课表空状态与首页卡片都显示「去登录」', (tester) async {
      _load();
      await bind(tester, false);
      await pumpPage(tester);
      expect(find.byKey(const Key('timetable_empty_login')), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(find.text('立即同步'), findsNothing);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TimetableHomeCard())),
      );
      await tester.pump();
      expect(find.byKey(const Key('home_card_login')), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
    });

    testWidgets('TB11 已绑定：空状态与首页卡片都没有「立即同步」/同步按钮', (tester) async {
      _load();
      await bind(tester, true);
      await pumpPage(tester);
      await _settleIo(tester);
      expect(find.text('还没有课程'), findsOneWidget);
      expect(find.text('立即同步'), findsNothing);
      expect(find.text('去登录'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TimetableHomeCard())),
      );
      await tester.pump();
      expect(find.text('立即同步'), findsNothing);
      expect(find.text('去登录'), findsNothing);
      // 只看首页卡片内：上一页同步失败的 SnackBar（重试）可能还挂在根 Messenger 上。
      expect(
        find.descendant(
          of: find.byType(TimetableHomeCard),
          matching: find.byType(TextButton),
        ),
        findsNothing,
      );
    });

    testWidgets('登录成功的同步不由课表侧调用：从登录页返回（未绑定→已绑定）只刷新'
        '「已绑定」，不触发 onLoginSucceeded（不发同步请求）', (tester) async {
      _bigView(tester, size: const Size(1080, 6000));
      _load();
      await bind(tester, false);
      final origFetch = TimetableController.fetchSnapshot;
      addTearDown(() => TimetableController.fetchSnapshot = origFetch);
      var fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        throw const SocketException('test');
      };
      for (final entry in ['settings', 'home']) {
        await bind(tester, false);
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => entry == 'settings'
                  ? TimetableSettingsPage(controller: _c)
                  : const Scaffold(body: TimetableHomeCard()),
            ),
            GoRoute(
              path: '/portal-bind',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  key: const Key('fake_bind_done'),
                  // 模拟在门户页登录成功（真实页面会自己调 onLoginSucceeded）。
                  onPressed: () {
                    TimetableController.bindingCheck = () async => true;
                    context.pop();
                  },
                  child: const Text('done'),
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pump();
        await tester.tap(
          find.byKey(
            Key(
              entry == 'settings' ? 'tt_settings_account' : 'home_card_login',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('fake_bind_done')));
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(_c.portalBound, isTrue, reason: entry);
        if (entry == 'settings') {
          expect(find.text('已绑定'), findsOneWidget);
        }
        expect(fetches, 0, reason: entry);
      }
    });

    testWidgets('TB04/TB09/TB10/TB12 设置「其他」：教务账号（已绑定/去登录）在第 1 行，'
        '恢复教务课程第 2 行；点击走原登录/解绑入口', (tester) async {
      _bigView(tester, size: const Size(1080, 6000));
      _load();
      await bind(tester, true);
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TimetableSettingsPage(
            controller: _c,
            onOpenAccount: () async => opened++,
          ),
        ),
      );
      await tester.pump();
      final other = find.byKey(const Key('tt_settings_group_other'));
      final account = find.byKey(const Key('tt_settings_account'));
      final restore = find.byKey(const Key('tt_settings_restore_jwxt'));
      expect(find.descendant(of: other, matching: account), findsOneWidget);
      expect(
        tester.getTopLeft(account).dy < tester.getTopLeft(restore).dy,
        isTrue,
      );
      // 「其他」在最底部（考试卡片之后）。
      expect(
        tester.getTopLeft(other).dy >
            tester
                .getTopLeft(find.byKey(const Key('tt_settings_group_exam')))
                .dy,
        isTrue,
      );
      expect(find.text('已绑定'), findsOneWidget);
      await tester.tap(account);
      await tester.pump();
      expect(opened, 1);
      // 解绑后立即变「去登录」。
      await bind(tester, false);
      expect(find.text('已绑定'), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tt_settings_account_state')))
            .data,
        '去登录',
      );
      await tester.tap(account);
      await tester.pump();
      expect(opened, 2);
    });

    testWidgets('TB06 点「+」弹底部面板「课程 / 考试 / 其他」（同 EV01）', (tester) async {
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await pumpPage(tester);
      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const Key('add_entry_sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.byType(ListTile)),
        findsNWidgets(3),
      );
      for (final t in ['课程', '考试', '其他']) {
        expect(
          find.descendant(of: sheet, matching: find.text(t)),
          findsOneWidget,
          reason: t,
        );
      }
      final ys = [
        for (final k in [
          'add_entry_course',
          'add_entry_exam',
          'add_entry_other',
        ])
          tester.getTopLeft(find.byKey(Key(k))).dy,
      ];
      expect(ys[0], lessThan(ys[1]));
      expect(ys[1], lessThan(ys[2]));
    });

    testWidgets('TB05/SW04 点同步图标触发同步；正在看第 9 周时失败（断网 mock）：'
        '不弹「已同步」，按原失败提示，仍停在第 9 周', (tester) async {
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now(), week: 9);
      await bind(tester, true);
      var fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        throw const SocketException('offline (test)');
      };
      await pumpPage(tester);
      await _settleIo(tester);
      // 当天已同步：进入页面不自动同步。
      expect(fetches, 0);
      expect(_c.viewingWeek, 9);
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(fetches, 1);
      expect(_c.syncStatus, TimetableSyncStatus.failure);
      expect(find.textContaining('已同步'), findsNothing);
      // AS-1：手动同步断网失败文案。
      expect(find.text('同步失败，请检查网络'), findsOneWidget);
      expect(find.byKey(const Key('timetable_sync_retry')), findsOneWidget);
      expect(find.byKey(const Key('timetable_sync_error_dot')), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(_c.viewingWeek, 9);
    });

    // 模拟教务返回的开学日（termStartFromJwxt），同步后本周仍是第 7 周。
    TimetableSnapshot okSnapshot() => TimetableSnapshot(
      courses: [_course('K1|01', '测试课乙', source: CourseSource.jwxt)],
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: _termStart,
        termStartFromJwxt: true,
      ),
    );

    testWidgets('SW01 正在看第 9 周时同步成功：停留第 9 周，只弹 2 秒「已同步」'
        '（无「回到本周」操作），到时自动消失、周次不变', (tester) async {
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now(), week: 9);
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          okSnapshot();
      await pumpPage(tester);
      await _settleIo(tester);
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(_c.syncStatus, TimetableSyncStatus.success);
      expect(_c.viewingWeek, 9);
      final bar = find.byKey(const Key('timetable_sync_snackbar'));
      expect(
        find.descendant(of: bar, matching: find.text('已同步')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('回到本周')),
        findsNothing,
      );
      final snack = tester.widget<SnackBar>(bar);
      expect(snack.action, isNull);
      expect(snack.duration, const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(_c.viewingWeek, 9);
      expect(_c.isViewingCurrentWeek, isFalse);
    });

    testWidgets('SW03 正在看本周时同步成功：只弹 2 秒「已同步」、不出现「回到本周」，到时自动消失', (tester) async {
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          okSnapshot();
      await pumpPage(tester);
      await _settleIo(tester);
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(_c.syncStatus, TimetableSyncStatus.success);
      expect(_c.viewingWeek, 7);
      final bar = find.byKey(const Key('timetable_sync_snackbar'));
      expect(
        find.descendant(of: bar, matching: find.text('已同步')),
        findsOneWidget,
      );
      expect(tester.widget<SnackBar>(bar).action, isNull);
      expect(find.text('回到本周'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(_c.viewingWeek, 7);
    });

    Future<void> pumpWithMotion(
      WidgetTester tester, {
      required bool disableAnimations,
    }) async {
      _bigView(tester);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: disableAnimations),
            child: child!,
          ),
          home: const TimetablePage(),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> openStripTapCurrent(WidgetTester tester) async {
      await tester.tap(find.textContaining('第 9 周'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('timetable_week_strip_current')));
    }

    testWidgets('SW02 周条「本周」：按跨周数时长 easeOutCubic 翻页动画到本周，'
        '动画结束后浏览周对齐本周', (tester) async {
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now(), week: 9);
      await pumpWithMotion(tester, disableAnimations: false);
      await _settleIo(tester);
      expect(_c.viewingWeek, 9);
      expect(find.text('回到本周'), findsNothing);
      await openStripTapCurrent(tester);
      await tester.pump();
      // 动画刚开始：还没到本周（不是直接跳）。
      expect(_c.viewingWeek, 9);
      await tester.pumpAndSettle();
      expect(_c.viewingWeek, _week);
      expect(_c.isViewingCurrentWeek, isTrue);
    });

    testWidgets('SW02 周条「本周」：系统关闭动画（disableAnimations）时直接跳到本周', (tester) async {
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now(), week: 9);
      await pumpWithMotion(tester, disableAnimations: true);
      await _settleIo(tester);
      expect(_c.viewingWeek, 9);
      await openStripTapCurrent(tester);
      // 不等动画：点下即到本周。
      expect(_c.viewingWeek, _week);
      expect(_c.isViewingCurrentWeek, isTrue);
      await tester.pump();
    });

    // ---- AS-1（设计师 10/18，取代 §24 AS03 原「标题栏轻提示」）：
    // 手动同步失败 → 浮动 SnackBar + 「重试」；自动同步失败 → 不弹 SnackBar，
    // 同步图标右上角 6dp #C62828 圆点，读屏「同步，上次同步失败」，下次成功后消失。
    final errorDot = find.byKey(const Key('timetable_sync_error_dot'));

    void expectErrorDot(WidgetTester tester) {
      expect(errorDot, findsOneWidget);
      expect(tester.getSize(errorDot), const Size(6, 6));
      final deco =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: errorDot,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(deco.color, const Color(0xFFC62828));
      expect(deco.shape, BoxShape.circle);
      expect(find.bySemanticsLabel('同步，上次同步失败'), findsOneWidget);
      // 顶栏尺寸不变：同步按钮仍是 48×48。
      expect(
        tester.getSize(find.byKey(const Key('timetable_sync_button'))),
        const Size(48, 48),
      );
    }

    void expectNoErrorDot() {
      expect(errorDot, findsNothing);
      expect(find.bySemanticsLabel('同步，上次同步失败'), findsNothing);
      expect(find.bySemanticsLabel('同步'), findsOneWidget);
    }

    testWidgets('AS-1/AS03 冷启动后台同步失败（mock 超时）：不弹 SnackBar、不弹对话框，'
        '缓存照常显示；同步图标圆点，读屏「同步，上次同步失败」', (tester) async {
      final semantics = tester.ensureSemantics();
      // 无 syncedAt、无成功时间戳：冷启动即后台同步。
      _load(manual: [_course('a', '测试课甲')]);
      await bind(tester, true);
      var fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        throw TimeoutException('timeout (test)');
      };
      await pumpPage(tester);
      await _settleIo(tester);
      expect(fetches, 1);
      expect(_c.syncStatus, TimetableSyncStatus.failure);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(_cell('测试课甲'), findsWidgets);
      expectErrorDot(tester);
      semantics.dispose();
    });

    testWidgets('AS-1/AS03 自动同步（启动）先失败、之后才打开课表页：不弹 SnackBar，'
        '同步图标仍有圆点', (tester) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const SocketException('offline (test)');
      await tester.runAsync(_c.onAppStart);
      expect(_c.syncStatus, TimetableSyncStatus.failure);
      await pumpPage(tester);
      await _settleIo(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(_cell('测试课甲'), findsWidgets);
      expectErrorDot(tester);
      semantics.dispose();
    });

    testWidgets('AS-1 手动同步断网失败：SnackBar「同步失败，请检查网络」带「重试」（4 秒），'
        '点重试再同步一次；不画圆点', (tester) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await bind(tester, true);
      var fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        throw const SocketException('offline (test)');
      };
      await pumpPage(tester);
      await _settleIo(tester);
      expect(fetches, 0);
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(fetches, 1);
      expect(_c.syncFailure, TimetableSyncFailure.network);
      final bar = tester.widget<SnackBar>(
        find.byKey(const Key('timetable_sync_snackbar')),
      );
      expect(bar.behavior, SnackBarBehavior.floating);
      expect(bar.duration, const Duration(seconds: 4));
      expect(bar.action?.label, '重试');
      expect(find.text('同步失败，请检查网络'), findsOneWidget);
      expectNoErrorDot();
      // 点「重试」= 再走一次手动同步。
      await tester.tap(find.byKey(const Key('timetable_sync_retry')));
      await _settleIo(tester);
      expect(fetches, 2);
      expect(find.text('同步失败，请检查网络'), findsOneWidget);
      expectNoErrorDot();
      semantics.dispose();
    });

    testWidgets('AS-1 手动同步服务端出错：SnackBar「同步超时，请稍后再试」带「重试」；不画圆点', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const JwxtHttpError('wdkb', 503);
      await pumpPage(tester);
      await _settleIo(tester);
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(_c.syncFailure, TimetableSyncFailure.server);
      expect(find.text('同步超时，请稍后再试'), findsOneWidget);
      expect(
        tester
            .widget<SnackBar>(find.byKey(const Key('timetable_sync_snackbar')))
            .action
            ?.label,
        '重试',
      );
      expectNoErrorDot();
      semantics.dispose();
    });

    testWidgets('AS-1/AS03 自动同步失败后，下一次同步成功：圆点消失，读屏恢复「同步」', (tester) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')]);
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw TimeoutException('timeout (test)');
      await pumpPage(tester);
      await _settleIo(tester);
      expectErrorDot(tester);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_course('K1|01', '测试课乙', source: CourseSource.jwxt)],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(termStartDate: _termStart),
          );
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(_c.syncStatus, TimetableSyncStatus.success);
      expectNoErrorDot();
      semantics.dispose();
    });

    // ---- 登录过期（设计师 10/18）：自动 / 手动同步遇到过期都弹「登录已过期」+
    // 「重新登录」6 秒；同一次过期只弹一次，清掉后再次过期再弹。
    const expiredError = JwxtSessionExpiredError('expired (test)');
    final expiredText = find.text('登录已过期');

    void expectExpiredBar(WidgetTester tester) {
      expect(expiredText, findsOneWidget);
      final bar = tester.widget<SnackBar>(
        find.byKey(const Key('timetable_sync_snackbar')),
      );
      expect(bar.behavior, SnackBarBehavior.floating);
      expect(bar.duration, const Duration(seconds: 6));
      expect(bar.action?.label, '重新登录');
    }

    Future<void> hideBar(WidgetTester tester) async {
      ScaffoldMessenger.of(tester.element(find.byType(TimetablePage)))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    testWidgets('AS-1 自动同步登录过期：「登录已过期」+「重新登录」6 秒，圆点照常；'
        '再次过期失败不再弹', (tester) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')]); // 打开课表页即自动同步
      await bind(tester, true);
      var fetches = 0;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        fetches++;
        throw expiredError;
      };
      await pumpPage(tester);
      await _settleIo(tester);
      expect(fetches, 1);
      expect(_c.portalSessionExpired, isTrue);
      expectExpiredBar(tester);
      expectErrorDot(tester);
      await hideBar(tester);
      // 同一次过期：再来一次自动同步过期失败，不再弹。
      await tester.runAsync(_c.onAppStart);
      await _settleIo(tester);
      expect(fetches, 2);
      expect(_c.portalSessionExpired, isTrue);
      expect(expiredText, findsNothing);
      semantics.dispose();
    });

    testWidgets('AS-1 手动同步登录过期：同样弹「登录已过期」+「重新登录」6 秒；不画圆点', (tester) async {
      final semantics = tester.ensureSemantics();
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw expiredError;
      await pumpPage(tester);
      await _settleIo(tester);
      expect(expiredText, findsNothing);
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(_c.portalSessionExpired, isTrue);
      expectExpiredBar(tester);
      expectNoErrorDot();
      semantics.dispose();
    });

    testWidgets('AS-1 过期后同步成功清掉过期，再次过期会再弹；点「重新登录」进登录页', (tester) async {
      _bigView(tester);
      _load(manual: [_course('a', '测试课甲')], syncedAt: DateTime.now());
      await bind(tester, true);
      Object? error = expiredError;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        final e = error;
        if (e != null) throw e;
        return okSnapshot();
      };
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
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await _settleIo(tester);
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expectExpiredBar(tester);
      await hideBar(tester);
      // 同步成功：清掉过期。
      error = null;
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expect(_c.syncStatus, TimetableSyncStatus.success);
      expect(_c.portalSessionExpired, isFalse);
      expect(expiredText, findsNothing);
      // 新的一次过期：再弹。
      error = expiredError;
      await tester.tap(find.byTooltip('同步'));
      await _settleIo(tester);
      expectExpiredBar(tester);
      await tester.tap(find.byKey(const Key('timetable_sync_relogin')));
      await tester.pumpAndSettle();
      expect(find.text('PORTAL_BIND_PAGE'), findsOneWidget);
    });

    testWidgets('AS-1/TB09 登录已过期：设置「教务账号」右侧红字「已过期」，'
        '读屏「其他，教务账号，已过期」；点这一行进登录', (tester) async {
      final semantics = tester.ensureSemantics();
      _bigView(tester, size: const Size(1080, 6000));
      _load();
      await bind(tester, true);
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw expiredError;
      await tester.runAsync(_c.manualSync);
      expect(_c.portalSessionExpired, isTrue);
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TimetableSettingsPage(
            controller: _c,
            onOpenAccount: () async => opened++,
          ),
        ),
      );
      await tester.pump();
      final state = tester.widget<Text>(
        find.byKey(const Key('tt_settings_account_state')),
      );
      expect(state.data, '已过期');
      expect(state.style?.color, const Color(0xFFC62828));
      expect(find.text('已绑定'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp(r'^其他，教务账号，已过期($|\n)')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('tt_settings_account')));
      await tester.pump();
      expect(opened, 1);
      semantics.dispose();
    });
  });

  // ---------------------------------------------------------------- HT
}
