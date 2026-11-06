// 主页「考试安排」卡片用例（issue #30）。
// 数据全部构造，不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/router.dart';

final _c = TimetableController.instance;

/// 开学 2026-08-31；测试时钟固定 2026-10-12（周一，第 7 周）。
final _termStart = DateTime(2026, 8, 31);
final _today = DateTime(2026, 10, 12);

/// 手动考试日程；标题带 id 便于定位，备注使用有效提醒。
ScheduleEvent _exam(
  String id,
  DateTime date, {
  int sh = 9,
  int sm = 0,
  int eh = 11,
  int em = 0,
  String location = '测试楼 A101',
  String note = '请提前到场',
}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.exam,
  source: ScheduleSource.manual,
  title: '测试考试$id',
  date: date,
  start: TimeOfDayMinutes(sh, sm),
  end: TimeOfDayMinutes(eh, em),
  location: location,
  note: note,
);

/// 非考试（「其他」日程），用于确认不会混进考试卡。
ScheduleEvent _other(String id, DateTime date) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.other,
  source: ScheduleSource.manual,
  title: '测试日程$id',
  date: date,
  start: TimeOfDayMinutes(9, 0),
  end: TimeOfDayMinutes(10, 0),
);

void _load({bool showExams = true}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: const [],
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: _termStart,
        showExams: showExams,
      ),
    ),
  );
}

Future<void> _add(WidgetTester tester, ScheduleEvent e) =>
    tester.runAsync(() => _c.addScheduleEvent(e));

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TimetableExamsCard(now: () => _today)),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;
  final origFetch = TimetableController.fetchSnapshot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_exams');
    TimetableStore.debugDirectory = tmp;
    _c.debugReset();
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        throw const SocketException('offline (test)');
    TimetableController.clock = () => _today;
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableController.fetchSnapshot = origFetch;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('纯函数', () {
    test('examDaysAway：今天 0、明天 1、昨天 -1', () {
      expect(examDaysAway(_today, DateTime(2026, 10, 12)), 0);
      expect(examDaysAway(_today, DateTime(2026, 10, 13)), 1);
      expect(examDaysAway(_today, DateTime(2026, 10, 11)), -1);
      // 跨年不混：2026-12-31 → 2027-01-01 差 1 天。
      expect(examDaysAway(DateTime(2026, 12, 31), DateTime(2027, 1, 1)), 1);
    });

    test('examCountdownLabel：今天/明天/后天/还有X天/已结束', () {
      expect(examCountdownLabel(_today, DateTime(2026, 10, 12)), '今天');
      expect(examCountdownLabel(_today, DateTime(2026, 10, 13)), '明天');
      expect(examCountdownLabel(_today, DateTime(2026, 10, 14)), '后天');
      expect(examCountdownLabel(_today, DateTime(2026, 10, 20)), '还有 8 天');
      expect(examCountdownLabel(_today, DateTime(2026, 10, 11)), '已结束');
    });

    testWidgets('upcomingExams：只要考试、排除过去、按日期升序', (tester) async {
      _load();
      await _add(tester, _exam('c', DateTime(2026, 10, 20))); // 8 天后
      await _add(tester, _exam('a', DateTime(2026, 10, 13))); // 明天
      await _add(tester, _exam('p', DateTime(2026, 10, 11))); // 昨天，排除
      await _add(tester, _other('o', DateTime(2026, 10, 15))); // 非考试，排除
      final got = upcomingExams(_c, today: _today);
      expect(got.map((e) => e.title).toList(), ['测试考试a', '测试考试c']);
    });

    for (final showExams in [false, true]) {
      test('考试查询不受显示开关影响：showExams=$showExams', () async {
        _load(showExams: showExams);
        final upcoming = _exam(
          'a',
          _today,
        ).copyWith(source: ScheduleSource.jwxt, courseCode: 'test-a');
        final past = _exam(
          'p',
          DateTime(2026, 10, 11),
        ).copyWith(source: ScheduleSource.jwxt, courseCode: 'test-p');
        await _c.replaceJwxtExams([past, upcoming]);
        await _c.addScheduleEvent(_other('o', _today));
        expect(upcomingExams(_c, today: _today).map((e) => e.id), ['a']);
        expect(pastExams(_c, today: _today).map((e) => e.id), ['p']);
        expect(
          _c.scheduleEventsOn(_today).map((e) => e.id),
          showExams ? ['a', 'o'] : ['o'],
        );
        expect(
          (await ScheduleStore.readEvents()).where((e) => e.isExam),
          hasLength(2),
        );
      });
    }
  });

  group('卡片 UI', () {
    testWidgets('有未来考试：显示卡片与倒计时，保留考场和有效备注', (tester) async {
      _load();
      await _add(tester, _exam('a', DateTime(2026, 10, 13))); // 明天
      await _add(tester, _exam('b', DateTime(2026, 10, 20))); // 还有 8 天
      await _pump(tester);

      expect(find.byKey(const Key('exams_card_title')), findsOneWidget);
      expect(find.text('考试安排'), findsOneWidget);
      expect(find.text('近期 2 场'), findsOneWidget);
      // 科目都在。
      expect(find.text('测试考试a'), findsOneWidget);
      expect(find.text('测试考试b'), findsOneWidget);
      // 倒计时与日期。
      expect(find.textContaining('明天'), findsWidgets);
      expect(find.textContaining('还有 8 天'), findsOneWidget);
      // 考场与用户填写的有效备注。
      expect(find.text('@测试楼 A101'), findsNWidgets(2));
      expect(find.text('请提前到场'), findsNWidgets(2));
    });

    testWidgets('今天的考试也显示并标「今天」', (tester) async {
      _load();
      await _add(tester, _exam('a', _today));
      await _pump(tester);
      expect(find.text('测试考试a'), findsOneWidget);
      expect(find.textContaining('今天'), findsWidgets);
    });

    testWidgets('无未来考试：整张卡片隐藏', (tester) async {
      _load();
      await _add(tester, _exam('p', DateTime(2026, 10, 11))); // 只有过去的
      await _pump(tester);
      expect(find.byKey(const Key('exams_card_title')), findsNothing);
      expect(find.text('考试安排'), findsNothing);
    });

    testWidgets('教务考试：切换开关只影响周课表，卡片与列表始终显示', (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      _c.debugSetSnapshot(
        TimetableSnapshot(
          courses: const [],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: today.subtract(Duration(days: today.weekday - 1)),
          ),
        ),
        viewingWeek: 1,
      );
      final upcoming = _exam(
        'a',
        today,
      ).copyWith(source: ScheduleSource.jwxt, courseCode: 'test-a');
      final past = _exam(
        'p',
        today.subtract(const Duration(days: 1)),
      ).copyWith(source: ScheduleSource.jwxt, courseCode: 'test-p');
      await tester.runAsync(() => _c.replaceJwxtExams([upcoming, past]));
      // 同一份教务数据反复切换，确认无须重新同步就能恢复周课表。
      for (final showExams in [false, true, false]) {
        await tester.runAsync(
          () => _c.updateSettings(_c.settings.copyWith(showExams: showExams)),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TimetableExamsCard(now: () => today)),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('exams_card_title')), findsOneWidget);
        expect(find.text('测试考试a'), findsOneWidget);
        expect(find.text('测试考试p'), findsNothing);

        await tester.pumpWidget(const MaterialApp(home: TimetableExamsPage()));
        await tester.pump();
        expect(find.text('即将到来（1）'), findsOneWidget);
        expect(find.text('已结束（1）'), findsOneWidget);
        expect(find.byKey(const Key('exams_page_row_a')), findsOneWidget);
        expect(find.byKey(const Key('exams_page_row_p')), findsOneWidget);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: WeekGrid(week: 1, controller: _c)),
          ),
        );
        await tester.pump();
        final cell = find.byWidgetPredicate(
          (w) => w is ScheduleEventCell && w.event.id == 'a',
        );
        expect(cell, showExams ? findsOneWidget : findsNothing);
      }
    });
  });

  group('考试定位', () {
    setUp(() {
      // 已有本地数据即可定位，避免导航测试触发同步。
      TimetableController.bindingCheck = () async => false;
    });

    testWidgets('首页单场直达所在周，提示消退后返回仍可再次定位，标题进入列表', (tester) async {
      _load();
      final exam = _exam('focus', DateTime(2026, 10, 20));
      await _add(tester, exam);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                Scaffold(body: TimetableExamsCard(now: () => _today)),
          ),
          GoRoute(
            path: '/apps/exam-schedule',
            builder: (_, _) => const TimetableExamsPage(),
          ),
          GoRoute(
            path: '/apps/timetable',
            builder: (_, state) =>
                TimetablePage(focusEvent: state.extra as ScheduleEvent?),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: appLightTheme(), routerConfig: router),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exams_card_title')));
      await tester.pumpAndSettle();
      expect(find.byType(TimetableExamsPage), findsOneWidget);
      expect(find.byType(TimetablePage), findsNothing);
      router.pop();
      await tester.pumpAndSettle();

      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byKey(const Key('exams_card_row_focus')));
        await tester.pumpAndSettle();
        expect(find.byType(TimetablePage), findsOneWidget);
        expect(_c.viewingWeek, 8);
        expect(
          find.byKey(const Key('schedule_cell_focus')).hitTestable(),
          findsOneWidget,
        );
        expect(find.byKey(const Key('schedule_focus_focus')), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('schedule_focus_focus')), findsNothing);
        expect(find.byKey(const Key('schedule_cell_focus')), findsOneWidget);
        // 翻到不相邻周以销毁目标网格，再回来只显示考试，不重新强调。
        _c.setViewingWeek(10);
        await tester.pumpAndSettle();
        _c.setViewingWeek(8);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('schedule_cell_focus')), findsOneWidget);
        expect(find.byKey(const Key('schedule_focus_focus')), findsNothing);
        router.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('exams_card_row_focus')), findsOneWidget);
      }
    });

    testWidgets('实际路由：考试列表中的未来和已结束考试均定位到各自周次', (tester) async {
      _load();
      await _add(tester, _exam('past', DateTime(2026, 10, 6)));
      await _add(tester, _exam('future', DateTime(2026, 11, 23)));
      final router = buildRouter()..go('/apps/exam-schedule');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: appLightTheme(), routerConfig: router),
      );
      await tester.pumpAndSettle();

      for (final entry in {'future': 13, 'past': 6}.entries) {
        await tester.tap(find.byKey(Key('exams_page_row_${entry.key}')));
        await tester.pumpAndSettle();
        expect(find.byType(TimetablePage), findsOneWidget);
        expect(_c.viewingWeek, entry.value);
        expect(
          find.byKey(Key('schedule_cell_${entry.key}')).hitTestable(),
          findsOneWidget,
        );
        router.pop();
        await tester.pumpAndSettle();
        expect(find.byType(TimetableExamsPage), findsOneWidget);
      }
    });

    testWidgets('深色减少动画：隐藏的周末晚间考试可见并自动滚动，不改显示设置', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      _c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: _termStart,
            showExams: false,
            showSaturday: false,
            showSunday: false,
          ),
        ),
        viewingWeek: 7,
      );
      final exam = _exam(
        'late',
        DateTime(2026, 10, 18),
        sh: 19,
        sm: 40,
        eh: 21,
        em: 20,
      ).copyWith(source: ScheduleSource.jwxt, courseCode: 'test-late');
      await tester.runAsync(() => _c.replaceJwxtExams([exam]));
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(375, 667),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: WeekGrid(week: 7, controller: _c, focusedEvent: exam),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('day_header_7')), findsOneWidget);
      final cell = find.byKey(const Key('schedule_cell_late'));
      expect(cell.hitTestable(), findsOneWidget);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(WeekGrid),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.pixels, greaterThan(0));
      expect(find.byKey(const Key('schedule_focus_late')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_focus_late')), findsNothing);
      expect(cell.hitTestable(), findsOneWidget);
      expect(_c.settings.showExams, isFalse);
      expect(_c.settings.showSaturday, isFalse);
      expect(_c.settings.showSunday, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('目标考试与课程及另一考试重叠时展示目标，仍可查看全部安排', (tester) async {
      for (final separateCourseGroups in [false, true]) {
        await tester.pumpWidget(const SizedBox.shrink());
        _c.debugReset();
        _c.debugSetSnapshot(
          TimetableSnapshot(
            courses: [
              Course(
                id: 'overlap-course',
                name: '测试重叠课程',
                slots: [
                  CourseSlot(
                    day: 2,
                    startNode: 1,
                    endNode: separateCourseGroups ? 2 : 4,
                    weeks: '1' * 20,
                  ),
                ],
              ),
              if (separateCourseGroups)
                Course(
                  id: 'later-course',
                  name: '测试后段课程',
                  slots: [
                    CourseSlot(
                      day: 2,
                      startNode: 4,
                      endNode: 4,
                      weeks: '1' * 20,
                    ),
                  ],
                ),
            ],
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(termStartDate: _termStart),
          ),
          viewingWeek: 8,
        );
        final exam = _exam(
          'target',
          DateTime(2026, 10, 20),
          sh: separateCourseGroups ? 9 : 10,
          em: separateCourseGroups ? 50 : 0,
        );
        await _add(tester, _exam('earlier', exam.date, sh: 8));
        await _add(tester, exam);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WeekGrid(week: 8, controller: _c, focusedEvent: exam),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cell = find.byWidgetPredicate(
          (widget) =>
              widget is ScheduleEventCell && widget.event.id == 'target',
        );
        expect(cell, findsOneWidget);
        expect(
          tester.widget<ScheduleEventCell>(cell).stackCount,
          separateCourseGroups ? 4 : 3,
        );
        final button = find.byKey(const Key('schedule_cell_target'));
        // 考试跨过两组课程时，下半部也必须由目标接收点击，不能被后绘制的课程盖住。
        expect(button.hitTestable(at: const Alignment(0, 0.8)), findsOneWidget);
        await tester.tapAt(
          tester.getRect(button).bottomCenter - const Offset(0, 12),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('stack_item_overlap-course')),
          findsOneWidget,
        );
        if (separateCourseGroups) {
          expect(
            find.byKey(const Key('stack_item_later-course')),
            findsOneWidget,
          );
        }
        expect(
          find.byKey(const Key('stack_item_event_earlier')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('stack_item_event_target')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('没有对应节次或开学日期时打开考试详情，避免定位到无关课程', (tester) async {
      for (final hasTermStart in [true, false]) {
        await tester.pumpWidget(const SizedBox.shrink());
        _c.debugReset();
        _c.debugSetSnapshot(
          TimetableSnapshot(
            periods: TimetableController.defaultPeriods(),
            settings: TimetableSettings(
              termStartDate: hasTermStart ? _termStart : null,
            ),
          ),
          viewingWeek: 1,
        );
        final exam = _exam('unplaced', DateTime(2026, 10, 20), sh: 12, eh: 13);
        await _add(tester, exam);
        await tester.pumpWidget(
          MaterialApp(home: TimetablePage(focusEvent: exam)),
        );
        await tester.pumpAndSettle();
        final detail = tester.widget<ScheduleEventDetailSheet>(
          find.byType(ScheduleEventDetailSheet),
        );
        expect(detail.eventId, 'unplaced');
        expect(_c.viewingWeek, hasTermStart ? 8 : 1);
        expect(find.byKey(const Key('schedule_cell_unplaced')), findsNothing);
        if (hasTermStart) {
          Navigator.of(tester.element(find.byType(ScheduleEventDetailSheet)))
              .pop();
          await tester.pumpAndSettle();
          _c.setViewingWeek(10);
          await tester.pumpAndSettle();
          _c.setViewingWeek(8);
          await tester.pumpAndSettle();
          expect(find.byType(ScheduleEventDetailSheet), findsNothing);
          expect(
            find.byKey(const Key('schedule_focus_unplaced')),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      }
    });
  });
}
