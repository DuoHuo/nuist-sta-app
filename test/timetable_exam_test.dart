import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exam_merge.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exam_parser.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_store.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/timetable/$name').readAsStringSync())
        as Map<String, dynamic>;

List<ScheduleEvent> _parse(String name) =>
    ExamParser.parse(_fixture(name)).exams;

final _c = TimetableController.instance;

ScheduleEvent _manual(String id, {ScheduleKind kind = ScheduleKind.exam}) =>
    ScheduleEvent(
      id: id,
      kind: kind,
      source: ScheduleSource.manual,
      title: '测试手动$id',
      date: DateTime(2027, 1, 4),
      start: const TimeOfDayMinutes(9, 0),
      end: const TimeOfDayMinutes(10, 0),
    );

ScheduleEvent _mergeExam(
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
  date: date ?? DateTime(2026, 10, 20),
  start: TimeOfDayMinutes(sh, sm),
  end: TimeOfDayMinutes(eh, em),
  location: location,
  note: note,
  courseCode: courseCode,
);

void main() {
  group('ExamParser（纯函数）', () {
    test('EX01 EX35 EX36 exam_mock / empty 解析完整、未排跳过且脱敏不落敏感字段', () {
      final r = ExamParser.parse(_fixture('exam_mock.json'));
      expect(r.exams, hasLength(2));
      expect(r.skippedCourseCodes, isEmpty);

      final a = r.exams[0];
      expect(a.kind, ScheduleKind.exam);
      expect(a.source, ScheduleSource.jwxt);
      expect(a.title, '示例课程甲');
      expect(a.courseCode, '00000001');
      expect(a.date, DateTime(2027, 1, 5));
      expect(a.start, const TimeOfDayMinutes(9, 0));
      expect(a.end, const TimeOfDayMinutes(11, 0));
      expect(a.location, '示例楼A101');
      expect(a.note, '请携带学生证');
      expect(a.jwxtKey, '00000001|2027-01-05|09:00');
      expect(a.id, 'jwxt-exam:00000001|2027-01-05|09:00');

      final b = r.exams[1];
      expect(b.title, '示例课程乙');
      expect(b.location, '示例楼B202');
      expect(b.note, '');
      expect(r.exams.map((e) => e.courseCode), isNot(contains('00000003')));

      final json = jsonEncode([for (final e in r.exams) e.toJson()]);
      for (final s in [
        '202512340001',
        '张老师',
        '李老师',
        'synthetic-',
        'XH',
        'ZJJSXM',
        'KSDM',
      ]) {
        expect(json, isNot(contains(s)), reason: s);
      }

      final empty = ExamParser.parse(_fixture('exam_mock_empty.json'));
      expect(empty.exams, isEmpty);
      expect(empty.skippedCourseCodes, isEmpty);
    });

    test('EX34 EX37 缺失字段保留有效行、location 回退 JXLMC、非法响应整批抛错', () {
      final r = ExamParser.parse(_fixture('exam_mock_missing_fields.json'));
      final e = r.exams.single;
      expect(e.courseCode, '00000006');
      expect(e.title, '示例课程庚（无教室无座位，应保留）');
      expect(e.date, DateTime(2027, 1, 7));
      expect(e.location, '');
      expect(e.note, '');
      expect(r.skippedCourseCodes, containsAll(['00000005', '']));
      expect(r.skippedCourseCodes, isNot(contains('00000006')));

      final rows =
          ((_fixture('exam_mock.json')['datas'] as Map)['cxxsksap']
                  as Map)['rows']
              as List;
      final first = Map<String, Object?>.from(rows[0] as Map);
      final noRoom = ExamParser.parseRow({...first, 'JASMC': ''});
      expect(noRoom, isA<ExamRowOk>());
      expect((noRoom as ExamRowOk).exam.location, '示例楼');
      final none = ExamParser.parseRow({...first, 'JASMC': '', 'JXLMC': ''});
      expect((none as ExamRowOk).exam.location, '');

      expect(
        () => ExamParser.parse({...(_fixture('exam_mock.json')), 'code': '1'}),
        throwsA(isA<ExamResponseError>()),
      );
      expect(() => ExamParser.parse(null), throwsA(isA<ExamResponseError>()));
      expect(
        () => ExamParser.parse({'code': '0', 'datas': {}}),
        throwsA(isA<ExamResponseError>()),
      );
    });

    test('日期/时间格式校验、异常与未排分类及同一 examKey 去重', () {
      expect(ExamParser.parseExamDate('2027-01-05'), DateTime(2027, 1, 5));
      for (final bad in ['2027/01/05', '2027-1-5', '2027-02-30', '20270105']) {
        expect(ExamParser.parseExamDate(bad), isNull, reason: bad);
      }
      Map<String, Object?> row(Map<String, Object?> o) => {
        'KCH': '00000009',
        'KCM': '示例课程',
        'KSRQ': '2027-01-08',
        'KSKSSJ': '09:00',
        'KSJSSJ': '11:00',
        'SFAPSJ': '1',
        ...o,
      };
      expect(ExamParser.parseRow(row({})), isA<ExamRowOk>());
      expect(
        ExamParser.parseRow(row({'KSKSSJ': '9:00'})),
        isA<ExamRowMalformed>(),
      );
      expect(
        ExamParser.parseRow(row({'KSJSSJ': '08:00'})),
        isA<ExamRowMalformed>(),
      );
      expect(ExamParser.parseRow(row({'KCH': ''})), isA<ExamRowMalformed>());
      expect(
        ExamParser.parseRow(row({'SFAPSJ': '0'})),
        isA<ExamRowUnscheduled>(),
      );
      expect(ExamParser.parseRow(row({'KSRQ': ''})), isA<ExamRowUnscheduled>());
      final ok =
          ExamParser.parseRow(row({'JXLMC': '示例楼', 'KCM': ''})) as ExamRowOk;
      expect(ok.exam.location, '示例楼');
      expect(ok.exam.title, '00000009');

      final dedup = ExamParser.parseRows([
        row({}),
        row({'JASMC': '另一间'}),
      ]);
      expect(dedup.exams, hasLength(1));
      expect(dedup.exams.single.location, '');
    });

    test('教务备注移除自动审核说明并忽略纯座位号冗余备注', () {
      expect(ExamParser.cleanRemark(''), '');
      expect(ExamParser.cleanRemark('带笔'), '带笔');
      expect(ExamParser.cleanRemark('考试审核通过生成考试安排'), '');
      expect(
        ExamParser.cleanRemark('  考试审核通过生成考试安排\r\n请携带学生证\n带笔'),
        '请携带学生证\n带笔',
      );
      expect(ExamParser.cleanRemark('请确认考试审核通过生成的通知'), '请确认考试审核通过生成的通知');
      final result = ExamParser.parseRow({
        'KCH': '00000009',
        'KCM': '示例课程',
        'KSRQ': '2027-01-08',
        'KSKSSJ': '09:00',
        'KSJSSJ': '11:00',
        'SFAPSJ': '1',
        'ZWH': '12',
        'BZ': '考试审核通过生成考试安排',
      }) as ExamRowOk;
      expect(result.exam.note, isEmpty);
    });
  });

  group('TimetableApi.fetchExams', () {
    tearDown(() => TimetableApi.debugPost = null);

    test('请求 studentWdksapApp cxxsksap.do，表单 requestParamStr 带学期', () async {
      Uri? url;
      Map<String, String>? form;
      TimetableApi.debugPost = (u, f) async {
        url = u;
        form = f;
        return _fixture('exam_mock.json');
      };
      final exams = await TimetableApi.fetchExams('2026-2027-1');
      expect(exams, hasLength(2));
      expect(
        url!.path,
        endsWith('/jwapp/sys/studentWdksapApp/WdksapController/cxxsksap.do'),
      );
      expect(form!.keys, ['requestParamStr']);
      final p = jsonDecode(form!['requestParamStr']!) as Map<String, dynamic>;
      expect(p['XNXQDM'], '2026-2027-1');
      expect(p['*order'], '-KSRQ,-KSSJMS');
    });

    test('非 JSON → 抛错', () async {
      TimetableApi.debugPost = (u, f) async => null;
      await expectLater(
        TimetableApi.fetchExams('2026-2027-1'),
        throwsA(isA<ExamResponseError>()),
      );
    });
  });

  group('同步集成（TimetableController）', () {
    late Directory tmp;
    final now = DateTime(2026, 12, 1, 8);
    final origFetchExams = TimetableController.fetchExams;
    final origFetchSnapshot = TimetableController.fetchSnapshot;
    final origClock = TimetableController.clock;
    final origSyncClock = TimetableController.syncClock;
    final origBinding = TimetableController.bindingCheck;
    var examCalls = 0;
    Future<List<ScheduleEvent>?> Function(String term) exams = (_) async =>
        const [];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_exam_fetch');
      TimetableStore.debugDirectory = tmp;
      examCalls = 0;
      TimetableController.clock = () => DateTime(2026, 12, 1);
      TimetableController.syncClock = () => now;
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: const [
              Course(
                id: 'j1',
                name: '示例课程甲',
                source: CourseSource.jwxt,
                slots: [
                  CourseSlot(
                    day: 1,
                    startNode: 1,
                    endNode: 2,
                    weeks: '1111111111111111',
                  ),
                ],
              ),
            ],
            periods: TimetableController.defaultPeriods(),
            settings: (baseSettings ?? const TimetableSettings()).copyWith(
              termCode: '2026-2027-1',
            ),
          );
      TimetableController.fetchExams = (term) {
        examCalls++;
        return exams(term);
      };
      _c.debugReset();
      await _c.ensureStarted();
    });

    tearDown(() async {
      TimetableController.fetchExams = origFetchExams;
      TimetableController.fetchSnapshot = origFetchSnapshot;
      TimetableController.clock = origClock;
      TimetableController.syncClock = origSyncClock;
      TimetableController.bindingCheck = origBinding;
      TimetableStore.debugDirectory = null;
      _c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    List<ScheduleEvent> jwxtExams() => [
      for (final e in _c.scheduleEvents)
        if (e.isFromJwxt) e,
    ];

    test('EX01 课表成功后拉考试并入库；学号、教师等不进 schedule_events.json', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      expect(examCalls, 1);
      expect(_c.statusIsSuccess, isTrue);
      expect(jwxtExams().map((e) => e.courseCode), ['00000001', '00000002']);
      final raw = File('${tmp.path}/${ScheduleStore.scheduleEventsFile}')
          .readAsStringSync();
      expect(raw, contains('示例课程甲'));
      for (final s in ['202512340001', '张老师', 'synthetic-', 'ZJJSXM']) {
        expect(raw, isNot(contains(s)), reason: s);
      }
    });

    test('EX08 关闭课表考试显示仍同步入库，考试卡片与列表查询保留数据', () async {
      await _c.updateSettings(_c.settingsForEditing.copyWith(showExams: false));
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      expect(_c.settings.showExams, isFalse);
      expect(examCalls, 1);
      expect(jwxtExams(), hasLength(2));
      expect(
        (await ScheduleStore.readEvents()).where((e) => e.isFromJwxt),
        hasLength(2),
      );
      final storedIds = jwxtExams().map((e) => e.id).toSet();
      expect(upcomingExams(_c, today: now).map((e) => e.id).toSet(), storedIds);
      expect(
        pastExams(_c, today: DateTime(2027, 2)).map((e) => e.id).toSet(),
        storedIds,
      );
      final examDate = jwxtExams().first.date;
      expect(_c.scheduleEventsOn(examDate), isEmpty);
      await _c.updateSettings(_c.settings.copyWith(showExams: true));
      expect(_c.scheduleEventsOn(examDate), hasLength(2));
      expect(examCalls, 1, reason: '切换显示无需重新拉取考试');
    });

    test('EX33 exam_mock_empty.json：清掉教务考试，手动日程保留', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      await _c.addScheduleEvent(_manual('m1'));
      await _c.addScheduleEvent(_manual('m2', kind: ScheduleKind.other));
      final manualBefore = [
        for (final e in _c.scheduleEvents)
          if (!e.isFromJwxt) jsonEncode(e.toJson()),
      ];
      exams = (_) async => _parse('exam_mock_empty.json');
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isTrue);
      expect(jwxtExams(), isEmpty);
      expect([
        for (final e in _c.scheduleEvents)
          if (!e.isFromJwxt) jsonEncode(e.toJson()),
      ], manualBefore);
      expect(_c.scheduleEvents.map((e) => e.id), containsAll(['m1', 'm2']));
    });

    test('EX34 exam_mock_missing_fields.json：只入库第 4 行（整批成功）', () async {
      exams = (_) async => _parse('exam_mock_missing_fields.json');
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isTrue);
      expect(jwxtExams().single.courseCode, '00000006');
    });

    test('EX14 EX15 EX19 覆盖记录：考试不变时保留，教务改了时间后清除', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final a = jwxtExams().firstWhere((e) => e.courseCode == '00000001');
      await _c.updateScheduleEvent(a.copyWith(location: '测试楼自改'));
      final key = a.jwxtKey!;
      expect(_c.isJwxtOverridden(examKey: key), isTrue);

      await _c.syncFromJwxt();
      expect(_c.isJwxtOverridden(examKey: key), isTrue);
      expect(
        _c.scheduleEvents.firstWhere((e) => e.id == a.id).location,
        '测试楼自改',
      );
      expect((await ScheduleStore.readExamOverrides()).keys, contains(key));

      final changed = _fixture('exam_mock.json');
      final rows =
          ((changed['datas'] as Map)['cxxsksap'] as Map)['rows'] as List;
      (rows[0] as Map)['KSKSSJ'] = '09:30';
      exams = (_) async => ExamParser.parse(changed).exams;
      await _c.syncFromJwxt();
      expect(_c.isJwxtOverridden(examKey: key), isFalse);
      expect((await ScheduleStore.readExamOverrides()), isEmpty);
      final moved = jwxtExams().firstWhere((e) => e.courseCode == '00000001');
      expect(moved.start, const TimeOfDayMinutes(9, 30));
      expect(moved.id, isNot(a.id));
      expect(_c.scheduleEvents.any((e) => e.id == a.id), isFalse);
      expect(moved.location, '示例楼A101');
    });

    test('只替换了课表拉取的测试不发真实考试请求（默认钩子返回 null，已有考试保留）', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      TimetableController.fetchExams = origFetchExams;
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isTrue);
      expect(jwxtExams(), hasLength(2));
    });

    test('EX30 课表请求完成后才发考试请求；课表失败不拉考试', () async {
      final order = <String>[];
      final okSnapshot = TimetableController.fetchSnapshot;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        final s = await okSnapshot(term, baseSettings: baseSettings);
        order.add('kb-done');
        return s;
      };
      exams = (_) async {
        order.add('exam');
        return _parse('exam_mock.json');
      };
      await _c.syncFromJwxt();
      expect(order, ['kb-done', 'exam']);

      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const JwxtHttpError('kb', 500);
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isFalse);
      expect(examCalls, 1);
    });

    test('EX11 EX31 考试拉取失败（离线/500/timeout/code≠0/跳登录页）：课表照常更新，旧考试保留', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final before = jwxtExams().map((e) => e.id).toList();
      final failures = <String, Object>{
        'offline': const SocketException('offline'),
        '500': const JwxtHttpError('cxxsksap.do', 500),
        'timeout': TimeoutException('t'),
        'code≠0': const ExamResponseError('code=1'),
        '跳登录页': const JwxtSessionExpiredError('重新登录后教务仍要求登录'),
      };
      var step = 1;
      for (final entry in failures.entries) {
        final later = now.add(Duration(hours: step++));
        TimetableController.syncClock = () => later;
        exams = (_) async => throw entry.value;
        await _c.syncFromJwxt();
        expect(_c.statusIsSuccess, isTrue, reason: entry.key);
        expect(_c.syncFailure, TimetableSyncFailure.none, reason: entry.key);
        expect(_c.snapshot.lastError, isNull, reason: entry.key);
        expect(_c.lastSyncSuccessAt, later, reason: entry.key);
        expect(
          await ScheduleStore.readLastSyncSuccess(),
          later,
          reason: entry.key,
        );
        expect(jwxtExams().map((e) => e.id), before, reason: entry.key);
        expect(
          (await ScheduleStore.readEvents()).where((e) => e.isFromJwxt),
          hasLength(2),
          reason: entry.key,
        );
      }
    });

    test('EX32 考试失败后：<90 分钟自动不拉；≥90 分钟自动或手动重新拉', () async {
      var t = now;
      TimetableController.syncClock = () => t;
      exams = (_) async => throw const JwxtHttpError('cxxsksap.do', 500);
      expect(await _c.onAppStart(), isTrue);
      expect(examCalls, 1);
      expect(_c.statusIsSuccess, isTrue);

      exams = (_) async => _parse('exam_mock.json');
      t = t.add(const Duration(minutes: 89));
      expect(await _c.onAppStart(), isFalse);
      expect(examCalls, 1);

      t = t.add(const Duration(minutes: 1));
      expect(await _c.onAppStart(), isTrue);
      expect(examCalls, 2);
      expect(jwxtExams(), hasLength(2));

      t = t.add(const Duration(minutes: 1));
      expect(await _c.manualSync(), isTrue);
      expect(examCalls, 3);
    });

    test('EX12 AS09 一次同步只发 1 个考试请求；失败不重试', () async {
      exams = (_) async => _parse('exam_mock.json');
      expect(await _c.onAppStart(), isTrue);
      expect(examCalls, 1);
      exams = (_) async => throw TimeoutException('t');
      await _c.manualSync();
      expect(examCalls, 2, reason: 'one request per sync, no retry loop');
      await pumpEventQueue();
      expect(examCalls, 2);
    });

    test('EX18 删除的教务考试同步后仍不显示', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final a = jwxtExams().firstWhere((e) => e.courseCode == '00000001');
      expect(await _c.deleteScheduleEvent(a.id), isTrue);
      expect(_c.scheduleEvents.any((e) => e.id == a.id), isFalse);
      await _c.syncFromJwxt();
      expect(_c.scheduleEvents.any((e) => e.id == a.id), isFalse);
      expect(_c.isJwxtOverridden(examKey: a.jwxtKey), isTrue);
      _c.debugReset();
      await _c.ensureStarted();
      expect(_c.scheduleEvents.any((e) => e.id == a.id), isFalse);
    });

    test('EX21 同步失败（课表或考试）时考试覆盖记录保留并继续生效', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final a = jwxtExams().firstWhere((e) => e.courseCode == '00000001');
      await _c.updateScheduleEvent(a.copyWith(location: '测试楼自改'));
      final key = a.jwxtKey!;

      final okSnapshot = TimetableController.fetchSnapshot;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const SocketException('offline');
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isFalse);
      expect(_c.isJwxtOverridden(examKey: key), isTrue);
      expect(
        _c.scheduleEvents.firstWhere((e) => e.id == a.id).location,
        '测试楼自改',
      );

      TimetableController.fetchSnapshot = okSnapshot;
      exams = (_) async => throw TimeoutException('t');
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isTrue);
      expect((await ScheduleStore.readExamOverrides()).keys, [key]);
      expect(
        _c.scheduleEvents.firstWhere((e) => e.id == a.id).location,
        '测试楼自改',
      );
    });

    test('EX25 EX27 解绑：教务考试与教务课、学期信息一起清除；手动考试与「其他」保留并显示', () async {
      final okSnapshot = TimetableController.fetchSnapshot;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async {
        final s = await okSnapshot(term, baseSettings: baseSettings);
        return s.copyWith(
          settings: s.settings.copyWith(
            termStartDate: DateTime(2026, 8, 31),
            termStartFromJwxt: true,
          ),
        );
      };
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final day = DateTime(2027, 1, 4);
      await _c.addScheduleEvent(_manual('m1'));
      await _c.addScheduleEvent(_manual('m2', kind: ScheduleKind.other));
      expect(_c.jwxtCourses, isNotEmpty);
      expect(_c.settings.termStartDate, isNotNull);

      await _c.handleLogout();
      expect(_c.jwxtCourses, isEmpty);
      expect(_c.settings.termStartDate, isNull);
      expect(jwxtExams(), isEmpty);
      expect(_c.scheduleEventsOn(DateTime(2027, 1, 5)), isEmpty);
      expect(
        (await ScheduleStore.readEvents()).where((e) => e.isFromJwxt),
        isEmpty,
      );
      expect(_c.scheduleEventsOn(day).map((e) => e.id).toSet(), {'m1', 'm2'});
      await _c.updateSettings(_c.settings.copyWith(showExams: false));
      expect(_c.scheduleEventsOn(day).map((e) => e.id), ['m2']);
    });

    test('EX16 手动考试与教务考试完全相同：不去重，两条都在', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final a = jwxtExams().firstWhere((e) => e.courseCode == '00000001');
      await _c.addScheduleEvent(
        a.copyWith(id: 'dup', source: ScheduleSource.manual),
      );
      final sameDay = _c.scheduleEventsOn(a.date);
      expect(sameDay.where((e) => e.title == a.title), hasLength(2));
      expect(sameDay.map((e) => e.id), containsAll([a.id, 'dup']));
    });

    test('EX38 同步后存储文件与日志都不含学号、教师名、XH、XSBH', () async {
      final logs = <String>[];
      final events = <Map<String, Object?>>[];
      final origLogger = portalLogger;
      final origEventLogger = portalEventLogger;
      final origDebugPrint = debugPrint;
      portalLogger = logs.add;
      portalEventLogger = (event, fields) =>
          events.add({'event': event, 'attrs': fields});
      debugPrint = (String? m, {int? wrapWidth}) => logs.add('$m');
      addTearDown(() {
        portalLogger = origLogger;
        portalEventLogger = origEventLogger;
        debugPrint = origDebugPrint;
        TimetableApi.debugPost = null;
      });
      final mock = _fixture('exam_mock.json');
      final rows = ((mock['datas'] as Map)['cxxsksap'] as Map)['rows'] as List;
      rows.add({...(rows[0] as Map), 'KCH': '00000009', 'KSRQ': '2027/01/09'});
      TimetableApi.debugPost = (u, f) async => mock;
      TimetableController.fetchExams = (term) {
        examCalls++;
        return TimetableApi.fetchExams(term);
      };
      await _c.syncFromJwxt();
      expect(jwxtExams(), hasLength(2));
      final skipped = events.singleWhere(
        (event) => event['event'] == 'exams.records_skipped',
      );
      expect((skipped['attrs'] as Map)['skipped_count'], 1);
      expect(logs.join('\n'), isNot(contains('00000009')));

      final stored = [
        for (final f in tmp.listSync(recursive: true).whereType<File>())
          f.readAsStringSync(),
      ].join('\n');
      final logText = '${logs.join('\n')}\n${jsonEncode(events)}';
      expect(logText, isNot(contains('00000009')));
      for (final s in [
        '202512340001',
        '张老师',
        '李老师',
        '王老师',
        'XH',
        'XSBH',
        'ZJJSXM',
      ]) {
        expect(stored, isNot(contains(s)), reason: 'storage: $s');
        expect(logText, isNot(contains(s)), reason: 'log: $s');
      }
    });
  });

  group('normalizeExamTitle & mergeExams', () {
    test('normalizeExamTitle 去空白与全半角括号归一，不影响 normalizeCourseName', () {
      expect(normalizeExamTitle('  高等数学 (上)  '), '高等数学（上）');
      expect(normalizeExamTitle('高等　数学'), '高等数学');
      expect(normalizeExamTitle('大学 英语（1）'), '大学英语（1）');
      expect(normalizeExamTitle('大学\t英语\n（1）'), '大学英语（1）');
      expect(normalizeExamTitle('测试课程(1)'), normalizeExamTitle('测试课程（1）'));
      expect(normalizeCourseName(' 大学 英语(1) '), '大学 英语（1）');
    });

    test('mergeExams 同日时间重叠合并：教务优先且已有字段不被覆盖；双手动保留先出并补空', () {
      final jwxt = _mergeExam(
        'jwxt-1',
        '高等数学（上）',
        source: ScheduleSource.jwxt,
        courseCode: '00000001',
      );
      final manual = _mergeExam(
        'manual-1',
        '高等数学 (上)',
        sh: 9,
        sm: 30,
        eh: 10,
        em: 30,
        location: '测试楼 A101',
        note: '座位号 12',
      );
      final merged = mergeExams([jwxt, manual]).single;
      expect(merged.id, 'jwxt-1');
      expect(merged.source, ScheduleSource.jwxt);
      expect(merged.title, '高等数学（上）');
      expect(merged.courseCode, '00000001');
      expect(merged.location, '测试楼 A101');
      expect(merged.note, '座位号 12');
      expect(merged.start, const TimeOfDayMinutes(9, 0));
      expect(merged.end, const TimeOfDayMinutes(11, 0));

      final filledJwxt = _mergeExam(
        'jwxt-2',
        '测试课程甲',
        source: ScheduleSource.jwxt,
        location: '教务楼 B202',
        note: '教务备注',
        courseCode: '00000001',
      );
      final kept = mergeExams([
        filledJwxt,
        _mergeExam('manual-2', '测试课程甲', location: '测试楼 A101', note: '座位号 12'),
      ]).single;
      expect(kept.location, '教务楼 B202');
      expect(kept.note, '教务备注');
      expect(kept.courseCode, '00000001');

      final bothManual = mergeExams([
        _mergeExam('m1', '测试课程甲'),
        _mergeExam(
          'm2',
          '测试 课程甲',
          sh: 9,
          sm: 30,
          eh: 10,
          location: '测试楼 A101',
          note: '座位号 12',
        ),
      ]).single;
      expect(bothManual.id, 'm1');
      expect(bothManual.source, ScheduleSource.manual);
      expect(bothManual.location, '测试楼 A101');
      expect(bothManual.note, '座位号 12');
    });

    test('mergeExams 不合并场景（端点相接/课名不同/日期不同/单条原样）', () {
      expect(
        mergeExams([
          _mergeExam('a', '测试课程甲', eh: 11, em: 0),
          _mergeExam('b', '测试课程甲', sh: 11, sm: 0, eh: 13, em: 0),
        ]).map((e) => e.id),
        ['a', 'b'],
      );
      expect(
        mergeExams([
          _mergeExam('a', '测试课程甲'),
          _mergeExam('b', '测试课程乙', sh: 10, eh: 12),
        ]).map((e) => e.id),
        ['a', 'b'],
      );
      expect(
        mergeExams([
          _mergeExam('a', '测试课程甲'),
          _mergeExam('b', '测试课程甲', date: DateTime(2026, 10, 21)),
        ]).map((e) => e.id),
        ['a', 'b'],
      );
      expect(mergeExams([_mergeExam('m', '测试课程甲')]).single.id, 'm');
      expect(
        mergeExams([
          _mergeExam(
            'j',
            '测试课程乙',
            source: ScheduleSource.jwxt,
            courseCode: '00000002',
          ),
        ]).single.id,
        'j',
      );
    });

    test('showExams=false 时仍返回去重后的考试（教务优先）', () async {
      final tmp = await Directory.systemTemp.createTemp('tt_exam_merge');
      final origClock = TimetableController.clock;
      final origBinding = TimetableController.bindingCheck;
      final origFetch = TimetableController.fetchSnapshot;
      addTearDown(() async {
        TimetableController.clock = origClock;
        TimetableController.bindingCheck = origBinding;
        TimetableController.fetchSnapshot = origFetch;
        TimetableStore.debugDirectory = null;
        _c.debugReset();
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      TimetableStore.debugDirectory = tmp;
      _c.debugReset();
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const SocketException('offline (test)');
      final today = DateTime(2026, 10, 12);
      final day = DateTime(2026, 10, 20);
      TimetableController.clock = () => today;

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
      final upcomingJwxt = _mergeExam(
        'jwxt-up',
        '测试课程甲',
        source: ScheduleSource.jwxt,
        courseCode: '00000001',
      );
      final pastJwxt = _mergeExam(
        'jwxt-past',
        '测试课程乙',
        date: DateTime(2026, 10, 11),
        source: ScheduleSource.jwxt,
        courseCode: '00000002',
      );
      await _c.replaceJwxtExams([upcomingJwxt, pastJwxt]);
      await _c.addScheduleEvent(
        _mergeExam(
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
        _mergeExam(
          'manual-past',
          '测试课程乙',
          date: DateTime(2026, 10, 11),
          sh: 10,
          eh: 12,
          location: '测试楼 B202',
        ),
      );

      final upcoming = upcomingExams(_c, today: today);
      expect(upcoming, hasLength(1));
      expect(upcoming.single.id, 'jwxt-up');
      expect(upcoming.single.location, '测试楼 A101');
      expect(upcoming.single.note, '座位号 12');

      final past = pastExams(_c, today: today);
      expect(past, hasLength(1));
      expect(past.single.id, 'jwxt-past');
      expect(past.single.location, '测试楼 B202');

      expect(_c.scheduleEventsOn(day), isEmpty);
      expect(_c.scheduleEvents.where((e) => e.isExam), hasLength(4));
    });
  });

  group('jwxt exam overrides & EX28', () {
    late Directory tmp;
    final termStart = DateTime(2026, 8, 31);
    final monday = DateTime(2026, 9, 7);
    List<Course> nextFetch = const [];
    List<ScheduleEvent>? nextExams;
    final origFetchExams = TimetableController.fetchExams;
    final origFetchSnapshot = TimetableController.fetchSnapshot;
    final origClock = TimetableController.clock;
    final origSyncClock = TimetableController.syncClock;
    final origBinding = TimetableController.bindingCheck;

    Course jwxtCourse(
      String id,
      String name, {
      int day = 1,
      String weeks = '1111111111111111',
    }) => Course(
      id: id,
      name: name,
      source: CourseSource.jwxt,
      slots: [
        CourseSlot(
          day: day,
          startNode: 1,
          endNode: 2,
          weeks: weeks,
          teacher: '张老师',
          location: '教一-101',
        ),
      ],
    );

    ScheduleEvent examItem(
      String id,
      String code, {
      DateTime? date,
      int startH = 9,
      int endH = 11,
    }) => ScheduleEvent(
      id: id,
      kind: ScheduleKind.exam,
      source: ScheduleSource.jwxt,
      title: '高等数学考试',
      date: date ?? monday,
      start: TimeOfDayMinutes(startH, 0),
      end: TimeOfDayMinutes(endH, 0),
      location: '教二-201',
      courseCode: code,
    );

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_exam_override');
      TimetableStore.debugDirectory = tmp;
      TimetableController.clock = () => monday;
      TimetableController.bindingCheck = () async => true;
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          TimetableSnapshot(
            courses: nextFetch,
            periods: TimetableController.defaultPeriods(),
            settings: const TimetableSettings(termCode: '2026-2027-1')
                .copyWith(termStartDate: termStart, termStartFromJwxt: true),
          );
      nextExams = null;
      TimetableController.fetchExams = (term) async => nextExams;
      _c.debugReset();
    });

    tearDown(() async {
      TimetableStore.debugDirectory = null;
      TimetableController.clock = origClock;
      TimetableController.syncClock = origSyncClock;
      TimetableController.fetchSnapshot = origFetchSnapshot;
      TimetableController.fetchExams = origFetchExams;
      TimetableController.bindingCheck = origBinding;
      _c.debugReset();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'EX20 edit override survives sync; dropped when key disappears',
      () async {
        await _c.ensureStarted();
        await _c.replaceJwxtExams([
          examItem('e1', 'MATH01'),
          examItem('e2', 'PHY01'),
        ]);
        final key1 = _c.jwxtExamKeyOf('e1')!;
        expect(
          key1,
          ScheduleEvent.examKeyOf(
            'MATH01',
            monday,
            const TimeOfDayMinutes(9, 0),
          ),
        );
        final moved = examItem('e1', 'MATH01').copyWith(
          date: DateTime(2026, 9, 8),
          start: const TimeOfDayMinutes(14, 0),
          end: const TimeOfDayMinutes(16, 0),
          location: '体育馆',
        );
        expect(await _c.updateScheduleEvent(moved), isTrue);
        expect(_c.isJwxtOverridden(examKey: key1), isTrue);
        expect(_c.jwxtExamKeyOf('e1'), key1, reason: 'original key stays');
        await _c.deleteScheduleEvent('e2');
        final key2 = _c.jwxtExamKeyOf('e2')!;

        await _c.replaceJwxtExams([
          examItem('e1-new', 'MATH01'),
          examItem('e3', 'CHEM01', startH: 14, endH: 16),
        ]);
        final e1 = _c.scheduleEvents.firstWhere((e) => e.id == 'e1-new');
        expect(e1.date, DateTime(2026, 9, 8));
        expect(e1.start, const TimeOfDayMinutes(14, 0));
        expect(e1.location, '体育馆');
        expect(_c.isJwxtOverridden(examKey: key1), isTrue);
        expect(_c.isJwxtOverridden(examKey: key2), isFalse);
        expect((await ScheduleStore.readExamOverrides()).keys, [key1]);

        _c.debugReset();
        await _c.ensureStarted();
        expect(_c.isJwxtOverridden(examKey: key1), isTrue);
        expect(await _c.restoreJwxtExam(key1), isTrue);
        final restored = _c.scheduleEvents.firstWhere((e) => e.id == 'e1-new');
        expect(restored.date, monday);
        expect(await _c.restoreJwxtExam(key1), isFalse);

        await _c.replaceJwxtExams(const []);
        expect(_c.scheduleEvents, isEmpty);
      },
    );

    test('EX13 replaceJwxtExams leaves manual events untouched', () async {
      await _c.ensureStarted();
      final manualExam = ScheduleEvent(
        id: 'm1',
        kind: ScheduleKind.exam,
        source: ScheduleSource.manual,
        title: '自加小测',
        date: monday,
        start: const TimeOfDayMinutes(8, 0),
        end: const TimeOfDayMinutes(9, 0),
      );
      await _c.addScheduleEvent(manualExam);
      await _c.addScheduleEvent(
        ScheduleEvent(
          id: 'o1',
          kind: ScheduleKind.other,
          source: ScheduleSource.manual,
          title: '社团活动',
          date: monday,
          start: const TimeOfDayMinutes(20, 0),
          end: const TimeOfDayMinutes(21, 0),
        ),
      );
      await _c.replaceJwxtExams([examItem('e1', 'MATH01')]);
      await _c.replaceJwxtExams([examItem('e2', 'PHY01')]);
      expect(_c.scheduleEvents.map((e) => e.id).toSet(), {'m1', 'o1', 'e2'});
      final m1 = _c.scheduleEvents.firstWhere((e) => e.id == 'm1');
      expect(m1.title, '自加小测');
      expect(m1.source, ScheduleSource.manual);
    });

    test('EX28 rebind + successful sync: matching overrides apply again, stale ones are dropped', () async {
      Course shown(String id) => _c.courses.firstWhere((x) => x.id == id);
      ScheduleEvent eventById(String id) =>
          _c.scheduleEvents.firstWhere((e) => e.id == id);

      nextFetch = [
        jwxtCourse('j1', '高等数学'),
        jwxtCourse('j2', '大学物理', day: 2),
        jwxtCourse('j3', '线性代数', day: 3),
      ];
      nextExams = [
        examItem('e1', 'MATH01'),
        examItem('e2', 'PHY01', startH: 14, endH: 16),
        examItem('e3', 'CHEM01', date: DateTime(2026, 9, 8)),
      ];
      await _c.ensureStarted();
      await _c.syncFromJwxt();
      expect(_c.syncStatus, TimetableSyncStatus.success);
      expect(_c.scheduleEvents.where((e) => e.isFromJwxt), hasLength(3));
      final k1 = _c.jwxtExamKeyOf('e1')!;
      final k2 = _c.jwxtExamKeyOf('e2')!;
      final k3 = _c.jwxtExamKeyOf('e3')!;
      await _c.editJwxtCourse('j1', name: 'A');
      await _c.editJwxtCourse('j2', name: 'B');
      await _c.deleteJwxtCourse('j3');
      await _c.updateScheduleEvent(eventById('e1').copyWith(location: '体育馆'));
      await _c.updateScheduleEvent(eventById('e2').copyWith(location: '操场'));
      await _c.deleteScheduleEvent('e3');

      await _c.handleLogout();
      expect((await ScheduleStore.readCourseEdits()).keys.toSet(), {
        'j1',
        'j2',
        'j3',
      });
      expect((await ScheduleStore.readExamOverrides()).keys.toSet(), {
        k1,
        k2,
        k3,
      });
      expect(_c.courses, isEmpty);
      expect(_c.scheduleEvents.where((e) => e.isFromJwxt), isEmpty);

      nextFetch = [
        jwxtCourse('j1', '高等数学'),
        jwxtCourse('j2', '大学物理', day: 2, weeks: '1111111100000000'),
      ];
      nextExams = [
        examItem('e1', 'MATH01'),
        examItem('e2b', 'PHY01', startH: 15, endH: 17),
      ];
      await _c.syncFromJwxt();
      expect(_c.syncStatus, TimetableSyncStatus.success);
      expect(shown('j1').name, 'A');
      expect(_c.courseEditOf('j2'), isNull);
      expect(shown('j2').name, '大学物理');
      expect(_c.courseEditOf('j3'), isNull);
      expect((await ScheduleStore.readCourseEdits()).keys, ['j1']);
      expect((await ScheduleStore.readExamOverrides()).keys, [k1]);
      expect(eventById('e1').location, '体育馆');
      expect(eventById('e2b').location, '教二-201');
      expect(eventById('e2b').start, const TimeOfDayMinutes(15, 0));
      expect(_c.scheduleEvents.any((e) => e.id == 'e3'), isFalse);
    });
  });
}
