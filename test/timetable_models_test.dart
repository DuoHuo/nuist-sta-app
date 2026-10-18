import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_theme.dart';

const _fx = 'test/fixtures/timetable';

/// 真实打码样例（git-ignore，只在本地）。缺任一个就跳过「真实样例」组。
const _realSamples = [
  'kb_real_sample.json',
  'unscheduled_real_sample.json',
  'dqxnxq_real_sample.json',
  'dqzc_real_sample.json',
  'jc_real_sample.json',
];

bool get _realSamplesPresent =>
    _realSamples.every((n) => File('$_fx/$n').existsSync());

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_fx/$name').readAsStringSync()) as Map<String, dynamic>;

Future<Map<String, dynamic>> _loadRaw(String name) async => _json(name);

void main() {
  test('theme defaults match spec v0.2', () {
    expect(TimetableTheme.periodHeight, 64);
    expect(TimetableTheme.cellRadius, 4);
    expect(TimetableTheme.coursePalette, hasLength(16));
    expect(TimetableTheme.coursePaletteDark, hasLength(16));
    expect(TimetableTheme.accent.toARGB32(), 0xFF0082EF);
  });

  test('parse kb_mock_2026-1 fixture', () async {
    final file = File('test/fixtures/timetable/kb_mock_2026-1.json');
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final rows = (json['datas'] as Map)['cxxszhxqkb']['rows'] as List;
    final result = TimetableParser.parseKbRows(rows);
    expect(result.courses, isNotEmpty);
    // 高等数学应合并周一+周三两个时段
    final math = result.courses.firstWhere((c) => c.name.contains('高等数学'));
    expect(math.slots.length, greaterThanOrEqualTo(2));
    // 周末跨节课保留
    expect(result.courses.any((c) => c.name.contains('天文观测')), isTrue);
  });

  test('same course name maps to same color index', () {
    final a = TimetableTheme.colorIndexFor('数据结构');
    final b = TimetableTheme.colorIndexFor('数据结构');
    expect(a, b);
    expect(a, inInclusiveRange(0, 15));
  });

  test('week parity from bitstring', () {
    const odd = CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '10101010101010101010',
    );
    const even = CourseSlot(
      day: 1,
      startNode: 1,
      endNode: 2,
      weeks: '01010101010101010101',
    );
    expect(odd.parity, WeekParity.odd);
    expect(even.parity, WeekParity.even);
    expect(odd.occursInWeek(1), isTrue);
    expect(odd.occursInWeek(2), isFalse);
  });

  test('parseImportJson accepts snapshot shape', () {
    final snap = TimetableParser.parseImportJson({
      'courses': [
        {
          'id': 'c1',
          'name': '测试课',
          'slots': [
            {
              'day': 1,
              'startNode': 1,
              'endNode': 2,
              'weeks': '11111111111111111111',
            },
          ],
        },
      ],
      'periods': [
        {'node': 1, 'start': '08:00', 'end': '08:45'},
      ],
      'settings': {'nodesPerDay': 11, 'periodHeight': 64, 'cellRadius': 4},
    });
    expect(snap.courses, hasLength(1));
    expect(snap.settings.periodHeight, 64);
    expect(snap.settings.cellRadius, 4);
  });
  test('KXH maps to classId; null JASMC stays empty; XF credit', () {
    final result = TimetableParser.parseKbRows([
      {
        'KCM': '测试课',
        'KCH': '10001',
        'JXBID': '2026202710710001',
        'KXH': '02',
        'SKJS': '张三',
        'JASMC': null,
        'SKXQ': 1,
        'KSJC': '1',
        'JSJC': '2',
        'SKZC': '11111111111111111111',
        'XF': 2.0,
        'SKBJ': '很长的班级名单不应进模型',
      },
    ]);
    expect(result.courses, hasLength(1));
    final c = result.courses.single;
    expect(c.classId, '02');
    expect(c.credit, 2.0);
    expect(c.slots.single.location, isEmpty);
    expect(c.slots.single.teacher, '张三');
  });

  group('mock fixtures（始终运行，假数据）', () {
    test('parse kb_mock + unscheduled_mock', () {
      final week = _json('kb_mock.json');
      final unsched = _json('unscheduled_mock.json');
      final rows = (week['datas'] as Map)['cxxszhxqkb']['rows'] as List;
      expect(rows, hasLength(15));
      final datas = <String, dynamic>{
        ...(week['datas'] as Map<String, dynamic>),
        ...(unsched['datas'] as Map<String, dynamic>),
      };
      final snap = TimetableParser.parseImportJson({
        'code': '0',
        'datas': datas,
      }, baseSettings: const TimetableSettings(maxWeeks: 30));
      // 15 行网格课（高等数学A 两行合并）+ 3 门未排课
      expect(snap.courses, hasLength(17));
      final math = snap.courses.singleWhere((c) => c.name == '高等数学A');
      expect(math.id, 'MK000101|01');
      expect(math.slots.map((s) => s.day), [1, 3]);
      // KXH 短序号，不用 JXBID
      expect(snap.courses.every((c) => c.classId.length <= 4), isTrue);
      expect(
        snap.courses.singleWhere((c) => c.name == '大学物理实验B').classId,
        '17',
      );
      // 未排课 / 中文 SKZC → 其他课程，不丢
      final others = snap.courses.where(
        (c) => c.slots.every((s) => !s.hasFixedTime),
      );
      expect(others, hasLength(3));
      expect(others.map((c) => c.slots.single.weeksLabel), contains('2-17周'));
      // SKZC 长度 20/24/30 → 全部按 maxWeeks=30 对齐
      final fixed = snap.courses
          .expand((c) => c.slots)
          .where((s) => s.hasFixedTime)
          .toList();
      expect(fixed, hasLength(15));
      expect(fixed.every((s) => s.weeks.length == 30), isTrue);
      // KSJC/JSJC 为字符串 → int
      final circuit = snap.courses.singleWhere((c) => c.name == '电路分析');
      expect(
        (circuit.slots.single.startNode, circuit.slots.single.endNode),
        (5, 6),
      );
      expect(circuit.credit, 4.0);
      // null 地点 → 空串
      final pe = snap.courses.singleWhere((c) => c.name == '数字电路');
      expect(pe.slots.single.location, isEmpty);
      expect(math.slots.first.location, '示例楼A101');
      expect(math.slots.first.teacher, '教师N');
    });

    test('jc_mock parses enabled periods (SFSY≠0)', () {
      final rows =
          (_json('jc_mock.json')['datas'] as Map)['jc']['rows'] as List;
      expect(rows, hasLength(12));
      final enabled = TimetableParser.parsePeriods(rows);
      expect(enabled, hasLength(11)); // 第 12 节 SFSY=0
      expect(enabled.first.node, 1);
      expect(enabled.first.start, '08:10');
      expect(enabled.last.node, 11);
      expect(enabled.last.end, '21:35');
      final all = TimetableParser.parsePeriods(rows, onlyEnabled: false);
      expect(all, hasLength(12));
      expect(all.last.end, '22:30');
    });

    test('dqxnxq_mock + dqzc_mock + jc_mock parse via import', () {
      final termJson = _json('dqxnxq_mock.json');
      final weekJson = _json('dqzc_mock.json');
      final jcJson = _json('jc_mock.json');
      final datas = <String, dynamic>{
        ...(termJson['datas'] as Map<String, dynamic>),
        ...(weekJson['datas'] as Map<String, dynamic>),
        ...(jcJson['datas'] as Map<String, dynamic>),
      };
      final snap = TimetableParser.parseImportJson({
        'code': '0',
        'datas': datas,
      });
      expect(snap.settings.termCode, '2026-2027-1');
      expect(snap.periods, hasLength(11));
      // RQ=2026-09-23（周三）、ZC=4 → 第 1 周周一 2026-08-31
      expect(snap.settings.termStartDate, DateTime(2026, 8, 31));
      expect(snap.settings.termStartFromJwxt, isTrue);
      final zc =
          ((weekJson['datas'] as Map)['dqzc']['rows'] as List).first as Map;
      expect(zc['ZC'], 4);
      expect(zc['XQJ'], 3);
    });
  });

  test('Chinese SKZC goes to other courses, not skipped', () {
    final result = TimetableParser.parseKbRows([
      {
        'KCM': '未排课示例',
        'KCH': '999',
        'KXH': '17',
        'SKJS': '李四',
        'JASMC': null,
        'SKZC': '2-17周',
        'XF': 1,
      },
      {'KCM': '空周次', 'KCH': '998', 'KXH': '01', 'SKJS': '王五', 'SKZC': null},
    ]);
    expect(result.courses, hasLength(2));
    expect(result.skips.where((s) => s.reason == 'bad_weeks'), isEmpty);
    expect(
      result.courses.every((c) => c.slots.every((s) => !s.hasFixedTime)),
      isTrue,
    );
    expect(
      result.courses.firstWhere((c) => c.code == '999').slots.single.weeksLabel,
      '2-17周',
    );
  });

  test('computeTermStartDate sample 2026-10-11 ZC=6 Sun → 2026-08-31', () {
    final start = TimetableParser.computeTermStartDate(
      refDate: DateTime(2026, 10, 11),
      weekday: 7,
      week: 6,
    );
    expect(start, DateTime(2026, 8, 31));
  });

  group('TimetableApi meta failures are non-fatal', () {
    tearDown(() => TimetableApi.debugPost = null);

    Future<Map<String, dynamic>> load(String name) async =>
        jsonDecode(await File('test/fixtures/timetable/$name').readAsString())
            as Map<String, dynamic>;

    test('dqxnxq/dqzc 403 → still returns timetable (mock)', () async {
      final kb = await load('kb_mock.json');
      final wp = await load('unscheduled_mock.json');
      final jc = await load('jc_mock.json');
      final calls = <String>[];
      TimetableApi.debugPost = (url, form) async {
        final name = url.pathSegments.last;
        calls.add(name);
        switch (name) {
          case 'cxxszhxqkb.do':
            expect(form, {'XNXQDM': '2026-2027-1'});
            return kb;
          case 'xswpkc.do':
            return wp;
          case 'jc.do':
            return jc;
          case 'dqzc.do':
            expect(form['RQ'], '2026-10-11');
            throw const JwxtHttpError('dqzc.do', 403);
          default:
            throw JwxtHttpError(name, 403);
        }
      };
      final cachedStart = DateTime(2026, 8, 31);
      final snap = await TimetableApi.fetchTermSnapshot(
        '2026-2027-1',
        baseSettings: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: cachedStart,
        ),
        now: DateTime(2026, 10, 11),
      );
      expect(calls.first, 'cxxszhxqkb.do');
      expect(calls, containsAll(['dqxnxq.do', 'dqzc.do', 'jc.do']));
      expect(snap.courses, hasLength(17)); // 14 门网格课 + 3 门未排课
      expect(snap.periods, hasLength(11));
      // dqzc 失败 → 保留缓存开学日
      expect(snap.settings.termStartDate, cachedStart);
      expect(snap.settings.termCode, '2026-2027-1');
    });

    test('main timetable failure is fatal', () async {
      TimetableApi.debugPost = (url, form) async =>
          throw JwxtHttpError(url.pathSegments.last, 403);
      expect(
        () => TimetableApi.fetchTermSnapshot('2026-2027-1'),
        throwsA(isA<JwxtHttpError>()),
      );
    });

    test('formatDate is yyyy-MM-dd', () {
      expect(
        TimetableApi.formatDate(DateTime(2026, 1, 5, 23, 59)),
        '2026-01-05',
      );
    });
  });

  group('真实样例（仅本地存在时运行）', () {
    tearDown(() => TimetableApi.debugPost = null);

    test('parse kb_real_sample + unscheduled_real_sample', () async {
      final week = jsonDecode(
        await File('test/fixtures/timetable/kb_real_sample.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      final unsched = jsonDecode(
        await File('test/fixtures/timetable/unscheduled_real_sample.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      final datas = <String, dynamic>{
        ...(week['datas'] as Map<String, dynamic>),
        ...(unsched['datas'] as Map<String, dynamic>),
      };
      final snap = TimetableParser.parseImportJson({
        'code': '0',
        'datas': datas,
      }, baseSettings: const TimetableSettings(maxWeeks: 30));
      expect(snap.courses, isNotEmpty);
      // KXH 短序号
      final withSerial = snap.courses.where((c) => c.classId.isNotEmpty);
      expect(withSerial, isNotEmpty);
      expect(withSerial.every((c) => c.classId.length <= 4), isTrue);
      // 未排课 / 中文 SKZC → 其他课程，不丢
      final others = snap.courses.where(
        (c) => c.slots.every((s) => !s.hasFixedTime),
      );
      expect(others.length, greaterThanOrEqualTo(3));
      // 位串按 maxWeeks=30 pad
      final fixed = snap.courses
          .expand((c) => c.slots)
          .where((s) => s.hasFixedTime);
      expect(fixed.every((s) => s.weeks.length == 30), isTrue);
      // null 地点
      expect(
        snap.courses.any((c) => c.slots.any((s) => s.location.isEmpty)),
        isTrue,
      );
    });

    test('jc_real_sample parses enabled periods (SFSY≠0)', () async {
      final json = jsonDecode(
        await File('test/fixtures/timetable/jc_real_sample.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      final rows = (json['datas'] as Map)['jc']['rows'] as List;
      expect(rows, hasLength(12));
      final enabled = TimetableParser.parsePeriods(rows);
      expect(enabled, hasLength(11)); // period 12 SFSY=0
      expect(enabled.first.node, 1);
      expect(enabled.first.start, '08:00');
      expect(enabled.last.node, 11);
      final all = TimetableParser.parsePeriods(rows, onlyEnabled: false);
      expect(all, hasLength(12));
      expect(all.last.end, '22:00');
    });

    test('dqxnxq + dqzc samples parse via import / splitTerm', () async {
      final termJson = jsonDecode(
        await File('test/fixtures/timetable/dqxnxq_real_sample.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      final weekJson = jsonDecode(
        await File('test/fixtures/timetable/dqzc_real_sample.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      final jcJson = jsonDecode(
        await File('test/fixtures/timetable/jc_real_sample.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      final datas = <String, dynamic>{
        ...(termJson['datas'] as Map<String, dynamic>),
        ...(weekJson['datas'] as Map<String, dynamic>),
        ...(jcJson['datas'] as Map<String, dynamic>),
      };
      final snap = TimetableParser.parseImportJson({
        'code': '0',
        'datas': datas,
      });
      expect(snap.settings.termCode, '2026-2027-1');
      expect(snap.periods, hasLength(11));
      expect(snap.settings.termStartDate, DateTime(2026, 8, 31));
      expect(TimetableApi.splitTermCode('2026-2027-1'), (
        year: '2026-2027',
        term: '1',
      ));
      final zc =
          ((weekJson['datas'] as Map)['dqzc']['rows'] as List).first as Map;
      expect(zc['ZC'], 6);
    });

    test('dqxnxq/dqzc 403 → still returns timetable', () async {
      final kb = await _loadRaw('kb_real_sample.json');
      final wp = await _loadRaw('unscheduled_real_sample.json');
      final jc = await _loadRaw('jc_real_sample.json');
      final calls = <String>[];
      TimetableApi.debugPost = (url, form) async {
        final name = url.pathSegments.last;
        calls.add(name);
        switch (name) {
          case 'cxxszhxqkb.do':
            expect(form, {'XNXQDM': '2026-2027-1'});
            return kb;
          case 'xswpkc.do':
            return wp;
          case 'jc.do':
            return jc;
          case 'dqzc.do':
            expect(form['RQ'], '2026-10-11');
            throw const JwxtHttpError('dqzc.do', 403);
          default:
            throw JwxtHttpError(name, 403);
        }
      };
      final cachedStart = DateTime(2026, 8, 31);
      final snap = await TimetableApi.fetchTermSnapshot(
        '2026-2027-1',
        baseSettings: TimetableSettings(
          termCode: '2026-2027-1',
          termStartDate: cachedStart,
        ),
        now: DateTime(2026, 10, 11),
      );
      expect(calls.first, 'cxxszhxqkb.do');
      expect(calls, containsAll(['dqxnxq.do', 'dqzc.do', 'jc.do']));
      expect(snap.courses, isNotEmpty);
      expect(snap.periods, hasLength(11));
      // dqzc 失败 → 保留缓存开学日
      expect(snap.settings.termStartDate, cachedStart);
      expect(snap.settings.termCode, '2026-2027-1');
    });
  }, skip: _realSamplesPresent ? false : 'real sample not present');
}
