import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

// 全部为虚构数据。
const _settings = TimetableSettings(termCode: '2026-2027-1');
final _termStart = DateTime(2026, 8, 31); // 周一，第 1 周
final _monday = DateTime(2026, 9, 7); // 第 2 周周一

Course _jwxt(
  String id,
  String name, {
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '1111111111111111',
}) => Course(
  id: id,
  name: name,
  source: CourseSource.jwxt,
  slots: [
    CourseSlot(
      day: day,
      startNode: start,
      endNode: end,
      weeks: weeks,
      teacher: '张老师',
      location: '教一-101',
    ),
  ],
);

Course _manual(String id, String name) => Course(
  id: id,
  name: name,
  source: CourseSource.manual,
  slots: const [
    CourseSlot(day: 3, startNode: 5, endNode: 6, weeks: '1111111111111111'),
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

ScheduleEvent _exam(
  String id,
  String code, {
  DateTime? date,
  int startH = 9,
  int endH = 11,
  String title = '高等数学考试',
}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.exam,
  source: ScheduleSource.jwxt,
  title: title,
  date: date ?? _monday,
  start: TimeOfDayMinutes(startH, 0),
  end: TimeOfDayMinutes(endH, 0),
  location: '教二-201',
  courseCode: code,
);

ScheduleEvent _other(String id, {int endH = 21}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.other,
  source: ScheduleSource.manual,
  title: '社团活动',
  date: _monday,
  start: TimeOfDayMinutes(endH - 1, 0),
  end: TimeOfDayMinutes(endH, 0),
);

void main() {
  late Directory tmp;
  final c = TimetableController.instance;
  List<Course> nextFetch = const [];
  List<ScheduleEvent>? nextExams;
  final origFetchExams = TimetableController.fetchExams;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tt_data');
    TimetableStore.debugDirectory = tmp;
    TimetableController.clock = () => _monday;
    TimetableController.bindingCheck = () async => true;
    TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
        _snap(nextFetch);
    // 默认返回 null（本次不拉考试，与替换了 fetchSnapshot 时的默认钩子一致）。
    nextExams = null;
    TimetableController.fetchExams = (term) async => nextExams;
    c.debugReset();
  });

  tearDown(() async {
    TimetableStore.debugDirectory = null;
    TimetableController.clock = TimetableApi.shanghaiToday;
    TimetableController.syncClock = DateTime.now;
    TimetableController.fetchSnapshot = (term, {baseSettings}) =>
        TimetableApi.fetchTermSnapshot(term, baseSettings: baseSettings);
    TimetableController.fetchExams = origFetchExams;
    c.debugReset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 模拟重启：清内存，按同一目录重新读盘。
  Future<void> restart() async {
    c.debugReset();
    await c.ensureStarted();
  }

  Future<void> seed(List<Course> jwxt, {List<Course> manual = const []}) async {
    nextFetch = jwxt;
    await c.ensureStarted();
    for (final m in manual) {
      await c.addManualCourse(m);
    }
    await c.syncFromJwxt();
    expect(c.syncStatus, TimetableSyncStatus.success);
  }

  Course shown(String id) => c.courses.firstWhere((x) => x.id == id);

  GridCell cellAt(String id, int week, int day) => c
      .cellsForDay(week, day)
      .firstWhere((value) => value.activeThisWeek && value.course.id == id);

  Future<Course?> saveForm(
    GridCell cell, {
    String? name,
    String? teacher,
    String? location,
    String? note,
    CourseKind? kind,
    int? day,
    int? start,
    int? end,
    List<int>? weeks,
    List<int>? applyWeeks,
    int? color,
    bool colorChanged = false,
  }) {
    final base = c.baseOccurrenceOf(cell)!;
    return c.saveCourseForm(
      initial: cell.course,
      initialSlot: cell.slot,
      cell: cell,
      name: name ?? cell.course.name,
      teacher: teacher ?? cell.slot.teacher,
      location: location ?? cell.slot.location,
      note: note ?? cell.slot.note,
      kind: kind ?? courseKindOf(course: cell.course, slot: cell.slot),
      day: day ?? cell.slot.day,
      startNode: start ?? cell.slot.startNode,
      endNode: end ?? cell.slot.endNode,
      courseWeeks: weeks ?? weeksOf(base.course.slots[base.slotIndex]),
      applyWeeks: applyWeeks,
      userArgb: color,
      colorChanged: colorChanged,
    );
  }

  group('统一课程编辑数据', () {
    for (final source in [CourseSource.jwxt, CourseSource.manual]) {
      test('${source.name} 单周课程移为独立考试，其他安排和重启保持', () async {
        final original = _jwxt('convert', '测试课程', weeks: '111').copyWith(
          source: source,
          slots: [
            _jwxt(
              'x',
              'x',
              weeks: '111',
            ).slots.single.copyWith(kind: CourseKind.lab),
            _jwxt(
              'x',
              'x',
              day: 3,
              start: 5,
              end: 6,
              weeks: '111',
            ).slots.single,
          ],
        );
        await seed(
          source == CourseSource.jwxt ? [original] : [],
          manual: source == CourseSource.manual ? [original] : [],
        );
        final opening = cellAt('convert', 2, 1);
        expect(await saveForm(opening, kind: CourseKind.exam), isNull);
        expect(c.scheduleEvents, isEmpty);
        final exam = await c.convertCourseOccurrenceToExam(
          cell: opening,
          title: ' 测试考试 ',
          location: ' 教二-201 ',
          note: ' 带计算器 ',
          day: 1,
          startNode: 1,
          endNode: 2,
        );
        expect(exam, isNotNull);
        expect(exam!.kind, ScheduleKind.exam);
        expect(exam.source, ScheduleSource.manual);
        expect(exam.title, '测试考试');
        expect(exam.date, _monday);
        expect(exam.start.format(), '08:00');
        expect(exam.end.format(), '09:40');
        expect(exam.location, '教二-201');
        expect(exam.note, '带计算器');
        expect(
          c.cellsForDay(2, 1).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
        expect(cellAt('convert', 1, 1).slot.kind, CourseKind.lab);
        expect(cellAt('convert', 2, 3).slot.startNode, 5);
        expect(c.courseDateEdits, isEmpty);
        expect(shown('convert').slots.first.weeks, '101');
        expect(
          await c.convertCourseOccurrenceToExam(
            cell: opening,
            title: '重复保存',
            location: '',
            note: '',
            day: 1,
            startNode: 1,
            endNode: 2,
          ),
          isNull,
        );
        await restart();
        expect(c.scheduleEvents.single.toJson(), exam.toJson());
        expect(
          c.cellsForDay(2, 1).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
        expect(cellAt('convert', 3, 1).slot.kind, CourseKind.lab);
        expect(
          await c.updateScheduleEvent(exam.copyWith(title: '独立改名')),
          isTrue,
        );
        expect(cellAt('convert', 3, 1).course.name, '测试课程');
        expect(await c.deleteScheduleEvent(exam.id), isTrue);
        expect(
          c.cellsForDay(2, 1).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
        await c.syncFromJwxt();
        expect(c.scheduleEvents, isEmpty);
        expect(
          c.cellsForDay(2, 1).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
      });
    }

    test('最后一周课程转换考试后浏览上限不缩短，隐藏考试与重启仍可访问', () async {
      await seed([
        _jwxt('keep', '保留课程', day: 2, weeks: '1000'),
        _jwxt('convert', '期末课程', weeks: '0001'),
      ]);
      final lastDate = _termStart.add(const Duration(days: 21));
      TimetableController.clock = () => lastDate;
      c.setViewingWeek(4);
      expect(c.totalWeeks, 4);
      expect(
        await c.convertCourseOccurrenceToExam(
          cell: cellAt('convert', 4, 1),
          title: '期末考试',
          location: '',
          note: '',
          day: 1,
          startNode: 1,
          endNode: 2,
        ),
        isNotNull,
      );
      expect(c.totalWeeks, 4);
      expect(c.viewingWeek, 4);
      await c.updateSettings(c.settings.copyWith(showExams: false));
      expect(c.totalWeeks, 4);
      expect(c.viewingWeek, 4);
      await restart();
      expect(c.totalWeeks, 4);
      expect(c.viewingWeek, 4);
      expect(c.scheduleEvents.single.date, lastDate);
    });

    test('周末课程转换考试后当天列仍可见，隐藏考试后不保留空列', () async {
      await seed([
        _jwxt('saturday', '周六课程', day: 6, weeks: '010'),
        _jwxt('sunday', '周日课程', day: 7, weeks: '010'),
      ]);
      await c.updateSettings(
        c.settings.copyWith(
          showSaturday: false,
          showSunday: false,
          showNonCurrentWeek: true,
        ),
      );
      expect(c.visibleDays(2), containsAll([6, 7]));
      for (final day in [6, 7]) {
        expect(
          await c.convertCourseOccurrenceToExam(
            cell: cellAt(day == 6 ? 'saturday' : 'sunday', 2, day),
            title: '周末考试',
            location: '',
            note: '',
            day: day,
            startNode: 1,
            endNode: 2,
          ),
          isNotNull,
        );
        expect(
          c.cellsForDay(2, day).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
      }
      expect(c.visibleDays(2), containsAll([6, 7]));
      expect(c.visibleDays(1), isNot(contains(6)));
      expect(c.visibleDays(1), isNot(contains(7)));
      await c.updateSettings(c.settings.copyWith(showExams: false));
      expect(c.visibleDays(2), isNot(contains(6)));
      expect(c.visibleDays(2), isNot(contains(7)));
      expect(c.scheduleEvents, hasLength(2));
    });

    for (final source in [CourseSource.jwxt, CourseSource.manual]) {
      test('${source.name} 交换后移动的课程转换考试，撤销交换或删除考试不恢复原次', () async {
        final original = _jwxt(
          'convert',
          '测试课程',
          weeks: '111',
        ).copyWith(source: source);
        await seed(
          source == CourseSource.jwxt ? [original] : [],
          manual: source == CourseSource.manual ? [original] : [],
        );
        await c.editOccurrenceWeeks(
          cellAt('convert', 2, 1),
          weeks: [2, 3],
          note: '按周备注',
        );
        final swap = await c.addDaySwap(
          _monday,
          _monday.add(const Duration(days: 1)),
        );
        await c.editOccurrence(
          cellAt('convert', 2, 2),
          toDay: 4,
          toStart: 3,
          toEnd: 4,
        );
        final moved = cellAt('convert', 2, 4);
        final exam = await c.convertCourseOccurrenceToExam(
          cell: moved,
          title: '独立考试',
          location: '教三-301',
          note: '',
          day: 5,
          startNode: 5,
          endNode: 6,
        );
        expect(exam!.date, _monday.add(const Duration(days: 4)));
        expect(exam.start.format(), c.periodStart(5));
        expect(exam.end.format(), c.periodEnd(6));
        for (final day in [1, 2, 4, 5]) {
          expect(
            c.cellsForDay(2, day).where((cell) => cell.activeThisWeek),
            isEmpty,
          );
        }
        expect(c.courseDateEdits.single.isWeeksScoped, isTrue);
        expect(c.courseDateEdits.single.weeks, [2, 3]);
        expect(cellAt('convert', 3, 1).slot.startNode, 1);
        expect(cellAt('convert', 3, 1).slot.note, '按周备注');
        await restart();
        expect(c.scheduleEvents.single.date, exam.date);
        expect(
          c.cellsForDay(2, 4).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
        expect(await c.removeDaySwap(swap!.id), isTrue);
        expect(
          c.cellsForDay(2, 1).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
        expect(await c.deleteScheduleEvent(exam.id), isTrue);
        expect(
          c.cellsForDay(2, 1).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
        await restart();
        expect(
          c.cellsForDay(2, 1).where((cell) => cell.activeThisWeek),
          isEmpty,
        );
        expect(cellAt('convert', 3, 1).slot.note, '按周备注');
      });
    }

    test('主动恢复教务课程可恢复被转换的周次，但独立考试仍保留', () async {
      await seed([_jwxt('convert', '测试课程', weeks: '111')]);
      final exam = await c.convertCourseOccurrenceToExam(
        cell: cellAt('convert', 2, 1),
        title: '独立考试',
        location: '',
        note: '',
        day: 1,
        startNode: 1,
        endNode: 2,
      );
      expect(exam, isNotNull);
      expect(await c.restoreJwxtCourse('convert'), isTrue);
      expect(cellAt('convert', 2, 1).slot.weeks, '111');
      expect(c.scheduleEvents.single.toJson(), exam!.toJson());
    });

    test('同起始节次的重叠时段不会借用另一时段的类型名称或颜色', () async {
      await seed([
        _jwxt('overlap', '原始课程').copyWith(
          slots: [
            _jwxt('x', 'x', end: 2).slots.single,
            _jwxt('x', 'x', end: 3).slots.single,
          ],
        ),
      ]);
      final opening = c
          .cellsForDay(2, 1)
          .firstWhere(
            (cell) =>
                cell.activeThisWeek &&
                cell.course.id == 'overlap' &&
                cell.slot.endNode == 2,
          );
      await saveForm(
        opening,
        kind: CourseKind.lab,
        name: '本周实验',
        colorChanged: true,
        color: 0xFF123456,
        applyWeeks: [2],
      );
      final today = c.coursesOnDate(_monday);
      expect(today, hasLength(2));
      final lab = today.singleWhere((item) => item.slot.endNode == 2);
      final standard = today.singleWhere((item) => item.slot.endNode == 3);
      expect(courseKindOf(course: lab.course, slot: lab.slot), CourseKind.lab);
      expect(lab.course.name, '本周实验');
      expect(c.userColorOf(lab.course), 0xFF123456);
      expect(
        courseKindOf(course: standard.course, slot: standard.slot),
        CourseKind.standard,
      );
      expect(standard.course.name, '原始课程');
      expect(c.userColorOf(standard.course), isNull);
      expect(
        c.timeForSlot(standard.course, standard.slot, date: _monday).end,
        '10:55',
      );
    });

    for (final manual in [false, true]) {
      test('${manual ? '手动' : '教务'}混合课程只修改当前时段的类型名称颜色与重复安排', () async {
        final source = _jwxt('mixed', '测试课程', weeks: '1111').copyWith(
          source: manual ? CourseSource.manual : CourseSource.jwxt,
          slots: [
            _jwxt('x', 'x', weeks: '1111').slots.single,
            const CourseSlot(
              day: 3,
              startNode: 1,
              endNode: 2,
              weeks: '1111',
              isLab: true,
              teacher: '实验教师',
              location: '实验室',
            ),
          ],
        );
        await seed(manual ? [] : [source], manual: manual ? [source] : []);
        expect(
          await saveForm(
            cellAt('mixed', 2, 1),
            kind: CourseKind.pe,
            name: '体育训练',
            teacher: '',
            day: 2,
            start: 3,
            end: 4,
            weeks: [2, 4, 5],
            colorChanged: true,
            color: 0xFF123456,
          ),
          isNotNull,
        );
        expect(c.cellsForDay(1, 1).where((e) => e.activeThisWeek), isEmpty);
        for (final week in [2, 4, 5]) {
          final edited = cellAt('mixed', week, 2);
          expect(edited.course.name, '体育训练');
          expect(edited.slot.teacher, '');
          expect(edited.slot.startNode, 3);
          expect(
            courseKindOf(course: edited.course, slot: edited.slot),
            CourseKind.pe,
          );
          expect(c.userColorOf(edited.course), 0xFF123456);
        }
        final lab = cellAt('mixed', 2, 3);
        expect(lab.course.name, '测试课程');
        expect(lab.slot.teacher, '实验教师');
        expect(
          courseKindOf(course: lab.course, slot: lab.slot),
          CourseKind.lab,
        );
        expect(c.userColorOf(lab.course), isNull);
        await restart();
        expect(cellAt('mixed', 5, 2).slot.kind, CourseKind.pe);
        expect(cellAt('mixed', 2, 3).slot.kind, isNull);
        if (!manual) {
          expect(c.jwxtCourses.single.slots.first.day, 1);
          expect(await c.restoreJwxtCourse('mixed'), isTrue);
          expect(cellAt('mixed', 1, 1).slot.kind, isNull);
          expect(c.cellsForDay(5, 2).where((e) => e.activeThisWeek), isEmpty);
        }
      });
    }

    test('指定周类型和清空颜色不串到同课程同节次的另一天', () async {
      final source = _jwxt('mixed', '测试课程', weeks: '1111').copyWith(
        slots: [
          _jwxt('x', 'x', weeks: '1111').slots.single,
          _jwxt('x', 'x', day: 3, weeks: '1111').slots.single,
        ],
      );
      await seed([source]);
      await c.setUserCourseColor('mixed', 0xFF123456);
      await saveForm(
        cellAt('mixed', 2, 1),
        kind: CourseKind.lab,
        note: '周一备注',
        applyWeeks: [2, 3],
        colorChanged: true,
      );
      await saveForm(
        cellAt('mixed', 2, 3),
        kind: CourseKind.pe,
        note: '周三备注',
        applyWeeks: [2, 3],
      );
      for (final w in [2, 3]) {
        final monday = cellAt('mixed', w, 1), wednesday = cellAt('mixed', w, 3);
        expect(monday.slot.kind, CourseKind.lab);
        expect(monday.slot.note, '周一备注');
        expect(c.userColorOf(monday.course), isNull);
        expect(wednesday.slot.kind, CourseKind.pe);
        expect(wednesday.slot.note, '周三备注');
        expect(c.userColorOf(wednesday.course), 0xFF123456);
      }
      expect(cellAt('mixed', 1, 1).slot.kind, isNull);
      expect(c.userColorOf(cellAt('mixed', 4, 1).course), 0xFF123456);
      await restart();
      expect(cellAt('mixed', 3, 1).slot.kind, CourseKind.lab);
      expect(c.userColorOf(cellAt('mixed', 3, 1).course), isNull);
    });

    test('从局部改名备注进入只改全部周类型，不扩散局部字段', () async {
      await seed([_jwxt('j1', '原始名称')]);
      await saveForm(
        cellAt('j1', 2, 1),
        name: '本周名称',
        note: '本周备注',
        kind: CourseKind.lab,
        applyWeeks: [2],
      );
      await saveForm(cellAt('j1', 2, 1), kind: CourseKind.pe);
      expect(cellAt('j1', 2, 1).course.name, '本周名称');
      expect(cellAt('j1', 2, 1).slot.note, '本周备注');
      expect(cellAt('j1', 3, 1).course.name, '原始名称');
      expect(cellAt('j1', 3, 1).slot.note, '');
      expect(cellAt('j1', 2, 1).slot.kind, CourseKind.pe);
      expect(cellAt('j1', 3, 1).slot.kind, CourseKind.pe);
    });

    test('先改类型再拖动及恢复位置保留类型和字段', () async {
      await seed([_jwxt('j1', '测试课程')]);
      await saveForm(cellAt('j1', 2, 1), kind: CourseKind.lab, note: '备课说明');
      final course = shown('j1');
      expect(
        (await c.moveSlot(
          course,
          0,
          toDay: 4,
          toStartPeriod: 3,
          week: 2,
          scope: MoveScope.thisWeek,
        )).ok,
        isTrue,
      );
      expect(cellAt('j1', 2, 4).slot.kind, CourseKind.lab);
      expect(cellAt('j1', 2, 4).slot.note, '备课说明');
      expect(cellAt('j1', 3, 1).slot.kind, CourseKind.lab);
      await restart();
      final moved = shown('j1');
      final index = moved.slots.indexWhere((slot) => slot.day == 4);
      expect(await c.restoreOverride(moved, index), isTrue);
      expect(shown('j1').slots, hasLength(1));
      expect(cellAt('j1', 2, 1).slot.kind, CourseKind.lab);
      expect(cellAt('j1', 2, 1).slot.note, '备课说明');
    });

    test('已有拖动后表单只改类型，其他周与另一分段的时间保持', () async {
      await seed([_jwxt('j1', '测试课程')]);
      await c.moveSlot(
        shown('j1'),
        0,
        toDay: 4,
        toStartPeriod: 3,
        week: 2,
        scope: MoveScope.thisWeek,
      );
      await saveForm(cellAt('j1', 2, 4), kind: CourseKind.lab);
      expect(cellAt('j1', 2, 4).slot.kind, CourseKind.lab);
      expect(cellAt('j1', 2, 4).slot.startNode, 3);
      expect(cellAt('j1', 3, 1).slot.kind, isNull);
      expect(cellAt('j1', 3, 1).slot.startNode, 1);
      await restart();
      expect(cellAt('j1', 2, 4).slot.kind, CourseKind.lab);
    });

    test('类型覆盖跨同步保留，未改的老师继续同步，教务改周次后覆盖失效', () async {
      await seed([_jwxt('j1', '测试课程', weeks: '1111')]);
      await saveForm(cellAt('j1', 2, 1), kind: CourseKind.lab);
      nextFetch = [
        _jwxt('j1', '测试课程', weeks: '1111').copyWith(
          slots: [
            _jwxt(
              'x',
              'x',
              weeks: '1111',
            ).slots.single.copyWith(teacher: '新任教师'),
          ],
        ),
      ];
      await c.syncFromJwxt();
      expect(cellAt('j1', 2, 1).slot.kind, CourseKind.lab);
      expect(cellAt('j1', 2, 1).slot.teacher, '新任教师');
      nextFetch = [_jwxt('j1', '测试课程', weeks: '11111')];
      await c.syncFromJwxt();
      expect(cellAt('j1', 2, 1).slot.kind, isNull);
      expect(c.courseEditOf('j1'), isNull);
    });

    test('新建体育课颜色可从原始课程读取并在重启后保留', () async {
      await seed([]);
      final added = await c.saveCourseForm(
        name: '训练',
        teacher: '',
        location: '',
        note: '',
        kind: CourseKind.pe,
        day: 1,
        startNode: 1,
        endNode: 2,
        courseWeeks: [1, 2],
        userArgb: 0xFF123456,
        colorChanged: true,
      );
      expect(added, isNotNull);
      expect(c.userColorOf(c.manualCourses.single), 0xFF123456);
      expect(c.manualCourses.single.slots.single.kind, CourseKind.pe);
      await restart();
      expect(c.userColorOf(c.manualCourses.single), 0xFF123456);
    });

    test('全课程配色覆盖表单局部颜色与默认色，类型和备注仍保留', () async {
      await seed([_jwxt('j1', '测试课程')]);
      await saveForm(
        cellAt('j1', 2, 1),
        kind: CourseKind.lab,
        colorChanged: true,
        color: 0xFF123456,
      );
      await saveForm(
        cellAt('j1', 2, 1),
        note: '本周备注',
        applyWeeks: [2],
        colorChanged: true,
      );
      await c.setUserCourseColor('j1', 0xFF654321);
      for (final week in [2, 3]) {
        final cell = cellAt('j1', week, 1);
        expect(c.userColorOf(cell.course), 0xFF654321);
        expect(cell.slot.kind, CourseKind.lab);
      }
      expect(cellAt('j1', 2, 1).slot.note, '本周备注');
    });

    test('详情仅这次恢复默认色覆盖时段颜色，同时保留局部类型和备注', () async {
      await seed([_jwxt('j1', '测试课程')]);
      await saveForm(cellAt('j1', 2, 1), colorChanged: true, color: 0xFF123456);
      await saveForm(
        cellAt('j1', 2, 1),
        kind: CourseKind.lab,
        note: '本周备注',
        applyWeeks: [2],
      );
      expect(
        await c.setOccurrenceColor(
          cellAt('j1', 2, 1),
          null,
          useDefaultColor: true,
        ),
        isTrue,
      );
      final reset = cellAt('j1', 2, 1);
      expect(c.userColorOf(reset.course), isNull);
      expect(reset.slot.kind, CourseKind.lab);
      expect(reset.slot.note, '本周备注');
      expect(c.userColorOf(cellAt('j1', 3, 1).course), 0xFF123456);
      expect(
        await c.setOccurrenceColor(
          cellAt('j1', 4, 1),
          null,
          useDefaultColor: true,
        ),
        isTrue,
      );
      expect(c.userColorOf(cellAt('j1', 4, 1).course), isNull);
    });

    test('全部周只清当前时段与旧多周覆盖的交集，其他时段的记录保留', () async {
      await seed([
        _jwxt('j1', '测试课程', weeks: '1100').copyWith(
          slots: [
            _jwxt('x', 'x', weeks: '1100').slots.single,
            _jwxt('x', 'x', weeks: '0011').slots.single,
          ],
        ),
      ]);
      await c.editOccurrenceWeeks(
        cellAt('j1', 2, 1),
        weeks: [2, 3],
        note: '跨段备注',
      );
      await saveForm(cellAt('j1', 1, 1), note: '前半段备注', kind: CourseKind.lab);
      expect(cellAt('j1', 1, 1).slot.note, '前半段备注');
      expect(cellAt('j1', 2, 1).slot.note, '前半段备注');
      expect(cellAt('j1', 3, 1).slot.note, '跨段备注');
      expect(cellAt('j1', 3, 1).slot.kind, isNull);
      expect(cellAt('j1', 4, 1).slot.note, '');
      await restart();
      expect(cellAt('j1', 3, 1).slot.note, '跨段备注');
    });
  });

  // ===== §24 补充用例（FC / JE / EV / EX / SW01）=====

  ScheduleEvent manualExam() => ScheduleEvent(
    id: 'm1',
    kind: ScheduleKind.exam,
    source: ScheduleSource.manual,
    title: '测试手动考试',
    date: _monday,
    start: const TimeOfDayMinutes(8, 0),
    end: const TimeOfDayMinutes(9, 0),
  );

  ScheduleEvent eventById(String id) =>
      c.scheduleEvents.firstWhere((e) => e.id == id);

  String manualEventsJson() => jsonEncode([
    for (final e in c.scheduleEvents)
      if (!e.isFromJwxt) e.toJson(),
  ]);
  group('jwxt course edit / delete', () {
    test('edit shows new fields; delete hides; restore clears all', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      expect(
        await c.editJwxtCourse('j1', name: '高数（改）', location: '教三-303'),
        isTrue,
      );
      final j1 = shown('j1');
      expect(j1.name, '高数（改）');
      expect(j1.slots.single.location, '教三-303');
      expect(j1.slots.single.teacher, '张老师');
      expect(c.isJwxtOverridden(courseId: 'j1'), isTrue);
      expect(c.jwxtCourses.firstWhere((x) => x.id == 'j1').name, '高等数学');

      expect(await c.deleteJwxtCourse('j2'), isTrue);
      expect(c.courses.any((x) => x.id == 'j2'), isFalse);
      expect(c.cellsForDay(2, 2), isEmpty);
      expect(c.deletedJwxtCourses.map((x) => x.id), ['j2']);

      await restart();
      expect(shown('j1').name, '高数（改）');
      expect(c.courses.any((x) => x.id == 'j2'), isFalse);

      expect(await c.restoreJwxtCourse('j2'), isTrue);
      expect(shown('j2').name, '大学物理');
      expect(c.isJwxtOverridden(courseId: 'j2'), isFalse);
      expect(await c.restoreJwxtCourse('j2'), isFalse);
    });

    test('restoreJwxtCourse also clears move overrides', () async {
      await seed([_jwxt('j1', '高等数学')]);
      final r = await c.moveSlot(
        shown('j1'),
        0,
        toDay: 4,
        toStartPeriod: 3,
        week: 2,
        scope: MoveScope.thisWeek,
      );
      expect(r.status, MoveStatus.moved);
      await c.editJwxtCourse('j1', note: '带计算器');
      expect(c.slotOverrides, isNotEmpty);
      expect(await c.restoreJwxtCourse('j1'), isTrue);
      expect(c.slotOverrides, isEmpty);
      expect(c.courseEditOf('j1'), isNull);
      expect(shown('j1').slots.single.note, '');
    });

    test(
      'EX22 restoreAllJwxt clears moves, edits, deletes and exam overrides',
      () async {
        await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
        await c.moveSlot(
          shown('j1'),
          0,
          toDay: 4,
          toStartPeriod: 3,
          week: 2,
          scope: MoveScope.fromThisWeek,
        );
        await c.editJwxtCourse('j1', name: '高数（改）');
        await c.deleteJwxtCourse('j2');
        await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
        await c.deleteScheduleEvent('e1');
        expect(c.scheduleEvents, isEmpty);

        expect(await c.restoreAllJwxt(), isTrue);
        expect(c.slotOverrides, isEmpty);
        expect(c.courseEditOf('j1'), isNull);
        expect(c.courseEditOf('j2'), isNull);
        expect(shown('j1').name, '高等数学');
        expect(shown('j2').name, '大学物理');
        expect(c.scheduleEvents.map((e) => e.id), ['e1']);
        expect(await c.restoreAllJwxt(), isFalse);
        await restart();
        expect(c.slotOverrides, isEmpty);
        expect(c.courses.length, 2);
        expect(c.scheduleEvents.map((e) => e.id), ['e1']);
      },
    );

    test('renaming keeps the colour (original name lookup)', () async {
      await seed([
        _jwxt('j1', '高等数学'),
        _jwxt('j2', '大学物理', day: 2),
        _jwxt('j3', '线性代数', day: 3),
      ]);
      final before = c.colorIndexOf(shown('j1'));
      final colorsFile = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final colorsBefore = colorsFile.readAsStringSync();
      await c.editJwxtCourse('j1', name: '线性代数');
      expect(shown('j1').name, '线性代数');
      expect(c.colorIndexOf(shown('j1')), before);
      expect(colorsFile.readAsStringSync(), colorsBefore);
      await restart();
      expect(c.colorIndexOf(shown('j1')), before);
    });

    test('JE10 edit invalidated after sync when SKZC weeks change', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      await c.editJwxtCourse('j1', name: 'A');
      await c.editJwxtCourse('j2', name: 'B');
      nextFetch = [
        _jwxt('j1', '高等数学', weeks: '1111111100000000'),
        _jwxt('j2', '大学物理', day: 2),
      ];
      await c.syncFromJwxt();
      expect(c.courseEditOf('j1'), isNull);
      expect(shown('j1').name, '高等数学');
      expect(shown('j2').name, 'B', reason: 'unchanged course keeps edit');
      expect((await ScheduleStore.readCourseEdits()).keys, ['j2']);
    });

    test(
      'JE11 edit invalidated after sync when slot time changes or course gone',
      () async {
        await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
        await c.deleteJwxtCourse('j1');
        await c.editJwxtCourse('j2', teacher: '李老师');
        nextFetch = [_jwxt('j1', '高等数学', start: 3, end: 4)];
        await c.syncFromJwxt();
        expect(c.courseEditOf('j1'), isNull);
        expect(c.courseEditOf('j2'), isNull);
        expect(c.courses.any((x) => x.id == 'j1'), isTrue);
      },
    );

    test('edits survive a failed sync', () async {
      await seed([_jwxt('j1', '高等数学')]);
      await c.editJwxtCourse('j1', name: 'A');
      TimetableController.fetchSnapshot = (t, {baseSettings}) async =>
          throw const SocketException('offline');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(shown('j1').name, 'A');
    });
  });

  group('JE 教务课编辑 / 删除（§24.8 单测）', () {
    test(
      'JE05 deleted jwxt course stays hidden after a successful sync',
      () async {
        await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
        await c.deleteJwxtCourse('j2');
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(c.courses.any((x) => x.id == 'j2'), isFalse);
        expect(c.cellsForDay(2, 2), isEmpty);
        await restart();
        expect(c.courses.any((x) => x.id == 'j2'), isFalse);
        expect(c.courseEditOf('j2')?.deleted, isTrue);
      },
    );

    test('JE09 EX22 restore all clears edits/deletes/moves/exam overrides; manual data untouched', () async {
      await seed(
        [_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)],
        manual: [_manual('m1', '自习')],
      );
      await c.addScheduleEvent(manualExam());
      await c.addScheduleEvent(_other('o1'));
      await c.replaceJwxtExams([_exam('e1', 'MATH01')]);
      final r = await c.moveSlot(
        shown('j1'),
        0,
        toDay: 4,
        toStartPeriod: 3,
        week: 2,
        scope: MoveScope.thisWeek,
      );
      expect(r.status, MoveStatus.moved);
      await c.editJwxtCourse('j1', name: 'A');
      await c.deleteJwxtCourse('j2');
      await c.updateScheduleEvent(eventById('e1').copyWith(location: '体育馆'));
      final k1 = c.jwxtExamKeyOf('e1')!;
      final manualEvents = manualEventsJson();
      final manualCourses = jsonEncode([
        for (final m in c.manualCourses) m.toJson(),
      ]);

      expect(await c.restoreAllJwxt(), isTrue);
      Future<void> check() async {
        expect(c.slotOverrides, isEmpty);
        expect(c.courseEditOf('j1'), isNull);
        expect(c.courseEditOf('j2'), isNull);
        expect(shown('j1').name, '高等数学');
        expect(shown('j2').name, '大学物理');
        expect(c.isJwxtOverridden(examKey: k1), isFalse);
        expect(eventById('e1').location, '教二-201');
        expect(await ScheduleStore.readExamOverrides(), isEmpty);
        expect(await ScheduleStore.readCourseEdits(), isEmpty);
        expect(manualEventsJson(), manualEvents);
        expect(
          jsonEncode([for (final m in c.manualCourses) m.toJson()]),
          manualCourses,
        );
      }

      await check();
      await restart();
      await check();
    });

    test('JE12 EX29 records survive failed sync, unbind and failed re-sync; apply again on success', () async {
      nextExams = [_exam('e1', 'MATH01')];
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      await c.editJwxtCourse('j1', name: 'A');
      await c.deleteJwxtCourse('j2');
      await c.updateScheduleEvent(eventById('e1').copyWith(location: '体育馆'));
      final k1 = c.jwxtExamKeyOf('e1')!;
      void expectApplied() {
        expect(shown('j1').name, 'A');
        expect(c.courses.any((x) => x.id == 'j2'), isFalse);
        expect(eventById('e1').location, '体育馆');
      }

      Future<void> expectStored() async {
        expect((await ScheduleStore.readCourseEdits()).keys.toSet(), {
          'j1',
          'j2',
        });
        expect((await ScheduleStore.readExamOverrides()).keys, [k1]);
      }

      final ok = TimetableController.fetchSnapshot;
      TimetableController.fetchSnapshot = (t, {baseSettings}) async =>
          throw const SocketException('offline');
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expectApplied();
      await expectStored();

      await c.handleLogout();
      expect(c.courses, isEmpty);
      expect(c.scheduleEvents.where((e) => e.isFromJwxt), isEmpty);
      await expectStored();

      // 重新绑定后同步失败：记录仍在，无教务数据可套用，不崩溃。
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.failure);
      expect(c.courses, isEmpty);
      await expectStored();
      await restart();
      await expectStored();

      TimetableController.fetchSnapshot = ok;
      await c.syncFromJwxt();
      expect(c.syncStatus, TimetableSyncStatus.success);
      expectApplied();
    });

    test(
      'JE13 colour index stays through edit/restore and delete/restore all',
      () async {
        await seed([
          _jwxt('j1', '高等数学'),
          _jwxt('j2', '大学物理', day: 2),
          _jwxt('j3', '线性代数', day: 3),
        ]);
        final idx = c.colorIndexOf(shown('j1'));
        await c.editJwxtCourse('j1', name: '测试课乙', teacher: '李老师');
        expect(c.colorIndexOf(shown('j1')), idx);
        await c.restoreJwxtCourse('j1');
        expect(c.colorIndexOf(shown('j1')), idx);
        await c.deleteJwxtCourse('j1');
        await c.restoreAllJwxt();
        expect(c.colorIndexOf(shown('j1')), idx);
        await restart();
        expect(c.colorIndexOf(shown('j1')), idx);
      },
    );

    test('JE14 old data without edit/delete files: no records, nothing written back', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      final newFiles = [
        ScheduleStore.scheduleEventsFile,
        ScheduleStore.courseEditsFile,
        ScheduleStore.examOverridesFile,
        ScheduleStore.syncStateFile,
      ];
      for (final n in newFiles) {
        final x = File('${tmp.path}/$n');
        if (x.existsSync()) x.deleteSync();
      }
      await restart();
      expect(c.courses.map((x) => x.id).toSet(), {'j1', 'j2'});
      expect(c.courseEditOf('j1'), isNull);
      expect(c.deletedJwxtCourses, isEmpty);
      expect(c.isJwxtOverridden(courseId: 'j1'), isFalse);
      expect(c.scheduleEvents, isEmpty);
      for (final n in newFiles) {
        expect(File('${tmp.path}/$n').existsSync(), isFalse, reason: n);
      }
    });

    test('JE20 rename/teacher edit never re-colours: across schemes, sync and restart', () async {
      await seed([
        _jwxt('j1', '高等数学'),
        _jwxt('j2', '大学物理', day: 2),
        _jwxt('j3', '线性代数', day: 3),
      ]);
      Map<String, int> colours() => {
        for (final x in c.courses) x.id: c.colorIndexOf(x),
      };
      final expected = <String, Map<String, int>>{};
      for (final s in ['B', 'C', 'A']) {
        await c.updateSettings(c.settings.copyWith(paletteScheme: s));
        expected[s] = colours();
      }
      // 改成与 j3 同名，并改老师。
      await c.editJwxtCourse('j1', name: '线性代数', teacher: '李老师');
      Future<void> check(String when) async {
        for (final s in ['B', 'C', 'A']) {
          await c.updateSettings(c.settings.copyWith(paletteScheme: s));
          expect(colours(), expected[s], reason: '$when / scheme $s');
        }
      }

      await check('after edit');
      await c.syncFromJwxt();
      expect(shown('j1').name, '线性代数');
      await check('after sync');
      await restart();
      await check('after restart');
    });

    test('JE21 restore course clears its edits and moves only; other course keeps its move', () async {
      await seed([_jwxt('j1', '高等数学'), _jwxt('j2', '大学物理', day: 2)]);
      for (final (id, day) in [('j1', 4), ('j2', 5)]) {
        final r = await c.moveSlot(
          shown(id),
          0,
          toDay: day,
          toStartPeriod: 3,
          week: 2,
          scope: MoveScope.thisWeek,
        );
        expect(r.status, MoveStatus.moved, reason: id);
      }
      final j2Moves = [
        for (final o in c.slotOverrides)
          if (o.courseId == 'j2') o.id,
      ];
      expect(j2Moves, isNotEmpty);
      await c.editJwxtCourse('j1', name: 'A', location: '教三-303');

      expect(await c.restoreJwxtCourse('j1'), isTrue);
      expect(c.courseEditOf('j1'), isNull);
      expect(c.slotOverrides.any((o) => o.courseId == 'j1'), isFalse);
      expect([for (final o in c.slotOverrides) o.id], j2Moves);
      expect(c.isJwxtOverridden(courseId: 'j1'), isFalse);
      expect(c.isJwxtOverridden(courseId: 'j2'), isTrue);
      expect(shown('j1').name, '高等数学');
      expect(shown('j1').slots.single.location, '教一-101');
      expect(c.cellsForDay(2, 1).any((g) => g.course.id == 'j1'), isTrue);
      expect(c.cellsForDay(2, 4).any((g) => g.course.id == 'j1'), isFalse);
    });
  });
}
