// 配色表持久化（timetable/course_colors.json）与编辑/解绑/重启颜色稳定。全部构造数据。
//
// 「学术英语（1）」「数据结构」「算法设计」哈希同为 12；「学…」排序在「数…」前，
// 相邻时「数据结构」（教务课）顺延。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_colors.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
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

  test('编辑或拖动手动课（挨着教务课）后重启：所有课颜色不变', () async {
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

    final a = c.manualCourseById('a')!;
    await c.updateManualCourse(
      a.copyWith(
        slots: const [
          CourseSlot(day: 4, startNode: 7, endNode: 8, weeks: _w16),
        ],
      ),
    );
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

  test('只有手动课（无教务快照）：增课持久化、编辑与本周拆分拖动重启不变、删课后重算', () async {
    await c.ensureStarted();
    await c.addManualCourse(_m('a', _a, start: 1, end: 2));
    await c.addManualCourse(_m('b', _j, start: 3, end: 4));
    final before = colours();
    expect(c.manualCourseById('a')!.assignedColorIndex, 12);
    expect(c.manualCourseById('b')!.assignedColorIndex, isNot(12));
    expect(before['b'], isNot(12));

    final b = c.manualCourseById('b')!;
    await c.updateManualCourse(
      b.copyWith(
        slots: const [
          CourseSlot(day: 6, startNode: 1, endNode: 2, weeks: _w16),
        ],
      ),
    );
    expect(colours(), before);
    final r1 = await c.moveSlot(
      byId('b'),
      0,
      toDay: 5,
      toStartPeriod: 1,
      week: 1,
      scope: MoveScope.fromThisWeek,
    );
    expect(r1.status, MoveStatus.moved);
    final r2 = await c.moveSlot(
      byId('a'),
      0,
      toDay: 4,
      toStartPeriod: 7,
      week: 2,
      scope: MoveScope.thisWeek,
    );
    expect(r2.status, MoveStatus.moved);
    expect(colours(), before);
    await restart();
    expect(colours(), before);

    // 删掉 a 后重算，b 回到哈希色 12
    expect(await c.deleteManualCourse('a'), isTrue);
    expect(c.colorIndexOf(byId('b')), 12);
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
    expect(raw['schemaVersion'], TimetableStore.courseColorsSchemaVersion);
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

  test('course_colors.json 不可用（9 种损坏/失配场景）→ 重建一次并落盘，不崩溃', () async {
    final cases = <String, void Function(File)>{
      '文件不存在': (f) => f.deleteSync(),
      'JSON 损坏': (f) => f.writeAsStringSync('{not json'),
      '顶层不是对象': (f) => f.writeAsStringSync('[1, 2]'),
      '其他配色方案': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': TimetableStore.courseColorsSchemaVersion,
          'scheme': 'macaron',
          'map': {_j: 3, _a: 3},
        }),
      ),
      '未知方案名': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': TimetableStore.courseColorsSchemaVersion,
          'scheme': 'Z',
          'map': {},
        }),
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
          'schemaVersion': TimetableStore.courseColorsSchemaVersion,
          'scheme': 'soft',
          'map': {_j: '3'},
        }),
      ),
      'map 色号越界': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': TimetableStore.courseColorsSchemaVersion,
          'scheme': 'soft',
          'map': {_j: 99},
        }),
      ),
      'map 不是对象': (f) => f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': TimetableStore.courseColorsSchemaVersion,
          'scheme': 'soft',
          'map': [3],
        }),
      ),
    };
    final before = await seed();
    for (final entry in cases.entries) {
      entry.value(colorsFile());
      await restart();
      expect(colours(), before, reason: entry.key);
      final raw = colorsJson();
      expect(
        raw['schemaVersion'],
        TimetableStore.courseColorsSchemaVersion,
        reason: entry.key,
      );
      expect(raw['scheme'], 'soft', reason: entry.key);
      expect(
        (raw['map'] as Map)[normalizeCourseName(_j)],
        before['J1'],
        reason: '${entry.key} 重建结果已落盘',
      );
      await restart();
      expect(colours(), before, reason: '${entry.key} 二次重启');
    }
  });

  group('教务课调课覆盖不改色（MoveScope）', () {
    const kEnglish = '学术英语（1）';
    const kDataStruct = '数据结构';

    Course jwPair(String id, String name, {int day = 1, int start = 1}) =>
        Course(
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

    void loadPair(List<Course> jwxt) => c.debugSetSnapshot(
      TimetableSnapshot(
        courses: jwxt,
        settings: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: DateTime(2026, 8, 31),
          termStartFromJwxt: true,
        ),
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: 7,
    );

    Future<void> addDummyManual() => c.addManualCourse(
      Course(
        id: 'x',
        name: '体育',
        slots: [CourseSlot(day: 7, startNode: 11, endNode: 12, weeks: _w16)],
      ),
    );

    for (final scope in MoveScope.values) {
      test('教务课 ${scope.name} 移走/并邻/恢复/重启均保持原色', () async {
        Map<String, int> jwxtColours() => {
          for (final x in c.courses)
            if (x.source == CourseSource.jwxt) x.id: c.colorIndexOf(x),
        };
        loadPair([
          jwPair('A', kEnglish),
          jwPair('B', kDataStruct, start: 3),
          jwPair('C', '大学物理', day: 2),
        ]);
        final before = jwxtColours();
        expect(before['A'], 12);
        expect(before['B'], isNot(12));
        final r1 = await c.moveSlot(
          byId('A'),
          0,
          toDay: 5,
          toStartPeriod: 7,
          week: 7,
          scope: scope,
        );
        expect(r1.status, MoveStatus.moved);
        expect(jwxtColours(), before);
        await addDummyManual();
        expect(jwxtColours(), before);

        // 恢复原位置不改色
        expect(await c.restoreOverride(byId('A'), 0), isTrue);
        expect(c.slotOverrides, isEmpty);
        expect(jwxtColours(), before);

        // 分离后移至相邻不触发顺延，且重启不变
        final jwSep = [
          jwPair('A', kEnglish),
          jwPair('B', kDataStruct, day: 4, start: 7),
        ];
        await TimetableStore.saveSnapshot(
          TimetableSnapshot(
            courses: jwSep,
            settings: TimetableSettings(
              termCode: '2026-2027-1',
              termStartDate: DateTime(2026, 8, 31),
              termStartFromJwxt: true,
            ),
            periods: TimetableController.defaultPeriods(),
          ),
        );
        loadPair(jwSep);
        final sepBefore = jwxtColours();
        expect(sepBefore.values.toSet(), hasLength(2));
        await c.moveSlot(
          byId('B'),
          0,
          toDay: 1,
          toStartPeriod: 3,
          week: 7,
          scope: scope,
        );
        expect(jwxtColours(), sepBefore);
        await restart();
        expect(jwxtColours(), sepBefore);
      });
    }
  });

  group('手动课历史兼容', () {
    File manualFile() => File('${tmp.path}/manual_courses.json');

    test('旧 v1 手动课缺 assignedColorIndex：启动补算并保留未知键；重读不再重写', () async {
      manualFile().writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'futureTop': 1,
          'courses': [
            {..._m('a', _a, start: 1, end: 2).toJson(), 'futureKey': 'x'},
            _m('b', _j, start: 3, end: 4).toJson(),
          ],
        }),
      );
      await c.ensureStarted();
      final a = c.manualCourseById('a')!;
      final b = c.manualCourseById('b')!;
      expect(a.assignedColorIndex, 12);
      expect(b.assignedColorIndex, isNot(12));
      final once = manualFile().readAsStringSync();
      final raw = jsonDecode(once) as Map;
      expect(raw['futureTop'], 1);
      expect(((raw['courses'] as List).first as Map)['futureKey'], 'x');
      await restart();
      expect(manualFile().readAsStringSync(), once);

      // schema v2 更新 colorIndex 后保留且越界回 null
      await c.updateManualCourse(a.copyWith(colorIndex: 7));
      expect(manualFile().readAsStringSync(), contains('"schemaVersion":2'));
      await restart();
      expect(c.manualCourseById('a')!.resolvedColorIndex, 7);
      expect(
        Course.fromJson({'id': 'x', 'name': 'a', 'colorIndex': 99}).colorIndex,
        isNull,
      );
    });
  });

  group('UC 自选颜色、局部颜色与最近颜色表', () {
    test('UC01 userColors 往返；与配色表互不覆盖；损坏或 user=false 跳过', () async {
      expect(await TimetableStore.readUserCourseColors(), isEmpty);
      await TimetableStore.saveCourseColors(CoursePaletteScheme.soft, {'x': 3});
      await TimetableStore.saveUserCourseColors({'a': 0xFF3366CC});
      expect(await TimetableStore.readUserCourseColors(), {'a': 0xFF3366CC});
      await TimetableStore.saveCourseColors(CoursePaletteScheme.soft, {'x': 5});
      expect(await TimetableStore.readUserCourseColors(), {'a': 0xFF3366CC});
      expect((await TimetableStore.readCourseColors())!.map, {'x': 5});
      final raw = colorsJson();
      raw['userColors'] = {
        'a': {'argb': 0xFF3366CC, 'user': false},
        'b': {'argb': 'bad', 'user': true},
      };
      colorsFile().writeAsStringSync(jsonEncode(raw));
      expect(await TimetableStore.readUserCourseColors(), isEmpty);
    });

    test('局部/多周颜色与全局覆盖；同日他段保原色；UC05 跳过自选色', () async {
      await TimetableStore.saveSnapshot(
        TimetableSnapshot(
          courses: [_jw('a', '测试课甲'), _jw('b', '测试课乙', day: 2)],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        ),
      );
      c.debugSetSnapshot(
        await TimetableStore.readSnapshot() ?? const TimetableSnapshot(),
        viewingWeek: 7,
      );
      await c.editOccurrence(
        c.cellsForDay(7, 1).single,
        name: '测试课习题',
        note: '保留备注',
      );
      await c.setOccurrenceColor(c.cellsForDay(7, 1).single, 0xFF753AC5);
      expect(
        (await ScheduleStore.readCourseDateEdits()).single.color,
        0xFF753AC5,
      );
      await restart();
      expect(c.userColorOf(c.cellsForDay(7, 1).single.course), 0xFF753AC5);
      expect(c.userColorOf(c.cellsForDay(8, 1).single.course), isNull);

      await c.editOccurrenceWeeks(
        c.cellsForDay(7, 1).single,
        weeks: [7, 8],
        note: '多周备注',
      );
      await c.setOccurrenceColor(c.cellsForDay(8, 1).single, 0xFF386F95);
      expect(c.userColorOf(c.cellsForDay(8, 1).single.course), 0xFF386F95);
      await c.setOccurrenceColor(c.cellsForDay(8, 1).single, null);
      expect(c.userColorOf(c.cellsForDay(8, 1).single.course), isNull);
      expect(c.cellsForDay(8, 1).single.slot.note, '多周备注');

      await c.setUserCourseColor('a', 0xFF43856B);
      expect(c.courseDateEdits.every((e) => e.color == null), isTrue);
      // 同步重建配色表时自选色课程不占自动配色表槽位
      await sync([_jw('a', '测试课甲'), _jw('b', '测试课乙', day: 2)]);
      expect(c.courseColorMap.keys.any((k) => k.contains('甲')), isFalse);
      expect(c.courseColorMap.keys.any((k) => k.contains('乙')), isTrue);
    });

    test('同一天其他时段保持原色；手动自选色不写 assignedColorIndex', () async {
      await c.ensureStarted();
      await c.addManualCourse(_m('a', _a, start: 1, end: 2));
      await c.addManualCourse(_m('b', _j, start: 3, end: 4, colorIndex: 5));
      expect(c.colorIndexOf(c.manualCourseById('b')!), 5);
      expect(c.manualCourseById('b')!.assignedColorIndex, isNull);
      await c.moveSlot(
        byId('b'),
        0,
        toDay: 5,
        toStartPeriod: 1,
        week: 1,
        scope: MoveScope.fromThisWeek,
      );
      await restart();
      expect(c.colorIndexOf(c.manualCourseById('b')!), 5);

      final twoSlot = _jw('s', '双节测试课').copyWith(
        slots: [
          ..._jw('s', '双节测试课').slots,
          const CourseSlot(
            day: 1,
            startNode: 5,
            endNode: 6,
            weeks: '11111111111111111111',
          ),
        ],
      );
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: [twoSlot],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(termStartDate: DateTime(2026, 8, 31)),
        ),
        viewingWeek: 7,
      );
      await c.setOccurrenceColor(c.cellsForDay(7, 1).first, 0xFF386F95);
      expect(c.userColorOf(c.cellsForDay(7, 1).first.course), 0xFF386F95);
      expect(c.userColorOf(c.cellsForDay(7, 1).last.course), isNull);
    });

    test('最近自定义存储去重插前，最多 6 条', () async {
      expect(await TimetableStore.readRecentCustomColors(), isEmpty);
      await TimetableStore.pushRecentCustomColor(0xFF112233);
      await TimetableStore.pushRecentCustomColor(0xFF445566);
      await TimetableStore.pushRecentCustomColor(0xFF112233);
      expect(await TimetableStore.readRecentCustomColors(), [
        0xFF112233,
        0xFF445566,
      ]);
      for (var i = 0; i < 8; i++) {
        await TimetableStore.pushRecentCustomColor(0xFF000000 | (i + 1));
      }
      final recent = await TimetableStore.readRecentCustomColors();
      expect(recent, hasLength(6));
      expect(recent.first, 0xFF000008);
    });
  });
}
