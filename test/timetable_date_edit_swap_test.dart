// 第 1 条（只改这一天）与第 8 条（整天调课）数据层。全部为虚构数据。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_date_edits.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

const _settings = TimetableSettings(termCode: '2026-2027-1');
final _termStart = DateTime(2026, 8, 31); // 周一，第 1 周
final _mon2 = DateTime(2026, 9, 7); // 第 2 周周一
final _tue2 = DateTime(2026, 9, 8);
final _wed2 = DateTime(2026, 9, 9);
final _thu2 = DateTime(2026, 9, 10);
final _mon3 = DateTime(2026, 9, 14);

Course _jwxt(String id, String name, {int day = 1, int start = 1}) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: start + 1,
      weeks: '1111111111111111',
      teacher: '虚构老师',
      location: '教一-101',
    ),
  ],
);

Course _manual(String id, String name) => Course(
  id: id,
  name: name,
  source: CourseSource.manual,
  slots: const [
    CourseSlot(
      day: 3,
      startNode: 5,
      endNode: 6,
      weeks: '1111111111111111',
      location: '图书馆',
    ),
  ],
);

TimetableSnapshot _snap(List<Course> courses) => TimetableSnapshot(
  courses: courses,
  periods: TimetableController.defaultPeriods(),
  settings: _settings.copyWith(
    termStartDate: _termStart,
    termStartFromJwxt: true,
  ),
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  List<Course> nextFetch = const [];
  final origFetchExams = TimetableController.fetchExams;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_date_edit');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => _mon2;
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        _snap(nextFetch);
    TimetableController.fetchExams = (term) async => null;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    TimetableController.fetchExams = origFetchExams;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  /// 教务「高数」周一 1–2、「英语」周二 3–4；手动「读书会」周三 5–6。
  Future<String> seed() async {
    nextFetch = [
      _jwxt('MATH|01', '高数'),
      _jwxt('ENG|01', '英语', day: 2, start: 3),
    ];
    await c.ensureStarted();
    final m = await c.addManualCourse(_manual('', '读书会'));
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
    return m.id;
  }

  int weekOf(DateTime d) => c.weekOfDate(d);

  List<GridCell> active(DateTime d) => [
    for (final x in c.cellsForDay(weekOf(d), d.weekday))
      if (x.activeThisWeek) x,
  ];

  GridCell cellOf(DateTime d, String id) =>
      active(d).firstWhere((x) => x.course.id == id);

  Map<String, dynamic> readJson(String name) =>
      jsonDecode(File('${tmp.path}/$name').readAsStringSync())
          as Map<String, dynamic>;

  group('第 1 条 只改这一天', () {
    test('教务课：只改这一天只影响那一天；落盘 version=2；重启仍在', () async {
      await seed();
      final cell = cellOf(_mon2, 'MATH|01');
      expect(cell.date, _mon2);
      final rec = await c.editOccurrence(
        cell,
        name: '高数习题课',
        location: '教二-202',
      );
      expect(rec, isNotNull);
      final now = cellOf(_mon2, 'MATH|01');
      expect(now.course.name, '高数习题课');
      expect(now.slot.location, '教二-202');
      expect(now.slot.teacher, '虚构老师');
      expect(now.dateEdit?.id, rec!.id);
      // 别的周不变。
      expect(cellOf(_mon3, 'MATH|01').course.name, '高数');
      expect(cellOf(_mon3, 'MATH|01').dateEdit, isNull);
      // 课程本身（所有周）不变。
      expect(c.courses.firstWhere((x) => x.id == 'MATH|01').name, '高数');
      final file = readJson(ScheduleStore.courseEditsFile);
      expect(file['version'], 2);
      expect((file['dateEdits'] as List).single['date'], '2026-09-07');
      await restart();
      expect(cellOf(_mon2, 'MATH|01').course.name, '高数习题课');
      expect(c.courseDateEdits, hasLength(1));
    });

    test('手动课同规则；删除只删这一天；恢复后回到原样', () async {
      final mid = await seed();
      final cell = cellOf(_wed2, mid);
      await c.editOccurrence(cell, teacher: '临时老师');
      expect(cellOf(_wed2, mid).slot.teacher, '临时老师');
      expect(c.manualCourseById(mid)!.slots.single.teacher, '');
      final del = await c.deleteOccurrence(cellOf(_wed2, mid));
      expect(del!.isDelete, isTrue);
      expect(active(_wed2).where((x) => x.course.id == mid), isEmpty);
      expect(active(_wed2.add(const Duration(days: 7))).single.course.id, mid);
      expect(await c.restoreDateEdit(del.id), isTrue);
      expect(cellOf(_wed2, mid).slot.teacher, '');
      expect(c.courseDateEdits, isEmpty);
    });

    test('只改这一天挪时间到同周别的天（表单改星期 / 节次）', () async {
      await seed();
      await c.editOccurrence(
        cellOf(_mon2, 'MATH|01'),
        toDay: 4,
        toStart: 7,
        toEnd: 8,
      );
      expect(active(_mon2).where((x) => x.course.id == 'MATH|01'), isEmpty);
      final moved = cellOf(_thu2, 'MATH|01');
      expect(moved.slot.day, 4);
      expect(moved.slot.startNode, 7);
      expect(moved.slot.endNode, 8);
      expect(moved.dateEdit, isNotNull);
      // 挪回原位：记录变空即删除。
      await c.editOccurrence(moved, toDay: 1, toStart: 1, toEnd: 2);
      expect(c.courseDateEdits, isEmpty);
      expect(cellOf(_mon2, 'MATH|01').dateEdit, isNull);
    });

    test(
      '旧 course_edits.json（无 version / 无 dateEdits）照旧读，写回保留 edits',
      () async {
        await seed();
        final fp = courseFingerprint(
          c.jwxtCourses.firstWhere((x) => x.id == 'MATH|01'),
        );
        File('${tmp.path}/${ScheduleStore.courseEditsFile}').writeAsStringSync(
          jsonEncode({
            'schemaVersion': 1,
            'edits': [
              {'courseId': 'MATH|01', 'origFingerprint': fp, 'name': '高数A'},
            ],
            'futureKey': 1,
          }),
        );
        await restart();
        expect(c.courseDateEdits, isEmpty);
        expect(cellOf(_mon2, 'MATH|01').course.name, '高数A');
        await c.editOccurrence(cellOf(_mon2, 'MATH|01'), note: '带计算器');
        final file = readJson(ScheduleStore.courseEditsFile);
        expect(file['version'], 2);
        expect(file['futureKey'], 1);
        expect((file['edits'] as List).single['name'], '高数A');
        expect((file['dateEdits'] as List), hasLength(1));
        // 单日修改叠在所有周编辑之上。
        expect(cellOf(_mon2, 'MATH|01').course.name, '高数A');
        expect(cellOf(_mon2, 'MATH|01').slot.note, '带计算器');
      },
    );

    test('坏的 dateEdits 条目跳过', () async {
      await seed();
      File('${tmp.path}/${ScheduleStore.courseEditsFile}').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'version': 2,
          'edits': [],
          'dateEdits': [
            {
              'id': 'x',
              'courseId': 'MATH|01',
              'date': '2026-02-30',
              'origStart': 1,
              'origEnd': 2,
            },
            'junk',
            {
              'id': 'ok',
              'courseId': 'MATH|01',
              'date': '2026-09-07',
              'origStart': 1,
              'origEnd': 2,
              'kind': 'edit',
              'name': '改',
            },
          ],
        }),
      );
      await restart();
      expect(c.courseDateEdits.map((e) => e.id), ['ok']);
    });

    test('重新同步不清记录；课不在那天了就忽略，回来了又生效', () async {
      await seed();
      await c.editOccurrence(cellOf(_mon2, 'MATH|01'), name: '改名');
      // 教务把高数挪到周五：这条记录忽略但保留。
      nextFetch = [
        _jwxt('MATH|01', '高数', day: 5),
        _jwxt('ENG|01', '英语', day: 2, start: 3),
      ];
      await c.syncFromJwxt();
      expect(active(_mon2), isEmpty);
      expect(
        active(_mon2.add(const Duration(days: 4))).single.course.name,
        '高数',
      );
      expect(c.courseDateEdits, hasLength(1));
      nextFetch = [
        _jwxt('MATH|01', '高数'),
        _jwxt('ENG|01', '英语', day: 2, start: 3),
      ];
      await c.syncFromJwxt();
      expect(cellOf(_mon2, 'MATH|01').course.name, '改名');
    });

    test('拖动「只改这一天」普通格仍走拖动调课；「所有周」改课程本身', () async {
      await seed();
      final r = await c.moveOccurrenceThisDay(
        cellOf(_mon2, 'MATH|01'),
        toDay: 4,
        toStartPeriod: 3,
      );
      expect(r.ok, isTrue);
      expect(c.slotOverrides, hasLength(1));
      expect(c.courseDateEdits, isEmpty);
      expect(cellOf(_thu2, 'MATH|01').slot.startNode, 3);
      expect(cellOf(_mon3, 'MATH|01').slot.day, 1);
      final r2 = await c.moveOccurrenceAllWeeks(
        cellOf(_tue2, 'ENG|01'),
        toDay: 5,
        toStartPeriod: 1,
      );
      expect(r2.ok, isTrue);
      expect(r2.affectedWeeks, hasLength(16));
      expect(active(_tue2), isEmpty);
      expect(
        active(_mon3.add(const Duration(days: 4))).single.course.id,
        'ENG|01',
      );
    });
  });

  group('第 8 条 整天调课', () {
    test('两天课程互换，考试留在原日期；表头「调」；落盘、重启、恢复', () async {
      final mid = await seed();
      await c.addScheduleEvent(
        ScheduleEvent(
          id: '',
          kind: ScheduleKind.exam,
          source: ScheduleSource.manual,
          title: '虚构考试',
          date: _mon2,
          start: const TimeOfDayMinutes(14, 0),
          end: const TimeOfDayMinutes(16, 0),
        ),
      );
      final swap = await c.addDaySwap(_mon2, _wed2);
      expect(swap, isNotNull);
      expect(c.isSwappedDate(_mon2), isTrue);
      expect(c.isSwappedDate(_wed2), isTrue);
      expect(c.isSwappedDate(_tue2), isFalse);
      expect(c.swapPartnerOf(_mon2), _wed2);
      final mon = active(_mon2);
      expect(mon.single.course.id, mid);
      expect(mon.single.slot.day, 1);
      expect(mon.single.swappedFrom, _wed2);
      expect(active(_wed2).single.course.id, 'MATH|01');
      expect(active(_wed2).single.slot.day, 3);
      // 其他周不受影响。
      expect(cellOf(_mon3, 'MATH|01').swappedFrom, isNull);
      // 考试不动。
      expect(c.scheduleEventsOn(_mon2).single.title, '虚构考试');
      expect(c.scheduleEventsOn(_wed2), isEmpty);
      // 已参与调课的日期 / 同一天不能再加。
      expect(await c.addDaySwap(_mon2, _thu2), isNull);
      expect(await c.addDaySwap(_tue2, _tue2), isNull);
      final file = readJson(ScheduleStore.daySwapsFile);
      expect((file['swaps'] as List).single, {
        'id': swap!.id,
        'dateA': '2026-09-07',
        'dateB': '2026-09-09',
        'createdAt': swap.createdAt,
      });
      await restart();
      expect(c.daySwaps.single.id, swap.id);
      expect(active(_mon2).single.course.id, mid);
      expect(await c.removeDaySwap(swap.id), isTrue);
      expect(await c.removeDaySwap(swap.id), isFalse);
      expect(active(_mon2).single.course.id, 'MATH|01');
      expect(c.isSwappedDate(_mon2), isFalse);
    });

    test('坏的 day_swaps.json：改名 .corrupt，按空读，可继续写', () async {
      await seed();
      File('${tmp.path}/${ScheduleStore.daySwapsFile}')
          .writeAsStringSync('{oops');
      await restart();
      expect(c.daySwaps, isEmpty);
      expect(
        File('${tmp.path}/${ScheduleStore.daySwapsFile}.corrupt').existsSync(),
        isTrue,
      );
      expect(await c.addDaySwap(_mon2, _tue2), isNotNull);
      expect(readJson(ScheduleStore.daySwapsFile)['swaps'], hasLength(1));
    });

    test('坏条目跳过（同一天 / 日期坏 / 缺 id）', () async {
      await seed();
      File('${tmp.path}/${ScheduleStore.daySwapsFile}').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'swaps': [
            {'id': 'a', 'dateA': '2026-09-07', 'dateB': '2026-09-07'},
            {'id': 'b', 'dateA': '2026-13-01', 'dateB': '2026-09-07'},
            {'dateA': '2026-09-07', 'dateB': '2026-09-08'},
            {'id': 'ok', 'dateA': '2026-09-07', 'dateB': '2026-09-08'},
          ],
        }),
      );
      await restart();
      expect(c.daySwaps.map((s) => s.id), ['ok']);
    });

    test('PM 规则：调课前的单日修改在调课期间暂停，恢复调课后重新生效（不删）', () async {
      await seed();
      await c.editOccurrence(cellOf(_mon2, 'MATH|01'), name: '高数（改）');
      expect(cellOf(_mon2, 'MATH|01').course.name, '高数（改）');
      final swap = await c.addDaySwap(_mon2, _tue2);
      // A 显示 B 的课，B 显示 A 的高数（未改）：单日修改暂不生效。
      expect(active(_mon2).single.course.id, 'ENG|01');
      final onTue = cellOf(_tue2, 'MATH|01');
      expect(onTue.course.name, '高数');
      expect(onTue.dateEdit, isNull);
      expect(c.courseDateEdits, hasLength(1));
      await c.removeDaySwap(swap!.id);
      expect(cellOf(_mon2, 'MATH|01').course.name, '高数（改）');
      expect(c.courseDateEdits, hasLength(1));
    });

    test('调课期间的修改记在显示日期；优先级 单日修改 > 整天调课', () async {
      await seed();
      final swap = await c.addDaySwap(_mon2, _tue2);
      final onTue = cellOf(_tue2, 'MATH|01');
      final rec = await c.editOccurrence(onTue, location: '操场');
      expect(rec!.date, _tue2);
      expect(cellOf(_tue2, 'MATH|01').slot.location, '操场');
      expect(c.baseOccurrenceOf(cellOf(_tue2, 'MATH|01'))!.week, 2);
      // 恢复调课：高数回到周一（未改），记录保留但暂停。
      await c.removeDaySwap(swap!.id);
      expect(cellOf(_mon2, 'MATH|01').slot.location, '教一-101');
      expect(active(_tue2).single.course.id, 'ENG|01');
      expect(c.courseDateEdits, hasLength(1));
    });

    test('拖动调课后再整天调课：调过去的课跟着那一天走（整天调课 > 拖动）', () async {
      await seed();
      await c.moveOccurrenceThisDay(
        cellOf(_mon2, 'MATH|01'),
        toDay: 4,
        toStartPeriod: 3,
      );
      await c.addDaySwap(_thu2, _wed2);
      final m = cellOf(_wed2, 'MATH|01');
      expect(m.slot.startNode, 3);
      expect(m.slot.day, 3);
      expect(m.swappedFrom, _thu2);
    });

    test('调课日的拖动「只改这一天」写单日修改，不写拖动记录', () async {
      final mid = await seed();
      await c.addDaySwap(_mon2, _wed2);
      final cell = cellOf(_mon2, mid);
      final r = await c.moveOccurrenceThisDay(cell, toDay: 1, toStartPeriod: 9);
      expect(r.ok, isTrue);
      expect(c.slotOverrides, isEmpty);
      expect(c.courseDateEdits.single.date, _mon2);
      expect(cellOf(_mon2, mid).slot.startNode, 9);
      // 手动课本身不变。
      expect(c.manualCourseById(mid)!.slots.single.startNode, 5);
    });

    test('首页今日课程跟随整天调课', () async {
      final mid = await seed();
      await c.addDaySwap(_mon2, _wed2);
      final items = c.todayCourses(now: DateTime(2026, 9, 7, 7));
      expect(items.single.course.id, mid);
    });
  });

  test('DaySwap / CourseDateEdit JSON 往返保留未知键', () {
    final e = CourseDateEdit.tryParse({
      'id': 'i',
      'courseId': 'c',
      'date': '2026-09-07',
      'origStart': 1,
      'origEnd': 2,
      'kind': 'delete',
      'x': 1,
    })!;
    expect(e.isDelete, isTrue);
    expect(e.toJson()['x'], 1);
    expect(CourseDateEdit.tryParse({...e.toJson(), 'kind': 'weird'}), isNull);
    final s = DaySwap.tryParse({
      'id': 's',
      'dateA': '2026-09-07',
      'dateB': '2026-09-09',
    })!;
    expect(s.partnerOf(DateTime(2026, 9, 9, 13)), DateTime(2026, 9, 7));
    expect(DaySwap.tryParse(s.toJson())!.dateB, DateTime(2026, 9, 9));
    expect(MoveScope.values, contains(MoveScope.allWeeks));
  });
}
