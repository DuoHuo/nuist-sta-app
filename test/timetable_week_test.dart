import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
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
