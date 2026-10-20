// 手动课拖动拆分后的「[非本周]」虚影（QA V05h–V05k）。全部为构造数据，不读真实样例。
//
// 拆出的时段带 CourseSlot.splitFrom（原时段的星期 + 起止节）；第 w 周拆出的时段有课
// 时，原时段在第 w 周不画非本周灰格。其他周照常。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_course_cell.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

const _w16 = '1111111111111111';
const _week = 7; // 2026-10-12 周一 = 第 7 周（开学 08-31）
const _orig = SlotRef(day: 1, startNode: 1, endNode: 2);

Course _manual(String id, String name, {String weeks = _w16}) => Course(
  id: id,
  name: name,
  slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final origClock = TimetableController.clock;
  final settings = TimetableSettings(
    termCode: '2026-2027-1',
    termStartDate: DateTime(2026, 8, 31),
    termStartFromJwxt: true,
    showNonCurrentWeek: true,
  );

  File manualFile() => File('${tmp.path}/manual_courses.json');

  void load(List<Course> manual) => c.debugSetSnapshot(
    TimetableSnapshot(
      settings: settings,
      periods: TimetableController.defaultPeriods(),
    ),
    viewingWeek: _week,
    manualCourses: manual,
  );

  Future<MoveResult> move(
    String id,
    int slotIndex, {
    required int toDay,
    required int toStart,
    int week = _week,
    MoveScope scope = MoveScope.thisWeek,
  }) => c.moveSlot(
    c.manualCourseById(id)!,
    slotIndex,
    toDay: toDay,
    toStartPeriod: toStart,
    week: week,
    scope: scope,
  );

  /// 第 [week] 周第 [day] 天的格子：(起始节, 本周有课)。
  List<(int, bool)> cells(int week, int day) => [
    for (final g in c.cellsForDay(week, day))
      (g.slot.startNode, g.activeThisWeek),
  ];

  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_split_ghost');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 12);
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = origClock;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('V05h 只改本周：本周原位置无虚影，其他周照常；拆出时段他周为灰格', () async {
    load([_manual('m1', '甲课程')]);
    final r = await move('m1', 0, toDay: 3, toStart: 9);
    expect(r.status, MoveStatus.moved);
    final slots = c.manualCourseById('m1')!.slots;
    expect(slots.length, 2);
    expect(slots[0].splitFrom, isNull);
    expect(slots[1].splitFrom, _orig);
    // 第 7 周：原位置（周一 1-2）不画「[非本周]」；新位置本周有课。
    expect(cells(_week, 1), isEmpty);
    expect(cells(_week, 3), [(9, true)]);
    // 第 8 周：原位置照常有课；拆出时段仅第 7 周有课 → §15 之后无安排，不画灰格。
    expect(cells(8, 1), [(1, true)]);
    expect(cells(8, 3), isEmpty);
    // 关掉「显示非本周」：本来就没有灰格。
    await c.updateSettings(c.settings.copyWith(showNonCurrentWeek: false));
    expect(cells(_week, 1), isEmpty);
    expect(cells(8, 3), isEmpty);
  });

  test('V05h 改以后所有周：移走的各周原位置无虚影，之前的周照常', () async {
    load([_manual('m1', '甲课程')]);
    await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
    final slots = c.manualCourseById('m1')!.slots;
    expect(slots.length, 2);
    expect(slots[1].splitFrom, _orig);
    for (final w in [7, 10, 16]) {
      expect(cells(w, 1), isEmpty, reason: '第 $w 周');
      expect(cells(w, 3), [(9, true)]);
    }
    for (final w in [1, 6]) {
      expect(cells(w, 1), [(1, true)]);
      expect(cells(w, 3), [(9, false)], reason: '拆出时段在第 $w 周为灰格');
    }
  });

  test('V05i 单周课改以后所有周：两边都无课的双周两处灰格照常', () async {
    load([_manual('m1', '乙课程', weeks: '10' * 8)]);
    await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
    expect(cells(_week, 1), isEmpty); // 7 周移走
    expect(cells(_week, 3), [(9, true)]);
    // 第 8 周（双周）：原位置已无后续周 → §15 隐藏；拆出时段之后还有单周 → 灰格。
    expect(cells(8, 1), isEmpty);
    expect(cells(8, 3), [(9, false)]);
    expect(cells(5, 1), [(1, true)]);
    expect(cells(5, 3), [(9, false)]);
  });

  test('拆出的时段再拆：沿 splitFrom 链，原位置与中间位置本周都无虚影', () async {
    load([_manual('m1', '甲课程')]);
    await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
    await move('m1', 1, toDay: 5, toStart: 3, week: 9);
    final slots = c.manualCourseById('m1')!.slots;
    expect(slots.length, 3);
    expect(
      slots[2].splitFrom,
      const SlotRef(day: 3, startNode: 9, endNode: 10),
    );
    expect(cells(9, 1), isEmpty);
    expect(cells(9, 3), isEmpty);
    expect(cells(9, 5), [(3, true)]);
    expect(cells(10, 3), [(9, true)]);
    // 第 9 周拆出的时段仅该周有课 → §15 在第 10 周不画灰格。
    expect(cells(10, 5), isEmpty);
  });

  test('V05j 拖回原位置：并回原时段，无重复格、无虚影', () async {
    load([_manual('m1', '甲课程')]);
    final before = c.colorIndexOf(c.manualCourseById('m1')!);
    await move('m1', 0, toDay: 3, toStart: 9);
    final r = await move('m1', 1, toDay: 1, toStart: 1);
    expect(r.status, MoveStatus.moved);
    final slots = c.manualCourseById('m1')!.slots;
    expect(slots.length, 1);
    expect(slots.single.weeks, _w16);
    expect(slots.single.splitFrom, isNull);
    for (final w in [1, _week, 8]) {
      expect(cells(w, 1), [(1, true)]);
      expect(cells(w, 3), isEmpty);
    }
    expect(c.colorIndexOf(c.manualCourseById('m1')!), before);
  });

  test('V05j 改以后所有周再整段拖回：合并成一个时段', () async {
    load([_manual('m1', '甲课程')]);
    await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
    await move('m1', 1, toDay: 1, toStart: 1, scope: MoveScope.fromThisWeek);
    final slots = c.manualCourseById('m1')!.slots;
    expect(slots.length, 1);
    expect(slots.single.weeks, _w16);
    expect(cells(_week, 1), [(1, true)]);
    expect(cells(_week, 3), isEmpty);
  });

  test('V05j 删课：所有周都不留格子/虚影', () async {
    load([_manual('m1', '甲课程')]);
    await move('m1', 0, toDay: 3, toStart: 9);
    expect(await c.deleteManualCourse('m1'), isTrue);
    for (var w = 1; w <= 16; w++) {
      for (var d = 1; d <= 7; d++) {
        expect(c.cellsForDay(w, d), isEmpty);
      }
    }
  });

  test('V05k splitFrom 落盘并在重启后保留，虚影规则仍生效', () async {
    load([]);
    await TimetableStore.saveSettings(settings); // 重启后仍「显示非本周」
    await c.addManualCourse(_manual('m1', '甲课程'));
    final colour = c.colorIndexOf(c.manualCourseById('m1')!);
    await move('m1', 0, toDay: 3, toStart: 9);
    final raw = jsonDecode(manualFile().readAsStringSync()) as Map;
    final slotsJson = ((raw['courses'] as List).single as Map)['slots'] as List;
    expect((slotsJson[0] as Map).containsKey('splitFrom'), isFalse);
    expect((slotsJson[1] as Map)['splitFrom'], {
      'day': 1,
      'startNode': 1,
      'endNode': 2,
    });
    await restart();
    expect(c.settings.showNonCurrentWeek, isTrue);
    expect(c.manualCourseById('m1')!.slots[1].splitFrom, _orig);
    expect(cells(_week, 1), isEmpty);
    expect(cells(8, 3), isEmpty); // 仅第 7 周的拆出时段，§15 不画灰格
    expect(c.colorIndexOf(c.manualCourseById('m1')!), colour);
  });

  test('V05k 旧 manual_courses.json 无 splitFrom：正常读、按普通时段、颜色不变', () async {
    manualFile().writeAsStringSync(
      jsonEncode({
        'schemaVersion': 2,
        'courses': [
          {
            'id': 'm1',
            'name': '甲课程',
            'source': 'manual',
            'assignedColorIndex': 9,
            'slots': [
              {'day': 1, 'startNode': 1, 'endNode': 2, 'weeks': '1' * 6},
              // 老版本「只改本周」拆出的时段：没有 splitFrom。
              {'day': 3, 'startNode': 9, 'endNode': 10, 'weeks': '0000001'},
            ],
          },
          {
            'id': 'm2',
            'name': '乙课程',
            'source': 'manual',
            'colorIndex': 4,
            'slots': [
              {
                'day': 2,
                'startNode': 3,
                'endNode': 4,
                'weeks': _w16,
                'splitFrom': 'garbage', // 类型不对 → 当作没有
              },
            ],
          },
        ],
      }),
    );
    await c.ensureStarted();
    final m1 = c.manualCourseById('m1')!, m2 = c.manualCourseById('m2')!;
    expect(m1.slots.map((s) => s.splitFrom), [null, null]);
    expect(m2.slots.single.splitFrom, isNull);
    expect(c.colorIndexOf(m1), 9);
    expect(c.colorIndexOf(m2), 4);
    expect(m1.assignedColorIndex, 9);
  });

  test('SlotRef JSON：往返；缺键/类型不对 → null', () {
    const ref = SlotRef(day: 2, startNode: 3, endNode: 4);
    expect(SlotRef.tryParse(ref.toJson()), ref);
    expect(SlotRef.tryParse(null), isNull);
    expect(SlotRef.tryParse({'day': 2, 'startNode': 3}), isNull);
    expect(
      SlotRef.tryParse({'day': '2', 'startNode': 3, 'endNode': 4}),
      isNull,
    );
    final s = CourseSlot.fromJson({
      'day': 3,
      'startNode': 9,
      'endNode': 10,
      'weeks': '01',
      'splitFrom': ref.toJson(),
    });
    expect(s.splitFrom, ref);
    expect(CourseSlot.fromJson(s.toJson()).splitFrom, ref);
    expect(
      const CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: '1').toJson(),
      isNot(contains('splitFrom')),
    );
  });

  test('拆分不改颜色；编辑表单：位置不变保留 splitFrom，改了星期/节次清掉', () async {
    load([]);
    await c.addManualCourse(_manual('m1', '甲课程'));
    await c.addManualCourse(
      Course(
        id: 'm2',
        name: '乙课程',
        slots: const [
          CourseSlot(day: 2, startNode: 1, endNode: 2, weeks: _w16),
        ],
      ),
    );
    final before = {for (final x in c.courses) x.id: c.colorIndexOf(x)};
    await move('m1', 0, toDay: 3, toStart: 9);
    expect({for (final x in c.courses) x.id: c.colorIndexOf(x)}, before);
    // 表单重建的时段不带 splitFrom（只改了地点）。
    final m1 = c.manualCourseById('m1')!;
    final edited = await c.updateManualCourse(
      m1.copyWith(
        slots: [
          m1.slots[0],
          CourseSlot(
            day: 3,
            startNode: 9,
            endNode: 10,
            weeks: m1.slots[1].weeks,
            location: '新地点',
          ),
        ],
      ),
    );
    expect(edited.slots[1].splitFrom, _orig);
    expect(cells(_week, 1), isEmpty);
    // 改了节次 → 清掉 splitFrom，原位置第 7 周恢复普通灰格。
    final moved = await c.updateManualCourse(
      edited.copyWith(
        slots: [
          edited.slots[0],
          CourseSlot(
            day: 3,
            startNode: 5,
            endNode: 6,
            weeks: edited.slots[1].weeks,
          ),
        ],
      ),
    );
    expect(moved.slots[1].splitFrom, isNull);
    expect(cells(_week, 1), [(1, false)]);
    expect({for (final x in c.courses) x.id: c.colorIndexOf(x)}, before);
  });

  testWidgets('V05h 周视图：显示非本周 + 手动课只改本周，原位置不留「[非本周]」虚影', (tester) async {
    load([_manual('m1', '甲课程')]);
    final r = (await tester.runAsync(
      () => move('m1', 0, toDay: 3, toStart: 9),
    ))!;
    expect(r.status, MoveStatus.moved);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    Future<void> pump(int week) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekGrid(key: ValueKey(week), week: week, controller: c),
          ),
        ),
      );
      await tester.pump();
    }

    await pump(_week);
    expect(find.byType(CourseCell), findsOneWidget);
    expect(find.textContaining('非本周'), findsNothing);
    await pump(8);
    // §15：仅第 7 周的拆出时段之后无课，不画灰格；只剩周一原课。
    expect(find.byType(CourseCell), findsOneWidget);
    expect(find.text('非本周'), findsNothing);
  });
}
