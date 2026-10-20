// spec-next-1019 item 2（首页刷新）、item 4（上课中·还剩）、item 13（最多 2 项、四行）、
// 首页行点按只进课表（10/19）。全部为构造数据，不读真实样例。
// ignore_for_file: unused_element

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

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
  String weeksLabel = '',
  String location = '测试楼 A101',
  String teacher = '张老师',
  CourseSource source = CourseSource.manual,
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      weeksLabel: weeksLabel,
      location: location,
      teacher: teacher,
    ),
  ],
);

void _load({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  int week = _week,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(termStartDate: _termStart),
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

Future<void> _io(WidgetTester tester, [int rounds = 3]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void _setUpController() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_next');
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
}

void main() {
  _setUpController();

  Future<void> pumpHome(
    WidgetTester tester,
    DateTime now, {
    double width = 400,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width * 3, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    TimetableController.clock = () => now;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(child: TimetableHomeCard(now: () => now)),
        ),
      ),
    );
    await tester.pump();
  }

  // 周一 10/12：1-2 节 08:00–09:40、3-4 节 10:10–11:50、5-6 节 13:45–15:25、
  // 7-8 节（下午第二段）。
  final a = _course('a', '测试课甲', start: 1, end: 2);
  final b = _course('b', '测试课乙', start: 3, end: 4);
  final c = _course('c', '测试课丙', start: 5, end: 6);
  final d = _course('d', '测试课丁', start: 7, end: 8);

  group('item 4 上课中·还剩', () {
    test('HN01 文案：向下取整、至少 1；≥60 按小时，整点省略分钟', () {
      expect(formatClassRemaining(45), '上课中·还剩 45 分钟');
      expect(formatClassRemaining(0), '上课中·还剩 1 分钟');
      expect(formatClassRemaining(-3), '上课中·还剩 1 分钟');
      expect(formatClassRemaining(59), '上课中·还剩 59 分钟');
      expect(formatClassRemaining(60), '上课中·还剩 1 小时');
      expect(formatClassRemaining(61), '上课中·还剩 1 小时 1 分钟');
      expect(formatClassRemaining(125), '上课中·还剩 2 小时 5 分钟');
    });

    testWidgets('HN02 上课中：「还剩 N 分钟」（09:00:30 → 39）+ 2dp 主色进度条', (tester) async {
      _load(manual: [a]);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 0, 30));
      expect(find.text('上课中·还剩 39 分钟'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('home_course_progress')),
      );
      expect(bar.minHeight, 2);
      expect(bar.color, TimetableColors.light.accent);
      expect(bar.value, closeTo(60.5 / 100, 0.02));
    });

    testWidgets('HN03 上课中 ≥60 分钟：「X 小时 Y 分钟」', (tester) async {
      _load(manual: [_course('a', '测试课甲', start: 1, end: 4)]);
      await pumpHome(tester, DateTime(2026, 10, 12, 8, 30));
      expect(find.text('上课中·还剩 3 小时 20 分钟'), findsOneWidget);
    });
  });

  group('item 13 最多 2 项、四行', () {
    testWidgets('HN04 剩 0 项：不列课程，显示「已上完」', (tester) async {
      _load(manual: [a]);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 50));
      expect(find.text('测试课甲'), findsNothing);
      expect(find.text('已上完'), findsOneWidget);
    });

    testWidgets('HN05 剩 1 项：上过的隐藏，只列下一节', (tester) async {
      _load(manual: [a, b]);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 50));
      expect(find.text('测试课甲'), findsNothing);
      expect(find.text('测试课乙'), findsOneWidget);
    });

    testWidgets('HN06 剩 2 项：正在上的 + 下一节', (tester) async {
      _load(manual: [a, b, c]);
      await pumpHome(tester, DateTime(2026, 10, 12, 10, 30));
      expect(find.text('测试课甲'), findsNothing);
      expect(find.text('测试课乙'), findsOneWidget);
      expect(find.text('测试课丙'), findsOneWidget);
      expect(find.byKey(const Key('home_course_remaining')), findsOneWidget);
    });

    testWidgets('HN07 剩 3+ 项：只列 homeMaxItems（默认 2）项，无「更多」', (tester) async {
      _load(manual: [a, b, c, d]);
      await pumpHome(tester, DateTime(2026, 10, 12, 10, 30));
      expect(find.text('测试课乙'), findsOneWidget);
      expect(find.text('测试课丙'), findsOneWidget);
      expect(find.text('测试课丁'), findsNothing);
      expect(find.textContaining('还有'), findsNothing);
    });

    testWidgets('HN08 四行：课名 / 时间 · 节次 / 地点 / 老师', (tester) async {
      _load(manual: [b]);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 50));
      String text(String key) =>
          tester.widget<Text>(find.byKey(Key(key))).data!;
      expect(text('home_course_time'), '10:10–11:50 · 第3–4节');
      expect(text('home_course_location'), '测试楼 A101');
      expect(text('home_course_teacher'), '张老师');
      final yName = tester.getTopLeft(find.text('测试课乙')).dy;
      final yTime = tester
          .getTopLeft(find.byKey(const Key('home_course_time')))
          .dy;
      final yLoc = tester
          .getTopLeft(find.byKey(const Key('home_course_location')))
          .dy;
      final yTeacher = tester
          .getTopLeft(find.byKey(const Key('home_course_teacher')))
          .dy;
      expect(yName < yTime && yTime < yLoc && yLoc < yTeacher, isTrue);
    });

    testWidgets('HN09 老师为空：不占老师那一行', (tester) async {
      _load(manual: [_course('a', '测试课甲', teacher: '')]);
      await pumpHome(tester, DateTime(2026, 10, 12, 7));
      expect(find.byKey(const Key('home_course_teacher')), findsNothing);
      expect(find.byKey(const Key('home_course_location')), findsOneWidget);
    });

    testWidgets('HN10 长地点 / 长老师：320dp、textScaler 1.3 换行不截断、不溢出', (
      tester,
    ) async {
      const place = '测试楼 A 区东侧三层多媒体阶梯教室（演示用很长的上课地点）';
      const teacher = '张老师、李老师、王老师、赵老师、钱老师（演示用很长的教师名单）';
      _load(
        manual: [_course('a', '测试课甲', location: place, teacher: teacher)],
      );
      await pumpHome(tester, DateTime(2026, 10, 12, 7), width: 320, scale: 1.3);
      expect(tester.takeException(), isNull);
      for (final key in ['home_course_location', 'home_course_teacher']) {
        final f = find.byKey(Key(key));
        final w = tester.widget<Text>(f);
        expect(w.maxLines, isNull);
        expect(w.overflow, isNot(TextOverflow.ellipsis));
        // 换行：比单行（12sp × 1.3）高。
        expect(tester.getSize(f).height, greaterThan(12 * 1.3 * 1.6));
      }
      expect(tester.getRect(find.byType(TimetableHomeCard)).right, 320);
    });

    testWidgets('HN11 明天卡片同样最多 2 项（今天最后一节结束后才显示明天）', (tester) async {
      _load(
        manual: [
          a,
          _course('t1', '明日课一', day: 2, start: 1, end: 2),
          _course('t2', '明日课二', day: 2, start: 3, end: 4),
          _course('t3', '明日课三', day: 2, start: 5, end: 6),
        ],
      );
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 30));
      expect(find.text('明日课一'), findsNothing);
      await pumpHome(tester, DateTime(2026, 10, 12, 20));
      expect(find.text('明日课一'), findsOneWidget);
      expect(find.text('明日课二'), findsOneWidget);
      expect(find.text('明日课三'), findsNothing);
    });
  });

  group('item 2 首页刷新', () {
    testWidgets('HN12 刷新按钮在标题右侧、48dp；标题不截断', (tester) async {
      _load(manual: [a]);
      await pumpHome(tester, DateTime(2026, 10, 12, 7), width: 320, scale: 1.5);
      expect(tester.takeException(), isNull);
      final btn = find.byKey(const Key('home_card_refresh'));
      expect(btn, findsOneWidget);
      expect(tester.getSize(btn), const Size(48, 48));
      final title = find.byKey(const Key('home_card_title'));
      expect(
        tester.getRect(btn).left,
        greaterThanOrEqualTo(tester.getRect(title).right),
      );
      final t = tester.widget<Text>(title);
      expect(t.maxLines, isNull);
      expect(t.overflow, isNot(TextOverflow.ellipsis));
    });

    testWidgets('HN13 点刷新走 manualSync：同步中图标旋转，结束后停止', (tester) async {
      _load(manual: [a]);
      final gate = Completer<void>();
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        await gate.future;
        throw const SocketException('offline (test)');
      };
      await pumpHome(tester, DateTime(2026, 10, 12, 7));
      await _io(tester);
      await tester.tap(find.byKey(const Key('home_card_refresh')));
      await _io(tester);
      expect(_c.syncStatus, TimetableSyncStatus.syncing);
      RotationTransition spin() => tester.widget<RotationTransition>(
        find.byKey(const Key('home_card_refresh_spin')),
      );
      final v0 = spin().turns.value;
      await tester.pump(const Duration(milliseconds: 200));
      expect(spin().turns.value, isNot(v0));
      gate.complete();
      await _io(tester, 5);
      expect(_c.syncStatus, isNot(TimetableSyncStatus.syncing));
      expect(spin().turns.value, 0);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('10/19 首页行点按只进课表', () {
    Future<void> pumpRouted(WidgetTester tester, DateTime now) async {
      TimetableController.clock = () => now;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: SingleChildScrollView(
                child: TimetableHomeCard(now: () => now),
              ),
            ),
          ),
          GoRoute(
            path: '/apps/timetable',
            builder: (_, _) => const Scaffold(body: Text('课表页占位')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();
    }

    void expectNoEditPage() {
      expect(find.byType(JwxtCourseEditPage), findsNothing);
      expect(find.byType(ManualCourseForm), findsNothing);
      expect(find.byType(ScheduleEventEditPage), findsNothing);
    }

    testWidgets('HN14 点今天的课程行（手动 / 教务）：打开课表页，不打开编辑页', (tester) async {
      _load(
        manual: [a],
        jwxt: [
          _course('j', '测试课教务', start: 3, end: 4, source: CourseSource.jwxt),
        ],
      );
      await pumpRouted(tester, DateTime(2026, 10, 12, 9));
      await tester.tap(find.text('测试课甲'));
      await tester.pumpAndSettle();
      expect(find.text('课表页占位'), findsOneWidget);
      expectNoEditPage();
      expect(_c.consumePendingOpen(), isNull, reason: '不再请求弹出课程详情');
    });

    testWidgets('HN15 点考试 / 日程行：同样只打开课表页', (tester) async {
      _load(manual: [a]);
      await tester.runAsync(
        () => _c.addScheduleEvent(
          ScheduleEvent(
            id: '',
            kind: ScheduleKind.exam,
            source: ScheduleSource.manual,
            title: '测试考试',
            date: DateTime(2026, 10, 12),
            start: const TimeOfDayMinutes(7, 30),
            end: const TimeOfDayMinutes(7, 50),
            location: '测试楼 A101',
          ),
        ),
      );
      await pumpRouted(tester, DateTime(2026, 10, 12, 7));
      await tester.tap(find.text('测试考试'));
      await tester.pumpAndSettle();
      expect(find.text('课表页占位'), findsOneWidget);
      expectNoEditPage();
    });
  });
}
