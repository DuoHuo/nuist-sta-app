import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

const _w16 = '1111111111111111';

Course _jwxt(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = _w16,
}) => Course(
  id: id,
  name: name,
  code: id,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      weeksLabel: '1-16周',
      teacher: '教师N',
    ),
  ],
);

Course _manual(String id, String name, {String weeks = '11111111'}) => Course(
  id: id,
  name: name,
  colorIndex: 3,
  slots: [
    CourseSlot(day: 3, startNode: 5, endNode: 6, weeks: weeks, teacher: '教师O'),
  ],
);

List<int> _weeks(CourseSlot s) => weeksOf(s);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  final settings = TimetableSettings(
    termCode: '2026-2027-1',
    termStartDate: DateTime(2026, 8, 31),
    termStartFromJwxt: true,
  );
  final origFetch = TimetableController.fetchSnapshot;
  final origClock = TimetableController.clock;

  File file(String name) => File('${tmp.path}/$name');

  void load({List<Course>? jwxt, List<Course> manual = const []}) {
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: jwxt ?? [_jwxt('K1|01', '高数')],
        settings: settings,
        periods: TimetableController.defaultPeriods(),
      ),
      manualCourses: manual,
    );
  }

  Course jwxtEff(String id) => c.courses.firstWhere((x) => x.id == id);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_drag');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => DateTime(2026, 10, 12);
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.fetchSnapshot = origFetch;
    TimetableController.clock = origClock;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('手动课', () {
    test('只改本周：新时段恰好 {w}，原时段恰好少了 w', () async {
      load(manual: [_manual('m1', '自选课')]);
      final course = c.manualCourses.single;
      final r = await c.moveSlot(
        course,
        0,
        toDay: 2,
        toStartPeriod: 3,
        week: 3,
        scope: MoveScope.thisWeek,
      );
      expect(r.status, MoveStatus.moved);
      expect(r.affectedWeeks, [3]);
      final saved = c.manualCourses.single;
      expect(c.manualCourses, hasLength(1)); // 不新建课程
      expect(saved.slots, hasLength(2));
      expect(_weeks(saved.slots[0]), [1, 2, 4, 5, 6, 7, 8]);
      expect(saved.slots[0].day, 3);
      expect(_weeks(saved.slots[1]), [3]);
      expect(
        (saved.slots[1].day, saved.slots[1].startNode, saved.slots[1].endNode),
        (2, 3, 4),
      );
      expect(saved.slots[1].teacher, '教师O');
      expect(saved.colorIndex, 3);
      final disk = await TimetableStore.readManualCourses();
      expect(_weeks(disk.single.slots[1]), [3]);
    });

    test('改以后所有周：w 之前留原位，w 及以后到新时段', () async {
      load(manual: [_manual('m1', '自选课')]);
      final r = await c.moveSlot(
        c.manualCourses.single,
        0,
        toDay: 4,
        toStartPeriod: 1,
        week: 5,
        scope: MoveScope.fromThisWeek,
      );
      expect(r.affectedWeeks, [5, 6, 7, 8]);
      final s = c.manualCourses.single.slots;
      expect(_weeks(s[0]), [1, 2, 3, 4]);
      expect(_weeks(s[1]), [5, 6, 7, 8]);
    });

    test('只移原时段实际有的周（单周课）', () async {
      load(manual: [_manual('m1', '单周课', weeks: '10101010')]);
      await c.moveSlot(
        c.manualCourses.single,
        0,
        toDay: 4,
        toStartPeriod: 1,
        week: 3,
        scope: MoveScope.fromThisWeek,
      );
      final s = c.manualCourses.single.slots;
      expect(_weeks(s[0]), [1]);
      expect(_weeks(s[1]), [3, 5, 7]);
    });

    test('原时段周次变空就删掉', () async {
      load(manual: [_manual('m1', '自选课')]);
      await c.moveSlot(
        c.manualCourses.single,
        0,
        toDay: 4,
        toStartPeriod: 1,
        week: 1,
        scope: MoveScope.fromThisWeek,
      );
      final s = c.manualCourses.single.slots;
      expect(s, hasLength(1));
      expect(s.single.day, 4);
      expect(_weeks(s.single), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('落回原位：noChange，不写盘', () async {
      load(manual: [_manual('m1', '自选课')]);
      final r = await c.moveSlot(
        c.manualCourses.single,
        0,
        toDay: 3,
        toStartPeriod: 5,
        week: 2,
        scope: MoveScope.thisWeek,
      );
      expect(r.status, MoveStatus.noChange);
      expect(file('manual_courses.json').existsSync(), isFalse);
      expect(file('overrides.json').existsSync(), isFalse);
    });

    test('越界与非法输入', () async {
      load(manual: [_manual('m1', '自选课')]);
      final course = c.manualCourses.single;
      Future<MoveResult> mv(int day, int start, int week, [int idx = 0]) =>
          c.moveSlot(
            course,
            idx,
            toDay: day,
            toStartPeriod: start,
            week: week,
            scope: MoveScope.thisWeek,
          );
      expect(
        (await mv(1, 11, 1)).error,
        MoveError.pastLastPeriod,
      ); // 11-12 > 11
      expect((await mv(1, 10, 1)).status, MoveStatus.moved); // 10-11 ok
      expect((await mv(8, 1, 2)).error, MoveError.invalidTarget);
      expect((await mv(1, 0, 2)).error, MoveError.invalidTarget);
      expect((await mv(1, 1, 12)).error, MoveError.notInWeek);
      expect((await mv(1, 1, 2, 5)).error, MoveError.invalidSlot);
    });
  });

  group('教务课覆盖记录', () {
    Future<MoveResult> moveJ(
      int idx,
      int day,
      int start,
      int week,
      MoveScope scope,
    ) => c.moveSlot(
      jwxtEff('K1|01'),
      idx,
      toDay: day,
      toStartPeriod: start,
      week: week,
      scope: scope,
    );

    test('只改本周：不改教务数据，展示为两段，记录落盘', () async {
      load();
      final r = await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
      expect(r.ok, isTrue);
      expect(c.jwxtCourses.single.slots.single.weeks, _w16); // 原数据未动
      final eff = jwxtEff('K1|01');
      expect(eff.slots, hasLength(2));
      expect(_weeks(eff.slots[0]), [
        for (var w = 1; w <= 16; w++)
          if (w != 6) w,
      ]);
      expect(_weeks(eff.slots[1]), [6]);
      expect(eff.slots[1].day, 3);
      expect(eff.slots[1].teacher, '教师N');
      expect(c.overrideInfoFor(eff, 1)?.originalDay, 1);
      expect(c.overrideInfoFor(eff, 1)?.originalStart, 1);
      expect(c.overrideInfoFor(eff, 1)?.originalEnd, 2);
      expect(c.overrideInfoFor(eff, 0), isNull);
      expect(c.hasOverride(eff, 1), isTrue);
      final json = jsonDecode(file('overrides.json').readAsStringSync()) as Map;
      final rec = (json['overrides'] as List).single as Map;
      expect(rec['courseId'], 'K1|01');
      expect(rec['origDay'], 1);
      expect(rec['origWeeks'], _w16);
      expect(rec['weeks'], [6]);
      expect(rec['scope'], 'thisWeek');
      expect([rec['toDay'], rec['toStart'], rec['toEnd']], [3, 5, 6]);
      // 周视图：第 6 周周三有、周一没有；第 7 周周一有
      expect(c.cellsForDay(6, 3).where((x) => x.activeThisWeek), hasLength(1));
      expect(c.cellsForDay(6, 1).where((x) => x.activeThisWeek), isEmpty);
      expect(c.cellsForDay(7, 1).where((x) => x.activeThisWeek), hasLength(1));
      expect(c.totalWeeks, 16);
    });

    test('再拖回原位：记录合并消失', () async {
      load();
      await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
      final r = await moveJ(1, 1, 1, 6, MoveScope.thisWeek);
      expect(r.ok, isTrue);
      expect(c.slotOverrides, isEmpty);
      expect(jwxtEff('K1|01').slots.single.weeks, _w16);
    });

    test('多次移动后恢复原位置一次清掉全部记录', () async {
      load();
      await moveJ(0, 3, 5, 10, MoveScope.fromThisWeek);
      var eff = jwxtEff('K1|01');
      expect(_weeks(eff.slots[1]), [10, 11, 12, 13, 14, 15, 16]);
      await moveJ(1, 5, 7, 12, MoveScope.thisWeek); // 再拖已调过的时段
      eff = jwxtEff('K1|01');
      expect(eff.slots, hasLength(3));
      expect(_weeks(eff.slots[2]), [12]);
      expect(c.overrideInfoFor(eff, 2)?.originalDay, 1); // 仍指向教务原时段
      expect(await c.restoreOverride(eff, 2), isTrue);
      expect(c.slotOverrides, isEmpty);
      expect(jwxtEff('K1|01').slots.single.weeks, _w16);
      expect(await c.restoreOverride(jwxtEff('K1|01'), 0), isFalse);
    });

    test('同步后重新套用；原课改时间 → 删记录，显示教务新数据', () async {
      load();
      await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
      var remote = [_jwxt('K1|01', '高数')];
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(courses: remote, settings: settings);
      await c.syncFromJwxt();
      expect(c.slotOverrides, hasLength(1));
      expect(jwxtEff('K1|01').slots, hasLength(2));

      remote = [_jwxt('K1|01', '高数', day: 2)];
      await c.syncFromJwxt();
      expect(c.slotOverrides, isEmpty);
      expect(jwxtEff('K1|01').slots.single.day, 2);
      final json = jsonDecode(file('overrides.json').readAsStringSync()) as Map;
      expect(json['overrides'], isEmpty);
    });

    test('解绑保留记录，重新绑定同步后再套用', () async {
      load();
      await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
      await c.handleLogout();
      expect(c.jwxtCourses, isEmpty);
      expect(c.slotOverrides, hasLength(1));
      expect(c.orphanedOverrideIds, hasLength(1)); // 暂不生效，但不删
      expect(file('overrides.json').existsSync(), isTrue);

      c.debugReset();
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_jwxt('K1|01', '高数')],
            settings: settings,
          );
      await c.ensureStarted();
      expect(c.slotOverrides, hasLength(1));
      await c.syncFromJwxt();
      expect(c.slotOverrides, hasLength(1));
      expect(_weeks(jwxtEff('K1|01').slots[1]), [6]);
    });

    test('冲突：本周只查 w；以后所有周查全部周，课名排序', () async {
      load(
        jwxt: [
          _jwxt('K1|01', '高数'),
          _jwxt('K2|01', '物理', day: 3, start: 5, end: 6, weeks: '0000001'),
          _jwxt('K3|01', '化学', day: 3, start: 6, end: 7, weeks: '0000000001'),
        ],
      );
      var r = await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
      expect(r.conflictNames, isEmpty);
      expect(r.conflictMessage, isNull);
      await c.restoreOverride(jwxtEff('K1|01'), 1);

      r = await moveJ(0, 3, 5, 7, MoveScope.thisWeek);
      expect(r.conflictNames, ['物理']);
      expect(r.conflictMessage, '与物理时间冲突');
      await c.restoreOverride(jwxtEff('K1|01'), 1);

      r = await moveJ(0, 3, 5, 6, MoveScope.fromThisWeek);
      final sorted = ['化学', '物理']..sort();
      expect(r.conflictNames, sorted);
      expect(r.conflictCount, 2);
      expect(r.conflictMessage, '与${sorted.first}等 2 门课时间冲突');
    });

    test('overrides.json 合并写：未知键和解析不了的条目保留', () async {
      file('overrides.json').writeAsStringSync(
        jsonEncode({
          'futureKey': {'a': 1},
          'overrides': [
            {'garbage': true},
          ],
        }),
      );
      await c.ensureStarted();
      load();
      await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
      final json = jsonDecode(file('overrides.json').readAsStringSync()) as Map;
      expect(json['futureKey'], {'a': 1});
      expect(json['schemaVersion'], 1);
      final list = json['overrides'] as List;
      expect(list, hasLength(2));
      expect(list.any((e) => e is Map && e['garbage'] == true), isTrue);
    });

    test('记录未知字段读写保留', () {
      final o = SlotOverride.tryParse({
        'id': 'x',
        'courseId': 'K',
        'origDay': 1,
        'origStart': 1,
        'origEnd': 2,
        'weeks': [3, 3, 'bad', 0],
        'toDay': 2,
        'toStart': 1,
        'toEnd': 2,
        'newField': 'keep',
      })!;
      expect(o.weeks, [3]);
      expect(o.toJson()['newField'], 'keep');
      expect(SlotOverride.tryParse({'id': 'x'}), isNull);
    });
  });

  group('同步失效规则（SKZC / 时段 / 课程存在）', () {
    Future<void> moveK1() async {
      final r = await c.moveSlot(
        jwxtEff('K1|01'),
        0,
        toDay: 3,
        toStartPeriod: 5,
        week: 6,
        scope: MoveScope.thisWeek,
      );
      expect(r.ok, isTrue);
      expect(c.slotOverrides, hasLength(1));
    }

    List<Course> remote = [];
    void useRemote() {
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(courses: remote, settings: settings);
    }

    List<dynamic> diskOverrides() =>
        (jsonDecode(file('overrides.json').readAsStringSync())
                as Map)['overrides']
            as List;

    test('SKZC 未变 → 保留记录并继续套用', () async {
      load();
      await moveK1();
      remote = [_jwxt('K1|01', '高数')];
      useRemote();
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expect(c.slotOverrides, hasLength(1));
      expect(c.orphanedOverrideIds, isEmpty);
      final eff = jwxtEff('K1|01');
      expect(eff.slots, hasLength(2));
      expect(_weeks(eff.slots[1]), [6]);
      expect(eff.slots[1].day, 3);
      expect(diskOverrides(), hasLength(1));
    });

    test('SKZC 变了（星期节次不变）→ 删记录，显示教务数据', () async {
      load();
      await moveK1();
      remote = [_jwxt('K1|01', '高数', weeks: '1111111111111100')];
      useRemote();
      await c.syncFromJwxt();
      expect(c.slotOverrides, isEmpty);
      final eff = jwxtEff('K1|01');
      expect(eff.slots, hasLength(1));
      expect(eff.slots.single.day, 1);
      expect(eff.slots.single.weeks, '1111111111111100');
      expect(c.hasOverride(eff, 0), isFalse);
      expect(diskOverrides(), isEmpty);
    });

    test('原课被删 → 删记录', () async {
      load(jwxt: [_jwxt('K1|01', '高数'), _jwxt('K2|01', '物理', day: 2)]);
      await moveK1();
      remote = [_jwxt('K2|01', '物理', day: 2)];
      useRemote();
      await c.syncFromJwxt();
      expect(c.slotOverrides, isEmpty);
      expect(c.courses.any((x) => x.id == 'K1|01'), isFalse);
      expect(diskOverrides(), isEmpty);
    });

    test('原时段时间变了（起止节）→ 删记录', () async {
      load();
      await moveK1();
      remote = [_jwxt('K1|01', '高数', start: 3, end: 4)];
      useRemote();
      await c.syncFromJwxt();
      expect(c.slotOverrides, isEmpty);
      final s = jwxtEff('K1|01').slots.single;
      expect((s.day, s.startNode, s.endNode), (1, 3, 4));
      expect(diskOverrides(), isEmpty);
    });

    test('只删失效的那条，其余记录保留', () async {
      load(jwxt: [_jwxt('K1|01', '高数'), _jwxt('K2|01', '物理', day: 2)]);
      await moveK1();
      await c.moveSlot(
        jwxtEff('K2|01'),
        0,
        toDay: 4,
        toStartPeriod: 7,
        week: 3,
        scope: MoveScope.fromThisWeek,
      );
      expect(c.slotOverrides, hasLength(2));
      remote = [
        _jwxt('K1|01', '高数', weeks: '1010101010101010'),
        _jwxt('K2|01', '物理', day: 2),
      ];
      useRemote();
      await c.syncFromJwxt();
      expect(c.slotOverrides.single.courseId, 'K2|01');
      expect(jwxtEff('K1|01').slots, hasLength(1));
      expect(jwxtEff('K2|01').slots, hasLength(2));
    });

    test('解绑不触发删除（即使原课已不在），同步成功才比较', () async {
      load();
      await moveK1();
      await c.handleLogout();
      expect(c.slotOverrides, hasLength(1));
      expect(c.orphanedOverrideIds, hasLength(1)); // 不渲染但保留
      expect(diskOverrides(), hasLength(1));
      // 同步失败也不删
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw Exception('network');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.slotOverrides, hasLength(1));
      expect(diskOverrides(), hasLength(1));
      // 重新绑定后 SKZC 变了 → 此时才删
      remote = [_jwxt('K1|01', '高数', weeks: '1111111100000000')];
      useRemote();
      await c.syncFromJwxt();
      expect(c.slotOverrides, isEmpty);
      expect(diskOverrides(), isEmpty);
    });

    test('手动课不受同步失效规则影响', () async {
      load(manual: [_manual('m1', '自选课')]);
      await c.moveSlot(
        c.manualCourses.single,
        0,
        toDay: 2,
        toStartPeriod: 3,
        week: 3,
        scope: MoveScope.thisWeek,
      );
      await moveK1();
      remote = []; // 教务课全没了
      useRemote();
      await c.syncFromJwxt();
      expect(c.slotOverrides, isEmpty); // 教务记录删了
      final m = c.manualCourses.single;
      expect(m.slots, hasLength(2)); // 手动课的拖动结果原样保留
      expect(_weeks(m.slots[1]), [3]);
      expect(m.slots[1].day, 2);
      expect(c.courses.any((x) => x.id == 'm1'), isTrue);
    });

    test('旧记录缺 origWeeks → 视为未知：不渲染，下次同步删除', () async {
      file('overrides.json').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'futureKey': 'keep',
          'overrides': [
            {
              'id': 'old-1',
              'courseId': 'K1|01',
              'origDay': 1,
              'origStart': 1,
              'origEnd': 2,
              'weeks': [6],
              'scope': 'thisWeek',
              'fromWeek': 6,
              'toDay': 3,
              'toStart': 5,
              'toEnd': 6,
              'createdAt': '2026-09-01T00:00:00.000',
            },
            {'garbage': true},
          ],
        }),
      );
      await c.ensureStarted();
      load();
      expect(c.slotOverrides.single.origWeeks, '');
      expect(c.orphanedOverrideIds, {'old-1'});
      expect(jwxtEff('K1|01').slots, hasLength(1)); // 不套到可能错误的位置
      remote = [_jwxt('K1|01', '高数')]; // 教务数据其实没变
      useRemote();
      await c.syncFromJwxt();
      expect(c.slotOverrides, isEmpty);
      final json = jsonDecode(file('overrides.json').readAsStringSync()) as Map;
      expect(json['futureKey'], 'keep'); // 未知键保留
      expect(json['overrides'], [
        {'garbage': true},
      ]); // 解析不了的条目保留
    });

    test('staleOverrideIds 纯函数', () {
      SlotOverride rec(String id, String cid, {String ow = _w16}) =>
          SlotOverride(
            id: id,
            courseId: cid,
            origDay: 1,
            origStart: 1,
            origEnd: 2,
            origWeeks: ow,
            weeks: const [6],
            scope: MoveScope.thisWeek,
            fromWeek: 6,
            toDay: 3,
            toStart: 5,
            toEnd: 6,
          );
      final jwxt = [_jwxt('K1|01', '高数'), _jwxt('K2|01', '物理', day: 2)];
      expect(
        staleOverrideIds(jwxt, [
          rec('keep', 'K1|01'),
          rec('gone', 'K9|01'),
          rec('skzc', 'K1|01', ow: '1111'),
          rec('slot', 'K2|01'), // K2 在周二，记录写的是周一
          rec('noow', 'K1|01', ow: ''),
        ]),
        {'gone', 'skzc', 'slot', 'noow'},
      );
      // 同 id 的手动课不算教务原课
      expect(staleOverrideIds([_manual('K1|01', '自选课')], [rec('m', 'K1|01')]), {
        'm',
      });
    });
  });

  test('scheduleChanged 在各类变动后触发', () async {
    final got = <ScheduleChangeReason>[];
    final sub = c.scheduleChanged.listen(got.add);
    load(manual: [_manual('m1', '自选课')]);
    await c.moveSlot(
      jwxtEff('K1|01'),
      0,
      toDay: 3,
      toStartPeriod: 1,
      week: 6,
      scope: MoveScope.thisWeek,
    );
    await c.restoreOverride(jwxtEff('K1|01'), 1);
    await c.addManualCourse(_manual('', '新课'));
    await c.deleteManualCourse('m1');
    await c.updateSettings(c.settings.copyWith(showTeacher: true));
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(courses: [_jwxt('K1|01', '高数')], settings: settings);
    await c.syncFromJwxt();
    await c.handleLogout();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(got, [
      ScheduleChangeReason.move,
      ScheduleChangeReason.restore,
      ScheduleChangeReason.manualCourse,
      ScheduleChangeReason.manualCourse,
      ScheduleChangeReason.settings,
      ScheduleChangeReason.sync,
      ScheduleChangeReason.unbind,
    ]);
  });

  test('noChange 不触发 scheduleChanged', () async {
    final got = <ScheduleChangeReason>[];
    final sub = c.scheduleChanged.listen(got.add);
    load();
    final r = await c.moveSlot(
      jwxtEff('K1|01'),
      0,
      toDay: 1,
      toStartPeriod: 1,
      week: 2,
      scope: MoveScope.fromThisWeek,
    );
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(r.status, MoveStatus.noChange);
    expect(got, isEmpty);
  });
}
