import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_manifest.dart';
import 'package:nuist_sta_app/core/app_registry.dart';
import 'package:nuist_sta_app/mini_apps/academic/academic_models.dart';
import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_models.dart';
import 'package:nuist_sta_app/mini_apps/registry.dart';
import 'package:nuist_sta_app/mini_apps/score/score_models.dart';

AcademicSummary _parseAcademic(Map<String, dynamic> json) =>
    AcademicSummary.fromJson(json, fetchedAt: DateTime(2025, 9, 1));

Map<String, dynamic> _allAcademic(Object? value) => {
  'XH': '202512340001',
  for (final k in [
    'YXZXF',
    'YHXF',
    'PJJD',
    'GPA',
    'PJF',
    'JQPJF',
    'BJPM',
    'ZYPM',
    'KCTGL',
    'XFJD',
  ])
    k: value,
};

Widget _entry(BuildContext context) => const Scaffold(body: Text('测试详情'));

AppManifest _card(
  String id, {
  int order = 0,
  Future<void> Function()? onRefresh,
  Future<void> Function(bool bound)? onPortalBindingChanged,
}) => AppManifest.cardOnly(
  id: id,
  label: id,
  onPortalBindingChanged: onPortalBindingChanged,
  studyCard: StudyCardContribution(
    builder: (_) => Text(id),
    order: order,
    onRefresh: onRefresh,
  ),
);

void main() {
  group('AcademicSummary', () {
    test('新生空串、全零、null 与缺失字段均安全归零', () {
      final empty = _parseAcademic(_allAcademic(''));
      expect(empty.creditProgressRatio, 0);
      expect(empty.creditProgressText, '0%');
      expect(empty.passRateText, '--');
      expect(empty.gpa, '');

      final zero = _parseAcademic(_allAcademic('0'));
      expect(zero.creditProgressRatio, 0);
      expect(zero.creditProgressText, '0%');
      expect(zero.passRateText, '0%');

      for (final v in [null, 'null', 'NULL']) {
        final s = _parseAcademic(_allAcademic(v));
        expect(s.requiredCredits, '');
        expect(s.creditProgress, '');
        expect(s.creditProgressRatio, 0);
        expect(s.passRateText, '--');
      }

      final missing = _parseAcademic({'XH': '202512340001'});
      expect(missing.creditProgressRatio, 0);
      expect(missing.creditProgressText, '0%');
      expect(missing.passRateText, '--');
    });

    test('XFJD 解析与缺失时按已获/应修推算，creditProgressText 同源', () {
      AcademicSummary of(Map<String, dynamic> json) => _parseAcademic(json);
      expect(
        of({'XH': '202512340001', 'XFJD': '32.9%'}).creditProgressRatio,
        closeTo(0.329, 1e-9),
      );
      expect(
        of({'XH': '202512340001', 'XFJD': '32.9%'}).creditProgressText,
        '32.9%',
      );
      expect(
        of({'XH': '202512340001', 'XFJD': '32.9'}).creditProgressRatio,
        closeTo(0.329, 1e-9),
      );
      expect(
        of({'XH': '202512340001', 'XFJD': '32.9'}).creditProgressText,
        '32.9%',
      );
      expect(
        of({'XH': '202512340001', 'XFJD': '0.5'}).creditProgressRatio,
        0.5,
      );
      expect(of({'XH': '202512340001', 'XFJD': '0'}).creditProgressRatio, 0);
      expect(of({'XH': '202512340001', 'XFJD': 'NaN%'}).creditProgressRatio, 0);
      expect(
        of({'XH': '202512340001', 'XFJD': 'NaN%'}).creditProgressText,
        '0%',
      );
      expect(of({'XH': '202512340001', 'XFJD': '150%'}).creditProgressRatio, 1);
      expect(
        of({'XH': '202512340001', 'XFJD': '150%'}).creditProgressText,
        '100%',
      );

      expect(
        of({'YHXF': '30', 'YXZXF': '120', 'XFJD': ''}).creditProgressRatio,
        0.25,
      );
      expect(of({'YHXF': '30', 'YXZXF': '120'}).creditProgressText, '25%');
      expect(
        of({'YHXF': '0', 'YXZXF': '0', 'XFJD': ''}).creditProgressRatio,
        0,
      );
      expect(of({'YHXF': '', 'YXZXF': '0', 'XFJD': ''}).creditProgressRatio, 0);
    });

    test('passRateText 兼容空 / NaN / 正常比例', () {
      String text(String v) => _parseAcademic({'KCTGL': v}).passRateText;
      expect(text(''), '--');
      expect(text('NaN'), '--');
      expect(text('1'), '100%');
      expect(text('0.875'), '87.5%');
    });
  });

  group('ScoreRecord & ScoreReport', () {
    test('教务成绩行兼容 display 字段并识别通过状态', () {
      final record = ScoreRecord.fromRow({
        'XNXQDM': '2025-2026-2',
        'KCM': '程序设计',
        'KCH': 'CS1001',
        'ZCJ_DISPLAY': '88',
        'XF': '3',
        'XFJD': '4.0',
        'SFJG_DISPLAY': '及格',
        'KSLXDM_DISPLAY': '期末考试',
      });

      expect(record.term, '2025-2026-2');
      expect(record.courseName, '程序设计');
      expect(record.numericScore, 88);
      expect(record.passed, isTrue);
      expect(record.failed, isFalse);
    });

    test('单科与学期学分格式保留整数、截断两位小数不四舍五入', () {
      expect(
        ScoreRecord.fromRow({'KCM': '程序设计', 'XF': '2.678'}).creditText,
        '2.67',
      );
      expect(ScoreRecord.fromRow({'KCM': '高等数学', 'XF': '3.0'}).creditText, '3');

      ScoreTermSummary summary(double credits) => ScoreTermSummary(
        term: '2025-2026-1',
        total: 3,
        passed: 3,
        failed: 0,
        credits: credits,
        averageScore: 90,
      );
      expect(summary(6).creditsText, '6');
      expect(summary(2.678).creditsText, '2.67');
      expect(summary(4.1).creditsText, '4.10');
    });

    test('成绩报告按学期倒序，并计算学期概览', () {
      final report = ScoreReport(
        records: [
          ScoreRecord.fromRow({
            'XNXQDM': '2024-2025-2',
            'KCM': '旧课',
            'ZCJ': '59',
            'XF': '2',
          }),
          ScoreRecord.fromRow({
            'XNXQDM': '2025-2026-1',
            'KCM': '高数',
            'ZCJ': '90',
            'XF': '4',
          }),
          ScoreRecord.fromRow({
            'XNXQDM': '2025-2026-1',
            'KCM': '英语',
            'ZCJ': '80',
            'XF': '2',
          }),
        ],
        fetchedAt: DateTime(2026, 9, 23),
      );

      expect(report.latestTerm, '2025-2026-1');
      final summary = report.summaryFor(report.latestTerm);
      expect(summary.total, 2);
      expect(summary.passed, 2);
      expect(summary.credits, 6);
      expect(summary.averageScore, 85);
    });

    test('优良中及格等等级成绩也能判断通过', () {
      final record = ScoreRecord.fromRow({'KCM': '体育', 'ZCJ_DISPLAY': '优秀'});
      expect(record.passed, isTrue);
      expect(record.numericScore, 95);
    });
  });

  group('FreeClassroom models', () {
    test('大节按教务 cxjcqk 的行构建，晚上是 9-11 一整块', () {
      final groups = PeriodGroup.fromRows([
        {
          'DJMC': '5-6节',
          'KSJC': 5,
          'JSJC': 6,
          'KSSJ': '13:45',
          'JSSJ': '15:25',
        },
        {
          'DJMC': '1-2节',
          'KSJC': 1,
          'JSJC': 2,
          'KSSJ': '08:00',
          'JSSJ': '09:40',
        },
        {
          'DJMC': '9-11节',
          'KSJC': 9,
          'JSJC': 11,
          'KSSJ': '18:45',
          'JSSJ': '21:20',
        },
      ]);
      expect(groups.map((g) => g.label), ['1-2', '5-6', '9-11']);
      expect(groups.last.periods, [9, 10, 11]);
      expect(groups.first.timeRange, '08:00–09:40');
      expect(groups.first.isOver(DateTime(2026, 9, 22, 9, 39)), isFalse);
      expect(groups.first.isOver(DateTime(2026, 9, 22, 9, 40)), isTrue);
    });

    test('cxjcqk 为空时退回内置五个大节', () {
      final groups = PeriodGroup.fromRows(const []);
      expect(groups.length, 5);
      expect(
        TermCalendar(
          termCode: 'x',
          week: 1,
          weekday: 1,
          groups: groups,
        ).maxPeriod,
        11,
      );
    });

    test('JC 字段只有 1_ 开头才算占用，0_ 与 null 都是空闲', () {
      expect(Classroom.parseOccupation(null), isEmpty);
      expect(Classroom.parseOccupation(''), isEmpty);
      expect(Classroom.parseOccupation('0_04,0_01'), isEmpty);
      expect(Classroom.parseOccupation('0_04,1_01'), ['01']);
      expect(Classroom.parseOccupation('1_01,1_04'), ['01', '04']);
    });

    test('教室行解析：类型 / 座位 / 楼层与逐节空闲', () {
      final room = Classroom.fromRow({
        'JASMC': '文德N101A',
        'JASLXDM_DISPLAY': '多媒体教室',
        'LC': 1,
        'SKZWS': 180,
        'JC1': '0_01',
        'JC2': '0_01',
        'JC5': '1_01',
        'JC6': '1_01',
        'JC11': '0_01',
      }, 11);
      expect(room.type, '多媒体教室');
      expect(room.seats, 180);
      expect(room.floor, 1);
      expect(room.isNonClassroom, isFalse);
      expect(room.isFree(1), isTrue);
      expect(room.isFree(5), isFalse);
      expect(room.occupationOf(5), ['01']);
      const morning = PeriodGroup(
        start: 1,
        end: 2,
        startTime: '08:00',
        endTime: '09:40',
      );
      const afternoon = PeriodGroup(
        start: 5,
        end: 6,
        startTime: '13:45',
        endTime: '15:25',
      );
      expect(room.freeCountIn(morning), 2);
      expect(room.freeCountIn(afternoon), 0);
    });

    test('LC 缺失时从名称推断楼层，办公室类不算教室', () {
      final office = Classroom.fromRow({
        'JASMC': 'N305',
        'JASLXDM_DISPLAY': '教师办公室',
      }, 11);
      expect(office.floor, 3);
      expect(office.isNonClassroom, isTrue);
      expect(office.seats, isNull);
    });

    test('分区取房间号前面的字母，没有就是 null', () {
      String? zoneOf(String name) =>
          Classroom.fromRow({'JASMC': name}, 11).zone;
      expect(zoneOf('文德N101A'), 'N');
      expect(zoneOf('明德S402'), 'S');
      expect(zoneOf('文德C104'), 'C');
      expect(zoneOf('N305'), 'N');
      expect(zoneOf('室外教室-雷丁'), isNull);
      expect(zoneOf('藕舫楼101'), isNull);
    });

    test('ClassroomDay.zones 去重、按 N/C/S 方位排，忽略没有分区的教室', () {
      final day = ClassroomDay(
        date: DateTime(2026, 9, 22),
        building: const Building(code: '1-120', name: '文德楼'),
        calendar: const TermCalendar(
          termCode: '2026-2027-1',
          week: 4,
          weekday: 2,
          groups: PeriodGroup.defaults,
        ),
        rooms: [
          for (final name in [
            '文德S401',
            '文德C104',
            '文德A101',
            '文德N101A',
            '文德N102',
            '室外教室-雷丁',
          ])
            Classroom.fromRow({'JASMC': name}, 11),
        ],
        fetchedAt: DateTime(2026, 9, 22, 8),
      );
      expect(day.zones, ['N', 'C', 'S', 'A']);
    });
  });

  group('小程序注册能力', () {
    test('普通小程序缺少入口或同时声明两种入口时拒绝构造', () {
      expect(
        () => AppManifest(id: 'empty', label: '空入口', color: Colors.blue),
        throwsAssertionError,
      );
      expect(
        () => AppManifest(
          id: 'both',
          label: '双入口',
          color: Colors.blue,
          entry: _entry,
          url: 'https://example.com',
        ),
        throwsAssertionError,
      );
    });

    test('纯卡片不进入宫格或路由，隐藏的详情仍可通过路由访问', () {
      final card = _card('semester');
      final registry = AppRegistry([
        card,
        const AppManifest(
          id: 'detail',
          label: '学习详情',
          color: Colors.blue,
          entry: _entry,
          showInHomeGrid: false,
        ),
        const AppManifest(
          id: 'home',
          label: '首页入口',
          color: Colors.blue,
          entry: _entry,
        ),
      ]);

      expect(card.hasEntry, isFalse);
      expect(card.color, isNull);
      expect(card.showInHomeGrid, isFalse);
      expect(registry.homeGridApps.map((app) => app.id), ['home']);
      expect(registry.studyApps.map((app) => app.id), ['semester']);
      expect(registry.byId.keys, unorderedEquals(['detail', 'home']));
    });

    test('同一 id 即使分属纯卡片与详情也会被拒绝', () {
      expect(
        () => AppRegistry([
          _card('duplicate'),
          const AppManifest(
            id: 'duplicate',
            label: '重复详情',
            color: Colors.blue,
            entry: _entry,
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => AppRegistry([_card('duplicate'), _card('duplicate')]),
        throwsArgumentError,
      );
    });

    test('学习顺序独立于登记顺序，同序按 id 稳定排列', () {
      final registry = AppRegistry([
        _card('late', order: 30),
        _card('second', order: 20),
        _card('first', order: 20),
        _card('early', order: 10),
      ]);
      expect(registry.studyApps.map((app) => app.id), [
        'early',
        'first',
        'second',
        'late',
      ]);
    });

    test('构造后不受源列表增删影响，派生集合不能被外部修改', () {
      final source = [_card('original')];
      final registry = AppRegistry(source);
      source.clear();

      expect(registry.apps.single.id, 'original');
      expect(() => registry.apps.clear(), throwsUnsupportedError);
      expect(() => registry.studyApps.clear(), throwsUnsupportedError);
      expect(() => registry.homeGridApps.clear(), throwsUnsupportedError);
      expect(() => registry.byId.clear(), throwsUnsupportedError);
    });

    test('实际学习页保持五卡及三个详情入口', () {
      expect(appRegistry.studyApps.map((app) => app.id), [
        'student-info',
        'academic',
        'scores',
        'innovation-credit',
        'labor-score',
      ]);
      expect(appRegistry.homeGridApps, hasLength(8));
      expect(appRegistry.byId.containsKey('student-info'), isFalse);
      expect(appRegistry.byId.containsKey('academic'), isFalse);
      for (final id in ['scores', 'innovation-credit', 'labor-score']) {
        expect(appRegistry.byId[id]?.hasEntry, isTrue);
      }
    });
  });

  group('门户绑定变化分发', () {
    for (final bound in [true, false]) {
      test('${bound ? '绑定' : '解绑'}默认刷新首页与学习卡片，同一回调不重复', () async {
        final refreshed = <String>[];
        Future<void> sharedRefresh() async => refreshed.add('shared');
        final registry = AppRegistry([
          AppManifest(
            id: 'both-cards',
            label: '两类卡片',
            color: Colors.blue,
            entry: _entry,
            homeCard: (_) => const Text('首页卡片'),
            onHomeRefresh: () async => refreshed.add('home'),
            studyCard: StudyCardContribution(
              builder: (_) => const Text('学习卡片'),
              order: 0,
              onRefresh: () async => refreshed.add('study'),
            ),
          ),
          AppManifest(
            id: 'shared-callback',
            label: '共享刷新',
            color: Colors.blue,
            entry: _entry,
            homeCard: (_) => const Text('首页卡片'),
            onHomeRefresh: sharedRefresh,
            studyCard: StudyCardContribution(
              builder: (_) => const Text('学习卡片'),
              order: 0,
              onRefresh: sharedRefresh,
            ),
          ),
          _card('card-only', onRefresh: () async => refreshed.add('card-only')),
        ]);

        expect(await registry.notifyPortalBindingChanged(bound: bound), isTrue);
        expect(
          refreshed,
          unorderedEquals(['home', 'study', 'shared', 'card-only']),
        );
      });

      test('${bound ? '绑定' : '解绑'}显式回调优先，普通与纯卡片模块都能接收状态', () async {
        final received = <(String, bool)>[];
        Future<void> unexpectedRefresh() async => fail('显式处理后不应再次刷新卡片');
        final registry = AppRegistry([
          AppManifest(
            id: 'explicit',
            label: '显式处理',
            color: Colors.blue,
            entry: _entry,
            homeCard: (_) => const Text('首页卡片'),
            onHomeRefresh: unexpectedRefresh,
            studyCard: StudyCardContribution(
              builder: (_) => const Text('学习卡片'),
              order: 0,
              onRefresh: unexpectedRefresh,
            ),
            onPortalBindingChanged: (value) async =>
                received.add(('app', value)),
          ),
          _card(
            'explicit-card',
            onRefresh: unexpectedRefresh,
            onPortalBindingChanged: (value) async =>
                received.add(('card', value)),
          ),
        ]);

        expect(await registry.notifyPortalBindingChanged(bound: bound), isTrue);
        expect(received, unorderedEquals([('app', bound), ('card', bound)]));
      });
    }

    test('只调用实际卡片的刷新，没有订阅或静态卡片时直接成功', () async {
      final registry = AppRegistry([
        _card('static'),
        AppManifest(
          id: 'entry-only',
          label: '仅入口',
          color: Colors.blue,
          entry: _entry,
          onHomeRefresh: () async => fail('没有首页卡片不应调用其刷新'),
        ),
      ]);

      expect(await registry.notifyPortalBindingChanged(bound: true), isTrue);
      expect(await registry.notifyPortalBindingChanged(bound: false), isTrue);
      expect(
        await AppRegistry([]).notifyPortalBindingChanged(bound: true),
        isTrue,
      );
    });

    test('并发启动所有处理，最后一项完成前不结束', () async {
      final started = <String>[];
      final first = Completer<void>();
      final second = Completer<void>();
      final registry = AppRegistry([
        _card(
          'first',
          onPortalBindingChanged: (_) {
            started.add('first');
            return first.future;
          },
        ),
        _card(
          'second',
          onRefresh: () {
            started.add('second');
            return second.future;
          },
        ),
      ]);

      var completed = false;
      final notification = registry
          .notifyPortalBindingChanged(bound: true)
          .then((success) {
            completed = true;
            return success;
          });
      expect(started, unorderedEquals(['first', 'second']));
      expect(completed, isFalse);

      second.complete();
      await Future<void>.value();
      expect(completed, isFalse);
      first.complete();
      expect(await notification, isTrue);
    });

    for (final asynchronous in [false, true]) {
      test('${asynchronous ? '异步' : '同步'}异常不阻断其他处理，等待全部后返回失败', () async {
        final remaining = Completer<void>();
        var remainingStarted = false;
        Future<void> broken() {
          final error = StateError('合成绑定通知失败');
          if (asynchronous) return Future<void>.error(error);
          throw error;
        }

        final registry = AppRegistry([
          _card(
            'broken',
            onRefresh: asynchronous ? broken : null,
            onPortalBindingChanged: asynchronous ? null : (_) => broken(),
          ),
          _card(
            'remaining',
            onRefresh: () {
              remainingStarted = true;
              return remaining.future;
            },
          ),
        ]);

        var completed = false;
        final notification = registry
            .notifyPortalBindingChanged(bound: false)
            .then((success) {
              completed = true;
              return success;
            });
        expect(remainingStarted, isTrue);
        await Future<void>.value();
        expect(completed, isFalse);
        remaining.complete();
        expect(await notification, isFalse);
      });
    }
  });
}
