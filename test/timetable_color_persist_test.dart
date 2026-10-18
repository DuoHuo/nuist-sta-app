// 配色表持久化（timetable/course_colors.json）与编辑/解绑/重启颜色稳定。全部构造数据。
//
// 「学术英语（1）」「数据结构」「算法设计」哈希同为 12；「学…」排序在「数…」前，
// 相邻时「数据结构」（教务课）顺延。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

const _w16 = '1111111111111111';
const _a = '学术英语（1）';
const _j = '数据结构';
const _x = '算法设计';

Course _m(
  String id,
  String name, {
  int day = 1,
  int start = 3,
  int end = 4,
  int? colorIndex,
}) => Course(
  id: id,
  name: name,
  colorIndex: colorIndex,
  slots: [CourseSlot(day: day, startNode: start, endNode: end, weeks: _w16)],
);

Course _jw(String id, String name, {int day = 1, int start = 5}) => Course(
  id: id,
  name: name,
  code: id,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: start + 1,
      weeks: _w16,
      weeksLabel: '1-16周',
    ),
  ],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final origClock = TimetableController.clock;
  final origFetch = TimetableController.fetchSnapshot;

  File colorsFile() => File('${tmp.path}/${TimetableStore.courseColorsFile}');
  Map<String, dynamic> colorsJson() =>
      jsonDecode(colorsFile().readAsStringSync()) as Map<String, dynamic>;

  Map<String, int> colours() => {
    for (final x in c.courses) x.id: c.colorIndexOf(x),
  };

  Course byId(String id) => c.courses.firstWhere((x) => x.id == id);

  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  Future<void> sync(List<Course> jwxt) async {
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: jwxt,
          settings: (baseSettings ?? const TimetableSettings()).copyWith(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
          ),
          periods: TimetableController.defaultPeriods(),
        );
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
  }

  /// 手动课「学术英语（1）」周一 3-4 + 教务课「数据结构」周一 5-6（相邻，教务课顺延）。
  Future<Map<String, int>> seed({List<Course> extraManual = const []}) async {
    await c.ensureStarted();
    await c.addManualCourse(_m('a', _a));
    for (final m in extraManual) {
      await c.addManualCourse(m);
    }
    await sync([_jw('J1', _j)]);
    final before = colours();
    expect(before['a'], 12);
    expect(before['J1'], isNot(12), reason: '前提：教务课因相邻被顺延');
    return before;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_color_persist');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 12);
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = origClock;
    TimetableController.fetchSnapshot = origFetch;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('编辑手动课时间（挨着教务课）后重启：所有课颜色不变', () async {
    final before = await seed();
    final a = c.manualCourseById('a')!;
    await c.updateManualCourse(
      a.copyWith(
        slots: const [
          CourseSlot(day: 5, startNode: 9, endNode: 10, weeks: _w16),
        ],
      ),
    );
    expect(colours(), before);
    await restart();
    expect(colours(), before);
  });

  test('拖动手动课（挨着教务课）后重启：所有课颜色不变', () async {
    final before = await seed();
    final r = await c.moveSlot(
      byId('a'),
      0,
      toDay: 5,
      toStartPeriod: 9,
      week: 1,
      scope: MoveScope.fromThisWeek,
    );
    expect(r.status, MoveStatus.moved);
    expect(colours(), before);
    await restart();
    expect(colours(), before);
  });

  test('编辑时清掉自选色：只给这门课补算颜色，其他课不变，重启后稳定', () async {
    final before = await seed(
      extraManual: [_m('x', _x, start: 1, end: 2, colorIndex: 5)],
    );
    expect(before['x'], 5);
    expect(c.manualCourseById('x')!.assignedColorIndex, isNull);
    final x = c.manualCourseById('x')!;
    final saved = await c.updateManualCourse(x.copyWith(clearColor: true));
    expect(saved.colorIndex, isNull);
    expect(saved.assignedColorIndex, isNotNull);
    expect(saved.assignedColorIndex, isNot(12), reason: '与相邻的学术英语（12）错开');
    final after = colours();
    expect(after['x'], saved.assignedColorIndex);
    expect({...after}..remove('x'), {...before}..remove('x'));
    await restart();
    expect(colours(), after);
  });

  test('编辑时调用方没传 assignedColorIndex：沿用原值', () async {
    final before = await seed();
    final a = c.manualCourseById('a')!;
    final saved = await c.updateManualCourse(
      a.copyWith(clearAssignedColor: true, name: _a),
    );
    expect(saved.assignedColorIndex, 12);
    expect(colours(), before);
  });

  test('只有手动课（无教务快照）：编辑 + 重启颜色不变', () async {
    await c.ensureStarted();
    await c.addManualCourse(_m('a', _a));
    await c.addManualCourse(_m('x', _x, start: 5, end: 6));
    final before = colours();
    expect(before['x'], isNot(12));
    final x = c.manualCourseById('x')!;
    await c.updateManualCourse(
      x.copyWith(
        slots: const [
          CourseSlot(day: 6, startNode: 1, endNode: 2, weeks: _w16),
        ],
      ),
    );
    expect(colours(), before);
    await restart();
    expect(colours(), before);
  });

  test('解绑（handleLogout / clearJwxtCourses）保留手动课颜色', () async {
    final before = await seed(extraManual: [_m('x', _x, day: 2)]);
    await c.handleLogout();
    expect(c.jwxtCourses, isEmpty);
    expect(colours(), {'a': before['a'], 'x': before['x']});
    expect(colorsFile().existsSync(), isTrue);
    await restart();
    expect(colours(), {'a': before['a'], 'x': before['x']});
    await c.clearJwxtCourses();
    expect(colours(), {'a': before['a'], 'x': before['x']});
  });

  test('改名成教务课名的手动课重启后不抢教务课颜色', () async {
    final before = await seed(
      extraManual: [_m('y', '大学物理', day: 7, start: 11, end: 12)],
    );
    final y = c.manualCourseById('y')!;
    await c.updateManualCourse(y.copyWith(name: _j));
    expect(colours(), before);
    await restart();
    expect(colours(), before);
    // 配色表丢了也一样：重建时手动课的 assignedColorIndex 不固定教务课名。
    colorsFile().deleteSync();
    await restart();
    expect(colours(), before);
  });

  test('换配色方案：重算并写 course_colors.json（方案名 + 新表）', () async {
    await seed();
    expect(colorsJson()['scheme'], 'soft');
    await c.updateSettings(c.settings.copyWith(paletteScheme: 'B'));
    final raw = colorsJson();
    expect(raw['schemaVersion'], 1);
    expect(raw['scheme'], 'macaron');
    expect(Map<String, int>.from(raw['map'] as Map), c.courseColorMap);
    final after = colours();
    await restart();
    expect(colours(), after);
  });

  test('同步成功：总是重写 course_colors.json，保留未知顶层键', () async {
    await c.ensureStarted();
    await c.addManualCourse(_m('a', _a));
    final raw = colorsJson()
      ..['futureTop'] = 'keep'
      ..['map'] = {'foo': 3};
    colorsFile().writeAsStringSync(jsonEncode(raw));
    await sync([_jw('J1', _j)]);
    final now = colorsJson();
    expect(now['futureTop'], 'keep');
    final map = Map<String, int>.from(now['map'] as Map);
    expect(map.containsKey('foo'), isFalse);
    expect(map[normalizeCourseName(_j)], c.colorIndexOf(byId('J1')));
    expect(map[normalizeCourseName(_a)], 12);
  });

  test('启动时读盘上的表（方案一致）：直接用，不重建', () async {
    await seed();
    final raw = colorsJson();
    (raw['map'] as Map)[normalizeCourseName(_j)] = 7;
    colorsFile().writeAsStringSync(jsonEncode(raw));
    await restart();
    expect(c.colorIndexOf(byId('J1')), 7);
  });

  group('course_colors.json 不可用 → 重建一次并落盘，不崩溃', () {
    final cases = <String, void Function(File)>{
      '文件不存在': (f) => f.deleteSync(),
      'JSON 损坏': (f) => f.writeAsStringSync('{not json'),
      '顶层不是对象': (f) => f.writeAsStringSync('[1, 2]'),
      '其他配色方案': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'scheme': 'macaron',
          'map': {_j: 3, _a: 3},
        }),
      ),
      '未知方案名': (f) => f.writeAsStringSync(
        jsonEncode({'schemaVersion': 1, 'scheme': 'Z', 'map': {}}),
      ),
      '版本不对': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 99,
          'scheme': 'soft',
          'map': {_j: 3},
        }),
      ),
      'map 值类型不对': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'scheme': 'soft',
          'map': {_j: '3'},
        }),
      ),
      'map 色号越界': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'scheme': 'soft',
          'map': {_j: 99},
        }),
      ),
      'map 不是对象': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'scheme': 'soft',
          'map': [3],
        }),
      ),
    };
    cases.forEach((name, damage) {
      test(name, () async {
        final before = await seed();
        damage(colorsFile());
        await restart();
        expect(colours(), before);
        final raw = colorsJson();
        expect(raw['schemaVersion'], 1);
        expect(raw['scheme'], 'soft');
        expect(
          (raw['map'] as Map)[normalizeCourseName(_j)],
          before['J1'],
          reason: '重建结果已落盘',
        );
        await restart();
        expect(colours(), before);
      });
    });
  });
}
