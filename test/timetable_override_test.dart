import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_change_format.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_overrides.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_week_grid.dart';

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

  group('课程详情本地差异', () {
    test('恢复单日记录仍继承按周修改，颜色 diff 不重复继承字段', () async {
      await seed([_jwxt('j1', '测试课程')]);
      await c.editOccurrenceWeeks(
        cellAt('j1', 2, 1),
        weeks: [2, 3],
        location: '教二-202',
      );
      await c.editOccurrence(cellAt('j1', 2, 1), location: '教三-303');
      var cell = cellAt('j1', 2, 1);
      var occurrence = c.courseDetailChanges(cell).single;
      expect(occurrence.changes.map((change) => change.field), ['地点']);
      expect(occurrence.changes.single.before, '教二-202');
      expect(occurrence.changes.single.after, '教三-303');
      await c.restoreDateEdit(cell.dateEdit!.id);
      expect(cellAt('j1', 2, 1).slot.location, '教二-202');

      await c.setOccurrenceColor(cellAt('j1', 2, 1), 0xFF123456);
      cell = cellAt('j1', 2, 1);
      occurrence = c.courseDetailChanges(cell).single;
      expect(occurrence.changes.map((change) => change.field), ['颜色']);
      expect(occurrence.changes.single.afterColor, 0xFF123456);
      await c.restoreDateEdit(cell.dateEdit!.id);
      expect(cellAt('j1', 2, 1).slot.location, '教二-202');
    });

    test('单日差异继承整门修改，只列本次变化字段', () async {
      await seed([_jwxt('j1', '测试课程')]);
      await c.editJwxtCourse('j1', location: '教二-202');
      await c.editOccurrence(cellAt('j1', 2, 1), location: '教三-303');
      final groups = c.courseDetailChanges(cellAt('j1', 2, 1));
      final occurrence = groups.singleWhere(
        (group) => group.scope == CourseDetailChangeScope.occurrence,
      );
      expect(occurrence.affectedScope, '9月7日 周一');
      expect(occurrence.changes.map((change) => change.field), ['地点']);
      expect(occurrence.changes.single.before, '教二-202');
      expect(occurrence.changes.single.after, '教三-303');
      expect(
        groups.any((group) => group.scope == CourseDetailChangeScope.course),
        isTrue,
      );
    });

    test('整门差异包含其他时段和单日删除，当前未改格仍可查看', () async {
      final original = _jwxt('j1', '测试课程').copyWith(
        slots: [
          _jwxt('x', 'x').slots.single,
          _jwxt('x', 'x', day: 3, start: 5, end: 6).slots.single,
        ],
      );
      await seed([original]);
      await saveForm(cellAt('j1', 2, 3), location: '教二-202');
      await c.deleteOccurrence(cellAt('j1', 3, 3));
      final course = c
          .courseDetailChanges(cellAt('j1', 2, 1))
          .singleWhere(
            (group) => group.scope == CourseDetailChangeScope.course,
          );
      expect(
        course.changes.any(
          (change) =>
              change.field.startsWith('地点') &&
              change.before == '教一-101' &&
              change.after == '教二-202',
        ),
        isTrue,
      );
      expect(
        course.changes.any(
          (change) => change.field.contains('9月16日') && change.after == '已删除',
        ),
        isTrue,
      );
    });

    test('恢复原位置差异包含同一原时段的所有调课周次', () async {
      await seed([_jwxt('j1', '测试课程')]);
      await c.moveSlot(
        shown('j1'),
        0,
        toDay: 4,
        toStartPeriod: 3,
        week: 2,
        scope: MoveScope.thisWeek,
      );
      final remaining = shown('j1');
      final index = remaining.slots.indexWhere(
        (slot) => slot.day == 1 && slot.hasClassInWeek(3),
      );
      await c.moveSlot(
        remaining,
        index,
        toDay: 5,
        toStartPeriod: 5,
        week: 3,
        scope: MoveScope.thisWeek,
      );
      final position = c
          .courseDetailChanges(cellAt('j1', 2, 4))
          .singleWhere(
            (group) => group.scope == CourseDetailChangeScope.position,
          );
      expect(position.affectedScope, '第 2–3 周');
      expect(position.changes.map((change) => change.after).toSet(), {
        '周四 第 3–4 节',
        '周五 第 5–6 节',
      });
    });
  });

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

    test('第20周课程转换考试后浏览上限固定，隐藏考试与重启仍可访问', () async {
      await seed([
        _jwxt('keep', '保留课程', day: 2, weeks: '1${'0' * 19}'),
        _jwxt('convert', '期末课程', weeks: '${'0' * 19}1'),
      ]);
      final lastDate = _termStart.add(const Duration(days: 19 * 7));
      TimetableController.clock = () => lastDate;
      c.setViewingWeek(20);
      expect(c.totalWeeks, 20);
      expect(
        await c.convertCourseOccurrenceToExam(
          cell: cellAt('convert', 20, 1),
          title: '期末考试',
          location: '',
          note: '',
          day: 1,
          startNode: 1,
          endNode: 2,
        ),
        isNotNull,
      );
      expect(c.totalWeeks, 20);
      expect(c.viewingWeek, 20);
      await c.updateSettings(c.settings.copyWith(showExams: false));
      expect(c.totalWeeks, 20);
      expect(c.viewingWeek, 20);
      await restart();
      expect(c.totalWeeks, 20);
      expect(c.viewingWeek, 20);
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
  group('jwxt course edit / delete（§24.8）', () {
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
      expect(await c.restoreAllJwxt(), isFalse);
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

    test('JE13 JE20 rename/teacher edit/delete/restore never re-colours across schemes, sync and restart', () async {
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
      final colorsFile = File('${tmp.path}/${TimetableStore.courseColorsFile}');
      final colorsBefore = colorsFile.readAsStringSync();

      // 改成与 j3 同名，并改老师；不重写配色文件且各方案不改色
      await c.editJwxtCourse('j1', name: '线性代数', teacher: '李老师');
      expect(colorsFile.readAsStringSync(), colorsBefore);
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

      // 单独恢复、删除后全部恢复仍保持原色号
      final idx = expected['A']!['j1']!;
      await c.restoreJwxtCourse('j1');
      expect(c.colorIndexOf(shown('j1')), idx);
      await c.deleteJwxtCourse('j1');
      await c.restoreAllJwxt();
      expect(c.colorIndexOf(shown('j1')), idx);
      await restart();
      expect(c.colorIndexOf(shown('j1')), idx);
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
      await c.editJwxtCourse('j1', name: 'A', location: '教三-303', note: '带计算器');

      expect(await c.restoreJwxtCourse('j1'), isTrue);
      expect(c.courseEditOf('j1'), isNull);
      expect(c.slotOverrides.any((o) => o.courseId == 'j1'), isFalse);
      expect([for (final o in c.slotOverrides) o.id], j2Moves);
      expect(c.isJwxtOverridden(courseId: 'j1'), isFalse);
      expect(c.isJwxtOverridden(courseId: 'j2'), isTrue);
      expect(shown('j1').name, '高等数学');
      expect(shown('j1').slots.single.location, '教一-101');
      expect(shown('j1').slots.single.note, '');
      expect(c.cellsForDay(2, 1).any((g) => g.course.id == 'j1'), isTrue);
      expect(c.cellsForDay(2, 4).any((g) => g.course.id == 'j1'), isFalse);
    });
  });

  group('拖动调课覆盖与落点计算', () {
    const w16 = '1111111111111111';
    final dragSettings = TimetableSettings(
      termCode: '2026-2027-1',
      termStartDate: DateTime(2026, 8, 31),
      termStartFromJwxt: true,
    );
    final origFetch = TimetableController.fetchSnapshot;
    final origDragClock = TimetableController.clock;

    Course dragJwxt(
      String id,
      String name, {
      int day = 1,
      int start = 1,
      int end = 2,
      String weeks = w16,
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

    Course dragManual(String id, String name, {String weeks = '11111111'}) =>
        Course(
          id: id,
          name: name,
          colorIndex: 3,
          slots: [
            CourseSlot(
              day: 3,
              startNode: 5,
              endNode: 6,
              weeks: weeks,
              teacher: '教师O',
            ),
          ],
        );

    List<int> slotWeeks(CourseSlot s) => weeksOf(s);
    File dragFile(String name) => File('${tmp.path}/$name');
    Course jwxtEff(String id) => c.courses.firstWhere((x) => x.id == id);

    void loadDrag({List<Course>? jwxt, List<Course> manual = const []}) {
      c.debugSetSnapshot(
        TimetableSnapshot(
          courses: jwxt ?? [dragJwxt('K1|01', '高数')],
          settings: dragSettings,
          periods: TimetableController.defaultPeriods(),
        ),
        manualCourses: manual,
      );
    }

    setUp(() {
      TimetableController.clock = () => DateTime(2026, 10, 12);
    });

    tearDown(() {
      TimetableController.fetchSnapshot = origFetch;
      TimetableController.clock = origDragClock;
    });

    group('手动课拖动', () {
      test('只改本周 / 改以后所有周 / 单周课拆分及原时段清空删除', () async {
        loadDrag(manual: [dragManual('m1', '自选课')]);
        final r = await c.moveSlot(
          c.manualCourses.single,
          0,
          toDay: 2,
          toStartPeriod: 3,
          week: 3,
          scope: MoveScope.thisWeek,
        );
        expect(r.status, MoveStatus.moved);
        expect(r.affectedWeeks, [3]);
        final saved = c.manualCourses.single;
        expect(saved.slots, hasLength(2));
        expect(slotWeeks(saved.slots[0]), [1, 2, 4, 5, 6, 7, 8]);
        expect(saved.slots[0].day, 3);
        expect(slotWeeks(saved.slots[1]), [3]);
        expect(
          (
            saved.slots[1].day,
            saved.slots[1].startNode,
            saved.slots[1].endNode,
          ),
          (2, 3, 4),
        );
        expect(saved.slots[1].teacher, '教师O');
        expect(saved.colorIndex, 3);
        final disk = await TimetableStore.readManualCourses();
        expect(slotWeeks(disk.single.slots[1]), [3]);

        // 改以后所有周：w 之前留原位，w 及以后到新时段
        loadDrag(manual: [dragManual('m1', '自选课')]);
        final rFrom = await c.moveSlot(
          c.manualCourses.single,
          0,
          toDay: 4,
          toStartPeriod: 1,
          week: 5,
          scope: MoveScope.fromThisWeek,
        );
        expect(rFrom.affectedWeeks, [5, 6, 7, 8]);
        var slots = c.manualCourses.single.slots;
        expect(slotWeeks(slots[0]), [1, 2, 3, 4]);
        expect(slotWeeks(slots[1]), [5, 6, 7, 8]);

        // 单周课只移原时段实际有的周
        loadDrag(manual: [dragManual('m1', '单周课', weeks: '10101010')]);
        await c.moveSlot(
          c.manualCourses.single,
          0,
          toDay: 4,
          toStartPeriod: 1,
          week: 3,
          scope: MoveScope.fromThisWeek,
        );
        slots = c.manualCourses.single.slots;
        expect(slotWeeks(slots[0]), [1]);
        expect(slotWeeks(slots[1]), [3, 5, 7]);

        // 原时段周次变空就删掉
        loadDrag(manual: [dragManual('m1', '自选课')]);
        await c.moveSlot(
          c.manualCourses.single,
          0,
          toDay: 4,
          toStartPeriod: 1,
          week: 1,
          scope: MoveScope.fromThisWeek,
        );
        slots = c.manualCourses.single.slots;
        expect(slots, hasLength(1));
        expect(slots.single.day, 4);
        expect(slotWeeks(slots.single), [1, 2, 3, 4, 5, 6, 7, 8]);
      });

      test('落回原位不写盘；越界与非法输入返回对应 MoveError', () async {
        loadDrag(manual: [dragManual('m1', '自选课')]);
        final course = c.manualCourses.single;
        final noChange = await c.moveSlot(
          course,
          0,
          toDay: 3,
          toStartPeriod: 5,
          week: 2,
          scope: MoveScope.thisWeek,
        );
        expect(noChange.status, MoveStatus.noChange);
        expect(dragFile('manual_courses.json').existsSync(), isFalse);
        expect(dragFile('overrides.json').existsSync(), isFalse);

        Future<MoveResult> mv(int day, int start, int week, [int idx = 0]) =>
            c.moveSlot(
              course,
              idx,
              toDay: day,
              toStartPeriod: start,
              week: week,
              scope: MoveScope.thisWeek,
            );
        expect((await mv(1, 11, 1)).error, MoveError.pastLastPeriod);
        expect((await mv(1, 10, 1)).status, MoveStatus.moved);
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
        loadDrag();
        final r = await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
        expect(r.ok, isTrue);
        expect(c.jwxtCourses.single.slots.single.weeks, w16);
        final eff = jwxtEff('K1|01');
        expect(eff.slots, hasLength(2));
        expect(slotWeeks(eff.slots[0]), [
          for (var w = 1; w <= 16; w++)
            if (w != 6) w,
        ]);
        expect(slotWeeks(eff.slots[1]), [6]);
        expect(eff.slots[1].day, 3);
        expect(eff.slots[1].teacher, '教师N');
        expect(c.overrideInfoFor(eff, 1)?.originalDay, 1);
        expect(c.overrideInfoFor(eff, 1)?.originalStart, 1);
        expect(c.overrideInfoFor(eff, 1)?.originalEnd, 2);
        expect(c.overrideInfoFor(eff, 0), isNull);
        expect(c.hasOverride(eff, 1), isTrue);
        final json =
            jsonDecode(dragFile('overrides.json').readAsStringSync()) as Map;
        final rec = (json['overrides'] as List).single as Map;
        expect(rec['courseId'], 'K1|01');
        expect(rec['origDay'], 1);
        expect(rec['origWeeks'], w16);
        expect(rec['weeks'], [6]);
        expect(rec['scope'], 'thisWeek');
        expect([rec['toDay'], rec['toStart'], rec['toEnd']], [3, 5, 6]);
        expect(
          c.cellsForDay(6, 3).where((x) => x.activeThisWeek),
          hasLength(1),
        );
        expect(c.cellsForDay(6, 1).where((x) => x.activeThisWeek), isEmpty);
        expect(
          c.cellsForDay(7, 1).where((x) => x.activeThisWeek),
          hasLength(1),
        );
        expect(c.totalWeeks, 20);
      });

      test('再拖回原位：记录合并消失', () async {
        loadDrag();
        await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
        final r = await moveJ(1, 1, 1, 6, MoveScope.thisWeek);
        expect(r.ok, isTrue);
        expect(c.slotOverrides, isEmpty);
        expect(jwxtEff('K1|01').slots.single.weeks, w16);
      });

      test('多次移动后恢复原位置一次清掉全部记录', () async {
        loadDrag();
        await moveJ(0, 3, 5, 10, MoveScope.fromThisWeek);
        var eff = jwxtEff('K1|01');
        expect(slotWeeks(eff.slots[1]), [10, 11, 12, 13, 14, 15, 16]);
        await moveJ(1, 5, 7, 12, MoveScope.thisWeek);
        eff = jwxtEff('K1|01');
        expect(eff.slots, hasLength(3));
        expect(slotWeeks(eff.slots[2]), [12]);
        expect(c.overrideInfoFor(eff, 2)?.originalDay, 1);
        expect(await c.restoreOverride(eff, 2), isTrue);
        expect(c.slotOverrides, isEmpty);
        expect(jwxtEff('K1|01').slots.single.weeks, w16);
        expect(await c.restoreOverride(jwxtEff('K1|01'), 0), isFalse);
      });

      test('冲突：本周只查 w；以后所有周查全部周，课名排序', () async {
        loadDrag(
          jwxt: [
            dragJwxt('K1|01', '高数'),
            dragJwxt('K2|01', '物理', day: 3, start: 5, end: 6, weeks: '0000001'),
            dragJwxt(
              'K3|01',
              '化学',
              day: 3,
              start: 6,
              end: 7,
              weeks: '0000000001',
            ),
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
        dragFile('overrides.json').writeAsStringSync(
          jsonEncode({
            'futureKey': {'a': 1},
            'overrides': [
              {'garbage': true},
            ],
          }),
        );
        await c.ensureStarted();
        loadDrag();
        await moveJ(0, 3, 5, 6, MoveScope.thisWeek);
        final json =
            jsonDecode(dragFile('overrides.json').readAsStringSync()) as Map;
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
            TimetableSnapshot(courses: remote, settings: dragSettings);
      }

      List<dynamic> diskOverrides() =>
          (jsonDecode(dragFile('overrides.json').readAsStringSync())
                  as Map)['overrides']
              as List;

      test('同步保留未变记录；SKZC/星期/节次变化或原课删除只清失效记录', () async {
        loadDrag(
          jwxt: [dragJwxt('K1|01', '高数'), dragJwxt('K2|01', '物理', day: 2)],
        );
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

        // 1) 原数据未变：全部保留并继续套用
        remote = [dragJwxt('K1|01', '高数'), dragJwxt('K2|01', '物理', day: 2)];
        useRemote();
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.success);
        expect(c.slotOverrides, hasLength(2));
        expect(c.orphanedOverrideIds, isEmpty);
        expect(slotWeeks(jwxtEff('K1|01').slots[1]), [6]);
        expect(diskOverrides(), hasLength(2));

        // 2) K1 的 SKZC 变了：只删 K1，保留 K2
        remote = [
          dragJwxt('K1|01', '高数', weeks: '1111111111111100'),
          dragJwxt('K2|01', '物理', day: 2),
        ];
        await c.syncFromJwxt();
        expect(c.slotOverrides.single.courseId, 'K2|01');
        expect(jwxtEff('K1|01').slots.single.weeks, '1111111111111100');
        expect(c.hasOverride(jwxtEff('K1|01'), 0), isFalse);
        expect(jwxtEff('K2|01').slots, hasLength(2));

        // 3) K2 原时段时间变了（星期或起止节）→ 删记录；重新移动后原课被删 → 删记录
        remote = [
          dragJwxt('K1|01', '高数'),
          dragJwxt('K2|01', '物理', day: 2, start: 3, end: 4),
        ];
        await c.syncFromJwxt();
        expect(c.slotOverrides, isEmpty);
        expect(
          (
            jwxtEff('K2|01').slots.single.day,
            jwxtEff('K2|01').slots.single.startNode,
            jwxtEff('K2|01').slots.single.endNode,
          ),
          (2, 3, 4),
        );
        expect(diskOverrides(), isEmpty);

        await moveK1();
        remote = [dragJwxt('K2|01', '物理', day: 2)];
        await c.syncFromJwxt();
        expect(c.slotOverrides, isEmpty);
        expect(c.courses.any((x) => x.id == 'K1|01'), isFalse);
        expect(diskOverrides(), isEmpty);
      });

      test('解绑与同步失败保留记录，重启重绑匹配则恢复套用、变更则清除', () async {
        loadDrag();
        await moveK1();
        await c.handleLogout();
        expect(c.jwxtCourses, isEmpty);
        expect(c.slotOverrides, hasLength(1));
        expect(c.orphanedOverrideIds, hasLength(1));
        expect(diskOverrides(), hasLength(1));

        TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
            throw Exception('network');
        await c.syncFromJwxt();
        expect(c.syncStatus, TimetableSyncStatus.failure);
        expect(c.slotOverrides, hasLength(1));
        expect(diskOverrides(), hasLength(1));

        // 重启后重新绑定同步原数据：重新套用
        c.debugReset();
        remote = [dragJwxt('K1|01', '高数')];
        useRemote();
        await c.ensureStarted();
        expect(c.slotOverrides, hasLength(1));
        await c.syncFromJwxt();
        expect(c.slotOverrides, hasLength(1));
        expect(slotWeeks(jwxtEff('K1|01').slots[1]), [6]);

        // 同步到周次变更后失效清除
        remote = [dragJwxt('K1|01', '高数', weeks: '1111111100000000')];
        await c.syncFromJwxt();
        expect(c.slotOverrides, isEmpty);
        expect(diskOverrides(), isEmpty);
      });

      test('手动课不受同步失效规则影响', () async {
        loadDrag(manual: [dragManual('m1', '自选课')]);
        await c.moveSlot(
          c.manualCourses.single,
          0,
          toDay: 2,
          toStartPeriod: 3,
          week: 3,
          scope: MoveScope.thisWeek,
        );
        await moveK1();
        remote = [];
        useRemote();
        await c.syncFromJwxt();
        expect(c.slotOverrides, isEmpty);
        final m = c.manualCourses.single;
        expect(m.slots, hasLength(2));
        expect(slotWeeks(m.slots[1]), [3]);
        expect(m.slots[1].day, 2);
        expect(c.courses.any((x) => x.id == 'm1'), isTrue);
      });

      test('旧记录缺 origWeeks → 视为未知：不渲染，下次同步删除', () async {
        dragFile('overrides.json').writeAsStringSync(
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
        loadDrag();
        expect(c.slotOverrides.single.origWeeks, '');
        expect(c.orphanedOverrideIds, {'old-1'});
        expect(jwxtEff('K1|01').slots, hasLength(1));
        remote = [dragJwxt('K1|01', '高数')];
        useRemote();
        await c.syncFromJwxt();
        expect(c.slotOverrides, isEmpty);
        final json =
            jsonDecode(dragFile('overrides.json').readAsStringSync()) as Map;
        expect(json['futureKey'], 'keep');
        expect(json['overrides'], [
          {'garbage': true},
        ]);
      });

      test('staleOverrideIds 纯函数', () {
        SlotOverride rec(String id, String cid, {String ow = w16}) =>
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
        final jwxt = [dragJwxt('K1|01', '高数'), dragJwxt('K2|01', '物理', day: 2)];
        expect(
          staleOverrideIds(jwxt, [
            rec('keep', 'K1|01'),
            rec('gone', 'K9|01'),
            rec('skzc', 'K1|01', ow: '1111'),
            rec('slot', 'K2|01'),
            rec('noow', 'K1|01', ow: ''),
          ]),
          {'gone', 'skzc', 'slot', 'noow'},
        );
        expect(
          staleOverrideIds([dragManual('K1|01', '自选课')], [rec('m', 'K1|01')]),
          {'m'},
        );
      });
    });

    test('scheduleChanged 在各类变动后触发', () async {
      final got = <ScheduleChangeReason>[];
      final sub = c.scheduleChanged.listen(got.add);
      loadDrag(manual: [dragManual('m1', '自选课')]);
      await c.moveSlot(
        jwxtEff('K1|01'),
        0,
        toDay: 3,
        toStartPeriod: 1,
        week: 6,
        scope: MoveScope.thisWeek,
      );
      await c.restoreOverride(jwxtEff('K1|01'), 1);
      await c.addManualCourse(dragManual('', '新课'));
      await c.deleteManualCourse('m1');
      await c.updateSettings(c.settings.copyWith(reminderLeadMinutes: 10));
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: [dragJwxt('K1|01', '高数')],
            settings: dragSettings,
          );
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
      loadDrag();
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

    group('resolveDropSlot 松手落点', () {
      const days7 = [1, 2, 3, 4, 5, 6, 7];
      ({int column, int day, int startPeriod}) drop(
        double left,
        double top, {
        List<int> days = days7,
        int span = 2,
        int lastPeriod = 12,
        DropTieBreak tie = kDropTieBreak,
      }) => resolveDropSlot(
        left: left,
        top: top,
        dayWidth: 50,
        periodHeight: 60,
        visibleDays: days,
        span: span,
        lastPeriod: lastPeriod,
        tieBreak: tie,
      );

      test('列定位、节次四舍五入与平局取向（earlier / later）', () {
        expect(drop(0, 0).day, 1);
        expect(drop(24, 0).day, 1);
        expect(drop(26, 0).day, 2);
        expect(drop(70, 0).day, 2);
        expect(drop(80, 0).day, 3);

        expect(drop(0, 29).startPeriod, 1);
        expect(drop(0, 31).startPeriod, 2);
        expect(drop(0, 96).startPeriod, 3);
        expect(drop(0, 140).startPeriod, 3);

        expect(kDropTieBreak, DropTieBreak.earlier);
        expect(drop(25, 0).day, 1);
        expect(drop(75, 0).day, 2);
        expect(drop(0, 30).startPeriod, 1);
        expect(drop(0, 150).startPeriod, 3);
        expect(drop(25, 30, tie: DropTieBreak.later), (
          column: 1,
          day: 2,
          startPeriod: 2,
        ));
      });

      test('越界夹紧与仅在可见列/周日首列中取值', () {
        expect(drop(0, 60 * 20).startPeriod, 11);
        expect(drop(0, 60 * 20, span: 3).startPeriod, 10);
        expect(drop(0, 60 * 20, span: 1).startPeriod, 12);
        expect(drop(0, -500).startPeriod, 1);
        expect(drop(-500, 0).day, 1);
        expect(drop(5000, 0).day, 7);
        expect(drop(0, 300, span: 14).startPeriod, 1);

        const weekdays = [1, 2, 3, 4, 5];
        expect(drop(5000, 0, days: weekdays), (
          column: 4,
          day: 5,
          startPeriod: 1,
        ));
        const sundayFirst = [7, 1, 2, 3, 4, 5];
        expect(drop(0, 0, days: sundayFirst).day, 7);
        expect(drop(5000, 0, days: sundayFirst).day, 5);
        expect(drop(60, 0, days: sundayFirst).day, 1);
      });
    });
  });
}
