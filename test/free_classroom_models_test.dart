// 空教室模型对教务真实返回形状的解析：大节定义、JC 占用字段、楼层 / 类型。

import 'package:flutter_test/flutter_test.dart';

import 'package:nuist_sta_app/mini_apps/free_classroom/free_classroom_models.dart';

void main() {
  test('大节按教务 cxjcqk 的行构建，晚上是 9-11 一整块', () {
    final groups = PeriodGroup.fromRows([
      {'DJMC': '5-6节', 'KSJC': 5, 'JSJC': 6, 'KSSJ': '13:45', 'JSSJ': '15:25'},
      {'DJMC': '1-2节', 'KSJC': 1, 'JSJC': 2, 'KSSJ': '08:00', 'JSSJ': '09:40'},
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
}
