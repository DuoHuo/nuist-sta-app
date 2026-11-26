// 课表：「+」三选一、考试 / 其他日程表单与周视图、教务课编辑 / 删除 / 恢复、
// 首页卡片日程（design/timetable-spec.md §13.15、§14.1–§14.4）。
// 编号对齐课表测试用例 §24（EV / EX / JE / HT）。
// 全部为虚构数据（「测试课甲」「张老师」「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_layout.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';
import 'package:nuist_sta_app/router.dart';

final _c = TimetableController.instance;

/// 开学 2026-08-31；第 8 周 10/19（周一）–10/25（双周）。
final _termStart = DateTime(2026, 8, 31);
const _week = 8;
final _tuesday = DateTime(2026, 10, 20);

Course _course(
  String id,
  String name, {
  int day = 1,
  int start = 3,
  int end = 4,
  CourseSource source = CourseSource.manual,
  String location = '测试楼 A101',
}) => Course(
  id: id,
  name: name,
  source: source,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: '11111111111111111111',
      location: location,
      teacher: '张老师',
    ),
  ],
);

ScheduleEvent _event(
  String id, {
  ScheduleKind kind = ScheduleKind.exam,
  ScheduleSource source = ScheduleSource.manual,
  String title = '测试考试甲',
  DateTime? date,
  TimeOfDayMinutes start = const TimeOfDayMinutes(8, 0),
  TimeOfDayMinutes end = const TimeOfDayMinutes(9, 40),
  String? courseCode,
}) => ScheduleEvent(
  id: id,
  kind: kind,
  source: source,
  title: title,
  date: date ?? _tuesday,
  start: start,
  end: end,
  location: '测试楼 B202',
  courseCode: courseCode,
);

void _load({
  List<Course> manual = const [],
  List<Course> jwxt = const [],
  bool showExams = true,
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: _termStart,
        showExams: showExams,
      ),
    ),
    viewingWeek: _week,
    manualCourses: manual,
  );
}

/// 切换「显示考试」（不落盘，等价于设置页切换后的内存状态）。
void _setShowExams(bool on) {
  _c.debugSetSnapshot(
    _c.snapshot.copyWith(settings: _c.settings.copyWith(showExams: on)),
    viewingWeek: _c.viewingWeek,
  );
}

void _setShowNonCurrentWeek(bool on) {
  _c.debugSetSnapshot(
    _c.snapshot.copyWith(
      settings: _c.settings.copyWith(showNonCurrentWeek: on),
    ),
    viewingWeek: _c.viewingWeek,
  );
}

/// 让真实文件 IO 走完：controller 先改内存、写完盘才 notify，写盘有多个 await，
/// 每个都要一轮 runAsync + pump。
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _pumpGrid(WidgetTester tester, {int week = _week}) async {
  _bigView(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WeekGrid(key: ValueKey(week), week: week, controller: _c),
      ),
    ),
  );
  await tester.pump();
}

/// 在空页面上用按钮打开弹层（便于点按钮后观察弹层关闭）。
Future<void> _pumpLauncher(
  WidgetTester tester,
  void Function(BuildContext context) open,
) async {
  _bigView(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('launcher'),
              onPressed: () => open(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pumpAndSettle();
}

Finder _eventCell(String title) =>
    find.widgetWithText(ScheduleEventCell, title);

void main() {
  late Directory tmp;
  final origClock = TimetableController.clock;
  final origBinding = TimetableController.bindingCheck;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tt_mobile_a');
    TimetableStore.debugDirectory = tmp;
    TimetableController.bindingCheck = () async => false;
    TimetableController.clock = () => DateTime(2026, 10, 19, 7);
    _c.debugReset();
  });

  tearDown(() {
    TimetableController.clock = origClock;
    TimetableController.bindingCheck = origBinding;
    TimetableStore.debugDirectory = null;
    _c.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('EV 「+」三选一与日程表单、教务/手动考试修改恢复', () {
    testWidgets('「+」菜单进入考试/其他表单、时间校验、删除二次确认、EX17/EX23 恢复及返回', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      _bigView(tester);
      await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // 1. 「+」三项；选「其他」进添加日程后返回
      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      for (final k in [
        'add_entry_course',
        'add_entry_exam',
        'add_entry_other',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget);
      }
      await tester.tap(find.text('其他'));
      await tester.pumpAndSettle();
      expect(find.text('添加日程'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // 2. EV02 名称为空保存禁用，填写保存为手动考试（EV15）；EV03 结束时间不晚于开始时间报错
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final bad = _event(
        'tmp',
        kind: ScheduleKind.other,
        title: '测试日程甲',
        start: const TimeOfDayMinutes(10, 0),
        end: const TimeOfDayMinutes(10, 0),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScheduleEventEditPage(controller: _c, initial: bad),
        ),
      );
      await tester.pump();
      expect(find.text('结束时间需晚于开始时间'), findsOneWidget);
      await tester.tap(find.byKey(const Key('schedule_form_save')));
      await _settleIo(tester);
      expect(_c.scheduleEvents, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: ScheduleEventEditPage(
            controller: _c,
            kind: ScheduleKind.exam,
            initialDate: _tuesday,
          ),
        ),
      );
      await tester.pump();
      TextButton save() =>
          tester.widget(find.byKey(const Key('schedule_form_save')));
      expect(save().onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('schedule_form_title')),
        '测试考试甲',
      );
      await tester.enterText(
        find.byKey(const Key('schedule_form_location')),
        '测试楼 B202',
      );
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('schedule_form_save')));
      await _settleIo(tester);
      final manualExam = _c.scheduleEvents.single;
      expect(manualExam.kind, ScheduleKind.exam);
      expect(manualExam.source, ScheduleSource.manual);

      // 3. EX23 手动考试详情无「恢复原考试」，支持取消/确认删除
      await _pumpLauncher(
        tester,
        (ctx) => showScheduleEventDetailSheet(
          ctx,
          event: manualExam,
          controller: _c,
        ),
      );
      expect(find.text('恢复原考试'), findsNothing);
      expect(find.text('已修改'), findsNothing);
      await tester.tap(find.byKey(const Key('schedule_detail_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule_delete_cancel')));
      await tester.pumpAndSettle();
      expect(_c.scheduleEvents, hasLength(1));
      await tester.tap(find.byKey(const Key('schedule_detail_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule_delete_confirm')));
      await _settleIo(tester);
      expect(_c.scheduleEvents, isEmpty);

      // 4. EX17 教务考试改日期/地点后详情按原 examKey 显示「已修改」+「恢复原考试」并可恢复
      _c.debugReset();
      _load(manual: [_course('m1', '测试课甲')]);
      final jwxtExam = _event(
        'j1',
        source: ScheduleSource.jwxt,
        courseCode: 'TEST01',
      );
      await tester.runAsync(() async {
        await _c.replaceJwxtExams([jwxtExam]);
        await _c.updateScheduleEvent(
          _c.scheduleEvents.single.copyWith(
            date: DateTime(2026, 10, 22),
            location: '测试楼 C303',
          ),
        );
      });
      final key = _c.jwxtExamKeyOf('j1')!;
      expect(_c.isJwxtOverridden(examKey: key), isTrue);
      await _pumpLauncher(
        tester,
        (ctx) => showScheduleEventDetailSheet(
          ctx,
          event: _c.scheduleEvents.single,
          controller: _c,
        ),
      );
      expect(find.text('已修改'), findsOneWidget);
      expect(find.text('恢复原考试'), findsOneWidget);
      await tester.tap(find.byKey(const Key('schedule_detail_restore')));
      await _settleIo(tester);
      expect(_c.isJwxtOverridden(examKey: key), isFalse);
      expect(_c.scheduleEvents.single.location, '测试楼 B202');

      // 5. 日程编辑页支持正常退出返回
      await _pumpLauncher(
        tester,
        (context) => showScheduleEventEditPage(
          context,
          controller: _c,
          kind: ScheduleKind.other,
        ),
      );
      final route =
          ModalRoute.of(
                tester.element(find.byKey(const Key('schedule_form_title'))),
              )!
              as PageRoute;
      expect(route.popGestureEnabled, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_form_title')), findsNothing);
    });
  });

  group('EV/EX 周视图显示', () {
    test('EV05/EV06/EV-2 时间映射：覆盖所有有重叠的节次；不与任何节次重叠 → 不进网格（不取整）', () {
      final p = TimetableController.defaultPeriods();
      TimeOfDayMinutes t(int h, int m) => TimeOfDayMinutes(h, m);
      ({int startNode, int endNode}) r(int a, int b) =>
          (startNode: a, endNode: b);
      // 恰好对齐节次。
      expect(scheduleNodeRange(p, t(8, 0), t(9, 40)), r(1, 2));
      expect(scheduleNodeRange(p, t(8, 55), t(9, 40)), r(2, 2));
      // 部分重叠：碰到的节都算。
      expect(scheduleNodeRange(p, t(8, 50), t(9, 30)), r(2, 2));
      expect(scheduleNodeRange(p, t(8, 30), t(9, 0)), r(1, 2));
      expect(scheduleNodeRange(p, t(7, 30), t(8, 10)), r(1, 1));
      expect(scheduleNodeRange(p, t(11, 30), t(14, 0)), r(4, 5));
      expect(scheduleNodeRange(p, t(21, 0), t(22, 0)), r(11, 11));
      // 首尾恰在上下课时刻不算重叠。
      expect(scheduleNodeRange(p, t(8, 45), t(8, 55)), isNull);
      expect(scheduleNodeRange(p, t(8, 45), t(10, 10)), r(2, 2));
      // 整段在课间 / 午休 / 所有节次之外 → null（不再取整到最近节）。
      expect(scheduleNodeRange(p, t(9, 50), t(10, 0)), isNull);
      expect(scheduleNodeRange(p, t(12, 0), t(13, 30)), isNull);
      expect(scheduleNodeRange(p, t(21, 30), t(22, 30)), isNull);
      expect(scheduleNodeRange(p, t(6, 0), t(7, 0)), isNull);
      // 零时长：落在节内才算。
      expect(scheduleNodeRange(p, t(8, 10), t(8, 10)), r(1, 1));
      expect(scheduleNodeRange(p, t(12, 0), t(12, 0)), isNull);
      expect(scheduleNodeRange(const [], t(8, 0), t(9, 0)), isNull);
    });

    test('EV22 EV23 碰到的每一节整节覆盖：格子数 = 碰到的节数', () async {
      final p = TimetableController.defaultPeriods();
      TimeOfDayMinutes t(int h, int m) => TimeOfDayMinutes(h, m);
      // EV22：14:00–16:10 碰到第 5（13:45–14:30）、6、7（15:55–16:40）节。
      expect(scheduleNodeRange(p, t(14, 0), t(16, 10)), (
        startNode: 5,
        endNode: 7,
      ));
      // EV23：结束落在课间只算第 1 节；碰到第 2 节开头则画第 1–2 节。
      expect(scheduleNodeRange(p, t(8, 0), t(8, 50)), (
        startNode: 1,
        endNode: 1,
      ));
      expect(scheduleNodeRange(p, t(8, 0), t(9, 0)), (
        startNode: 1,
        endNode: 2,
      ));

      _load(manual: [_course('m1', '测试课甲')]);
      await _c.addScheduleEvent(
        _event(
          'ev22',
          kind: ScheduleKind.other,
          title: '测试日程甲',
          start: t(14, 0),
          end: t(16, 10),
        ),
      );
      final item = scheduleItemsForColumn(_c, _week, 2).single;
      expect((item.startNode, item.endNode), (5, 7));
      expect(item.endNode - item.startNode + 1, 3);
    });

    test('EV21 学期外日期的「其他」与考试：第 1–20 周都不显示，当天日程列表照常有', () async {
      _load(manual: [_course('m1', '测试课甲')]);
      final before = DateTime(2026, 8, 30); // 开学前一天（周日）
      final after = DateTime(2027, 3, 1); // 远超第 20 周
      await _c.addScheduleEvent(
        _event(
          'o-out',
          kind: ScheduleKind.other,
          title: '测试日程学期外',
          date: before,
        ),
      );
      await _c.addScheduleEvent(_event('x-out', date: after));
      for (var w = 1; w <= 20; w++) {
        for (var d = 1; d <= 7; d++) {
          final ids = {
            for (final i in scheduleItemsForColumn(_c, w, d)) i.event.id,
            for (final e in scheduleUnplacedForColumn(_c, w, d)) e.id,
          };
          expect(ids, isEmpty, reason: '第 $w 周 周$d');
        }
      }
      // 首页卡片按当天日期取（scheduleEventsOn）：照常列出。
      expect(_c.scheduleEventsOn(before).map((e) => e.id), ['o-out']);
      expect(_c.scheduleEventsOn(after).map((e) => e.id), ['x-out']);
    });

    test('EX-offweek-1 日期在查看周内必有 item；showExams 关则无', () async {
      _load(manual: [_course('m1', '测试课甲')]);
      await _c.addScheduleEvent(_event('ex1'));
      final items = scheduleItemsForColumn(_c, _week, 2);
      expect(items.single.event.title, '测试考试甲');
      expect(items.single.activeThisWeek, isTrue); // clock 默认≈第 8 周
      _setShowExams(false);
      expect(scheduleItemsForColumn(_c, _week, 2), isEmpty);
    });

    testWidgets('周格渲染、非本周幽灵、重叠「2 项」、表头不在节次内圆点列表与学期外提示', (tester) async {
      final sem = tester.ensureSemantics();
      try {
        // 1. 考试/其他格与「显示考试」、非本周幽灵状态切换、与课程重叠优先显示考试与冲突计数
        _load(manual: [_course('m1', '测试课甲', day: 2, start: 1, end: 2)]);
        await tester.runAsync(() => _c.addScheduleEvent(_event('')));
        final other = _event(
          'other1',
          kind: ScheduleKind.other,
          title: '测试日程甲',
          start: const TimeOfDayMinutes(13, 45),
          end: const TimeOfDayMinutes(15, 25),
        );
        await tester.runAsync(() => _c.addScheduleEvent(other));
        await _pumpGrid(tester);
        expect(_eventCell('测试考试甲'), findsOneWidget);
        expect(
          find.byKey(const Key('schedule_cell_conflict_dot')),
          findsOneWidget,
        );
        expect(find.text('2 项'), findsOneWidget);
        expect(_eventCell('测试日程甲'), findsOneWidget);
        expect(
          find.byKey(const Key('schedule_cell_other_pill')),
          findsOneWidget,
        );

        _setShowExams(false);
        await _pumpGrid(tester);
        expect(_eventCell('测试考试甲'), findsNothing);
        expect(find.text('2 项'), findsNothing);
        expect(_eventCell('测试日程甲'), findsOneWidget);

        _setShowExams(true);
        _setShowNonCurrentWeek(true);
        await tester.runAsync(
          () => _c.addScheduleEvent(
            _event(
              'ghost3',
              title: '幽灵考试乙',
              date: _tuesday.add(const Duration(days: 1)),
            ),
          ),
        );
        await _pumpGrid(tester, week: 5);
        final ghost = _eventCell('幽灵考试乙');
        expect(ghost, findsOneWidget);
        expect(
          find.descendant(
            of: ghost,
            matching: find.byKey(const Key('schedule_cell_off_week_pill')),
          ),
          findsOneWidget,
        );
        await _pumpGrid(tester, week: 9);
        expect(_eventCell('幽灵考试乙'), findsNothing);

        // 2. 不在节次内的午休/晚间日程：不画格子，表头显示圆点 + 读屏，点击列表再打开详情
        _c.debugReset();
        _load(manual: [_course('m1', '测试课甲')]);
        final lunch = _event(
          'lunch',
          kind: ScheduleKind.other,
          title: '测试日程午休',
          date: _tuesday,
          start: const TimeOfDayMinutes(12, 0),
          end: const TimeOfDayMinutes(13, 30),
        );
        final late = _event(
          'late',
          title: '测试考试晚',
          date: _tuesday,
          start: const TimeOfDayMinutes(21, 30),
          end: const TimeOfDayMinutes(22, 30),
        );
        await tester.runAsync(() async {
          await _c.addScheduleEvent(late);
          await _c.addScheduleEvent(lunch);
        });
        await _pumpGrid(tester);
        expect(_eventCell('测试日程午休'), findsNothing);
        expect(_eventCell('测试考试晚'), findsNothing);
        expect(find.bySemanticsLabel('周二，另有 2 项不在节次内'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('day_header_unplaced_2')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('unplaced_events_sheet')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('unplaced_item_late')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('schedule_detail_sheet')), findsOneWidget);

        // 3. 日期不在本学期：编辑页展示提示且仍可保存并在首页卡片列出
        final outside = DateTime(2027, 3, 1);
        expect(isOutsideTermWeeks(_c, DateTime(2026, 8, 30)), isTrue);
        await _pumpLauncher(
          tester,
          (context) => showScheduleEventEditPage(
            context,
            controller: _c,
            initialDate: outside,
          ),
        );
        expect(find.text('不在本学期，周视图里看不到'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('schedule_form_title')),
          '测试日程学期外',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('schedule_form_save')));
        await _settleIo(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TimetableHomeCard(now: () => DateTime(2027, 3, 1, 7)),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('测试日程学期外'), findsOneWidget);
      } finally {
        sem.dispose();
      }
    });
  });

  group('首页考试卡、考试列表与定位', () {
    final examsToday = DateTime(2026, 10, 12);
    ScheduleEvent examCardItem(
      String id,
      DateTime date, {
      int sh = 9,
      int sm = 0,
      int eh = 11,
      int em = 0,
    }) => _event(
      id,
      title: '测试考试$id',
      date: date,
      start: TimeOfDayMinutes(sh, sm),
      end: TimeOfDayMinutes(eh, em),
    );

    test('examDaysAway：今天 0、明天 1、昨天 -1', () {
      expect(examDaysAway(examsToday, DateTime(2026, 10, 12)), 0);
      expect(examDaysAway(examsToday, DateTime(2026, 10, 13)), 1);
      expect(examDaysAway(examsToday, DateTime(2026, 10, 11)), -1);
      expect(examDaysAway(DateTime(2026, 12, 31), DateTime(2027, 1, 1)), 1);
    });

    test('examCountdownLabel：今天/明天/后天/还有X天/已结束', () {
      expect(examCountdownLabel(examsToday, DateTime(2026, 10, 12)), '今天');
      expect(examCountdownLabel(examsToday, DateTime(2026, 10, 13)), '明天');
      expect(examCountdownLabel(examsToday, DateTime(2026, 10, 14)), '后天');
      expect(examCountdownLabel(examsToday, DateTime(2026, 10, 20)), '还有 8 天');
      expect(examCountdownLabel(examsToday, DateTime(2026, 10, 11)), '已结束');
    });

    test('upcomingExams：只要考试、排除过去、按日期升序', () async {
      _load();
      await _c.addScheduleEvent(examCardItem('c', DateTime(2026, 10, 20)));
      await _c.addScheduleEvent(examCardItem('a', DateTime(2026, 10, 13)));
      await _c.addScheduleEvent(examCardItem('p', DateTime(2026, 10, 11)));
      await _c.addScheduleEvent(
        _event(
          'o',
          kind: ScheduleKind.other,
          title: '其他日程',
          date: DateTime(2026, 10, 15),
          start: const TimeOfDayMinutes(9, 0),
          end: const TimeOfDayMinutes(10, 0),
        ),
      );
      expect(
        upcomingExams(_c, today: examsToday).map((e) => e.title).toList(),
        ['测试考试a', '测试考试c'],
      );
    });

    for (final showExams in [false, true]) {
      test('考试查询不受显示开关影响：showExams=$showExams', () async {
        _load(showExams: showExams);
        await _c.replaceJwxtExams([
          examCardItem(
            'u',
            examsToday,
          ).copyWith(source: ScheduleSource.jwxt, courseCode: 'k-u'),
          examCardItem(
            'p',
            DateTime(2026, 10, 11),
          ).copyWith(source: ScheduleSource.jwxt, courseCode: 'k-p'),
        ]);
        await _c.addScheduleEvent(
          _event(
            'o',
            kind: ScheduleKind.other,
            title: '其他日程',
            date: examsToday,
            start: const TimeOfDayMinutes(9, 0),
            end: const TimeOfDayMinutes(10, 0),
          ),
        );
        expect(upcomingExams(_c, today: examsToday).map((e) => e.id), ['u']);
        expect(pastExams(_c, today: examsToday).map((e) => e.id), ['p']);
        expect(
          _c.scheduleEventsOn(examsToday).map((e) => e.id),
          showExams ? ['u', 'o'] : ['o'],
        );
        expect(
          (await ScheduleStore.readEvents()).where((e) => e.isExam),
          hasLength(2),
        );
      });
    }

    testWidgets('首页与考试列表卡片展示/截断、开关仅影响周课表及单场定位重复触发', (tester) async {
      // 1. 无未来考试时整张卡片隐藏；有未来考试时展示倒计时并按 homeMaxExams 截断
      _load();
      await tester.runAsync(
        () => _c.addScheduleEvent(examCardItem('old', DateTime(2026, 10, 11))),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableExamsCard(now: () => examsToday)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('exams_card_title')), findsNothing);

      await tester.runAsync(() async {
        await _c.addScheduleEvent(examCardItem('e0', examsToday));
        await _c.addScheduleEvent(examCardItem('e2', DateTime(2026, 10, 15)));
        await _c.addScheduleEvent(examCardItem('e3', DateTime(2026, 10, 18)));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('今天'), findsWidgets);
      expect(find.byKey(const Key('exams_card_row_e0')), findsOneWidget);
      expect(find.byKey(const Key('exams_card_row_e2')), findsOneWidget);
      expect(find.byKey(const Key('exams_card_row_e3')), findsNothing);

      await tester.runAsync(
        () => _c.updateSettings(_c.settings.copyWith(homeMaxExams: 3)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exams_card_row_e3')), findsOneWidget);

      // 2. showExams=false 时周课表不画，但首页卡片与考试列表始终展示
      await tester.runAsync(
        () => _c.updateSettings(_c.settings.copyWith(showExams: false)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exams_card_title')), findsOneWidget);
      await _pumpGrid(tester, week: 7);
      expect(find.byType(ScheduleEventCell), findsNothing);
      await tester.runAsync(
        () => _c.updateSettings(_c.settings.copyWith(showExams: true)),
      );

      // 3. 首页标题进列表；单场直达第 8 周、高亮 3 秒消失，返回后可再次定位
      _c.debugReset();
      _load();
      final focusExam = examCardItem('focus', DateTime(2026, 10, 20));
      await tester.runAsync(() => _c.addScheduleEvent(focusExam));
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                Scaffold(body: TimetableExamsCard(now: () => examsToday)),
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
      router.pop();
      await tester.pumpAndSettle();

      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byKey(const Key('exams_card_row_focus')));
        await tester.pumpAndSettle();
        expect(_c.viewingWeek, 8);
        expect(find.byKey(const Key('schedule_focus_focus')), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('schedule_focus_focus')), findsNothing);
        router.pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('实际路由定位未来/过去周次，深色减少动画隐藏周末晚间自动滚动，重叠点击与无节次打开详情', (tester) async {
      // 1. 实际路由从考试列表定位过去/未来周次
      _load();
      await tester.runAsync(() async {
        await _c.addScheduleEvent(examCardItem('past', DateTime(2026, 10, 6)));
        await _c.addScheduleEvent(
          examCardItem('future', DateTime(2026, 11, 23)),
        );
      });
      final router = buildRouter()..go('/apps/exam-schedule');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: appLightTheme(), routerConfig: router),
      );
      await tester.pumpAndSettle();
      for (final entry in {'future': 13, 'past': 6}.entries) {
        await tester.tap(find.byKey(Key('exams_page_row_${entry.key}')));
        await tester.pumpAndSettle();
        expect(_c.viewingWeek, entry.value);
        expect(
          find.byKey(Key('schedule_cell_${entry.key}')).hitTestable(),
          findsOneWidget,
        );
        router.pop();
        await tester.pumpAndSettle();
      }

      // 2. 深色减少动画下定位被隐藏的周日晚间考试：临时显露列、自动滚动但不改设置
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
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
      final lateExam = examCardItem(
        'late',
        DateTime(2026, 10, 18),
        sh: 19,
        sm: 40,
        eh: 21,
        em: 20,
      ).copyWith(source: ScheduleSource.jwxt, courseCode: 'test-late');
      await tester.runAsync(() => _c.replaceJwxtExams([lateExam]));
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(375, 667),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: WeekGrid(week: 7, controller: _c, focusedEvent: lateExam),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('day_header_7')), findsOneWidget);
      expect(
        find.byKey(const Key('schedule_cell_late')).hitTestable(),
        findsOneWidget,
      );
      expect(_c.settings.showExams, isFalse);
      expect(_c.settings.showSaturday, isFalse);
      expect(_c.settings.showSunday, isFalse);

      // 3. 目标考试与两组课程重叠时下半部分仍可点击弹出全部叠放；无节次直接弹出详情
      await tester.pumpWidget(const SizedBox.shrink());
      _c.debugReset();
      _c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            _course('overlap-course', '测试重叠课程', day: 2, start: 1, end: 2),
            _course('later-course', '测试后段课程', day: 2, start: 4, end: 4),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: _termStart),
        ),
        viewingWeek: 8,
      );
      final target = examCardItem(
        'target',
        DateTime(2026, 10, 20),
        sh: 9,
        em: 50,
      );
      await tester.runAsync(() async {
        await _c.addScheduleEvent(examCardItem('earlier', target.date, sh: 8));
        await _c.addScheduleEvent(target);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekGrid(week: 8, controller: _c, focusedEvent: target),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final btn = find.byKey(const Key('schedule_cell_target'));
      expect(btn.hitTestable(at: const Alignment(0, 0.8)), findsOneWidget);
      await tester.tapAt(
        tester.getRect(btn).bottomCenter - const Offset(0, 12),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('stack_item_overlap-course')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('stack_item_event_target')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      _c.debugReset();
      _load();
      final unplaced = examCardItem(
        'unplaced',
        DateTime(2026, 10, 20),
        sh: 12,
        eh: 13,
      );
      await tester.runAsync(() => _c.addScheduleEvent(unplaced));
      await tester.pumpWidget(
        MaterialApp(home: TimetablePage(focusEvent: unplaced)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ScheduleEventDetailSheet>(
              find.byType(ScheduleEventDetailSheet),
            )
            .eventId,
        'unplaced',
      );
    });
  });
}
