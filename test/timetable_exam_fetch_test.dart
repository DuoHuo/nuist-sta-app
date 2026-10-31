// 第 11 条：教务「我的考试安排」拉取与入库（lib/mini_apps/timetable/README.md）。
// 编号对齐课表测试用例 §24（EX）。只用 test/fixtures/timetable/
// 里的虚构样例（exam_mock*.json），不读真实响应。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exam_parser.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_card.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_exams_page.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_event.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_schedule_store.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_controller.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
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

void main() {
  group('ExamParser（纯函数）', () {
    test('EX01 EX35 EX36 exam_mock.json：已排时间的两场映射完整；未排时间的跳过', () {
      final r = ExamParser.parse(_fixture('exam_mock.json'));
      expect(r.exams, hasLength(2));
      expect(r.skippedCourseCodes, isEmpty); // 未排时间是正常跳过，不计为坏行

      final a = r.exams[0];
      expect(a.kind, ScheduleKind.exam);
      expect(a.source, ScheduleSource.jwxt);
      expect(a.title, '示例课程甲');
      expect(a.courseCode, '00000001');
      expect(a.date, DateTime(2027, 1, 5));
      expect(a.start, const TimeOfDayMinutes(9, 0));
      expect(a.end, const TimeOfDayMinutes(11, 0));
      expect(a.location, '示例楼A101');
      expect(a.note, '座位号 12\n请携带学生证');
      expect(a.jwxtKey, '00000001|2027-01-05|09:00');
      expect(a.id, 'jwxt-exam:00000001|2027-01-05|09:00');

      final b = r.exams[1];
      expect(b.title, '示例课程乙');
      expect(b.location, '示例楼B202');
      expect(b.note, ''); // 无座位号、无备注
      expect(r.exams.map((e) => e.courseCode), isNot(contains('00000003')));
    });

    test('EX01 不读也不存学号、教师与内部 ID', () {
      final json = jsonEncode([
        for (final e in _parse('exam_mock.json')) e.toJson(),
      ]);
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
    });

    test('exam_mock_empty.json：空列表', () {
      final r = ExamParser.parse(_fixture('exam_mock_empty.json'));
      expect(r.exams, isEmpty);
      expect(r.skippedCourseCodes, isEmpty);
    });

    test('EX34 exam_mock_missing_fields.json：只保留第 4 行（无教室无座位）', () {
      final r = ExamParser.parse(_fixture('exam_mock_missing_fields.json'));
      final e = r.exams.single;
      expect(e.courseCode, '00000006');
      expect(e.title, '示例课程庚（无教室无座位，应保留）');
      expect(e.date, DateTime(2027, 1, 7));
      expect(e.location, '');
      expect(e.note, '');
      // 日期格式错与缺课程号记为坏行（日志只给课程号）；缺开始时间按「未排时间」跳过。
      expect(r.skippedCourseCodes, containsAll(['00000005', '']));
      expect(r.skippedCourseCodes, isNot(contains('00000006')));
    });

    test('日期只认 yyyy-MM-dd 且须为合法日期；时间只认 HH:mm；结束早于开始丢弃', () {
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
      // 教室为空时退到教学楼；课程名为空时用课程号。
      final ok =
          ExamParser.parseRow(row({'JXLMC': '示例楼', 'KCM': ''})) as ExamRowOk;
      expect(ok.exam.location, '示例楼');
      expect(ok.exam.title, '00000009');
    });

    test('同一 examKey 重复出现只保留第一条', () {
      final row = {
        'KCH': '00000009',
        'KCM': '示例课程',
        'KSRQ': '2027-01-08',
        'KSKSSJ': '09:00',
        'KSJSSJ': '11:00',
        'SFAPSJ': '1',
      };
      final r = ExamParser.parseRows([
        row,
        {...row, 'JASMC': '另一间'},
      ]);
      expect(r.exams, hasLength(1));
      expect(r.exams.single.location, '');
    });

    test('响应不可用（code≠0 / 非 Map / 缺 rows）→ 抛错（整批视为失败）', () {
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

    test('备注组合', () {
      expect(ExamParser.composeNote(seat: '', remark: ''), '');
      expect(ExamParser.composeNote(seat: '3', remark: ''), '座位号 3');
      expect(ExamParser.composeNote(seat: '', remark: '带笔'), '带笔');
    });

    test('EX37 JASMC 空 → location 取 JXLMC；两者都空 → 空', () {
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
    var showExams = true;
    var examCalls = 0;
    Future<List<ScheduleEvent>?> Function(String term) exams = (_) async =>
        const [];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tt_exam_fetch');
      TimetableStore.debugDirectory = tmp;
      showExams = true;
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
            settings: TimetableSettings(
              termCode: '2026-2027-1',
              showExams: showExams,
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
      showExams = false;
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

    test('EX31 考试拉取失败：课表同步仍成功、更新成功时间、无报错，已有考试保留', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final before = jwxtExams();
      expect(before, hasLength(2));

      exams = (_) async => throw const SocketException('offline');
      final later = now.add(const Duration(hours: 1));
      TimetableController.syncClock = () => later;
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isTrue);
      expect(_c.syncFailure, TimetableSyncFailure.none);
      expect(_c.snapshot.lastError, isNull);
      expect(_c.lastSyncSuccessAt, later);
      expect(await ScheduleStore.readLastSyncSuccess(), later);
      expect(jwxtExams().map((e) => e.id), before.map((e) => e.id));

      // 响应格式不对同理。
      exams = (_) async => ExamParser.parse({'code': '1'}).exams;
      await _c.syncFromJwxt();
      expect(_c.statusIsSuccess, isTrue);
      expect(jwxtExams(), hasLength(2));
    });

    test('课表同步失败时不拉考试', () async {
      exams = (_) async => _parse('exam_mock.json');
      TimetableController.fetchSnapshot = (term, {baseSettings}) async =>
          throw const SocketException('offline');
      await _c.syncFromJwxt();
      expect(examCalls, 0);
      expect(_c.statusIsSuccess, isFalse);
    });

    test('EX14 EX15 EX19 覆盖记录：考试不变时保留，教务改了时间后清除', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      final a = jwxtExams().firstWhere((e) => e.courseCode == '00000001');
      await _c.updateScheduleEvent(a.copyWith(location: '测试楼自改'));
      final key = a.jwxtKey!;
      expect(_c.isJwxtOverridden(examKey: key), isTrue);

      await _c.syncFromJwxt(); // 同一份数据
      expect(_c.isJwxtOverridden(examKey: key), isTrue);
      expect(
        _c.scheduleEvents.firstWhere((e) => e.id == a.id).location,
        '测试楼自改',
      );
      expect((await ScheduleStore.readExamOverrides()).keys, contains(key));

      // 教务把甲的开始时间改了 → examKey 变 → 旧覆盖删除，显示教务新值。
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

    test('解绑清掉教务考试，手动日程保留', () async {
      exams = (_) async => _parse('exam_mock.json');
      await _c.syncFromJwxt();
      await _c.addScheduleEvent(_manual('m1'));
      await _c.handleLogout();
      expect(jwxtExams(), isEmpty);
      expect(_c.scheduleEvents.map((e) => e.id), ['m1']);
      final stored = await ScheduleStore.readEvents();
      expect(stored.map((e) => e.id), ['m1']);
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

    for (final entry in <String, Object>{
      '500': const JwxtHttpError('cxxsksap.do', 500),
      'timeout': TimeoutException('t'),
      'code≠0': const ExamResponseError('code=1'),
      '跳登录页': const JwxtSessionExpiredError('重新登录后教务仍要求登录'),
    }.entries) {
      test('EX11 EX31 考试拉取失败（${entry.key}）：课表照常更新，旧考试保留，无报错', () async {
        exams = (_) async => _parse('exam_mock.json');
        await _c.syncFromJwxt();
        final before = jwxtExams().map((e) => e.id).toList();
        final later = now.add(const Duration(hours: 1));
        TimetableController.syncClock = () => later;
        exams = (_) async => throw entry.value;
        await _c.syncFromJwxt();
        expect(_c.statusIsSuccess, isTrue);
        expect(_c.syncFailure, TimetableSyncFailure.none);
        expect(_c.lastSyncSuccessAt, later);
        expect(jwxtExams().map((e) => e.id), before);
        expect(
          (await ScheduleStore.readEvents()).where((e) => e.isFromJwxt),
          hasLength(2),
        );
      });
    }

    test('EX32 考试失败后：<10 分钟自动不拉；≥10 分钟自动或手动重新拉', () async {
      var t = now;
      TimetableController.syncClock = () => t;
      exams = (_) async => throw const JwxtHttpError('cxxsksap.do', 500);
      expect(await _c.onAppStart(), isTrue);
      expect(examCalls, 1);
      expect(_c.statusIsSuccess, isTrue);

      exams = (_) async => _parse('exam_mock.json');
      t = t.add(const Duration(minutes: 9));
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
      expect(await _c.onAppStart(), isTrue); // 自动同步含考试拉取
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
      // 手动考试仍受「显示考试」控制，「其他」不受。
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
      // 走真实 fetchExams（含「跳过坏行」日志），HTTP 用 mock 响应替换。
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
}
