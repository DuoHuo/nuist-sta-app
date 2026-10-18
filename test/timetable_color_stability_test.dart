import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

// 颜色稳定规则：拖动 / 恢复原位置 / 重启不改任何课颜色；
// 只在教务同步、增删课程、换配色方案时重算。
//
// 「学术英语（1）」「数据结构」哈希同为 12：相邻时排序靠后的「数据结构」顺延。
const _w16 = '1111111111111111';
const _a = '学术英语（1）';
const _b = '数据结构';

Course _m(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  int? colorIndex,
}) => Course(
  id: id,
  name: name,
  colorIndex: colorIndex,
  slots: [CourseSlot(day: day, startNode: start, endNode: end, weeks: _w16)],
);

Course _j(String id, String name, {int day = 1, int start = 5, int end = 6}) =>
    Course(
      id: id,
      name: name,
      code: id,
      source: CourseSource.jwxt,
      slots: [
        CourseSlot(
          day: day,
          startNode: start,
          endNode: end,
          weeks: _w16,
          weeksLabel: '1-16周',
        ),
      ],
    );

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final settings = TimetableSettings(
    termCode: '2026-2027-1',
    termStartDate: DateTime(2026, 8, 31),
    termStartFromJwxt: true,
  );
  final origClock = TimetableController.clock;

  File manualFile() => File('${tmp.path}/manual_courses.json');

  void load({List<Course> jwxt = const [], List<Course> manual = const []}) {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: jwxt,
        settings: settings,
        periods: TimetableController.defaultPeriods(),
      ),
      manualCourses: manual,
    );
  }

  Map<String, int> colours() => {
    for (final x in c.courses) x.id: c.colorIndexOf(x),
  };

  Course byId(String id) => c.courses.firstWhere((x) => x.id == id);

  Future<void> drag(String id, {required int toDay, int toStart = 1}) async {
    final r = await c.moveSlot(
      byId(id),
      0,
      toDay: toDay,
      toStartPeriod: toStart,
      week: 1,
      scope: MoveScope.fromThisWeek,
    );
    expect(r.status, MoveStatus.moved);
  }

  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  /// 两门相邻手动课（B 顺延）。
  Future<void> seed() async {
    load();
    await c.addManualCourse(_m('a', _a));
    await c.addManualCourse(_m('b', _b, start: 3, end: 4));
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_color_stab');
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

  test('增课时算出并持久化 assignedColorIndex（相邻撞色顺延）', () async {
    await seed();
    final b = c.manualCourseById('b')!;
    expect(c.manualCourseById('a')!.assignedColorIndex, 12);
    expect(b.assignedColorIndex, isNot(12));
    expect(c.colorIndexOf(b), b.assignedColorIndex);
    final raw = jsonDecode(manualFile().readAsStringSync()) as Map;
    final list = raw['courses'] as List;
    expect(
      list.every((e) => (e as Map).containsKey('assignedColorIndex')),
      isTrue,
    );
  });

  test('拖动手动课（整段/本周拆分）不改任何课颜色（含邻居）', () async {
    await seed();
    final before = colours();
    await drag('b', toDay: 5); // 离开邻居
    expect(colours(), before);
    final r = await c.moveSlot(
      byId('a'),
      0,
      toDay: 4,
      toStartPeriod: 7,
      week: 2,
      scope: MoveScope.thisWeek, // 拆分时段
    );
    expect(r.status, MoveStatus.moved);
    expect(c.manualCourseById('a')!.slots.length, greaterThan(1));
    expect(colours(), before);
  });

  test('教务课拖动与恢复原位置不改任何课颜色', () async {
    load(jwxt: [_j('J1', '大学物理'), _j('J2', _b, start: 7, end: 8)]);
    await c.addManualCourse(_m('a', _a, start: 3, end: 4));
    final before = colours();
    await drag('J1', toDay: 6, toStart: 1);
    expect(colours(), before);
    expect(await c.restoreOverride(byId('J1'), 0), isTrue);
    expect(colours(), before);
  });

  test('拖动后模拟重启（从磁盘重读）颜色不变', () async {
    await seed();
    final before = colours();
    await drag('b', toDay: 5);
    await restart();
    expect(colours(), before);
    expect(c.manualCourseById('b')!.assignedColorIndex, before['b']);
  });

  test('增 / 删课程会重算', () async {
    await seed();
    await drag('b', toDay: 5);
    final bumped = c.colorIndexOf(byId('b'));
    expect(bumped, isNot(12));
    await c.addManualCourse(_m('c', '体育', day: 7, start: 11, end: 12));
    expect(c.colorIndexOf(byId('b')), 12); // 不再相邻 → 回到哈希色
    // 再造相邻后删课触发重算
    await drag('b', toDay: 1, toStart: 3);
    expect(c.colorIndexOf(byId('b')), 12); // 拖动不重算
    expect(await c.deleteManualCourse('c'), isTrue);
    expect(c.colorIndexOf(byId('b')), isNot(12));
  });

  test('换配色方案会重算并落盘', () async {
    await seed();
    await drag('b', toDay: 5);
    expect(c.colorIndexOf(byId('b')), isNot(12));
    await c.updateSettings(c.settings.copyWith(paletteScheme: 'B'));
    expect(c.colorIndexOf(byId('b')), 12);
    expect(c.manualCourseById('b')!.assignedColorIndex, 12);
    await restart();
    expect(c.manualCourseById('b')!.assignedColorIndex, 12);
  });

  test('旧数据缺字段：启动算一次并落盘，未知键保留，之后不再改写', () async {
    manualFile().writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'futureTop': 1,
        'courses': [
          {..._m('a', _a).toJson(), 'futureKey': 'x'},
          _m('b', _b, start: 3, end: 4).toJson(),
        ],
      }),
    );
    await c.ensureStarted();
    final a = c.manualCourseById('a')!, b = c.manualCourseById('b')!;
    expect(a.assignedColorIndex, 12);
    expect(b.assignedColorIndex, isNot(12));
    final once = manualFile().readAsStringSync();
    final raw = jsonDecode(once) as Map;
    expect(raw['futureTop'], 1);
    expect(((raw['courses'] as List).first as Map)['futureKey'], 'x');
    await drag('b', toDay: 5);
    await restart();
    expect(c.manualCourseById('b')!.assignedColorIndex, b.assignedColorIndex);
    expect(
      (jsonDecode(manualFile().readAsStringSync()) as Map)['futureTop'],
      1,
    );
  });

  test('用户自选色号优先，且不写 assignedColorIndex', () async {
    load();
    await c.addManualCourse(_m('a', _a));
    await c.addManualCourse(_m('b', _b, start: 3, end: 4, colorIndex: 5));
    final b = c.manualCourseById('b')!;
    expect(c.colorIndexOf(b), 5);
    expect(b.assignedColorIndex, isNull);
    await drag('b', toDay: 5);
    await restart();
    expect(c.colorIndexOf(c.manualCourseById('b')!), 5);
  });
}
