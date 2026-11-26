import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_detail_sheet.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_date_edits.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_home_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';
import 'package:nuist_sta_app/router.dart';

TimetableSnapshot _snap(
  DateTime? start, {
  bool withCourse = false,
}) => TimetableSnapshot(
  courses: [
    if (withCourse)
      Course(
        id: 'ds',
        name: '数据结构',
        classId: '02',
        slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20)],
      ),
  ],
  periods: TimetableController.defaultPeriods(),
  settings: TimetableSettings(termCode: '2026-2027-1', termStartDate: start),
);

void main() {
  final c = TimetableController.instance;
  setUp(() => TimetableController.clock = () => DateTime(2026, 10, 11));
  tearDown(() => TimetableController.clock = TimetableApi.shanghaiToday);

  test('翻周复用派生课程列，课程、显示设置与待同步日期变化后及时更新', () {
    c.debugReset();
    addTearDown(c.debugReset);
    final snapshot = _snap(null, withCourse: true);
    c.debugSetSnapshot(snapshot);
    final courses = c.courses;
    final cells = c.cellsForDay(1, 1);
    expect(cells.single.date, DateTime(2026, 10, 5));
    c.setViewingWeek(2);
    expect(c.courses, same(courses));
    expect(c.cellsForDay(1, 1), same(cells));
    expect(() => cells.clear(), throwsUnsupportedError);

    TimetableController.clock = () => DateTime(2026, 10, 12);
    expect(c.cellsForDay(1, 1).single.date, DateTime(2026, 10, 12));

    final next = snapshot.copyWith(
      courses: [
        snapshot.courses.single.copyWith(
          name: '更新后的课程',
          slots: const [
            CourseSlot(day: 1, startNode: 3, endNode: 4, weeks: '01'),
          ],
        ),
      ],
      settings: snapshot.settings.copyWith(showNonCurrentWeek: true),
    );
    c.debugSetSnapshot(next);
    final ghost = c.cellsForDay(1, 1).single;
    expect(ghost.course.name, '更新后的课程');
    expect(ghost.slot.startNode, 3);
    expect(ghost.activeThisWeek, isFalse);
    c.debugSetSnapshot(
      next.copyWith(
        settings: next.settings.copyWith(showNonCurrentWeek: false),
      ),
    );
    expect(c.cellsForDay(1, 1), isEmpty);
    expect(c.cellsForDay(2, 1).single.activeThisWeek, isTrue);
  });

  group('纯逻辑：周次位串 / 课程类型 / 单双周 / 无存储降级', () {
    test('体育课即便带旧教务实验标记，courseKindOf 仍判为体育；显式设置仍优先', () {
      final pe = Course(
        id: 'pe',
        name: '体育（1）',
        buildingDisplay: '体育板块场地',
        projectName: '篮球',
        slots: [
          CourseSlot(
            day: 1,
            startNode: 1,
            endNode: 2,
            weeks: weeksToBits([1, 2, 3], 20),
            isLab: true,
          ),
        ],
      );
      expect(courseKindOf(course: pe, slot: pe.slots.single), CourseKind.pe);
      final explicitLab = pe.slots.single.copyWith(kind: CourseKind.lab);
      expect(
        courseKindOf(course: pe.forSlot(explicitLab), slot: explicitLab),
        CourseKind.lab,
      );
    });

    test('displayWeekParity 排除零散非连续周，保留法定节假日跳周的单双周', () {
      expect(displayWeekParity(weeksToBits([3, 15], 20)), WeekParity.all);
      expect(displayWeekParity(weeksToBits([1], 20)), WeekParity.all);
      expect(displayWeekParity(weeksToBits([1, 3], 20)), WeekParity.odd);
      expect(displayWeekParity(weeksToBits([2, 4], 20)), WeekParity.even);
      expect(
        displayWeekParity(weeksToBits([1, 3, 5, 9, 11, 13], 20)),
        WeekParity.odd,
      );
      expect(displayWeekParity(weeksToBits([1, 2, 3], 20)), WeekParity.all);
    });

    test('hasClassInWeek 第 1 周 = 下标 0；第 length 周 = 最后一位（防差一）', () {
      final s = CourseSlot(day: 1, startNode: 1, endNode: 1, weeks: '1001');
      expect(s.hasClassInWeek(1), isTrue);
      expect(s.hasClassInWeek(2), isFalse);
      expect(s.hasClassInWeek(4), isTrue);
      final tail = Course(
        id: 'a',
        name: 'A',
        slots: [
          CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '0${'0' * 18}1'),
        ],
      );
      expect(tail.hasClassInWeek(20), isTrue);
      expect(tail.hasClassInWeek(19), isFalse);
      expect(tail.hasClassInWeek(1), isFalse);
    });

    test('hasClassInWeek 0 / 负数 / 超出位串长度 → false', () {
      final full = Course(
        id: 'a',
        name: 'A',
        slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20)],
      );
      for (final w in [0, -1, -100, 21, 25, 1000]) {
        expect(full.hasClassInWeek(w), isFalse, reason: 'week $w');
      }
      expect(
        const Course(
          id: 'e',
          name: 'E',
          slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '')],
        ).hasClassInWeek(1),
        isFalse,
      );
    });

    test('手动课程与教务课程同一周次判断；多节次任一有课即 true', () {
      const manual = Course(
        id: 'm',
        name: '手动',
        slots: [
          CourseSlot(day: 1, startNode: 1, endNode: 1, weeks: '10'),
          CourseSlot(day: 3, startNode: 1, endNode: 1, weeks: '0001'),
        ],
      );
      expect(manual.isManual, isTrue);
      expect(manual.hasClassInWeek(1), isTrue);
      expect(manual.hasClassInWeek(2), isFalse);
      expect(manual.hasClassInWeek(4), isTrue);
      expect(manual.hasClassInWeek(5), isFalse);
      const jwxt = Course(
        id: 'j',
        name: '教务',
        source: CourseSource.jwxt,
        slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '01')],
      );
      expect(jwxt.hasClassInWeek(2), isTrue);
      expect(jwxt.hasClassInWeek(1), isFalse);
    });

    test('无存储时按空数据降级，本地阶段与完整启动依次完成', () async {
      c.debugReset();
      addTearDown(c.debugReset);
      TimetableStore.debugDirectory = null;
      final origBinding = TimetableController.bindingCheck;
      final binding = Completer<bool>();
      TimetableController.bindingCheck = () => binding.future;
      addTearDown(() => TimetableController.bindingCheck = origBinding);
      await c.ensureLocalReady();
      binding.complete(false);
      await c.ensureStarted();
      expect(c.isInitialized, isTrue);
      expect(c.ensureLocalReady(), completes);
    });
  });

  group('周网格与页面交互合并验证', () {
    late Directory tmp;
    final origClock = TimetableController.clock;
    final origBinding = TimetableController.bindingCheck;
    final origFetch = TimetableController.fetchSnapshot;
    final termStart = DateTime(2026, 8, 31);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_week_ui_');
      TimetableStore.debugDirectory = tmp;
      c.debugReset();
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
      c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 50 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    testWidgets('本地快载与空课表登录引导、PageView 滑条回本周、真实路由返回与 20 周边界', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      // 1. 本地有课表不等待绑定读取立即展示首帧；空课表等待绑定完成再显示登录引导
      final binding = Completer<bool>();
      TimetableController.bindingCheck = () => binding.future;
      await tester.runAsync(
        () => TimetableStore.saveSnapshot(_snap(termStart, withCourse: true)),
      );
      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await pumpUntil(
        tester,
        () => find.byType(WeekGrid).evaluate().isNotEmpty,
      );
      expect(find.text('数据结构'), findsWidgets);
      expect(binding.isCompleted, isFalse);
      binding.complete(false);
      await pumpUntil(tester, () => c.isInitialized);

      final emptyBinding = Completer<bool>();
      TimetableController.bindingCheck = () => emptyBinding.future;
      c.debugReset();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => TimetableStore.saveSnapshot(_snap(termStart)),
      );
      await tester.pumpWidget(
        MaterialApp(theme: appLightTheme(), home: const TimetablePage()),
      );
      await pumpUntil(tester, () => false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('去登录'), findsNothing);
      emptyBinding.complete(false);
      await pumpUntil(tester, () => find.text('去登录').evaluate().isNotEmpty);
      expect(find.text('还没有课程'), findsOneWidget);
      TimetableController.bindingCheck = () async => false;

      // 2. 无开学日顶栏提示；开学日变化后 PageView 跟随 viewingWeek
      c.debugReset();
      c.debugSetSnapshot(_snap(null), viewingWeek: 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('周次待同步 · 点此选择'), findsOneWidget);

      c.debugSetSnapshot(
        _snap(DateTime(2026, 9, 7), withCourse: true),
      ); // 第 6 周 -> 5
      await tester.pump();
      c.debugSetSnapshot(_snap(termStart, withCourse: true)); // 同步后 → 第 7 周
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 7);

      // 3. 真实路由下拖页、设置返回保留周次、滑条微调/回本周及 Android 手势取消/完成清除浏览周
      final router = buildRouter()..go('/profile');
      addTearDown(router.dispose);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp.router(theme: appDarkTheme(), routerConfig: router),
      );
      await tester.pumpAndSettle();
      router.push<void>('/apps/timetable');
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 7);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 8);
      await tester.tap(find.byKey(const Key('timetable_settings_button')));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 8);

      await tester.tap(find.textContaining('第 8 周', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable_week_strip')), findsOneWidget);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('timetable_week_slider')),
      );
      slider.onChanged?.call(12);
      await tester.pump();
      slider.onChangeEnd?.call(12);
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 12);
      await tester.tap(find.byKey(const Key('timetable_week_strip_current')));
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 7);
      await tester.tapAt(const Offset(200, 100));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable_week_strip')), findsNothing);

      Future<void> gesture(String method, {double progress = 0}) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'touchOffset': [5.0, 300.0],
              'progress': progress,
              'swipeEdge': 0,
            }),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await tester.drag(find.byType(PageView), const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 8);
      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', progress: 0.4);
      await gesture('cancelBackGesture');
      expect(find.byType(TimetablePage), findsOneWidget);
      expect(c.viewingWeek, 8);
      await gesture('startBackGesture');
      await gesture('updateBackGestureProgress', progress: 0.4);
      await gesture('commitBackGesture');
      expect(find.byType(TimetablePage), findsNothing);
      expect(c.viewingWeek, 7);

      // 4. 手动课表单周次选择器上限为第 20 周
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(home: ManualCourseForm(controller: c)),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('course_form_weeks')));
      await tester.tap(find.byKey(const Key('course_form_weeks')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('course_form_week_20'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('course_form_week_21'), skipOffstage: false),
        findsNothing,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('网格列与行规则：无节次「其他」行显隐与详情、隐藏周末有本周手动课自动显露及切周更新', (tester) async {
      // 1. 无节次教务课「其他」行（仅教务、按周过滤、空/中文描述每周显示、点开详情）
      Course unscheduled(String id, String name, String weeksLabel) => Course(
        id: id,
        name: name,
        source: CourseSource.jwxt,
        slots: [
          CourseSlot(
            day: 0,
            startNode: 0,
            endNode: 0,
            weeks: '',
            weeksLabel: weeksLabel,
            location: '测试楼 B202',
            teacher: '张老师',
          ),
        ],
      );
      final rowFinder = find.byKey(const Key('week_grid_other_row'));
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            Course(
              id: 'n',
              name: '测试课甲',
              source: CourseSource.jwxt,
              slots: [
                CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1' * 20),
              ],
            ),
            unscheduled('o1', '测试实践课', '2-5周'),
          ],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: termStart),
        ),
        viewingWeek: 3,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekGrid(key: const ValueKey(3), week: 3, controller: c),
          ),
        ),
      );
      await tester.pump();
      expect(rowFinder, findsOneWidget);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('other_course_o1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('other_course_sheet')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekGrid(key: const ValueKey(7), week: 7, controller: c),
          ),
        ),
      );
      await tester.pump();
      expect(rowFinder, findsNothing);

      // 2. 设置隐藏周六日：周六有本周手动课 → 显示周六列；周日仅非本周（含显示非本周开）→ 仍隐藏
      c.debugReset();
      c.debugSetSnapshot(
        TimetableSnapshot(
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: termStart,
            showSaturday: false,
            showSunday: false,
            showNonCurrentWeek: true,
          ),
        ),
        viewingWeek: 2,
        manualCourses: [
          Course(
            id: 'sat',
            name: '周六手动课',
            slots: [
              CourseSlot(
                day: 6,
                startNode: 1,
                endNode: 2,
                weeks: weeksToBits([2], 20),
              ),
            ],
          ),
          Course(
            id: 'sun',
            name: '周日非本周',
            slots: [
              CourseSlot(
                day: 7,
                startNode: 1,
                endNode: 2,
                weeks: weeksToBits([1], 20),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekGrid(key: const ValueKey(2), week: 2, controller: c),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('day_header_6')), findsOneWidget);
      expect(find.byKey(const Key('day_header_7')), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekGrid(key: const ValueKey(1), week: 1, controller: c),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('day_header_6')), findsNothing);
      expect(find.byKey(const Key('day_header_7')), findsOneWidget);
    });
  });

  group('周次/日期对齐', () {
    test('mondayOfWeek: 周日归属前一个周一', () {
      expect(mondayOfWeek(DateTime(2026, 10, 11)), DateTime(2026, 10, 5));
      expect(mondayOfWeek(DateTime(2026, 10, 5)), DateTime(2026, 10, 5));
      expect(
        mondayOfWeek(DateTime(2026, 10, 10, 23, 59)),
        DateTime(2026, 10, 5),
      );
    });

    test('周日 2026-10-11 为第 6 周，列为 10/05-10/11', () {
      c.debugSetSnapshot(_snap(DateTime(2026, 8, 31)));
      expect(c.currentWeek, 6);
      expect(c.viewingWeek, 6);
      final dates = c.datesOfWeek(c.currentWeek);
      expect(dates.first, DateTime(2026, 10, 5));
      expect(dates.last, DateTime(2026, 10, 11));
      expect(dates.last.weekday, DateTime.sunday);
      expect(c.weekPending, isFalse);
    });

    test('旧占位开学日 09-07 会得到第 5 周（复现根因）', () {
      expect(teachingWeekOf(DateTime(2026, 9, 7), DateTime(2026, 10, 11)), 5);
      expect(teachingWeekOf(DateTime(2026, 8, 31), DateTime(2026, 10, 11)), 6);
      expect(teachingWeekOf(DateTime(2026, 8, 31), DateTime(2026, 10, 12)), 7);
      expect(teachingWeekOf(DateTime(2026, 8, 31), DateTime(2026, 8, 30)), 0);
    });

    test('dqzc 周日样例推算开学日 08-31', () {
      expect(
        TimetableParser.computeTermStartDate(
          refDate: DateTime(2026, 10, 11),
          weekday: 7,
          week: 6,
        ),
        DateTime(2026, 8, 31),
      );
    });
  });

  group('开学日回退', () {
    test('dqzc 优先', () {
      final r = resolveTermStart(
        termCode: '2026-2027-1',
        fromDqzc: DateTime(2026, 9, 1),
        cached: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: DateTime(2026, 8, 24),
          termStartFromJwxt: true,
        ),
      );
      expect(r.source, TermStartSource.jwxt);
      expect(r.start, DateTime(2026, 9, 1));
    });

    test('dqzc 失败 → 可信缓存', () {
      final r = resolveTermStart(
        termCode: '2026-2027-1',
        cached: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: DateTime(2026, 8, 24),
          termStartFromJwxt: true,
        ),
      );
      expect(r.source, TermStartSource.cache);
      expect(r.start, DateTime(2026, 8, 24));
    });

    test('无缓存（或旧版写入的非教务缓存）→ 内置 2026-08-31', () {
      for (final cached in [
        null,
        TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: DateTime(2026, 9, 7),
        ),
      ]) {
        final r = resolveTermStart(termCode: '2026-2027-1', cached: cached);
        expect(r.source, TermStartSource.builtin);
        expect(r.start, DateTime(2026, 8, 31));
        expect(r.weekPending, isFalse);
      }
    });

    test('其他学期的缓存不复用', () {
      final r = resolveTermStart(
        termCode: '2026-2027-1',
        cached: TimetableSettings(
          termCode: '2025-2026-2',
          termStartDate: DateTime(2026, 3, 2),
          termStartFromJwxt: true,
        ),
      );
      expect(r.source, TermStartSource.builtin);
    });

    test('全部缺失 → weekPending，第 1 周', () {
      final r = resolveTermStart(termCode: '2030-2031-1');
      expect(r.source, TermStartSource.none);
      expect(r.weekPending, isTrue);
      c.debugSetSnapshot(_snap(null));
      expect(c.weekPending, isTrue);
      expect(c.currentWeek, 1);
      expect(c.datesOfWeek(1).first, DateTime(2026, 10, 5));
    });

    test('termStartFromJwxt 持久化往返 & clearTermStart', () {
      final s = TimetableSettings(
        termStartDate: DateTime(2026, 8, 31),
        termStartFromJwxt: true,
      );
      final back = TimetableSettings.fromJson(s.toJson());
      expect(back.termStartFromJwxt, isTrue);
      final cleared = back.copyWith(clearTermStart: true);
      expect(cleared.termStartDate, isNull);
      expect(cleared.termStartFromJwxt, isFalse);
    });

    test('dqzc 表单参数', () {
      final form = TimetableApi.dqzcForm(
        TimetableApi.splitTermCode('2026-2027-1')!,
        DateTime(2026, 10, 11),
      );
      expect(form, {'XN': '2026-2027', 'XQ': '1', 'RQ': '2026-10-11'});
      TimetableApi.logDqzcForm(form); // debug 下打印，不抛异常
    });
  });

  test('元数据端点为 dqzc/dqxnxq；角色由应用建会话处理', () async {
    final paths = <String>[];
    TimetableApi.debugPost = (url, form) async {
      paths.add(url.path);
      if (url.pathSegments.last == 'cxxszhxqkb.do') {
        return {
          'datas': {
            'cxxszhxqkb': {'rows': <Object?>[]},
          },
        };
      }
      if (url.pathSegments.last == 'xswpkc.do') {
        return {
          'datas': {
            'xswpkc': {'rows': <Object?>[]},
          },
        };
      }
      throw Exception('403');
    };
    addTearDown(() {
      TimetableApi.debugPost = null;
      TimetableApi.rolePreCallRoleId = null;
    });
    await TimetableApi.fetchTermSnapshot('2026-2027-1');
    expect(paths, contains('/jwapp/sys/wdkb/modules/jshkcb/dqzc.do'));
    expect(paths, contains('/jwapp/sys/wdkb/modules/jshkcb/dqxnxq.do'));
    expect(
      paths.any((p) => p.contains('dgzc') || p.contains('dgxnxq')),
      isFalse,
    );
    expect(paths.any((p) => p.contains('setJwCommonAppRole')), isFalse);
  });

  testWidgets('网格单双周/零误报幽灵/连通合并显示、详情调课来源与首页实验胶囊', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final termStart = DateTime(2026, 8, 31);

    // 1. 教务课改周次更新单双周胶囊；单日挪课不显示单双周胶囊
    final jwxt = const Course(
      id: 'k1',
      name: '高等数学',
      source: CourseSource.jwxt,
      slots: [
        CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1111111111111111'),
      ],
    );
    final editedOddSlot = CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: weeksToBits([1, 3, 5, 7, 9], 20),
    );
    tagSlotOrigin(
      editedOddSlot,
      SlotOrigin(
        courseId: jwxt.id,
        original: jwxt.slots.single,
        moved: false,
        weeksEdited: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseCell(
            controller: c,
            cell: GridCell(
              course: jwxt,
              slot: editedOddSlot,
              conflictCount: 0,
              activeThisWeek: true,
            ),
            width: 120,
            height: 120,
            radius: 4,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('course_cell_parity_pill')), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseCell(
            controller: c,
            cell: GridCell(
              course: jwxt,
              slot: editedOddSlot,
              conflictCount: 0,
              activeThisWeek: true,
              dateEdit: CourseDateEdit(
                id: 'de1',
                courseId: jwxt.id,
                date: termStart,
                origStart: 1,
                origEnd: 2,
                toDate: DateTime(2026, 9, 1),
                toStart: 3,
                toEnd: 4,
              ),
            ),
            width: 120,
            height: 120,
            radius: 4,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('course_cell_parity_pill')), findsNothing);

    // 2. 多门非本周课择最近、幽灵考试不制造伪冲突、考试跨两段连通合并「3 项」
    c.debugReset();
    c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(
          termStartDate: termStart,
          showNonCurrentWeek: true,
          showExams: true,
        ),
      ),
      viewingWeek: 1,
      manualCourses: [
        Course(
          id: 'c1',
          name: 'C语言',
          slots: [
            CourseSlot(
              day: 1,
              startNode: 1,
              endNode: 2,
              weeks: weeksToBits([9, 10], 20),
            ),
          ],
        ),
        Course(
          id: 'c2',
          name: '高等数学',
          slots: [
            CourseSlot(
              day: 1,
              startNode: 1,
              endNode: 2,
              weeks: weeksToBits([2, 3], 20),
            ),
          ],
        ),
        const Course(
          id: 'a',
          name: '早课甲',
          slots: [
            CourseSlot(
              day: 2,
              startNode: 1,
              endNode: 2,
              weeks: '1111111111111111',
            ),
          ],
        ),
        const Course(
          id: 'b',
          name: '早课乙',
          slots: [
            CourseSlot(
              day: 2,
              startNode: 3,
              endNode: 4,
              weeks: '1111111111111111',
            ),
          ],
        ),
      ],
    );
    await tester.runAsync(
      () => c.addScheduleEvent(
        ScheduleEvent(
          id: 'bridge',
          kind: ScheduleKind.exam,
          source: ScheduleSource.manual,
          title: '跨段期中考',
          date: DateTime(2026, 9, 1),
          start: const TimeOfDayMinutes(9, 0),
          end: const TimeOfDayMinutes(10, 30),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WeekGrid(week: 1, controller: c)),
      ),
    );
    await tester.pump();
    expect(find.widgetWithText(CourseCell, '高等数学'), findsOneWidget);
    expect(find.widgetWithText(CourseCell, 'C语言'), findsNothing);
    expect(find.byKey(const Key('course_cell_off_week_pill')), findsOneWidget);
    expect(find.byType(ScheduleEventCell), findsOneWidget);
    expect(find.text('3 项'), findsOneWidget);

    // 3. 详情显示整天调课来源「由 9月2日 调入」与首页实验课轻标「实验」胶囊
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseDetailSheet(
            cell: GridCell(
              course: const Course(
                id: 'm1',
                name: '数据结构',
                slots: [
                  CourseSlot(day: 7, startNode: 1, endNode: 2, weeks: '1111'),
                ],
              ),
              slot: const CourseSlot(
                day: 7,
                startNode: 1,
                endNode: 2,
                weeks: '1111',
              ),
              conflictCount: 0,
              activeThisWeek: true,
              date: DateTime(2026, 9, 6),
              swappedFrom: DateTime(2026, 9, 2),
            ),
            controller: c,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('course_detail_swapped_from')), findsOneWidget);
    expect(find.text('由 9月2日 调入'), findsOneWidget);

    c.debugReset();
    c.debugSetSnapshot(
      TimetableSnapshot(
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: termStart),
      ),
      viewingWeek: 1,
      manualCourses: [
        const Course(
          id: 'lab1',
          name: '物理实验',
          slots: [
            CourseSlot(
              day: 1,
              startNode: 1,
              endNode: 2,
              weeks: '1111',
              isLab: true,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimetableHomeCard(now: () => DateTime(2026, 8, 31, 7, 30)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('home_course_lab_pill')), findsOneWidget);
    expect(find.text('实验'), findsOneWidget);
  });

  test('SlotCellGroup.primary 按排序确定主课且正确统计冲突计数', () {
    Course makeCourse(String id, String name) => Course(
      id: id,
      name: name,
      slots: const [
        CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1111'),
      ],
    );
    final courseB = makeCourse('b', '编译原理');
    final courseA = makeCourse('a', '操作系统');
    final group = SlotCellGroup([
      GridCell(
        course: courseB,
        slot: courseB.slots.first,
        conflictCount: 99,
        activeThisWeek: true,
      ),
      GridCell(
        course: courseA,
        slot: courseA.slots.first,
        conflictCount: 99,
        activeThisWeek: true,
      ),
    ]);

    expect(group.primary.course.id, 'a');
    expect(group.primary.conflictCount, 1);

    final offGroup = SlotCellGroup([
      GridCell(
        course: courseB,
        slot: courseB.slots.first,
        conflictCount: 5,
        activeThisWeek: false,
      ),
    ]);
    expect(offGroup.primary.conflictCount, 0);
  });

  group('viewingWeek 独立 ValueNotifier 隔离', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tt_viewing_week');
      TimetableStore.debugDirectory = tmp;
      c.debugReset();
      TimetableController.bindingCheck = () async => false;
      TimetableController.clock = () => DateTime(2026, 10, 12, 8, 30);
      TimetableController.syncClock = () => DateTime(2026, 10, 12, 8, 30);
    });

    tearDown(() {
      TimetableController.syncClock = DateTime.now;
      TimetableController.bindingCheck = () async => false;
      TimetableStore.debugDirectory = null;
      c.debugReset();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('setViewingWeek / goToCurrentWeek / jumpToCurrentWeek 仅通知周次监听', () {
      c.debugSetSnapshot(_snap(DateTime(2026, 8, 31), withCourse: true));
      expect(c.currentWeek, 7);
      expect(c.viewingWeek, 7);
      expect(c.viewingWeekListenable.value, 7);
      expect(c.isViewingCurrentWeek, isTrue);

      var controllerCalls = 0;
      final weekValues = <int>[];
      void onController() => controllerCalls++;
      void onWeek() => weekValues.add(c.viewingWeekListenable.value);

      c.addListener(onController);
      c.viewingWeekListenable.addListener(onWeek);
      addTearDown(() {
        c.removeListener(onController);
        c.viewingWeekListenable.removeListener(onWeek);
      });

      c.setViewingWeek(10);
      expect(c.viewingWeek, 10);
      expect(c.isViewingCurrentWeek, isFalse);
      expect(weekValues, [10]);
      expect(controllerCalls, 0);

      c.setViewingWeek(10);
      c.setViewingWeek(99);
      c.setViewingWeek(25);
      c.setViewingWeek(0);
      expect(c.viewingWeek, 1);
      expect(weekValues, [10, 20, 1]);
      expect(controllerCalls, 0);

      c.goToCurrentWeek();
      expect(c.viewingWeek, 7);
      expect(c.isViewingCurrentWeek, isTrue);
      expect(weekValues, [10, 20, 1, 7]);
      expect(controllerCalls, 0);

      c.goToCurrentWeek();
      c.jumpToCurrentWeek();
      expect(weekValues, [10, 20, 1, 7]);
      expect(controllerCalls, 0);

      c.setViewingWeek(12);
      c.jumpToCurrentWeek();
      expect(c.viewingWeek, 7);
      expect(c.isViewingCurrentWeek, isTrue);
      expect(weekValues, [10, 20, 1, 7, 12, 7]);
      expect(controllerCalls, 0);
    });

    test('clearViewingWeek 与 debugReset 静默复位且不触发监听', () {
      c.debugSetSnapshot(
        _snap(DateTime(2026, 8, 31), withCourse: true),
        viewingWeek: 11,
      );
      expect(c.viewingWeek, 11);

      var controllerCalls = 0;
      var weekCalls = 0;
      void onController() => controllerCalls++;
      void onWeek() => weekCalls++;

      c.addListener(onController);
      c.viewingWeekListenable.addListener(onWeek);
      addTearDown(() {
        c.removeListener(onController);
        c.viewingWeekListenable.removeListener(onWeek);
      });

      c.clearViewingWeek();
      expect(c.viewingWeek, 7);
      expect(c.viewingWeekListenable.value, 7);
      expect(controllerCalls, 0);
      expect(weekCalls, 0);

      c.setViewingWeek(15);
      weekCalls = 0;

      c.debugReset();
      expect(c.viewingWeek, 1);
      expect(c.viewingWeekListenable.value, 1);
      expect(controllerCalls, 0);
      expect(weekCalls, 0);
    });

    test('跨周 onAppResumed 仍同时更新周次监听与主监听（保证首页跨周刷新）', () async {
      final sunday = DateTime(2026, 10, 18, 22);
      TimetableController.clock = () => sunday;
      TimetableController.syncClock = () => sunday;
      await TimetableStore.saveSnapshot(
        _snap(
          DateTime(2026, 8, 31),
          withCourse: true,
        ).copyWith(syncedAt: sunday),
      );
      await ScheduleStore.saveLastSyncSuccess(sunday);
      await c.ensureStarted();
      expect(c.viewingWeek, 7);

      var controllerCalls = 0;
      final weekValues = <int>[];
      void onController() => controllerCalls++;
      void onWeek() => weekValues.add(c.viewingWeekListenable.value);

      c.addListener(onController);
      c.viewingWeekListenable.addListener(onWeek);
      addTearDown(() {
        c.removeListener(onController);
        c.viewingWeekListenable.removeListener(onWeek);
      });

      TimetableController.clock = () => DateTime(2026, 10, 19, 8);
      expect(await c.onAppResumed(), isTrue);
      await pumpEventQueue();
      expect(c.viewingWeek, 8);
      expect(weekValues, [8]);
      expect(controllerCalls, 1);

      expect(await c.onAppResumed(), isTrue);
      await pumpEventQueue();
      expect(weekValues, [8]);
      expect(controllerCalls, 1);

      TimetableController.clock = () => DateTime(2026, 10, 20, 8);
      expect(await c.onAppResumed(), isTrue);
      await pumpEventQueue();
      expect(c.viewingWeek, 8);
      expect(weekValues, [8]);
      expect(controllerCalls, 2);
    });

    test('跨周时自动跟随最新本周，但同周内手动翻周后不再被拉回', () {
      final termStart = DateTime(2026, 8, 31);
      TimetableController.clock = () =>
          termStart.add(const Duration(days: 13 * 7));
      c.debugSetSnapshot(_snap(termStart, withCourse: true), viewingWeek: 14);
      expect(c.currentWeek, 14);
      expect(c.viewingWeek, 14);
      expect(c.followCurrentWeekIfChanged(), isFalse);

      TimetableController.clock = () => DateTime(2026, 12, 29); // 第 18 周
      expect(c.currentWeek, 18);
      expect(c.followCurrentWeekIfChanged(), isTrue);
      expect(c.viewingWeek, 18);

      c.setViewingWeek(10);
      expect(c.followCurrentWeekIfChanged(), isFalse);
      expect(c.viewingWeek, 10);
    });
  });
}
