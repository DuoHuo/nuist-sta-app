import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_models.dart';

SunshineRunState _baseline(
  int total,
  int morning, {
  int grade = 2,
  SunshineRunExemption exemption = SunshineRunExemption.none,
}) => SunshineRunState(
  grade: grade,
  exemption: exemption,
  baseTotal: total,
  baseMorning: morning,
);

void main() {
  test('默认大二、无减免且全部计数为零', () {
    final state = SunshineRunState.initial();
    final result = state.calculate();
    expect(state.grade, 2);
    expect(state.exemption, SunshineRunExemption.none);
    expect(state.activities.values, everyElement(0));
    expect(state.customActivities, isEmpty);
    expect(result.total, 0);
    expect(result.morning, 0);
    expect(result.percentage, 0);
    expect(result.morningPercentage, 0);
    expect(result.status, SunshineRunStatus.incomplete);
    expect(result.fullTotal, 48);
    expect(result.passingTotal, 24);
    expect(result.requiredMorning, 15);
    expect(result.remainingFullTotal, 48);
    expect(result.remainingPassingTotal, 24);
    expect(result.remainingMorning, 15);
  });

  test('固定活动各一场合计总次数6，其中晨跑5', () {
    var state = SunshineRunState.initial();
    for (final activity in kSunshineRunActivities) {
      final single = SunshineRunState()
          .withActivity(activity.id, 1)
          .calculate();
      expect(single.total, activity.total);
      expect(single.morning, activity.morning);
      state = state.withActivity(activity.id, 1);
    }
    final result = state.calculate();
    expect(result.total, 6);
    expect(result.morning, 5);
    expect(result.addedTotal, 6);
    expect(result.addedMorning, 5);
  });

  test('已有10/4加活动2/3/1/1为19/11，晨跑不重复计总次数', () {
    final state = _baseline(10, 4)
        .withActivity('regular', 2)
        .withActivity('morning', 3)
        .withActivity('fluorescent', 1)
        .withActivity('monday', 1);
    final result = state.calculate();
    expect(result.total, 19);
    expect(result.morning, 11);
    expect(result.addedTotal, 9);
    expect(result.addedMorning, 7);
    expect(result.percentage, 40);
  });

  test('普通跑一场显示2%，晨跑为0仍未达标', () {
    final result = SunshineRunState().withActivity('regular', 1).calculate();
    expect(result.total, 1);
    expect(result.morning, 0);
    expect(result.percentage, 2);
    expect(result.status, SunshineRunStatus.incomplete);
  });

  test('大二48/14总次数100%，晨跑缺1次仍未达标', () {
    final result = _baseline(48, 14).calculate();
    expect(result.percentage, 100);
    expect(result.morningPercentage, 93);
    expect(result.status, SunshineRunStatus.incomplete);
    expect(result.remainingFullTotal, 0);
    expect(result.remainingPassingTotal, 0);
    expect(result.remainingMorning, 1);
  });

  for (final row in <(int, int, SunshineRunStatus)>[
    (23, 15, SunshineRunStatus.incomplete),
    (24, 14, SunshineRunStatus.incomplete),
    (24, 15, SunshineRunStatus.passed),
    (47, 15, SunshineRunStatus.passed),
    (48, 15, SunshineRunStatus.full),
  ]) {
    test('大二普通标准 ${row.$1}/${row.$2}', () {
      expect(_baseline(row.$1, row.$2).calculate().status, row.$3);
    });
  }

  for (final row in <(int, int, SunshineRunStatus)>[
    (12, 12, SunshineRunStatus.passed),
    (35, 12, SunshineRunStatus.passed),
    (36, 11, SunshineRunStatus.incomplete),
    (36, 12, SunshineRunStatus.full),
  ]) {
    test('大一普通标准 ${row.$1}/${row.$2}', () {
      final result = _baseline(row.$1, row.$2, grade: 1).calculate();
      expect(result.status, row.$3);
      expect(result.passingTotal, isNull);
      expect(result.remainingPassingTotal, 0);
      expect(result.requiredMorning, 12);
    });
  }

  for (final row in <(int, int, SunshineRunStatus)>[
    (12, 12, SunshineRunStatus.incomplete),
    (15, 15, SunshineRunStatus.passed),
    (24, 14, SunshineRunStatus.incomplete),
    (24, 15, SunshineRunStatus.full),
  ]) {
    test('大二半免标准 ${row.$1}/${row.$2}', () {
      final result = _baseline(
        row.$1,
        row.$2,
        exemption: SunshineRunExemption.half,
      ).calculate();
      expect(result.status, row.$3);
      expect(result.fullTotal, 24);
      expect(result.passingTotal, 12);
      expect(result.requiredMorning, 15);
    });
  }

  test('大一半免仅满分总次数降为18，晨跑仍需12次', () {
    for (final row in <(int, int, SunshineRunStatus)>[
      (12, 12, SunshineRunStatus.passed),
      (18, 11, SunshineRunStatus.incomplete),
      (18, 12, SunshineRunStatus.full),
    ]) {
      final result = _baseline(
        row.$1,
        row.$2,
        grade: 1,
        exemption: SunshineRunExemption.half,
      ).calculate();
      expect(result.status, row.$3);
      expect(result.fullTotal, 18);
      expect(result.passingTotal, isNull);
      expect(result.requiredMorning, 12);
    }
  });

  test('全免无需跑步，保留标准目标且剩余次数全为零', () {
    for (final grade in [1, 2]) {
      final result = SunshineRunState(
        grade: grade,
        exemption: SunshineRunExemption.full,
      ).calculate();
      expect(result.status, SunshineRunStatus.exempt);
      expect(result.percentage, 100);
      expect(result.morningPercentage, 100);
      expect(result.fullTotal, grade == 1 ? 36 : 48);
      expect(result.requiredMorning, grade == 1 ? 12 : 15);
      expect(result.remainingFullTotal, 0);
      expect(result.remainingPassingTotal, 0);
      expect(result.remainingMorning, 0);
    }
  });

  test('年级减免改变门槛，实际记录及撤销快照不变', () {
    final before = _baseline(10, 4).withActivity('morning', 2);
    final snapshots = <SunshineRunState>[before];
    final full = before.copyWith(
      grade: 1,
      exemption: SunshineRunExemption.full,
    );
    final restored = full.copyWith(
      grade: 2,
      exemption: SunshineRunExemption.none,
    );
    expect(restored, before);
    expect(restored.hashCode, before.hashCode);
    expect(before.calculate().total, 12);
    expect(before.calculate().morning, 6);
    expect(snapshots.single.calculate().status, SunshineRunStatus.incomplete);
    expect(full.calculate().status, SunshineRunStatus.exempt);
    expect(restored.calculate().percentage, 25);
  });

  test('超过目标保留真实记录，两个百分比均封顶100', () {
    final result = _baseline(60, 20).calculate();
    expect(result.total, 60);
    expect(result.morning, 20);
    expect(result.percentage, 100);
    expect(result.morningPercentage, 100);
    expect(result.remainingFullTotal, 0);
    expect(result.remainingMorning, 0);
  });

  test('十进制输入接受整数、前导零和两端空格', () {
    expect(parseSunshineRunCount(12), 12);
    expect(parseSunshineRunCount(' 012 '), 12);
    expect(parseSunshineRunCount('0000'), 0);
    expect(parseSunshineRunCount('5', positive: true), 5);
    expect(
      parseSunshineRunCount(kSunshineRunMaxCount.toString()),
      kSunshineRunMaxCount,
    );
  });

  test('拒绝空白、负数、小数、科学计数及其他类型', () {
    for (final raw in <Object?>[
      '',
      ' ',
      '-1',
      '+1',
      '1.0',
      '1.2',
      '1e3',
      '１２',
      -1,
      1.0,
      1.2,
      double.nan,
      double.infinity,
      null,
      true,
      <int>[],
    ]) {
      expect(
        () => parseSunshineRunCount(raw),
        throwsFormatException,
        reason: '$raw',
      );
    }
    expect(
      () => parseSunshineRunCount(0, positive: true),
      throwsFormatException,
    );
    expect(
      () => parseSunshineRunCount(kSunshineRunMaxCount + 1),
      throwsFormatException,
    );
    expect(
      () => parseSunshineRunCount('${kSunshineRunMaxCount}0'),
      throwsFormatException,
    );
  });

  test('基数和固定活动校验拒绝晨跑超总数、负值、未知或缺失标识', () {
    expect(() => _baseline(2, 3), throwsFormatException);
    expect(() => SunshineRunState(baseTotal: -1), throwsFormatException);
    expect(() => SunshineRunState(grade: 3), throwsFormatException);
    expect(
      () => SunshineRunState(activities: {'regular': 0}),
      throwsFormatException,
    );
    expect(
      () => SunshineRunState().withActivity('unknown', 1),
      throwsFormatException,
    );
    expect(
      () => SunshineRunState().withActivity('morning', -1),
      throwsFormatException,
    );
  });

  test('活动单场乘法与累计加法均在运算前检查上界', () {
    final state = _baseline(kSunshineRunMaxCount, 0);
    expect(state.calculate().total, kSunshineRunMaxCount);
    expect(() => state.withActivity('regular', 1), throwsFormatException);
    expect(
      () => SunshineRunState().withActivity(
        'fluorescent',
        kSunshineRunMaxCount ~/ 2 + 1,
      ),
      throwsFormatException,
    );
    expect(
      () => SunshineRunCustomActivity(
        id: 'custom-max',
        total: kSunshineRunMaxCount,
        count: 2,
      ),
      throwsFormatException,
    );
    final nearMax = _baseline(
      1,
      1,
    ).withActivity('fluorescent', kSunshineRunMaxCount ~/ 2);
    expect(nearMax.calculate().total, kSunshineRunMaxCount);
    expect(nearMax.calculate().morning, kSunshineRunMaxCount);
  });

  test('输入集合、只读状态集合和JSON副本不会修改已有快照', () {
    final counts = {...SunshineRunState().activities, 'regular': 2};
    final custom = <SunshineRunCustomActivity>[
      SunshineRunCustomActivity(
        id: 'custom-a',
        label: '其他跑步',
        total: 2,
        morning: 1,
        count: 3,
      ),
    ];
    final state = SunshineRunState(
      activities: counts,
      customActivities: custom,
    );
    counts['regular'] = 99;
    custom.clear();
    expect(state.activities['regular'], 2);
    expect(state.customActivities.length, 1);
    expect(() => state.activities['regular'] = 8, throwsUnsupportedError);
    expect(() => state.customActivities.clear(), throwsUnsupportedError);
    final json = state.toJson();
    (json['activities'] as Map)['regular'] = 7;
    ((json['customActivities'] as List).first as Map)['count'] = 8;
    expect(state.calculate().total, 8);
    expect(state.customActivities.single.count, 3);
  });

  test('自定义活动新增修改场次改规则及删除正确撤销贡献', () {
    final item = SunshineRunCustomActivity(
      id: 'custom-a',
      label: '其他活动',
      total: 4,
      morning: 2,
      count: 3,
    );
    final before = _baseline(10, 4).withActivity('regular', 1);
    final added = before.withCustomAdded(item);
    expect(added.calculate().total, 23);
    expect(added.calculate().morning, 10);
    final counted = added.withCustomCount(item.id, 2);
    expect(counted.calculate().total, 19);
    final updated = counted.withCustomUpdated(
      item.copyWith(label: '其他晨跑活动', total: 3, morning: 3, count: 2),
    );
    expect(updated.calculate().total, 17);
    expect(updated.calculate().morning, 10);
    expect(updated.withCustomRemoved(item.id), before);
    expect(added.customActivities.single.count, 3);
    expect(before.customActivities, isEmpty);
  });

  test('自定义活动校验名称、单场权重、标识唯一性与未知活动', () {
    expect(
      SunshineRunCustomActivity(id: ' custom-a ', label: ' ').label,
      '其他活动',
    );
    expect(() => SunshineRunCustomActivity(id: ''), throwsFormatException);
    expect(
      () => SunshineRunCustomActivity(id: 'custom-a', total: 0),
      throwsFormatException,
    );
    expect(
      () => SunshineRunCustomActivity(id: 'custom-a', total: 1, morning: 2),
      throwsFormatException,
    );
    expect(
      () => SunshineRunCustomActivity(
        id: 'custom-a',
        label: List.filled(31, '跑').join(),
      ),
      throwsFormatException,
    );
    expect(
      () => SunshineRunCustomActivity(id: 'custom-a', label: '活动\n名称'),
      throwsFormatException,
    );
    final item = SunshineRunCustomActivity(id: 'custom-a');
    final state = SunshineRunState().withCustomAdded(item);
    expect(() => state.withCustomAdded(item), throwsFormatException);
    expect(
      () => state.withCustomAdded(SunshineRunCustomActivity(id: 'regular')),
      throwsFormatException,
    );
    expect(() => state.withCustomCount('missing', 1), throwsFormatException);
    expect(() => state.withCustomRemoved('missing'), throwsFormatException);
    expect(
      () => state.withCustomUpdated(SunshineRunCustomActivity(id: 'missing')),
      throwsFormatException,
    );
  });

  test('自定义最多50项，零场次定义仍保留', () {
    final items = [
      for (var i = 0; i < 50; i++) SunshineRunCustomActivity(id: 'custom-$i'),
    ];
    final state = SunshineRunState(customActivities: items);
    expect(state.customActivities.length, 50);
    expect(state.calculate().total, 0);
    expect(
      () => state.withCustomAdded(SunshineRunCustomActivity(id: 'custom-51')),
      throwsFormatException,
    );
  });

  test('清空新增保留基数、年级、减免与自定义定义，全清只保留年级', () {
    final before =
        _baseline(5, 2, grade: 1, exemption: SunshineRunExemption.half)
            .withActivity('regular', 2)
            .withCustomAdded(
              SunshineRunCustomActivity(
                id: 'custom-a',
                total: 3,
                morning: 1,
                count: 2,
              ),
            );
    final cleared = before.clearActivities();
    expect(cleared.baseTotal, 5);
    expect(cleared.baseMorning, 2);
    expect(cleared.grade, 1);
    expect(cleared.exemption, SunshineRunExemption.half);
    expect(cleared.activities.values, everyElement(0));
    expect(cleared.customActivities.single.total, 3);
    expect(cleared.customActivities.single.count, 0);
    expect(cleared.calculate().addedTotal, 0);
    final reset = before.resetAll();
    expect(reset, SunshineRunState(grade: 1));
    expect(before.calculate().total, 13);
    expect(before.customActivities.single.count, 2);
  });

  test('JSON整数严格往返保存所有数据且兼容旧记录没有自定义活动', () {
    final state =
        _baseline(10, 4, grade: 1, exemption: SunshineRunExemption.half)
            .withActivity('morning', 2)
            .withCustomAdded(
              SunshineRunCustomActivity(
                id: 'custom-a',
                label: '其他活动',
                total: 2,
                morning: 1,
                count: 3,
              ),
            );
    final restored = SunshineRunState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
    );
    expect(restored, state);
    expect(restored.hashCode, state.hashCode);
    final old = SunshineRunState().toJson()..remove('customActivities');
    expect(SunshineRunState.fromJson(old), SunshineRunState());
  });

  test('损坏JSON不会按字符串或浮点数猜测成有效计数', () {
    for (final change in <Map<String, dynamic>>[
      {'version': 2},
      {'version': 1.0},
      {'grade': 1.0},
      {'exemption': 'both'},
      {'baseTotal': '1'},
      {'baseMorning': 0.0},
      {'activities': null},
      {'customActivities': null},
      {
        'customActivities': [1],
      },
    ]) {
      final json = SunshineRunState().toJson()..addAll(change);
      expect(() => SunshineRunState.fromJson(json), throwsFormatException);
    }
    final damaged = SunshineRunState().toJson();
    damaged['activities'] = Map<String, dynamic>.from(
      damaged['activities'] as Map,
    )..['regular'] = 1.0;
    expect(() => SunshineRunState.fromJson(damaged), throwsFormatException);
    final targetOverride = SunshineRunState().toJson()..['fullTotal'] = 1;
    expect(SunshineRunState.fromJson(targetOverride).calculate().fullTotal, 48);
  });

  test('全免和JSON恢复仍不能绕过累计溢出校验', () {
    final json = SunshineRunState(exemption: SunshineRunExemption.full)
        .toJson();
    json['baseTotal'] = kSunshineRunMaxCount;
    (json['activities'] as Map)['regular'] = 1;
    expect(() => SunshineRunState.fromJson(json), throwsFormatException);
  });
}
