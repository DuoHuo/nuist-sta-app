import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/theme.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

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

  for (final dark in [false, true]) {
    testWidgets('真实课表翻周途中复用网格，内容与布局变化立即生效（dark=$dark）', (tester) async {
      c.debugReset();
      addTearDown(c.debugReset);
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final snapshot = _snap(DateTime(2026, 8, 31), withCourse: true);
      c.debugSetSnapshot(snapshot);
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: const TimetablePage(),
        ),
      );
      await tester.pumpAndSettle();
      final pager = tester.widget<PageView>(find.byType(PageView));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await gesture.moveBy(const Offset(-120, 0));
      await tester.pump();
      final grids = {
        for (final grid in tester.widgetList<WeekGrid>(find.byType(WeekGrid)))
          grid.week: grid,
      };
      expect(grids.keys, containsAll([6, 7]));
      await gesture.moveBy(const Offset(-110, 0));
      await tester.pump();
      expect(c.viewingWeek, 7);
      expect(tester.widget<PageView>(find.byType(PageView)), same(pager));
      for (final grid in tester.widgetList<WeekGrid>(find.byType(WeekGrid))) {
        expect(grid, same(grids[grid.week]));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 7);

      c.debugSetSnapshot(
        snapshot.copyWith(
          courses: [snapshot.courses.single.copyWith(name: '更新后的课程')],
          settings: snapshot.settings.copyWith(periodHeight: 80),
        ),
        viewingWeek: 7,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<PageView>(find.byType(PageView)),
        isNot(same(pager)),
      );
      final cell = tester.widget<CourseCell>(find.byType(CourseCell));
      expect(cell.cell.course.name, '更新后的课程');
      expect(cell.height, closeTo(157, 0.1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('真实课表短拖翻周，小拖和反拖回弹且保留快甩与纵向滚动（dark=$dark）', (tester) async {
      c.debugReset();
      addTearDown(c.debugReset);
      tester.view.physicalSize = const Size(375, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      c.debugSetSnapshot(_snap(DateTime(2026, 8, 31), withCourse: true));
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? appDarkTheme() : appLightTheme(),
          home: const TimetablePage(),
        ),
      );
      await tester.pumpAndSettle();
      final pageController = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;

      Future<void> slowDrag(double delta, {double? reverse}) async {
        final start = pageController.page!;
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(PageView)),
        );
        await gesture.moveBy(Offset(delta.sign * 25, 0));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveBy(Offset(delta - delta.sign * 25, 0));
        await tester.pump(const Duration(milliseconds: 100));
        if (reverse != null) {
          await gesture.moveBy(Offset(reverse, 0));
          await tester.pump(const Duration(milliseconds: 100));
        }
        // 手势结束前仍按原始距离跟手，没有放大位移或提前跳页。
        final progress = (pageController.page! - start).abs();
        if (delta.abs() == 135 && reverse == null && start > 0 && start < 19) {
          expect(progress, greaterThan(0.25));
          expect(progress, lessThan(0.5));
        }
        await tester.pump(const Duration(milliseconds: 250));
        await gesture.up();
        await tester.pumpAndSettle();
      }

      // 约三分之一屏即可慢速双向翻页，不需要拖过半屏。
      await slowDrag(-135);
      expect(c.viewingWeek, 7);
      expect(pageController.page, closeTo(6, 0.001));
      await slowDrag(135);
      expect(c.viewingWeek, 6);

      await slowDrag(-60);
      expect(c.viewingWeek, 6);
      // 已跨过半页也可反拖回原页，按松手时的净位移决定是否翻页。
      await slowDrag(-245, reverse: 190);
      expect(c.viewingWeek, 6);
      expect(pageController.page, closeTo(5, 0.001));

      // 快甩的距离小于四分之一屏，仍按速度进入相邻周。
      await tester.fling(find.byType(PageView), const Offset(-70, 0), 1500);
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 7);
      await tester.fling(find.byType(PageView), const Offset(70, 0), 1500);
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 6);

      final vertical = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(WeekGrid),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      expect(vertical.maxScrollExtent, greaterThan(0));
      await tester.drag(find.byType(WeekGrid), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(vertical.pixels, greaterThan(0));
      expect(c.viewingWeek, 6);

      c.setViewingWeek(1);
      await tester.pumpAndSettle();
      await slowDrag(135);
      expect(c.viewingWeek, 1);
      expect(pageController.page, closeTo(0, 0.001));
      c.setViewingWeek(20);
      await tester.pumpAndSettle();
      await slowDrag(-135);
      expect(c.viewingWeek, 20);
      expect(pageController.page, closeTo(19, 0.001));

      c.setViewingWeek(6);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('第 6 周', findRichText: true));
      await tester.pumpAndSettle();
      await tester.fling(find.byType(PageView), const Offset(-70, 0), 1500);
      await tester.pump(const Duration(milliseconds: 16));
      expect(pageController.position.isScrollingNotifier.value, isTrue);
      // 手势吸附还没结束就选远周，不能在程序动画结束后被旧起点拉回相邻周。
      await tester.tap(find.byKey(const ValueKey('week_chip_9')));
      await tester.pumpAndSettle();
      expect(c.viewingWeek, 9);
      expect(pageController.page, closeTo(8, 0.001));
      expect(tester.takeException(), isNull);
    });
  }

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

  test('元数据端点为 dqzc/dqxnxq；角色预调用默认关闭、开启后非致命', () async {
    final paths = <String>[];
    TimetableApi.debugPost = (url, form) async {
      paths.add(url.path);
      if (url.pathSegments.last == 'cxxszhxqkb.do') {
        return {'datas': {}};
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

    paths.clear();
    TimetableApi.rolePreCallRoleId = 'TEST_ROLE';
    await TimetableApi.fetchTermSnapshot('2026-2027-1');
    expect(paths, contains('/jwapp/sys/jwpubapp/pub/setJwCommonAppRole.do'));
  });

  testWidgets('开学日变化后 PageView 跟随 viewingWeek（顶栏与网格不错位）', (tester) async {
    c.debugSetSnapshot(_snap(DateTime(2026, 9, 7), withCourse: true)); // 第 5 周
    await tester.pumpWidget(const MaterialApp(home: TimetablePage()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    PageController pc() =>
        tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(pc().page!.round(), 4);

    c.debugSetSnapshot(
      _snap(DateTime(2026, 8, 31), withCourse: true),
    ); // 同步后 → 第 6 周
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(c.viewingWeek, 6);
    expect(pc().page!.round(), 5);
    final grid = tester.widget<WeekGrid>(find.byType(WeekGrid).first);
    expect(grid.week, 6);
    expect(c.datesOfWeek(grid.week).first, DateTime(2026, 10, 5));
    expect(find.textContaining('第 6 周', findRichText: true), findsOneWidget);
    expect(find.textContaining('非本周', findRichText: true), findsNothing);
  });
}
