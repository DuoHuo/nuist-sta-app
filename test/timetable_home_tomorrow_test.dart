import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_layout.dart';

const _w16 = '1111111111111111';

Course _c(String id, String name, int day) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(day: day, startNode: 1, endNode: 2, weeks: _w16, teacher: '教师P'),
  ],
);

void main() {
  final c = TimetableController.instance;
  late Directory tmp;

  void load({bool show = true}) => c.debugSetSnapshot(
    TimetableSnapshot(
      courses: [_c('mon', '周一课', 1), _c('tue', '周二课', 2)],
      periods: TimetableController.defaultPeriods(),
      settings: TimetableSettings(
        termStartDate: DateTime(2026, 8, 31),
        termStartFromJwxt: true,
        showTomorrowOnHome: show,
      ),
    ),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_tomorrow');
    TimetableStore.debugDirectory = tmp;
    c.debugReset();
  });
  tearDown(() async {
    TimetableStore.debugDirectory = null;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('明天有课：标题「明天（周二）」+ 课程', () {
    load();
    final i = c.homeTomorrow(now: DateTime(2026, 10, 12, 22)); // 周一晚
    expect(i.kind, HomeTomorrowKind.courses);
    expect(i.title, '明天（周二）');
    expect(i.courses.single.course.name, '周二课');
    expect(i.todayFinished, isTrue);
    expect(i.hasTomorrowSection, isTrue);
  });

  test('明天是下一周：「明天（周一·第 8 周）」', () {
    load();
    final i = c.homeTomorrow(now: DateTime(2026, 10, 18, 9));
    expect(i.title, '明天（周一·第 8 周）');
    expect(i.tomorrowWeek, 8);
  });

  test('明天没课：「明天没课」', () {
    load();
    final i = c.homeTomorrow(now: DateTime(2026, 10, 13, 22));
    expect(i.kind, HomeTomorrowKind.noClass);
    expect(i.message, '明天没课');
    expect(i.courses, isEmpty);
  });

  test('开关关闭：不显示明天一栏', () {
    load(show: false);
    final i = c.homeTomorrow(now: DateTime(2026, 10, 12, 22));
    expect(i.kind, HomeTomorrowKind.disabled);
    expect(i.hasTomorrowSection, isFalse);
  });

  test('学期已结束（actualWeek > 总周数）：「本学期已结束」', () {
    load();
    expect(c.totalWeeks, 16);
    final i = c.homeTomorrow(now: DateTime(2026, 12, 21)); // 第 17 周
    expect(i.kind, HomeTomorrowKind.termEnded);
    expect(i.message, '本学期已结束');
    expect(i.hasTomorrowSection, isFalse);
  });

  test('最后一周周日：明天超出总周数 → 明天没课（今天学期未结束）', () {
    load();
    final i = c.homeTomorrow(now: DateTime(2026, 12, 20, 20));
    expect(i.kind, HomeTomorrowKind.noClass);
  });

  test('开学前一天：照常显示第 1 周周一的课', () {
    load();
    final i = c.homeTomorrow(now: DateTime(2026, 8, 30, 20));
    expect(i.kind, HomeTomorrowKind.courses);
    expect(i.title, '明天（周一·第 1 周）');
    expect(i.courses.single.course.name, '周一课');
  });

  test('开学前更早：「距开学 N 天」', () {
    load();
    final i = c.homeTomorrow(now: DateTime(2026, 8, 20, 8));
    expect(i.kind, HomeTomorrowKind.beforeTerm);
    expect(i.daysUntilTerm, 11);
    expect(i.message, '距开学 11 天');
    expect(i.hasTomorrowSection, isFalse);
  });

  test('套用调课记录：周一课第 8 周挪到周三', () async {
    load();
    final mon = c.courses.firstWhere((x) => x.id == 'mon');
    final r = await c.moveSlot(
      mon,
      0,
      toDay: 3,
      toStartPeriod: 3,
      week: 8,
      scope: MoveScope.thisWeek,
    );
    expect(r.ok, isTrue);
    final wed = c.homeTomorrow(now: DateTime(2026, 10, 20, 22)); // 第 8 周周二
    expect(wed.courses.map((e) => e.course.name), ['周一课']);
    expect(wed.courses.single.slot.startNode, 3);
    final sun = c.homeTomorrow(now: DateTime(2026, 10, 18, 22));
    expect(sun.kind, HomeTomorrowKind.noClass); // 第 8 周周一的课被挪走
  });

  group('firstCourseTomorrow 公共接口', () {
    test('按明天实际节次取首课，和数据顺序无关，不受首页开关影响', () {
      final early = _c('early', '体育（3）', 2).copyWith(projectName: '射箭');
      final late = _c('late', '晚课', 2).copyWith(
        slots: [
          const CourseSlot(day: 2, startNode: 5, endNode: 6, weeks: _w16),
        ],
      );
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [late, early, _c('today', '今日课', 1)],
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 8, 31),
            showTomorrowOnHome: false,
          ),
        ),
      );
      final first = c.firstCourseTomorrow(now: DateTime(2026, 10, 12, 23, 59));
      expect(first!.course.id, 'early');
      expect(first.course.displayName, '体育·射箭');
      expect(first.slot.startNode, 1);
    });

    test('跨周和跨年按本机自然日查询，不把下周当本周', () {
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [
            _c('mon', '周一课', 1).copyWith(
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
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        ),
      );
      expect(c.firstCourseTomorrow(now: DateTime(2026, 10, 11)), isNull);
      expect(
        c.firstCourseTomorrow(now: DateTime(2026, 10, 18))!.course.id,
        'mon',
      );
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [_c('fri', '元旦课', 5)],
          settings: TimetableSettings(termStartDate: DateTime(2026, 12, 28)),
        ),
      );
      expect(
        c.firstCourseTomorrow(now: DateTime(2026, 12, 31, 23, 59))!.course.id,
        'fri',
      );
    });

    test('无课、隐藏课、学期外或未知开学日返回 null', () {
      load();
      expect(c.firstCourseTomorrow(now: DateTime(2026, 10, 13)), isNull);
      expect(c.firstCourseTomorrow(now: DateTime(2026, 8, 20)), isNull);
      expect(c.firstCourseTomorrow(now: DateTime(2026, 12, 21)), isNull);
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [_c('hidden', '隐藏课', 2).copyWith(hidden: true)],
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        ),
      );
      expect(c.firstCourseTomorrow(now: DateTime(2026, 10, 12)), isNull);
      c.debugSetSnapshot(const TimetableSnapshot());
      expect(c.firstCourseTomorrow(now: DateTime(2026, 10, 12)), isNull);
    });

    test('调课后只在新日期返回实际节次', () async {
      load();
      final mon = c.courses.firstWhere((x) => x.id == 'mon');
      final moved = await c.moveSlot(
        mon,
        0,
        toDay: 3,
        toStartPeriod: 3,
        week: 8,
        scope: MoveScope.thisWeek,
      );
      expect(moved.ok, isTrue);
      expect(c.firstCourseTomorrow(now: DateTime(2026, 10, 18)), isNull);
      final first = c.firstCourseTomorrow(now: DateTime(2026, 10, 20));
      expect(first!.course.id, 'mon');
      expect(first.slot.startNode, 3);
    });
  });

  test('无开学日：unknown', () {
    c.debugSetSnapshot(const TimetableSnapshot());
    expect(
      c.homeTomorrow(now: DateTime(2026, 10, 12)).kind,
      HomeTomorrowKind.unknown,
    );
  });
}
