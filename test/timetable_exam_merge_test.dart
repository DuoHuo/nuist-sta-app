// 考试列表合并去重（timetable_exam_merge.dart）与考试卡/列表数据源回归。
// 数据全部构造（课名「测试课程X」、地点「测试楼 A101」），不读真实样例。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exam_merge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

final _c = TimetableController.instance;

final _day = DateTime(2026, 10, 20);
final _today = DateTime(2026, 10, 12);

ScheduleEvent _exam(
  String id,
  String title, {
  DateTime? date,
  int sh = 9,
  int sm = 0,
  int eh = 11,
  int em = 0,
  ScheduleSource source = ScheduleSource.manual,
  String location = '',
  String note = '',
  String? courseCode,
}) => ScheduleEvent(
  id: id,
  kind: ScheduleKind.exam,
  source: source,
  title: title,
  date: date ?? _day,
  start: TimeOfDayMinutes(sh, sm),
  end: TimeOfDayMinutes(eh, em),
  location: location,
  note: note,
  courseCode: courseCode,
);

void main() {
  group('normalizeExamTitle', () {
    test('去除首尾与内部空白（含全角空格），括号统一为全角', () {
      expect(normalizeExamTitle('  高等数学 (上)  '), '高等数学（上）');
      expect(normalizeExamTitle('高等　数学'), '高等数学');
      expect(normalizeExamTitle('大学 英语（1）'), '大学英语（1）');
      expect(normalizeExamTitle('大学\t英语\n（1）'), '大学英语（1）');
    });

    test('全角与半角括号归一到同一写法', () {
      expect(normalizeExamTitle('测试课程(1)'), normalizeExamTitle('测试课程（1）'));
    });

    test('不影响配色用的 normalizeCourseName（保留内部空白）', () {
      expect(normalizeCourseName(' 大学 英语(1) '), '大学 英语（1）');
    });
  });

  group('mergeExams', () {
    test('同日时间重叠：保留教务条目，并补全 location / note', () {
      final jwxt = _exam(
        'jwxt-1',
        '高等数学（上）',
        source: ScheduleSource.jwxt,
        courseCode: '00000001',
      );
      final manual = _exam(
        'manual-1',
        '高等数学 (上)',
        sh: 9,
        sm: 30,
        eh: 10,
        em: 30,
        location: '测试楼 A101',
        note: '座位号 12',
      );

      final got = mergeExams([jwxt, manual]);
      expect(got, hasLength(1));
      final e = got.single;
      expect(e.id, 'jwxt-1');
      expect(e.source, ScheduleSource.jwxt);
      expect(e.title, '高等数学（上）');
      expect(e.courseCode, '00000001');
      expect(e.location, '测试楼 A101');
      expect(e.note, '座位号 12');
      expect(e.start, const TimeOfDayMinutes(9, 0));
      expect(e.end, const TimeOfDayMinutes(11, 0));
    });

    test('教务条目已有字段不被手动条目覆盖', () {
      final jwxt = _exam(
        'jwxt-1',
        '测试课程甲',
        source: ScheduleSource.jwxt,
        location: '教务楼 B202',
        note: '教务备注',
        courseCode: '00000001',
      );
      final manual = _exam(
        'manual-1',
        '测试课程甲',
        location: '测试楼 A101',
        note: '座位号 12',
      );

      final e = mergeExams([jwxt, manual]).single;
      expect(e.location, '教务楼 B202');
      expect(e.note, '教务备注');
      expect(e.courseCode, '00000001');
    });

    test('同名同日但时间不重叠（仅端点相接）保留两场', () {
      final a = _exam('a', '测试课程甲', eh: 11, em: 0);
      final b = _exam('b', '测试课程甲', sh: 11, sm: 0, eh: 13, em: 0);
      expect(mergeExams([a, b]).map((e) => e.id), ['a', 'b']);
    });

    test('同日时间重叠但课名不同不合并', () {
      final a = _exam('a', '测试课程甲');
      final b = _exam('b', '测试课程乙', sh: 10, eh: 12);
      expect(mergeExams([a, b]).map((e) => e.id), ['a', 'b']);
    });

    test('同名同时间但日期不同不合并', () {
      final a = _exam('a', '测试课程甲');
      final b = _exam('b', '测试课程甲', date: DateTime(2026, 10, 21));
      expect(mergeExams([a, b]).map((e) => e.id), ['a', 'b']);
    });

    test('只有手动或只有教务：原样返回', () {
      final manual = _exam('m', '测试课程甲');
      expect(mergeExams([manual]).single.id, 'm');
      final jwxt = _exam(
        'j',
        '测试课程乙',
        source: ScheduleSource.jwxt,
        courseCode: '00000002',
      );
      expect(mergeExams([jwxt]).single.id, 'j');
    });

    test('两条都是手动：保留先出现的一条并补全空字段', () {
      final first = _exam('m1', '测试课程甲');
      final second = _exam(
        'm2',
        '测试 课程甲',
        sh: 9,
        sm: 30,
        eh: 10,
        location: '测试楼 A101',
        note: '座位号 12',
      );
      final e = mergeExams([first, second]).single;
      expect(e.id, 'm1');
      expect(e.source, ScheduleSource.manual);
      expect(e.location, '测试楼 A101');
      expect(e.note, '座位号 12');
    });
  });

  group('考试列表数据源', () {
    late Directory tmp;
    final origClock = TimetableController.clock;
    final origBinding = TimetableController.bindingCheck;
    final origFetch = TimetableController.fetchSnapshot;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_exam_merge');
      TimetableStore.debugDirectory = tmp;
      _c.debugReset();
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const SocketException('offline (test)');
      TimetableController.clock = () => _today;
    });

    tearDown(() async {
      TimetableController.clock = origClock;
      TimetableController.bindingCheck = origBinding;
      TimetableController.fetchSnapshot = origFetch;
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('showExams=false 时仍返回去重后的考试（教务优先）', () async {
      _c.debugSetSnapshot(
        TimetableSnapshot(
          courses: const [],
          periods: TimetableController.defaultPeriods(),
          settings: TimetableSettings(
            termStartDate: DateTime(2026, 8, 31),
            showExams: false,
          ),
        ),
      );
      final upcomingJwxt = _exam(
        'jwxt-up',
        '测试课程甲',
        source: ScheduleSource.jwxt,
        courseCode: '00000001',
      );
      final pastJwxt = _exam(
        'jwxt-past',
        '测试课程乙',
        date: DateTime(2026, 10, 11),
        source: ScheduleSource.jwxt,
        courseCode: '00000002',
      );
      await _c.replaceJwxtExams([upcomingJwxt, pastJwxt]);
      await _c.addScheduleEvent(
        _exam(
          'manual-up',
          '测试课程甲',
          sh: 9,
          sm: 30,
          eh: 10,
          location: '测试楼 A101',
          note: '座位号 12',
        ),
      );
      await _c.addScheduleEvent(
        _exam(
          'manual-past',
          '测试课程乙',
          date: DateTime(2026, 10, 11),
          sh: 10,
          eh: 12,
          location: '测试楼 B202',
        ),
      );

      final upcoming = upcomingExams(_c, today: _today);
      expect(upcoming, hasLength(1));
      expect(upcoming.single.id, 'jwxt-up');
      expect(upcoming.single.location, '测试楼 A101');
      expect(upcoming.single.note, '座位号 12');

      final past = pastExams(_c, today: _today);
      expect(past, hasLength(1));
      expect(past.single.id, 'jwxt-past');
      expect(past.single.location, '测试楼 B202');

      // 周课表仍受 showExams 开关控制，不受本次合并影响。
      expect(_c.scheduleEventsOn(_day), isEmpty);
      expect(_c.scheduleEvents.where((e) => e.isExam), hasLength(4));
    });
  });
}
