// 主页「考试安排」卡片用例（issue #30）。
// 数据全部构造（课名「测试考试X」、地点「测试楼 A101」、座位「座位号 12」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

/// 开学 2026-08-31；测试时钟固定 2026-10-12（周一，第 7 周）。
final _termStart = DateTime(2026, 8, 31);
final _today = DateTime(2026, 10, 12);

/// 手动考试日程；标题带 id 便于定位，地点含考场、备注含座位号。
ScheduleEvent _exam(
  String id,
  DateTime date, {
  int sh = 9,
  int sm = 0,
  int eh = 11,
  int em = 0,
  String location = '测试楼 A101',
  String note = '座位号 12',
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
    testWidgets('有未来考试：显示卡片与倒计时，含考场与座位号', (tester) async {
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
      // 考场与座位号（直观界面要素）。
      expect(find.text('@测试楼 A101'), findsNWidgets(2));
      expect(find.text('座位号 12'), findsNWidgets(2));
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
}
