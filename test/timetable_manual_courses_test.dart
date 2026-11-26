import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/refresh/silent_refresh.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_manual_course_form.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

Course _jwxt(String id, {String weeks = '1111111111111111'}) => Course(
  id: id,
  name: 'JWXT $id',
  source: CourseSource.jwxt,
  slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
);

Course _manual(String name, {String weeks = '11111111'}) => Course(
  id: '',
  name: name,
  slots: [CourseSlot(day: 3, startNode: 5, endNode: 6, weeks: weeks)],
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_manual');
    TimetableStore.debugDirectory = tmp;
    c.debugReset();
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_jwxt('j1'), _jwxt('j2')],
          settings: baseSettings ?? const TimetableSettings(),
        );
    await c.ensureStarted();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('isManual flag', () {
    expect(_manual('x').isManual, isTrue);
    expect(_jwxt('j').isManual, isFalse);
  });

  test('坏手动课程只汇总一次诊断，保留正常条目且不记录课程正文', () async {
    final file = File('${tmp.path}/manual_courses.json');
    await file.writeAsString(
      jsonEncode({
        'courses': [
          _manual('正常合成课程').toJson(),
          {'name': '不可写入日志的合成课程', 'credit': 'invalid'},
          'invalid-entry',
        ],
      }),
    );
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    late List<Course> courses;
    await SilentRefresh.run(
      'test.manual_courses',
      action: () async {
        courses = await TimetableStore.readManualCourses();
      },
    );
    expect(courses.map((course) => course.name), ['正常合成课程']);
    final degraded = records.singleWhere(
      (record) => record['event'] == 'manual_courses.read_degraded',
    );
    final attrs = degraded['attrs'] as Map;
    expect(attrs['file_kind'], 'manual_courses.json');
    expect(attrs['skipped_count'], 2);
    expect(attrs['error_type'], isNotNull);
    expect(attrs['stack_trace'], isNotEmpty);
    expect((records.last['attrs'] as Map)['outcome'], 'degraded');
    expect(jsonEncode(records), isNot(contains('不可写入日志的合成课程')));
  });

  test('CRUD on manual courses', () async {
    final a = await c.addManualCourse(_manual('自习'));
    expect(a.id, isNotEmpty);
    expect(a.isManual, isTrue);
    expect(c.manualCourses, hasLength(1));
    expect(c.combinedCourses.map((e) => e.name), contains('自习'));

    final upd = await c.updateManualCourse(a.copyWith(name: '自习2'));
    expect(upd.name, '自习2');
    expect(c.manualCourseById(a.id)!.name, '自习2');

    expect(await c.deleteManualCourse(a.id), isTrue);
    expect(c.manualCourses, isEmpty);
    expect(await c.deleteManualCourse(a.id), isFalse);
  });

  test('JWXT courses are read-only via manual API', () async {
    await c.syncFromJwxt();
    expect(c.jwxtCourses, hasLength(2));
    expect(
      () => c.updateManualCourse(_jwxt('j1').copyWith(name: 'hack')),
      throwsStateError,
    );
    expect(await c.deleteManualCourse('j1'), isFalse);
    expect(c.jwxtCourses, hasLength(2));
    // 新增时 source 被强制为 manual，且 id 不与教务冲突
    final added = await c.addManualCourse(_jwxt('j1'));
    expect(added.isManual, isTrue);
    expect(added.id, isNot('j1'));
  });

  test(
    'sync preserves manual courses and drops manual from JWXT payload',
    () async {
      await c.addManualCourse(_manual('社团'));
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [_jwxt('j9'), _manual('stray')],
            settings: baseSettings ?? const TimetableSettings(),
          );
      await c.syncFromJwxt();
      expect(c.jwxtCourses.map((e) => e.id), ['j9']);
      expect(c.manualCourses.map((e) => e.name), ['社团']);
      expect(c.combinedCourses, hasLength(2));
      // 再同步一次仍保留
      await c.syncFromJwxt();
      expect(c.manualCourses.map((e) => e.name), ['社团']);
    },
  );

  test('logout clears JWXT by default, keeps manual', () async {
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        TimetableSnapshot(
          courses: [_jwxt('j1'), _jwxt('j2')],
          settings: (baseSettings ?? const TimetableSettings()).copyWith(
            termCode: '2026-2027-1',
            termStartDate: DateTime(2026, 9, 7),
            termStartFromJwxt: true,
            maxWeeks: 25,
          ),
        );
    await c.updateSettings(
      const TimetableSettings(
        periodHeight: 72,
        showSaturday: false,
        showSunday: false,
        showNonCurrentWeek: true,
      ),
    );
    await c.syncFromJwxt();
    await c.addManualCourse(_manual('健身'));
    expect(File('${tmp.path}/snapshot.json').existsSync(), isTrue);
    expect(c.settings.termStartFromJwxt, isTrue);
    expect(c.settings.termCode, '2026-2027-1');
    expect(c.settings.maxWeeks, 25);

    await c.handleLogout();
    expect(c.portalBound, isFalse);
    expect(c.manualCourses, hasLength(1));
    expect(c.jwxtCourses, isEmpty);
    expect(c.settings.termStartFromJwxt, isFalse);
    expect(c.settings.termCode, isEmpty);
    expect(c.settings.maxWeeks, 30);
    expect(File('${tmp.path}/snapshot.json').existsSync(), isFalse);
    expect(File('${tmp.path}/manual_courses.json').existsSync(), isTrue);
    expect(File('${tmp.path}/settings.json').existsSync(), isTrue);

    // 重新读盘：教务空、手动在；展示设置保留；开学日可被内置 08-31 回填
    c.debugReset();
    await c.ensureStarted();
    expect(c.manualCourses.map((e) => e.name), ['健身']);
    expect(c.jwxtCourses, isEmpty);
    expect(c.settings.termStartFromJwxt, isFalse);
    expect(c.settings.periodHeight, 72);
    expect(c.settings.showSaturday, isFalse);
    expect(c.settings.showSunday, isFalse);
    expect(c.settings.showNonCurrentWeek, isTrue);
    expect(c.settings.termStartDate, DateTime(2026, 8, 31));

    // clearJwxt:false 时教务与手动都保留
    await c.syncFromJwxt();
    expect(c.jwxtCourses, hasLength(2));
    expect(File('${tmp.path}/snapshot.json').existsSync(), isTrue);
    await c.handleLogout(clearJwxt: false);
    expect(c.portalBound, isFalse);
    expect(c.jwxtCourses, hasLength(2));
    expect(c.manualCourses, hasLength(1));
    expect(File('${tmp.path}/snapshot.json').existsSync(), isTrue);
  });

  test('persistence reload', () async {
    await c.syncFromJwxt();
    final a = await c.addManualCourse(_manual('A'));
    await c.addManualCourse(_manual('B'));
    await c.updateManualCourse(a.copyWith(name: 'A2', colorIndex: 3));
    expect(File('${tmp.path}/manual_courses.json').existsSync(), isTrue);

    c.debugReset();
    expect(c.manualCourses, isEmpty);
    await c.ensureStarted();
    expect(c.manualCourses.map((e) => e.name), ['A2', 'B']);
    expect(c.manualCourses.first.colorIndex, 3);
    expect(c.manualCourses.every((e) => e.isManual), isTrue);
    expect(c.jwxtCourses.map((e) => e.id), ['j1', 'j2']);
  });

  test('总周数固定 20，不随课程增删、同步或原始周次长度改变', () async {
    expect(c.totalWeeks, 20);
    // 30 位位串但最后有课在第 16 周，仍可浏览后面的空周。
    await c.addManualCourse(_manual('m', weeks: '${'1' * 16}${'0' * 14}'));
    expect(c.totalWeeks, 20);
    // 全 0 周次不影响浏览范围。
    await c.addManualCourse(_manual('none', weeks: '0' * 30));
    expect(c.totalWeeks, 20);
    await c.syncFromJwxt();
    expect(c.totalWeeks, 20);
    final late = await c.addManualCourse(
      _manual('late', weeks: '${'0' * 21}1${'0' * 8}'),
    );
    expect(c.totalWeeks, 20);
    expect(late.hasClassInWeek(22), isTrue);
    expect(await c.deleteManualCourse(late.id), isTrue);
    expect(c.totalWeeks, 20);
  });

  test('手动课程冲突提示文案基于 controller.conflictsFor', () {
    CourseSlot slot(String weeks, {int day = 1, int start = 1, int end = 2}) =>
        CourseSlot(day: day, startNode: start, endNode: end, weeks: weeks);
    final courses = [
      Course(
        id: 'A',
        name: 'A',
        source: CourseSource.jwxt,
        slots: [slot('1010101010')],
      ),
      Course(
        id: 'B',
        name: 'B',
        source: CourseSource.jwxt,
        slots: [slot('1111111111', day: 2)],
      ),
      Course(
        id: 'C',
        name: 'C',
        source: CourseSource.jwxt,
        slots: [slot('1111111111', start: 3, end: 4)],
      ),
    ];
    c.debugSetSnapshot(
      TimetableSnapshot(
        courses: courses,
        periods: TimetableController.defaultPeriods(),
        settings: TimetableSettings(termStartDate: DateTime(2026, 9, 7)),
      ),
      viewingWeek: 1,
    );
    final even = slot('0101010101', start: 2, end: 3);
    final evenHits = c.conflictsFor(even);
    expect(evenHits.map((e) => e.name), ['C']);
    expect(describeManualConflicts(even, evenHits), '与「C」第 2–10 周（双）冲突');

    final first5 = slot('1111100000', start: 2, end: 3);
    final both = c.conflictsFor(first5);
    expect(both.map((e) => e.name), ['A', 'C']);
    expect(describeManualConflicts(first5, both), '与 2 门课冲突');
    expect(
      describeManualConflicts(first5, [courses.first]),
      '与「A」第 1–5 周（单）冲突',
    );

    final self = slot('1' * 20, start: 3, end: 3);
    expect(c.conflictsFor(self, excludeId: 'C'), isEmpty);
    expect(
      describeManualConflicts(self, c.conflictsFor(self, excludeId: 'C')),
      isNull,
    );
  });

  group('splitFrom 拆分虚影与持久化', () {
    const w16 = '1111111111111111';
    const week = 7;
    const orig = SlotRef(day: 1, startNode: 1, endNode: 2);
    final origClock = TimetableController.clock;
    final splitSettings = TimetableSettings(
      termCode: '2026-2027-1',
      termStartDate: DateTime(2026, 8, 31),
      termStartFromJwxt: true,
      showNonCurrentWeek: true,
    );

    Course manualCourse(String id, String name, {String weeks = w16}) => Course(
      id: id,
      name: name,
      slots: [CourseSlot(day: 1, startNode: 1, endNode: 2, weeks: weeks)],
    );

    File manualFile() => File('${tmp.path}/manual_courses.json');

    void loadSplit(List<Course> manual) => c.debugSetSnapshot(
      TimetableSnapshot(
        settings: splitSettings,
        periods: TimetableController.defaultPeriods(),
      ),
      viewingWeek: week,
      manualCourses: manual,
    );

    Future<MoveResult> move(
      String id,
      int slotIndex, {
      required int toDay,
      required int toStart,
      int targetWeek = week,
      MoveScope scope = MoveScope.thisWeek,
    }) => c.moveSlot(
      c.manualCourseById(id)!,
      slotIndex,
      toDay: toDay,
      toStartPeriod: toStart,
      week: targetWeek,
      scope: scope,
    );

    List<(int, bool)> cells(int targetWeek, int day) => [
      for (final g in c.cellsForDay(targetWeek, day))
        (g.slot.startNode, g.activeThisWeek),
    ];

    setUp(() {
      TimetableController.clock = () => DateTime(2026, 10, 12);
    });

    tearDown(() {
      TimetableController.clock = origClock;
    });

    test('V05h 只改本周：本周原位置无虚影，其他周照常；拆出时段他周为灰格', () async {
      loadSplit([manualCourse('m1', '甲课程')]);
      final r = await move('m1', 0, toDay: 3, toStart: 9);
      expect(r.status, MoveStatus.moved);
      final slots = c.manualCourseById('m1')!.slots;
      expect(slots.length, 2);
      expect(slots[0].splitFrom, isNull);
      expect(slots[1].splitFrom, orig);
      expect(cells(week, 1), isEmpty);
      expect(cells(week, 3), [(9, true)]);
      expect(cells(8, 1), [(1, true)]);
      expect(cells(8, 3), isEmpty);
      await c.updateSettings(c.settings.copyWith(showNonCurrentWeek: false));
      expect(cells(week, 1), isEmpty);
      expect(cells(8, 3), isEmpty);
    });

    test('V05h 改以后所有周：移走的各周原位置无虚影，之前的周照常', () async {
      loadSplit([manualCourse('m1', '甲课程')]);
      await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
      final slots = c.manualCourseById('m1')!.slots;
      expect(slots.length, 2);
      expect(slots[1].splitFrom, orig);
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
      loadSplit([manualCourse('m1', '乙课程', weeks: '10' * 8)]);
      await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
      expect(cells(week, 1), isEmpty);
      expect(cells(week, 3), [(9, true)]);
      expect(cells(8, 1), isEmpty);
      expect(cells(8, 3), [(9, false)]);
      expect(cells(5, 1), [(1, true)]);
      expect(cells(5, 3), [(9, false)]);
    });

    test('拆出的时段再拆：沿 splitFrom 链，原位置与中间位置本周都无虚影', () async {
      loadSplit([manualCourse('m1', '甲课程')]);
      await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
      await move('m1', 1, toDay: 5, toStart: 3, targetWeek: 9);
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
      expect(cells(10, 5), isEmpty);
    });

    test('V05j 拖回原位置：并回原时段，无重复格、无虚影', () async {
      loadSplit([manualCourse('m1', '甲课程')]);
      final before = c.colorIndexOf(c.manualCourseById('m1')!);
      await move('m1', 0, toDay: 3, toStart: 9);
      final r = await move('m1', 1, toDay: 1, toStart: 1);
      expect(r.status, MoveStatus.moved);
      final slots = c.manualCourseById('m1')!.slots;
      expect(slots.length, 1);
      expect(slots.single.weeks, w16);
      expect(slots.single.splitFrom, isNull);
      for (final w in [1, week, 8]) {
        expect(cells(w, 1), [(1, true)]);
        expect(cells(w, 3), isEmpty);
      }
      expect(c.colorIndexOf(c.manualCourseById('m1')!), before);
    });

    test('V05j 改以后所有周再整段拖回：合并成一个时段', () async {
      loadSplit([manualCourse('m1', '甲课程')]);
      await move('m1', 0, toDay: 3, toStart: 9, scope: MoveScope.fromThisWeek);
      await move('m1', 1, toDay: 1, toStart: 1, scope: MoveScope.fromThisWeek);
      final slots = c.manualCourseById('m1')!.slots;
      expect(slots.length, 1);
      expect(slots.single.weeks, w16);
      expect(cells(week, 1), [(1, true)]);
      expect(cells(week, 3), isEmpty);
    });

    test('V05j 删课：所有周都不留格子/虚影', () async {
      loadSplit([manualCourse('m1', '甲课程')]);
      await move('m1', 0, toDay: 3, toStart: 9);
      expect(await c.deleteManualCourse('m1'), isTrue);
      for (var w = 1; w <= 16; w++) {
        for (var d = 1; d <= 7; d++) {
          expect(c.cellsForDay(w, d), isEmpty);
        }
      }
    });

    test('V05k splitFrom 落盘并在重启后保留，虚影规则仍生效', () async {
      loadSplit([]);
      await TimetableStore.saveSettings(splitSettings);
      await c.addManualCourse(manualCourse('m1', '甲课程'));
      final colour = c.colorIndexOf(c.manualCourseById('m1')!);
      await move('m1', 0, toDay: 3, toStart: 9);
      final raw = jsonDecode(manualFile().readAsStringSync()) as Map;
      final slotsJson =
          ((raw['courses'] as List).single as Map)['slots'] as List;
      expect((slotsJson[0] as Map).containsKey('splitFrom'), isFalse);
      expect((slotsJson[1] as Map)['splitFrom'], {
        'day': 1,
        'startNode': 1,
        'endNode': 2,
      });
      c.debugReset();
      await c.ensureStarted();
      expect(c.settings.showNonCurrentWeek, isTrue);
      expect(c.manualCourseById('m1')!.slots[1].splitFrom, orig);
      expect(cells(week, 1), isEmpty);
      expect(cells(8, 3), isEmpty);
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
                  'weeks': w16,
                  'splitFrom': 'garbage',
                },
              ],
            },
          ],
        }),
      );
      c.debugReset();
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
      loadSplit([]);
      await c.addManualCourse(manualCourse('m1', '甲课程'));
      await c.addManualCourse(
        Course(
          id: 'm2',
          name: '乙课程',
          slots: const [
            CourseSlot(day: 2, startNode: 1, endNode: 2, weeks: w16),
          ],
        ),
      );
      final before = {for (final x in c.courses) x.id: c.colorIndexOf(x)};
      await move('m1', 0, toDay: 3, toStart: 9);
      expect({for (final x in c.courses) x.id: c.colorIndexOf(x)}, before);
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
      expect(edited.slots[1].splitFrom, orig);
      expect(cells(week, 1), isEmpty);
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
      expect(cells(week, 1), [(1, false)]);
      expect({for (final x in c.courses) x.id: c.colorIndexOf(x)}, before);
    });
  });
}
