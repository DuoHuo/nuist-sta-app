// 教务课调课（覆盖记录）不改任何课颜色：教务课的近色顺延相邻关系只按教务原始位置算，
// 完全忽略调课记录（产品/设计 10/18）。全部为构造数据，不读真实样例。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

const _w16 = '1111111111111111';
const _week = 7; // 2026-10-12 = 第 7 周（开学 08-31）

// 两门课哈希色号相同（12）：相邻时课名排序靠后的「数据结构」顺延
// （与「数字电路 / 数字逻辑」现场问题同型）。
const _a = '学术英语（1）';
const _b = '数据结构';

Course _j(String id, String name, {int day = 1, int start = 1, int end = 2}) =>
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
  final origClock = TimetableController.clock;
  final settings = TimetableSettings(
    termCode: '2026-2027-1',
    termStartDate: DateTime(2026, 8, 31),
    termStartFromJwxt: true,
  );

  TimetableSnapshot snapshotOf(List<Course> jwxt) => TimetableSnapshot(
    courses: jwxt,
    settings: settings,
    periods: TimetableController.defaultPeriods(),
  );

  void load(List<Course> jwxt) =>
      c.debugSetSnapshot(snapshotOf(jwxt), viewingWeek: _week);

  /// 教务课 id → 色号。
  Map<String, int> colours() => {
    for (final x in c.courses)
      if (x.source == CourseSource.jwxt) x.id: c.colorIndexOf(x),
  };

  Course byId(String id) => c.courses.firstWhere((x) => x.id == id);

  Future<void> move(
    String id,
    MoveScope scope, {
    required int toDay,
    required int toStart,
  }) async {
    final r = await c.moveSlot(
      byId(id),
      0,
      toDay: toDay,
      toStartPeriod: toStart,
      week: _week,
      scope: scope,
    );
    expect(r.status, MoveStatus.moved);
  }

  /// 触发全量重算（增一门不挨着任何课的手动课）。
  Future<void> recompute() => c.addManualCourse(
    Course(
      id: 'x',
      name: '体育',
      slots: [CourseSlot(day: 7, startNode: 11, endNode: 12, weeks: _w16)],
    ),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_color_ovr');
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

  for (final scope in MoveScope.values) {
    group('教务课 ${scope.name}', () {
      test('把 A 移走：原本因相邻顺延的 B 保持顺延色，其余课不变', () async {
        load([
          _j('A', _a),
          _j('B', _b, start: 3, end: 4),
          _j('C', '大学物理', day: 2),
        ]);
        final before = colours();
        expect(before['A'], 12);
        expect(before['B'], isNot(12)); // 前提：相邻而顺延
        await move('A', scope, toDay: 5, toStart: 7);
        expect(colours(), before);
        await recompute(); // 增删课全量重算也只看教务原始位置
        expect(colours(), before);
      });

      test('把 B 移到 A 旁边：B 保持原色（不因新位置相邻而顺延）', () async {
        load([_j('A', _a), _j('B', _b, day: 4, start: 7, end: 8)]);
        final before = colours();
        expect(before, {'A': 12, 'B': 12}); // 前提：原本不相邻
        await move('B', scope, toDay: 1, toStart: 3);
        expect(colours(), before);
        await recompute();
        expect(colours(), before);
      });

      test('恢复原位置不改颜色', () async {
        load([_j('A', _a), _j('B', _b, start: 3, end: 4)]);
        final before = colours();
        await move('A', scope, toDay: 5, toStart: 7);
        expect(await c.restoreOverride(byId('A'), 0), isTrue);
        expect(c.slotOverrides, isEmpty);
        expect(colours(), before);
        await recompute();
        expect(colours(), before);
      });

      test('模拟重启（同一份落盘数据重建控制器）颜色不变', () async {
        final jwxt = [
          _j('A', _a),
          _j('B', _b, day: 4, start: 7, end: 8),
          _j('C', '大学物理', day: 2),
        ];
        await TimetableStore.saveSnapshot(snapshotOf(jwxt));
        load(jwxt);
        final before = colours();
        expect(before['B'], 12);
        await move('B', scope, toDay: 1, toStart: 3); // 移到 A 旁边
        await move('C', scope, toDay: 5, toStart: 1);
        final afterMove = colours();
        expect(afterMove, before);
        c.debugReset();
        await c.ensureStarted();
        expect(c.slotOverrides, hasLength(2));
        expect(colours(), before);
        // 再重启一次，结果相同（确定性）。
        c.debugReset();
        await c.ensureStarted();
        expect(colours(), before);
      });
    });
  }
}
