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
  group('CD 首页倒计时（§13.11）', () {
    test('CD01–CD06 文案', () {
      expect(formatClassCountdown(59), '59 分钟后上课');
      expect(formatClassCountdown(60), '1 小时后上课');
      expect(formatClassCountdown(61), '1 小时 1 分后上课');
      expect(formatClassCountdown(120), '2 小时后上课');
      expect(formatClassCountdown(125), '2 小时 5 分后上课');
      expect(formatClassCountdown(1), '1 分钟后上课');
      // 不足 1 分钟（向下取整为 0）→「即将上课」，不出现「0 分钟后上课」。
      expect(formatClassCountdown(0), '即将上课');
    });

    for (final (id, clock, text) in [
      // CD09：距上课不足 1 分钟（59 秒到 1 秒）一律「即将上课」。
      ('CD09', DateTime(2026, 10, 12, 7, 59, 30), '即将上课'),
      ('CD09', DateTime(2026, 10, 12, 7, 59, 1), '即将上课'),
      ('CD09', DateTime(2026, 10, 12, 7, 59, 59), '即将上课'),
      // CD10：按秒向下取整的边界（距 08:00 上课）。
      ('CD10', DateTime(2026, 10, 12, 7, 0, 1), '59 分钟后上课'), // 59:59
      ('CD10', DateTime(2026, 10, 12, 6, 59, 1), '1 小时后上课'), // 60:59
      // CD08：06:59:30（差 60 分 30 秒）分钟向下取整 →「1 小时后上课」。
      ('CD08', DateTime(2026, 10, 12, 6, 59, 30), '1 小时后上课'),
      ('CD06/CD09', DateTime(2026, 10, 12, 7, 59), '1 分钟后上课'),
      ('CD01', DateTime(2026, 10, 12, 7, 1), '59 分钟后上课'),
      ('CD02', DateTime(2026, 10, 12, 7, 0), '1 小时后上课'),
      ('CD03', DateTime(2026, 10, 12, 6, 59), '1 小时 1 分后上课'),
      ('CD05', DateTime(2026, 10, 12, 5, 55), '2 小时 5 分后上课'),
    ]) {
      testWidgets(
        '$id 首页卡片 ${clock.hour}:${clock.minute}:${clock.second} → 「$text」',
        (tester) async {
          TimetableController.clock = () => clock;
          _load(manual: [_course('a', '测试课甲')]);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: TimetableHomeCard(now: () => clock)),
            ),
          );
          await tester.pump();
          expect(
            find.byKey(const Key('home_course_countdown')),
            findsOneWidget,
          );
          expect(find.text(text), findsOneWidget);
          expect(find.textContaining('0 分钟后上课'), findsNothing);
        },
      );
    }
  });

  // ---------------------------------------------------------------- TB
  group('HT 首页今天/明天切换（§13.13）', () {
    // 周一 10/12：第 1-2 节 08:00–09:40；周二有「明日课」。
    final courses = [_course('a', '今日课', day: 1), _course('b', '明日课', day: 2)];
    final section = find.byKey(const Key('home_tomorrow_section'));

    Future<void> pumpHome(WidgetTester tester, DateTime now) async {
      TimetableController.clock = () => now;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => now)),
        ),
      );
      await tester.pump();
    }

    Future<void> addEvent(
      WidgetTester tester,
      ScheduleKind kind,
      int sh,
      int sm,
      int eh,
      int em,
    ) async {
      await tester.runAsync(
        () => _c.addScheduleEvent(
          ScheduleEvent(
            id: '',
            kind: kind,
            source: ScheduleSource.manual,
            title: kind == ScheduleKind.exam ? '测试考试' : '测试日程',
            date: DateTime(2026, 10, 12),
            start: TimeOfDayMinutes(sh, sm),
            end: TimeOfDayMinutes(eh, em),
            location: '测试楼 A101',
          ),
        ),
      );
    }

    testWidgets('HT01/HT03 最后一节结束前只显示今天；结束后切换为明天，卡片结构一致', (tester) async {
      _load(manual: courses);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 39));
      expect(section, findsNothing);
      expect(find.text('今日课表'), findsOneWidget);
      final todayHeader = tester.getSize(
        find.byKey(const Key('home_card_header')),
      );
      // HT02：结束那一分钟（09:40:00–09:40:59）仍算今天。
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 40));
      expect(section, findsNothing);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 40, 59));
      expect(section, findsNothing);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 41));
      expect(section, findsOneWidget);
      expect(find.text('明天（周二）'), findsOneWidget);
      expect(find.text('今日课表'), findsNothing);
      // 同一个标题组件、同一种课程行组件。
      expect(
        tester.getSize(find.byKey(const Key('home_card_header'))),
        todayHeader,
      );
      expect(
        find.descendant(of: section, matching: find.text('明日课')),
        findsOneWidget,
      );
    });

    testWidgets('HT06 「显示明天的课」关：不切换，仍显示今天（已上完）', (tester) async {
      _load(
        settings: TimetableSettings(
          termStartDate: _termStart,
          showTomorrowOnHome: false,
        ),
        manual: courses,
      );
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 41));
      expect(section, findsNothing);
      expect(find.text('已上完'), findsOneWidget);
    });

    testWidgets('HT08 「其他」日程计入最后一项', (tester) async {
      _load(manual: courses);
      await addEvent(tester, ScheduleKind.other, 18, 0, 20, 0);
      await pumpHome(tester, DateTime(2026, 10, 12, 17));
      expect(section, findsNothing);
      await pumpHome(tester, DateTime(2026, 10, 12, 20, 1));
      expect(section, findsOneWidget);
    });

    testWidgets('HT09 显示考试开：考试计入最后一项', (tester) async {
      _load(manual: courses);
      await addEvent(tester, ScheduleKind.exam, 18, 30, 20, 30);
      await pumpHome(tester, DateTime(2026, 10, 12, 17));
      expect(section, findsNothing);
      await pumpHome(tester, DateTime(2026, 10, 12, 20, 31));
      expect(section, findsOneWidget);
    });

    testWidgets('HT10 显示考试关：考试不计入，最后一节结束后即切换', (tester) async {
      _load(
        settings: TimetableSettings(
          termStartDate: _termStart,
          showExams: false,
        ),
        manual: courses,
      );
      await addEvent(tester, ScheduleKind.exam, 18, 30, 20, 30);
      await pumpHome(tester, DateTime(2026, 10, 12, 9, 41));
      expect(section, findsOneWidget);
    });

    testWidgets('HT11 考试、其他都早于最后一节：按最后一节切换', (tester) async {
      _load(
        manual: [_course('a', '今日课', day: 1, start: 7, end: 8), courses[1]],
      );
      await addEvent(tester, ScheduleKind.exam, 8, 0, 9, 0);
      await addEvent(tester, ScheduleKind.other, 9, 0, 10, 0);
      final end = _c.periodEnd(8)!.split(':');
      final endAt = DateTime(
        2026,
        10,
        12,
        int.parse(end[0]),
        int.parse(end[1]),
      );
      await pumpHome(tester, endAt.subtract(const Duration(minutes: 1)));
      expect(section, findsNothing);
      await pumpHome(tester, endAt.add(const Duration(minutes: 1)));
      expect(section, findsOneWidget);
    });

    Future<void> seedNoCourseDay(
      WidgetTester tester, {
      bool tomorrow = true,
    }) async {
      _load(); // 无教务课、无手动课
      expect(_c.hasCourses, isFalse);
      final today = DateTime(2026, 10, 12);
      await tester.runAsync(() async {
        await _c.addScheduleEvent(
          _ev('x', ScheduleKind.exam, today, 14, 0, 16, 0),
        );
        await _c.addScheduleEvent(
          _ev('o', ScheduleKind.other, today, 18, 0, 19, 0),
        );
        if (tomorrow) {
          await _c.addScheduleEvent(
            _ev('t', ScheduleKind.other, DateTime(2026, 10, 13), 10, 0, 11, 0),
          );
        }
      });
    }

    testWidgets('HT12 没有任何课程、只有考试与「其他」：18:59 显示今天，'
        '19:01 最后一项结束后切换为明天卡片', (tester) async {
      await seedNoCourseDay(tester);
      await pumpHome(tester, DateTime(2026, 10, 12, 18, 59));
      expect(section, findsNothing);
      expect(find.text('今日课表'), findsOneWidget);
      expect(find.byKey(const Key('home_event_row_o')), findsOneWidget);
      await pumpHome(tester, DateTime(2026, 10, 12, 19, 1));
      expect(section, findsOneWidget);
      expect(find.text('今日课表'), findsNothing);
      expect(
        find.descendant(
          of: section,
          matching: find.byKey(const Key('home_event_row_t')),
        ),
        findsOneWidget,
      );
    });

    // 实现与 §24 不符（10/18 代码阅读）：没有课程且明天也没有日程时，
    testWidgets('HT12 没有任何课程、明天也没有日程：19:01 显示「明天没课」', (tester) async {
      await seedNoCourseDay(tester, tomorrow: false);
      await pumpHome(tester, DateTime(2026, 10, 12, 19, 1));
      expect(find.text('明天没课'), findsOneWidget);
      expect(find.text('登录教务后自动显示今日课程'), findsNothing);
    });
  });

  // ---------------------------------------------------------------- HP
  group('HT 首页卡片窄屏不截断（320dp，产品 10/18）', () {
    const longName = '面向对象程序设计与软件工程综合实践（含课程设计与实验环节）';
    const coursePlace = '测试楼 A 区东侧三层多媒体阶梯教室（演示用很长的上课地点）';
    const examPlace = '测试楼 B 区西侧五层大型标准化考场（演示用很长的考试地点）';
    const otherPlace = '测试楼 C 区学生活动中心二层报告厅（演示用很长的日程地点）';

    Future<void> pumpNarrow(
      WidgetTester tester,
      DateTime now,
      double scale,
    ) async {
      tester.view.physicalSize = const Size(960, 6000);
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
            body: SingleChildScrollView(
              child: TimetableHomeCard(now: () => now),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// 文字完整：不限行数、不省略（含 DefaultTextStyle 继承）。
    void expectFull(WidgetTester tester, Finder text) {
      expect(text, findsOneWidget);
      final w = tester.widget<Text>(text);
      expect(w.maxLines, isNull);
      expect(w.overflow, isNot(TextOverflow.ellipsis));
      final rich = tester.widget<RichText>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      expect(rich.maxLines, isNull);
      expect(rich.overflow, isNot(TextOverflow.ellipsis));
    }

    for (final scale in [1.0, 1.3, 1.5]) {
      testWidgets('HT13 标题「明天（周一…）」完整显示，副标题「今天没有课」放不下时换行'
          '（textScaler $scale）', (tester) async {
        _load(manual: [_course('a', '测试课甲', day: 1)]);
        await pumpNarrow(tester, DateTime(2026, 10, 18, 20), scale);
        expect(tester.takeException(), isNull);
        final title = find.byKey(const Key('home_card_title'));
        final subtitle = find.byKey(const Key('home_card_subtitle'));
        expect(tester.widget<Text>(title).data, startsWith('明天（周一'));
        expect(tester.widget<Text>(subtitle).data, '今天没有课');
        expectFull(tester, title);
        expectFull(tester, subtitle);
        final t = tester.getRect(title);
        final s = tester.getRect(subtitle);
        // 同一行时副标题在标题右侧；放不下时在标题下方，二者不重叠。
        expect(s.left >= t.right - 0.5 || s.top >= t.bottom - 0.5, isTrue);
        expect(tester.getRect(find.byType(TimetableHomeCard)).right, 320);
      });

      testWidgets('HT14 长课名换行、长地点与时间完整；课程 + 考试混排不溢出，最多 2 项'
          '（textScaler $scale）', (tester) async {
        _load(manual: [_course('a', longName, location: coursePlace)]);
        final day = DateTime(2026, 10, 12);
        await tester.runAsync(() async {
          await _c.addScheduleEvent(
            ScheduleEvent(
              id: '',
              kind: ScheduleKind.exam,
              source: ScheduleSource.manual,
              title: '测试考试',
              date: day,
              start: const TimeOfDayMinutes(10, 0),
              end: const TimeOfDayMinutes(11, 30),
              location: examPlace,
            ),
          );
          await _c.addScheduleEvent(
            ScheduleEvent(
              id: '',
              kind: ScheduleKind.other,
              source: ScheduleSource.manual,
              title: '测试日程',
              date: day,
              start: const TimeOfDayMinutes(14, 0),
              end: const TimeOfDayMinutes(15, 0),
              location: otherPlace,
            ),
          );
        });
        await pumpNarrow(tester, DateTime(2026, 10, 12, 7), scale);
        expect(tester.takeException(), isNull);
        expectFull(tester, find.text(longName));
        final courseLine = find.textContaining(coursePlace);
        expectFull(tester, courseLine);
        // item 13：地点单独一行（不再带「@」），时间 · 节次另起一行。
        expect(tester.widget<Text>(courseLine).data, coursePlace);
        expect(
          tester.widget<Text>(find.byKey(const Key('home_course_time'))).data,
          '08:00–09:40 · 第1–2节',
        );
        final examLine = find.textContaining(examPlace);
        expectFull(tester, examLine);
        expect(tester.widget<Text>(examLine).data, contains('10:00–11:30'));
        // item 13：最多 2 项（下一节课 + 考试），14:00 的日程不显示。
        expect(find.textContaining(otherPlace), findsNothing);
        // 卡片高度随内容：长课名那一行比单行最小高度（48）更高。
        expect(
          tester.getSize(find.byType(TimetableHomeCard)).height,
          greaterThan(2 * 48),
        );
      });
    }
  });
}
