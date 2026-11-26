import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_edit_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_layout.dart';

final _c = TimetableController.instance;

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
}) {
  _c.debugSetSnapshot(
    TimetableSnapshot(
      courses: jwxt,
      periods: TimetableController.defaultPeriods(),
      settings: settings ?? TimetableSettings(termStartDate: _termStart),
    ),
    viewingWeek: week,
    manualCourses: manual,
  );
}

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
    tmp = Directory.systemTemp.createTempSync('tt_home_card');
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

  test('CD01–CD06 与 HN01 倒计时及剩余时长文案边界', () {
    expect(formatClassCountdown(59), '59 分钟后上课');
    expect(formatClassCountdown(60), '1 小时后上课');
    expect(formatClassCountdown(61), '1 小时 1 分后上课');
    expect(formatClassCountdown(120), '2 小时后上课');
    expect(formatClassCountdown(125), '2 小时 5 分后上课');
    expect(formatClassCountdown(1), '1 分钟后上课');
    expect(formatClassCountdown(0), '即将上课');

    expect(formatClassRemaining(45), '上课中·还剩 45 分钟');
    expect(formatClassRemaining(0), '上课中·还剩 1 分钟');
    expect(formatClassRemaining(-3), '上课中·还剩 1 分钟');
    expect(formatClassRemaining(59), '上课中·还剩 59 分钟');
    expect(formatClassRemaining(60), '上课中·还剩 1 小时');
    expect(formatClassRemaining(61), '上课中·还剩 1 小时 1 分钟');
    expect(formatClassRemaining(125), '上课中·还剩 2 小时 5 分钟');
  });

  testWidgets('今天课程倒计时/进度与考试日程混排（最多 2 项），点按只进课表', (tester) async {
    final a = _course('a', '测试课甲', start: 1, end: 2);
    final b = _course('b', '测试课乙', start: 3, end: 4);
    final c = _course('c', '测试课丙', start: 5, end: 6);
    final day = DateTime(2026, 10, 12);
    _load(manual: [a, b, c]);
    await tester.runAsync(() async {
      await _c.addScheduleEvent(
        _ev('ex', ScheduleKind.exam, day, 7, 30, 7, 50),
      );
      await _c.addScheduleEvent(
        _ev('ot', ScheduleKind.other, day, 19, 0, 20, 0),
      );
    });

    Future<void> pumpAt(DateTime now, {bool showExams = true}) async {
      _load(
        settings: TimetableSettings(
          termStartDate: _termStart,
          showExams: showExams,
        ),
        manual: [a, b, c],
      );
      TimetableController.clock = () => now;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => now)),
        ),
      );
      await tester.pump();
    }

    await pumpAt(DateTime(2026, 10, 12, 7, 0));
    expect(find.byKey(const Key('home_event_row_ex')), findsOneWidget);
    expect(find.byKey(const Key('home_event_exam_pill')), findsOneWidget);
    expect(find.text('测试课甲'), findsOneWidget);
    expect(find.byKey(const Key('home_event_row_ot')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const Key('home_event_row_ex'))).dy,
      lessThan(tester.getTopLeft(find.text('测试课甲')).dy),
    );

    await pumpAt(DateTime(2026, 10, 12, 7, 59, 30), showExams: false);
    expect(find.byKey(const Key('home_event_row_ex')), findsNothing);
    expect(find.text('即将上课'), findsOneWidget);

    _load(manual: [_course('a', '测试课甲', start: 1, end: 2, teacher: '')]);
    final inClass = DateTime(2026, 10, 12, 9, 0, 30);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TimetableHomeCard(now: () => inClass)),
      ),
    );
    await tester.pump();
    expect(find.text('上课中·还剩 39 分钟'), findsOneWidget);
    expect(find.byKey(const Key('home_course_teacher')), findsNothing);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('home_course_progress')),
          )
          .value,
      closeTo(60.5 / 100, 0.02),
    );

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: SingleChildScrollView(
              child: TimetableHomeCard(now: () => DateTime(2026, 10, 12, 7, 0)),
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
    _load(manual: [a]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.tap(find.text('测试课甲'));
    await tester.pumpAndSettle();
    expect(find.text('课表页占位'), findsOneWidget);
    expect(find.byType(JwxtCourseEditPage), findsNothing);
    expect(find.byType(ManualCourseForm), findsNothing);
    expect(find.byType(ScheduleEventEditPage), findsNothing);
    expect(_c.consumePendingOpen(), isNull);
  });

  testWidgets('今天最后一项结束后按开关切换明天卡片（含日程与周日跨周），关则显示已上完', (tester) async {
    final courses = [_course('a', '今日课', day: 1), _course('b', '明日课', day: 2)];
    final section = find.byKey(const Key('home_tomorrow_section'));

    Future<void> pumpHome(DateTime now) async {
      TimetableController.clock = () => now;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => now)),
        ),
      );
      await tester.pump();
    }

    _load(manual: courses);
    await tester.runAsync(() async {
      await _c.addScheduleEvent(
        _ev('ot', ScheduleKind.other, DateTime(2026, 10, 12), 18, 0, 20, 0),
      );
      await _c.addScheduleEvent(
        _ev('tm', ScheduleKind.other, DateTime(2026, 10, 13), 14, 0, 15, 0),
      );
    });
    await pumpHome(DateTime(2026, 10, 12, 9, 41));
    expect(section, findsNothing);
    expect(find.text('今日课表'), findsOneWidget);

    await pumpHome(DateTime(2026, 10, 12, 20, 1));
    expect(section, findsOneWidget);
    expect(find.text('明天（周二）'), findsOneWidget);
    expect(
      find.descendant(of: section, matching: find.text('明日课')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('home_event_row_tm')), findsOneWidget);

    _load(
      settings: TimetableSettings(
        termStartDate: _termStart,
        showTomorrowOnHome: false,
      ),
      manual: courses,
    );
    await pumpHome(DateTime(2026, 10, 12, 20, 1));
    expect(section, findsNothing);
    expect(find.text('已上完'), findsOneWidget);

    _load(
      manual: [
        _course('x', '双周课', day: 1, weeks: '01' * 10),
        _course('y', '单周课', day: 1, weeks: '10' * 10),
      ],
    );
    await pumpHome(DateTime(2026, 10, 18, 20));
    expect(find.text('明天（周一·第 8 周）'), findsOneWidget);
    expect(
      find.descendant(of: section, matching: find.text('双周课')),
      findsOneWidget,
    );
    expect(find.textContaining('单周课'), findsNothing);
  });

  testWidgets('空态、今天没课显示明天、学期结束与开学前边界', (tester) async {
    final section = find.byKey(const Key('home_tomorrow_section'));

    Future<void> pumpHome(DateTime now) async {
      TimetableController.clock = () => now;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TimetableHomeCard(now: () => now)),
        ),
      );
      await tester.pump();
    }

    _load(manual: [_course('a', '周四课', day: 4)]);
    await pumpHome(DateTime(2026, 8, 20, 9));
    expect(find.text('距开学 11 天'), findsOneWidget);
    expect(find.textContaining('周四课'), findsNothing);

    _load(manual: [_course('b', '明日课', day: 3)]);
    await pumpHome(DateTime(2026, 10, 13, 9));
    expect(find.text('今天没有课'), findsOneWidget);
    expect(find.text('明天（周三）'), findsOneWidget);
    expect(
      find.descendant(of: section, matching: find.text('明日课')),
      findsOneWidget,
    );

    _load();
    await tester.runAsync(
      () => _c.addScheduleEvent(
        _ev('ex', ScheduleKind.exam, DateTime(2026, 10, 12), 18, 0, 19, 0),
      ),
    );
    await pumpHome(DateTime(2026, 10, 12, 18, 59));
    expect(section, findsNothing);
    await pumpHome(DateTime(2026, 10, 12, 19, 1));
    expect(find.text('明天没课'), findsOneWidget);

    _load(manual: [_course('a', '今日课', day: 3)]);
    await pumpHome(DateTime(2027, 1, 20, 9));
    expect(find.text('本学期已结束'), findsOneWidget);
    expect(section, findsNothing);
  });

  testWidgets('320dp 窄屏大字号下长课名、长地点与长老师完整换行不溢出', (tester) async {
    const longName = '面向对象程序设计与软件工程综合实践（含课程设计与实验环节）';
    const coursePlace = '测试楼 A 区东侧三层多媒体阶梯教室（演示用很长的上课地点）';
    const teacher = '张老师、李老师、王老师、赵老师（演示用很长的教师名单）';
    const examPlace = '测试楼 B 区西侧五层大型标准化考场（演示用很长的考试地点）';
    _load(
      manual: [_course('a', longName, location: coursePlace, teacher: teacher)],
    );
    await tester.runAsync(
      () => _c.addScheduleEvent(
        _ev(
          'ex',
          ScheduleKind.exam,
          DateTime(2026, 10, 12),
          10,
          0,
          11,
          30,
        ).copyWith(location: examPlace),
      ),
    );

    tester.view.physicalSize = const Size(960, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 10, 12, 7);
    TimetableController.clock = () => now;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(child: TimetableHomeCard(now: () => now)),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text(longName), findsOneWidget);
    expect(find.text(coursePlace), findsOneWidget);
    expect(find.textContaining(examPlace), findsOneWidget);
    expect(find.textContaining(teacher), findsOneWidget);
  });

  group('homeTomorrow 与 firstCourseTomorrow', () {
    const w16 = '1111111111111111';

    Course tomorrowCourse(String id, String name, int day) => Course(
      id: id,
      name: name,
      source: CourseSource.jwxt,
      slots: [
        CourseSlot(
          day: day,
          startNode: 1,
          endNode: 2,
          weeks: w16,
          teacher: '教师P',
        ),
      ],
    );

    void loadTomorrow({bool show = true}) => _c.debugSetSnapshot(
      TimetableSnapshot(
        courses: [
          tomorrowCourse('mon', '周一课', 1),
          tomorrowCourse('tue', '周二课', 2),
        ],
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: _termStart,
          termStartFromJwxt: true,
          showTomorrowOnHome: show,
        ),
      ),
    );

    test('homeTomorrow：明天有课/跨周/无课/关闭/开学前/学期末/无开学日边界', () {
      loadTomorrow();
      final nextDay = _c.homeTomorrow(now: DateTime(2026, 10, 12, 22));
      expect(nextDay.kind, HomeTomorrowKind.courses);
      expect(nextDay.title, '明天（周二）');
      expect(nextDay.courses.single.course.name, '周二课');
      expect(nextDay.todayFinished, isTrue);
      expect(nextDay.hasTomorrowSection, isTrue);

      final nextWeek = _c.homeTomorrow(now: DateTime(2026, 10, 18, 9));
      expect(nextWeek.title, '明天（周一·第 8 周）');
      expect(nextWeek.tomorrowWeek, 8);

      final noClass = _c.homeTomorrow(now: DateTime(2026, 10, 13, 22));
      expect(noClass.kind, HomeTomorrowKind.noClass);
      expect(noClass.message, '明天没课');
      expect(noClass.courses, isEmpty);

      expect(_c.totalWeeks, 20);
      final emptyWeek = _c.homeTomorrow(now: DateTime(2026, 12, 21));
      expect(emptyWeek.kind, HomeTomorrowKind.noClass);
      final lastSun = _c.homeTomorrow(now: DateTime(2027, 1, 17, 20));
      expect(lastSun.kind, HomeTomorrowKind.noClass);
      expect(lastSun.tomorrowWeek, 21);
      final ended = _c.homeTomorrow(now: DateTime(2027, 1, 18));
      expect(ended.kind, HomeTomorrowKind.termEnded);
      expect(ended.message, '本学期已结束');
      expect(ended.hasTomorrowSection, isFalse);

      final eveBefore = _c.homeTomorrow(now: DateTime(2026, 8, 30, 20));
      expect(eveBefore.kind, HomeTomorrowKind.courses);
      expect(eveBefore.title, '明天（周一·第 1 周）');
      expect(eveBefore.courses.single.course.name, '周一课');

      final early = _c.homeTomorrow(now: DateTime(2026, 8, 20, 8));
      expect(early.kind, HomeTomorrowKind.beforeTerm);
      expect(early.daysUntilTerm, 11);
      expect(early.message, '距开学 11 天');
      expect(early.hasTomorrowSection, isFalse);

      loadTomorrow(show: false);
      final disabled = _c.homeTomorrow(now: DateTime(2026, 10, 12, 22));
      expect(disabled.kind, HomeTomorrowKind.disabled);
      expect(disabled.hasTomorrowSection, isFalse);

      _c.debugSetSnapshot(const TimetableSnapshot());
      expect(
        _c.homeTomorrow(now: DateTime(2026, 10, 12)).kind,
        HomeTomorrowKind.unknown,
      );
    });

    test('套用调课记录：homeTomorrow 与 firstCourseTomorrow 均在新日期返回实际节次', () async {
      loadTomorrow();
      final mon = _c.courses.firstWhere((x) => x.id == 'mon');
      final r = await _c.moveSlot(
        mon,
        0,
        toDay: 3,
        toStartPeriod: 3,
        week: 8,
        scope: MoveScope.thisWeek,
      );
      expect(r.ok, isTrue);
      final wed = _c.homeTomorrow(now: DateTime(2026, 10, 20, 22));
      expect(wed.courses.map((e) => e.course.name), ['周一课']);
      expect(wed.courses.single.slot.startNode, 3);
      expect(
        _c.homeTomorrow(now: DateTime(2026, 10, 18, 22)).kind,
        HomeTomorrowKind.noClass,
      );
      expect(_c.firstCourseTomorrow(now: DateTime(2026, 10, 18)), isNull);
      final first = _c.firstCourseTomorrow(now: DateTime(2026, 10, 20));
      expect(first!.course.id, 'mon');
      expect(first.slot.startNode, 3);
    });

    test('firstCourseTomorrow：首课排序、体育显示名、跨周跨年与空态边界', () {
      final early = tomorrowCourse(
        'early',
        '体育（3）',
        2,
      ).copyWith(projectName: '射箭');
      final late = tomorrowCourse('late', '晚课', 2).copyWith(
        slots: [const CourseSlot(day: 2, startNode: 5, endNode: 6, weeks: w16)],
      );
      _c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [late, early, tomorrowCourse('today', '今日课', 1)],
          settings: TimetableSettings(
            termStartDate: _termStart,
            showTomorrowOnHome: false,
          ),
        ),
      );
      final first = _c.firstCourseTomorrow(now: DateTime(2026, 10, 12, 23, 59));
      expect(first!.course.id, 'early');
      expect(first.course.displayName, '体育·射箭');
      expect(first.slot.startNode, 1);

      _c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            tomorrowCourse('mon', '周一课', 1).copyWith(
              slots: [
                const CourseSlot(
                  day: 1,
                  startNode: 3,
                  endNode: 4,
                  weeks: '00000001',
                ),
              ],
            ),
          ],
          settings: TimetableSettings(termStartDate: _termStart),
        ),
      );
      expect(_c.firstCourseTomorrow(now: DateTime(2026, 10, 11)), isNull);
      expect(
        _c.firstCourseTomorrow(now: DateTime(2026, 10, 18))!.course.id,
        'mon',
      );
      _c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [tomorrowCourse('fri', '元旦课', 5)],
          settings: TimetableSettings(termStartDate: DateTime(2026, 12, 28)),
        ),
      );
      expect(
        _c.firstCourseTomorrow(now: DateTime(2026, 12, 31, 23, 59))!.course.id,
        'fri',
      );

      loadTomorrow();
      expect(_c.firstCourseTomorrow(now: DateTime(2026, 10, 13)), isNull);
      expect(_c.firstCourseTomorrow(now: DateTime(2026, 8, 20)), isNull);
      expect(_c.firstCourseTomorrow(now: DateTime(2027, 1, 18)), isNull);
      _c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [tomorrowCourse('hidden', '隐藏课', 2).copyWith(hidden: true)],
          settings: TimetableSettings(termStartDate: _termStart),
        ),
      );
      expect(_c.firstCourseTomorrow(now: DateTime(2026, 10, 12)), isNull);
      _c.debugSetSnapshot(const TimetableSnapshot());
      expect(_c.firstCourseTomorrow(now: DateTime(2026, 10, 12)), isNull);
    });
  });
}
