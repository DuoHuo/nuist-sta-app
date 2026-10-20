// 课表：「+」三选一、考试 / 其他日程表单与周视图、教务课编辑 / 删除 / 恢复、
// 首页卡片日程（design/timetable-spec.md §13.15、§14.1–§14.4）。
// 编号对齐课表测试用例 §24（EV / EX / JE / HT）。
// 全部为虚构数据（「测试课甲」「张老师」「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

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

  group('首页卡片含日程', () {
    final now = DateTime(2026, 10, 19, 7);

    Future<void> pumpCard(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => now)),
        ),
      );
      await tester.pump();
    }

    Future<void> seed(WidgetTester tester) async {
      _load(manual: [_course('m1', '测试课甲')]); // 周一第 3–4 节 10:10
      await tester.runAsync(() async {
        await _c.addScheduleEvent(
          _event(
            'ex',
            date: _monday,
            start: const TimeOfDayMinutes(8, 0),
            end: const TimeOfDayMinutes(8, 45),
          ),
        );
        await _c.addScheduleEvent(
          _event(
            'ot',
            kind: ScheduleKind.other,
            title: '测试日程甲',
            date: _monday,
            start: const TimeOfDayMinutes(19, 0),
            end: const TimeOfDayMinutes(20, 0),
          ),
        );
      });
    }

    testWidgets('EV20/EX04 今天的考试与「其他」与课程按开始时间混排，带「考试」「日程」胶囊', (tester) async {
      await seed(tester);
      await pumpCard(tester);
      final exam = find.byKey(const Key('home_event_row_ex'));
      final other = find.byKey(const Key('home_event_row_ot'));
      expect(exam, findsOneWidget);
      // item 13：首页最多 2 项，19:00 的「其他」排第 3，收进「还有 1 项」。
      expect(other, findsNothing);
      expect(find.text('还有 1 项'), findsOneWidget);
      expect(find.text('测试课甲'), findsOneWidget);
      final examPill = find.byKey(const Key('home_event_exam_pill'));
      expect(
        find.descendant(of: examPill, matching: find.text('考试')),
        findsOneWidget,
      );
      final pillBox =
          tester
                  .widget<Container>(
                    find.descendant(
                      of: examPill,
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      expect(
        (pillBox.border! as Border).top.color,
        Color(_c.settings.examColor),
      );
      final yExam = tester.getTopLeft(exam).dy;
      final yCourse = tester.getTopLeft(find.text('测试课甲')).dy;
      expect(yExam, lessThan(yCourse));
    });

    testWidgets('EX07/EV12 「显示考试」关：首页不显示考试行，「其他」照常', (tester) async {
      await seed(tester);
      _setShowExams(false);
      await pumpCard(tester);
      expect(find.byKey(const Key('home_event_row_ex')), findsNothing);
      expect(find.byKey(const Key('home_event_row_ot')), findsOneWidget);
    });

    testWidgets('HT08 今天课已上完但「其他」日程未结束：仍显示今天，并列出该日程', (tester) async {
      await seed(tester);
      final evening = DateTime(2026, 10, 19, 18);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => evening)),
        ),
      );
      await tester.pump();
      expect(find.text('今日课表'), findsOneWidget);
      expect(find.byKey(const Key('home_event_row_ot')), findsOneWidget);
    });

    testWidgets('明天的日程并入明天卡片（今天全部结束后）', (tester) async {
      _load(manual: [_course('m1', '测试课甲')]);
      await tester.runAsync(
        () => _c.addScheduleEvent(
          _event('tm', kind: ScheduleKind.other, title: '测试日程乙'),
        ),
      );
      final evening = DateTime(2026, 10, 19, 21);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => evening)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('home_tomorrow_section')), findsOneWidget);
      expect(find.byKey(const Key('home_event_row_tm')), findsOneWidget);
    });
  });

  group('首页明天卡片：只有日程也切换', () {
    testWidgets('没有任何课程、明天有「其他」日程：今天结束后显示明天卡片', (tester) async {
      _load();
      expect(_c.hasCourses, isFalse);
      await tester.runAsync(
        () => _c.addScheduleEvent(
          _event('tm', kind: ScheduleKind.other, title: '测试日程乙'),
        ),
      );
      final evening = DateTime(2026, 10, 19, 21);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => evening)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('home_tomorrow_section')), findsOneWidget);
      expect(find.byKey(const Key('home_event_row_tm')), findsOneWidget);
    });

    testWidgets('没有课程、唯一的日程是考试且「显示考试」关：不切换', (tester) async {
      _load(showExams: false);
      await tester.runAsync(() => _c.addScheduleEvent(_event('tx')));
      final evening = DateTime(2026, 10, 19, 21);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => evening)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('home_tomorrow_section')), findsNothing);
      expect(find.byKey(const Key('home_event_row_tx')), findsNothing);
    });
  });
}
