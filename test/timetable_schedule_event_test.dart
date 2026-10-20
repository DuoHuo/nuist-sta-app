// 课表：「+」三选一、考试 / 其他日程表单与周视图、教务课编辑 / 删除 / 恢复、
// 首页卡片日程（design/timetable-spec.md §13.15、§14.1–§14.4）。
// 编号对齐课表测试用例 §24（EV / EX / JE / HT）。
// 全部为虚构数据（「测试课甲」「张老师」「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

final _c = TimetableController.instance;

/// 开学 2026-08-31；第 8 周 10/19（周一）–10/25（双周）。
final _termStart = DateTime(2026, 8, 31);
const _week = 8;
final _monday = DateTime(2026, 10, 19);
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

Positioned _positionedOf(WidgetTester tester, Finder f) => tester.widget(
  find.ancestor(of: f, matching: find.byType(Positioned)).first,
);

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

  group('EV 「+」三选一与日程表单', () {
    testWidgets('EV01 「+」弹出「课程」「考试」「其他」三项；「考试」进入新表单', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      _bigView(tester);
      await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add_entry_sheet')), findsOneWidget);
      final tiles = find.descendant(
        of: find.byKey(const Key('add_entry_sheet')),
        matching: find.byType(ListTile),
      );
      expect(tiles, findsNWidgets(3));
      for (final k in [
        'add_entry_course',
        'add_entry_exam',
        'add_entry_other',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget);
      }
      expect(find.text('课程'), findsOneWidget);
      expect(find.text('考试'), findsOneWidget);
      expect(find.text('其他'), findsOneWidget);

      await tester.tap(find.byKey(const Key('add_entry_exam')));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleEventEditPage), findsOneWidget);
      expect(find.text('添加考试'), findsOneWidget);
    });

    testWidgets('EV01 「其他」进入日程表单（标题「添加日程」）', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      _bigView(tester);
      await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add_entry_other')));
      await tester.pumpAndSettle();
      expect(find.text('添加日程'), findsOneWidget);
      expect(find.byKey(const Key('schedule_form_course_code')), findsNothing);
    });

    testWidgets('EV02 字段齐全；名称为空时「保存」禁用，填写后可保存为手动考试（EV15）', (tester) async {
      _load();
      _bigView(tester);
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
      for (final k in [
        'schedule_form_title',
        'schedule_form_date',
        'schedule_form_start',
        'schedule_form_end',
        'schedule_form_location',
        'schedule_form_note',
        'schedule_form_course_code',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      TextButton save() =>
          tester.widget(find.byKey(const Key('schedule_form_save')));
      expect(save().onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('schedule_form_title')),
        '   ',
      );
      await tester.pump();
      expect(save().onPressed, isNull, reason: '只有空格也算空');

      await tester.enterText(
        find.byKey(const Key('schedule_form_title')),
        '测试考试甲',
      );
      await tester.enterText(
        find.byKey(const Key('schedule_form_course_code')),
        'TEST01',
      );
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('schedule_form_save')));
      await _settleIo(tester);
      final saved = _c.scheduleEvents.single;
      expect(saved.kind, ScheduleKind.exam);
      expect(saved.source, ScheduleSource.manual);
      expect(saved.title, '测试考试甲');
      expect(saved.date, _tuesday);
      expect(saved.courseCode, 'TEST01');
      expect(saved.end.compareTo(saved.start), greaterThan(0));
      expect(_c.manualCourses, isEmpty, reason: 'EV15 不写入每周手动课');
    });

    testWidgets('EV03 结束时间不晚于开始时间：提示错误，不能保存', (tester) async {
      _load();
      _bigView(tester);
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
      expect(find.byKey(const Key('schedule_form_time_error')), findsOneWidget);
      expect(find.text('结束时间需晚于开始时间'), findsOneWidget);
      await tester.tap(find.byKey(const Key('schedule_form_save')));
      await _settleIo(tester);
      expect(find.byType(ScheduleEventEditPage), findsOneWidget, reason: '未关闭');
      expect(_c.scheduleEvents, isEmpty);
    });

    testWidgets('EV16/EX24 日程详情：日期/时间/地点；删除二次确认，取消不删、确认删除', (tester) async {
      _load();
      late ScheduleEvent e;
      await tester.runAsync(() async {
        e = await _c.addScheduleEvent(_event(''));
      });
      await _pumpLauncher(
        tester,
        (ctx) => showScheduleEventDetailSheet(ctx, event: e, controller: _c),
      );
      expect(find.text('10月20日 周二'), findsOneWidget);
      expect(find.text('08:00–09:40'), findsOneWidget);
      expect(find.text('测试楼 B202'), findsOneWidget);
      expect(find.byKey(const Key('schedule_detail_edit')), findsOneWidget);
      expect(find.byKey(const Key('schedule_detail_restore')), findsNothing);

      await tester.tap(find.byKey(const Key('schedule_detail_delete')));
      await tester.pumpAndSettle();
      expect(find.text('删除这场考试？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('schedule_delete_cancel')));
      await tester.pumpAndSettle();
      expect(_c.scheduleEvents, hasLength(1));

      await tester.tap(find.byKey(const Key('schedule_detail_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule_delete_confirm')));
      await _settleIo(tester);
      expect(_c.scheduleEvents, isEmpty);
      expect(find.byKey(const Key('schedule_detail_sheet')), findsNothing);
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

    testWidgets('EV05/EV13/EX02/EX04 考试画在周二第 1–2 节：考试色、白字、「考试」胶囊', (
      tester,
    ) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() => _c.addScheduleEvent(_event('')));
      await _pumpGrid(tester);
      final cell = _eventCell('测试考试甲');
      expect(cell, findsOneWidget);
      final pill = find.descendant(
        of: cell,
        matching: find.byKey(const Key('schedule_cell_exam_pill')),
      );
      expect(pill, findsOneWidget);
      expect(
        find.descendant(of: pill, matching: find.text('考试')),
        findsOneWidget,
      );
      final ink = tester.widget<Ink>(
        find.descendant(of: cell, matching: find.byType(Ink)),
      );
      expect(
        (ink.decoration! as BoxDecoration).color,
        Color(_c.settings.examColor),
      );
      final title = tester.widget<Text>(
        find.descendant(of: cell, matching: find.text('测试考试甲')),
      );
      expect(title.style?.color, TimetableTheme.examText);

      // 位置：周二列（第 2 列）、第 1–2 节。
      final pos = _positionedOf(tester, cell);
      final ph = _c.settings.periodHeight.clamp(
        TimetableTheme.periodHeightMin,
        TimetableTheme.periodHeightMax,
      );
      expect(pos.top, closeTo(TimetableTheme.cellMargin, 0.01));
      expect(pos.height, closeTo(2 * ph - 2 * TimetableTheme.cellMargin, 0.01));
      final days = _c.visibleDays(_week);
      final dayW = (pos.width! + 2 * TimetableTheme.cellMargin);
      expect(
        pos.left,
        closeTo(days.indexOf(2) * dayW + TimetableTheme.cellMargin, 0.01),
      );
    });

    testWidgets('EV08 只在所在周显示：第 7、9 周没有', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() => _c.addScheduleEvent(_event('')));
      for (final w in [7, 9]) {
        await _pumpGrid(tester, week: w);
        expect(_eventCell('测试考试甲'), findsNothing, reason: '第 $w 周');
      }
      await _pumpGrid(tester);
      expect(_eventCell('测试考试甲'), findsOneWidget);
    });

    testWidgets('EX06/EX09/EV13 「显示考试」关：不画考试；打开后立即恢复', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() => _c.addScheduleEvent(_event('')));
      _setShowExams(false);
      await _pumpGrid(tester);
      expect(_eventCell('测试考试甲'), findsNothing);
      expect(find.byKey(const Key('schedule_cell_exam_pill')), findsNothing);
      _setShowExams(true);
      await _pumpGrid(tester);
      expect(_eventCell('测试考试甲'), findsOneWidget);
    });

    testWidgets('EV10/EX06 与课程重叠显示冲突圆点和「2 门」；考试隐藏时不计冲突', (tester) async {
      _load(manual: [_course('m1', '测试课甲', day: 2, start: 1, end: 2)]);
      await tester.runAsync(() => _c.addScheduleEvent(_event('')));
      await _pumpGrid(tester);
      expect(find.text('2 门'), findsOneWidget);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsOneWidget);

      _setShowExams(false);
      await _pumpGrid(tester);
      expect(find.text('2 门'), findsNothing);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
    });

    testWidgets('EV11/EV12 「其他」：「日程」胶囊、按名称配色；不受「显示考试」控制', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      final other = _event(
        '',
        kind: ScheduleKind.other,
        title: '测试日程甲',
        start: const TimeOfDayMinutes(13, 45),
        end: const TimeOfDayMinutes(15, 25),
      );
      await tester.runAsync(() => _c.addScheduleEvent(other));
      await _pumpGrid(tester);
      final cell = _eventCell('测试日程甲');
      expect(cell, findsOneWidget);
      final pill = find.descendant(
        of: cell,
        matching: find.byKey(const Key('schedule_cell_other_pill')),
      );
      expect(pill, findsOneWidget);
      expect(
        find.descendant(of: pill, matching: find.text('日程')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('schedule_cell_exam_pill')), findsNothing);
      final idx = _c.otherColorIndexOf(_c.scheduleEvents.single);
      final ink = tester.widget<Ink>(
        find.descendant(of: cell, matching: find.byType(Ink)),
      );
      expect(
        (ink.decoration! as BoxDecoration).color,
        TimetableTheme.blendCellBg(
          TimetableTheme.courseColor(idx),
          _c.settings.cellOpacity,
        ),
      );

      _setShowExams(false);
      await _pumpGrid(tester);
      expect(_eventCell('测试日程甲'), findsOneWidget);
    });

    testWidgets('EV16 点日程格打开详情弹层', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() => _c.addScheduleEvent(_event('')));
      await _pumpGrid(tester);
      await tester.tap(_eventCell('测试考试甲'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_detail_sheet')), findsOneWidget);
      expect(find.byKey(const Key('schedule_detail_delete')), findsOneWidget);
    });
  });

  group('EV-2 不在节次内的日程（午休 / 节次之外）', () {
    final wednesday = DateTime(2026, 10, 21);
    ScheduleEvent lunch({DateTime? date}) => _event(
      'lunch',
      kind: ScheduleKind.other,
      title: '测试日程午休',
      date: date ?? _tuesday,
      start: const TimeOfDayMinutes(12, 0),
      end: const TimeOfDayMinutes(13, 30),
    );
    ScheduleEvent late({DateTime? date}) => _event(
      'late',
      title: '测试考试晚',
      date: date ?? wednesday,
      start: const TimeOfDayMinutes(21, 30),
      end: const TimeOfDayMinutes(22, 30),
    );
    Finder header(int day) => find.byKey(ValueKey('day_header_unplaced_$day'));
    Finder dotIn(int day) => find.descendant(
      of: header(day),
      matching: find.byKey(const Key('day_header_dot')),
    );
    Color dotColor(WidgetTester tester, int day) =>
        (tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: dotIn(day),
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration)
            .color!;

    testWidgets('EV07 EV32 EV33 午休日程与晚间考试：不画格子，表头日期下 4dp 圆点 + 读屏文案', (
      tester,
    ) async {
      final sem = tester.ensureSemantics();
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() async {
        await _c.addScheduleEvent(lunch());
        await _c.addScheduleEvent(late());
      });
      await _pumpGrid(tester);
      expect(_eventCell('测试日程午休'), findsNothing);
      expect(_eventCell('测试考试晚'), findsNothing);
      expect(find.byType(ScheduleEventCell), findsNothing);

      expect(dotIn(2), findsOneWidget);
      expect(dotIn(3), findsOneWidget);
      expect(find.byKey(const Key('day_header_dot')), findsNWidgets(2));
      expect(tester.getSize(dotIn(2)), const Size(4, 4));
      // 其他 → 该名称固定色（白底强调色）；考试 → examColor。
      expect(
        dotColor(tester, 2),
        scheduleAccentOnWhite(
          _c,
          _c.scheduleEvents.firstWhere((e) => e.id == 'lunch'),
        ),
      );
      expect(dotColor(tester, 3), Color(_c.settings.examColor));

      expect(find.bySemanticsLabel('周二，另有 1 项不在节次内'), findsOneWidget);
      expect(find.bySemanticsLabel('周三，另有 1 项不在节次内'), findsOneWidget);
      // 没有不在节次内日程的日期：无圆点、无点按。
      expect(header(1), findsNothing);
      sem.dispose();
    });

    testWidgets('同一天多项：圆点取最早一项颜色；点表头弹出列表，点一项打开详情', (tester) async {
      final sem = tester.ensureSemantics();
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() async {
        await _c.addScheduleEvent(late(date: _tuesday));
        await _c.addScheduleEvent(lunch());
      });
      await _pumpGrid(tester);
      expect(
        dotColor(tester, 2),
        scheduleAccentOnWhite(
          _c,
          _c.scheduleEvents.firstWhere((e) => e.id == 'lunch'),
        ),
      );
      expect(find.bySemanticsLabel('周二，另有 2 项不在节次内'), findsOneWidget);

      await tester.tap(header(2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unplaced_events_sheet')), findsOneWidget);
      expect(find.text('周二不在节次内的 2 项'), findsOneWidget);
      final a = tester.getTopLeft(
        find.byKey(const ValueKey('unplaced_item_lunch')),
      );
      final b = tester.getTopLeft(
        find.byKey(const ValueKey('unplaced_item_late')),
      );
      expect(a.dy, lessThan(b.dy)); // 按开始时间

      await tester.tap(find.byKey(const ValueKey('unplaced_item_late')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unplaced_events_sheet')), findsNothing);
      expect(find.byKey(const Key('schedule_detail_sheet')), findsOneWidget);
      expect(find.text('测试考试晚'), findsWidgets);
      sem.dispose();
    });

    testWidgets('不计入冲突圆点与「N 门」', (tester) async {
      // 周二第 1–2 节有课；同一天午休 + 晚间日程不和它成组。
      _load(manual: [_course('m1', '测试课甲', day: 2, start: 1, end: 2)]);
      await tester.runAsync(() async {
        await _c.addScheduleEvent(lunch());
        await _c.addScheduleEvent(late(date: _tuesday));
      });
      await _pumpGrid(tester);
      expect(dotIn(2), findsOneWidget);
      expect(find.textContaining('门'), findsNothing);
      expect(find.byKey(const Key('course_cell_conflict_dot')), findsNothing);
    });

    testWidgets('受「显示考试」与当前周控制', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(() async {
        await _c.addScheduleEvent(late());
      });
      await _pumpGrid(tester);
      expect(dotIn(3), findsOneWidget);

      _setShowExams(false);
      await _pumpGrid(tester);
      expect(header(3), findsNothing);
      expect(find.byKey(const Key('day_header_dot')), findsNothing);

      _setShowExams(true);
      await _pumpGrid(tester, week: _week + 1);
      expect(find.byKey(const Key('day_header_dot')), findsNothing);
      await _pumpGrid(tester, week: _week - 1);
      expect(find.byKey(const Key('day_header_dot')), findsNothing);
    });

    testWidgets('首页卡片照常按时间列出', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]); // 周一 10:10
      await tester.runAsync(() async {
        await _c.addScheduleEvent(lunch(date: _monday));
        await _c.addScheduleEvent(late(date: _monday));
      });
      final morning = DateTime(2026, 10, 19, 7);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => morning)),
        ),
      );
      await tester.pump();
      final l = find.byKey(const Key('home_event_row_lunch'));
      final t = find.byKey(const Key('home_event_row_late'));
      expect(l, findsOneWidget);
      // item 13：首页最多 2 项，最晚的一项收进「还有 1 项」。
      expect(t, findsNothing);
      expect(find.text('还有 1 项'), findsOneWidget);
    });
  });

  group('EV-1 日期不在本学期', () {
    testWidgets('日期在学期周次外：日期下灰字提示，仍可保存；首页照常显示', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      final outside = DateTime(2027, 3, 1); // 远超本学期周数
      await _pumpLauncher(
        tester,
        (context) => showScheduleEventEditPage(
          context,
          controller: _c,
          initialDate: outside,
        ),
      );
      final hint = find.byKey(const Key('schedule_form_outside_term_hint'));
      expect(hint, findsOneWidget);
      expect(find.text('不在本学期，周视图里看不到'), findsOneWidget);
      expect(tester.widget<Text>(hint).style?.color, TimetableTheme.hint);
      expect(isOutsideTermWeeks(_c, DateTime(2026, 8, 30)), isTrue); // 开学前
      expect(isOutsideTermWeeks(_c, _tuesday), isFalse);

      await tester.enterText(
        find.byKey(const Key('schedule_form_title')),
        '测试日程学期外',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('schedule_form_save')));
      await _settleIo(tester);
      expect(_c.scheduleEvents.single.date, outside);

      // 学期内日期：无提示。
      await tester.pumpWidget(
        MaterialApp(
          home: ScheduleEventEditPage(controller: _c, initialDate: _tuesday),
        ),
      );
      await tester.pump();
      expect(hint, findsNothing);

      // 首页：那天照常列出。
      final day = DateTime(2027, 3, 1, 7);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => day)),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(ValueKey('home_event_row_${_c.scheduleEvents.single.id}')),
        findsOneWidget,
      );
    });
  });

  group('「其他」日程固定配色（产品经理 10/18）', () {
    ScheduleEvent other(String id, String title) =>
        _event(id, kind: ScheduleKind.other, title: title);

    test('同名同色；写进 schedule_events.json 的 otherColors', () async {
      _load(manual: [_course('m1', '测试课甲')]);
      await _c.addScheduleEvent(other('a', '测试日程甲'));
      await _c.addScheduleEvent(other('b', '测试日程甲'));
      await _c.addScheduleEvent(other('c', '测试日程乙'));
      final ev = {for (final e in _c.scheduleEvents) e.id: e};
      expect(_c.otherColorIndexOf(ev['a']!), _c.otherColorIndexOf(ev['b']!));
      // 有空余色号时不同名称不同色。
      expect(
        _c.otherColorIndexOf(ev['a']!),
        isNot(_c.otherColorIndexOf(ev['c']!)),
      );
      final stored = await ScheduleStore.readOtherColors();
      expect(stored.keys, containsAll(['测试日程甲', '测试日程乙']));
      expect(stored['测试日程甲'], _c.otherColorIndexOf(ev['a']!));
      // 考试不登记色号。
      await _c.addScheduleEvent(_event('x'));
      expect((await ScheduleStore.readOtherColors()).length, 2);
      // 只写日程（如教务考试替换）也不丢 otherColors。
      await _c.replaceJwxtExams(const []);
      expect((await ScheduleStore.readOtherColors()).length, 2);
    });

    test('EV25 名称哈希位被课程占用 → 改用课程没用的色号', () async {
      final course = _course('m1', '测试课甲');
      _load(manual: [course]);
      final courseIdx = _c.colorIndexOf(_c.combinedCourses.single);
      String? clash;
      for (var i = 0; i < 500 && clash == null; i++) {
        final n = '测试日程$i';
        if (courseColorIndexForName(n) % kCoursePaletteSize == courseIdx) {
          clash = n;
        }
      }
      expect(clash, isNotNull);
      await _c.addScheduleEvent(other('a', clash!));
      final idx = _c.otherColorIndexOf(_c.scheduleEvents.single);
      expect(idx, isNot(courseIdx));
      expect(idx, inInclusiveRange(0, kCoursePaletteSize - 1));
    });

    test('不改课程颜色，也不写 course_colors.json', () async {
      _load(manual: [_course('m1', '测试课甲'), _course('m2', '测试课乙', day: 2)]);
      final before = {
        for (final c in _c.combinedCourses) c.id: _c.colorIndexOf(c),
      };
      final file = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final bytesBefore = file.existsSync() ? file.readAsStringSync() : null;
      for (var i = 0; i < 20; i++) {
        await _c.addScheduleEvent(other('o$i', '测试日程$i'));
      }
      final after = {
        for (final c in _c.combinedCourses) c.id: _c.colorIndexOf(c),
      };
      expect(after, before);
      expect(file.existsSync() ? file.readAsStringSync() : null, bytesBefore);
    });

    test('改名：改成已有名称 → 用该名称的颜色；改成新名称 → 沿用原颜色', () async {
      _load(manual: [_course('m1', '测试课甲')]);
      await _c.addScheduleEvent(other('a', '测试日程甲'));
      await _c.addScheduleEvent(other('b', '测试日程乙'));
      ScheduleEvent byId(String id) =>
          _c.scheduleEvents.firstWhere((e) => e.id == id);
      final colorA = _c.otherColorIndexOf(byId('a'));
      final colorB = _c.otherColorIndexOf(byId('b'));

      await _c.updateScheduleEvent(byId('a').copyWith(title: '测试日程丙'));
      expect(_c.otherColorIndexOf(byId('a')), colorA);
      expect((await ScheduleStore.readOtherColors())['测试日程丙'], colorA);

      await _c.updateScheduleEvent(byId('a').copyWith(title: '测试日程乙'));
      expect(_c.otherColorIndexOf(byId('a')), colorB);
      // 已分配的颜色不变。
      expect(_c.otherColorIndexOf(byId('b')), colorB);
    });
  });
}
