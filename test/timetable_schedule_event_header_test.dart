// 课表 UI 侧用例（design/timetable-spec.md §13.8–§13.16），
// 编号对齐课表测试用例 §24（NW / LC / SW / CD / TB / HT / HP / SN / AS / EV / EX）。
// 全部为构造数据（课名「测试课甲」、老师「张老师」、地点「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

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

void _bigView(WidgetTester tester, {Size size = const Size(1080, 2400)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _pumpGrid(
  WidgetTester tester, {
  int week = _week,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: WeekGrid(key: ValueKey(week), week: week, controller: _c),
      ),
    ),
  );
  await tester.pump();
}

Finder _cell(String name) => find.widgetWithText(CourseCell, name);

/// 手动日程（考试 / 其他）；标题带 id，便于定位。
ScheduleEvent _ev(
  String id,
  ScheduleKind kind,
  DateTime date,
  int sh,
  int sm,
  int eh,
  int em,
) => ScheduleEvent(
  id: id,
  kind: kind,
  source: ScheduleSource.manual,
  title: '${kind == ScheduleKind.exam ? '测试考试' : '测试日程'}$id',
  date: date,
  start: TimeOfDayMinutes(sh, sm),
  end: TimeOfDayMinutes(eh, em),
  location: '测试楼 A101',
);

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
  group('EV 不在节次内的日程 / 首页（1018b 补充）', () {
    final wed = DateTime(2026, 10, 14); // 第 7 周周三
    Finder header(int day) => find.byKey(ValueKey('day_header_unplaced_$day'));
    final sheet = find.byKey(const Key('unplaced_events_sheet'));

    // EV34 那一天：「其他」12:00、考试 21:30、「其他」22:00（插入顺序打乱）。
    Future<void> seedWed(WidgetTester tester) async {
      _bigView(tester);
      _load(manual: [_course('a', '测试课甲')]); // 周一第 1–2 节
      await tester.runAsync(() async {
        await _c.addScheduleEvent(
          _ev('o2', ScheduleKind.other, wed, 22, 0, 22, 30),
        );
        await _c.addScheduleEvent(
          _ev('x1', ScheduleKind.exam, wed, 21, 30, 22, 30),
        );
        await _c.addScheduleEvent(
          _ev('o1', ScheduleKind.other, wed, 12, 0, 13, 30),
        );
      });
      await _pumpGrid(tester);
    }

    testWidgets('EV35 点日期头弹出底部面板，按时间列出该日不在节次内的 3 项；点一项进入详情', (tester) async {
      await seedWed(tester);
      expect(find.byKey(const Key('day_header_dot')), findsOneWidget);
      await tester.tap(header(3));
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      expect(find.text('周三不在节次内的 3 项'), findsOneWidget);
      final ys = [
        for (final id in ['o1', 'x1', 'o2'])
          tester.getTopLeft(find.byKey(ValueKey('unplaced_item_$id'))).dy,
      ];
      expect(ys[0], lessThan(ys[1]));
      expect(ys[1], lessThan(ys[2]));
      await tester.tap(find.byKey(const ValueKey('unplaced_item_o2')));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(find.byKey(const Key('schedule_detail_sheet')), findsOneWidget);
      expect(find.text('测试日程o2'), findsWidgets);
    });

    testWidgets('EV40 有圆点的日期头：表头高 = weekHeaderHeight = 48dp，热区 ≥48×48dp，'
        '整个表头单元格可点；网格从表头下方开始', (tester) async {
      expect(TimetableTheme.weekHeaderHeight, 48);
      await seedWed(tester);
      final r = tester.getRect(header(3));
      expect(r.height, TimetableTheme.weekHeaderHeight);
      expect(r.height, greaterThanOrEqualTo(48));
      expect(r.width, greaterThanOrEqualTo(48));
      // 网格第 1 节紧接表头之下，不与表头重叠。
      expect(
        tester.getTopLeft(_cell('测试课甲')).dy,
        greaterThanOrEqualTo(r.bottom - 0.01),
      );
      // 表头单元格四角（各内缩 1dp）都能点开面板。
      for (final p in [
        r.topLeft + const Offset(1, 1),
        r.topRight + const Offset(-1, 1),
        r.bottomLeft + const Offset(1, -1),
        r.bottomRight + const Offset(-1, -1),
      ]) {
        await tester.tapAt(p);
        await tester.pumpAndSettle();
        expect(sheet, findsOneWidget, reason: '$p');
        Navigator.of(tester.element(sheet)).pop();
        await tester.pumpAndSettle();
        expect(sheet, findsNothing);
      }
    });

    testWidgets('EV38 今天 12:00–13:30「其他」与 21:30–22:30 考试：首页今日列表按时间顺序显示；'
        '考试受开关控制', (tester) async {
      final monday = DateTime(2026, 10, 12);
      _load(manual: [_course('a', '测试课甲')]); // 周一 08:00–09:40
      await tester.runAsync(() async {
        await _c.addScheduleEvent(
          _ev('late', ScheduleKind.exam, monday, 21, 30, 22, 30),
        );
        await _c.addScheduleEvent(
          _ev('lunch', ScheduleKind.other, monday, 12, 0, 13, 30),
        );
      });
      final now = DateTime(2026, 10, 12, 9);
      TimetableController.clock = () => now;
      Future<void> pumpCard() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TimetableHomeCard(now: () => now)),
          ),
        );
        await tester.pump();
      }

      await pumpCard();
      final lunch = find.byKey(const Key('home_event_row_lunch'));
      final late = find.byKey(const Key('home_event_row_late'));
      expect(lunch, findsOneWidget);
      // design item 4：首页最多 homeMaxItems（默认 2）项，截断且无「还有 N 项」。
      expect(late, findsNothing);
      expect(find.textContaining('还有'), findsNothing);
      expect(
        tester.getTopLeft(find.text('测试课甲')).dy,
        lessThan(tester.getTopLeft(lunch).dy),
      );
      // 「显示考试」关：考试行不显示，「其他」照常。
      _c.debugSetSnapshot(
        _c.snapshot.copyWith(settings: _c.settings.copyWith(showExams: false)),
        viewingWeek: _c.viewingWeek,
      );
      await pumpCard();
      expect(lunch, findsOneWidget);
      expect(late, findsNothing);
    });
  });
}
