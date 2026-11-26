import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/app_directories.dart';
import 'package:nuist_sta_app/core/auth/student_academic_info.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_controller.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_models.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_store.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SunshineRun models', () {
    test('初始状态、固定活动叠加计数与超目标百分比封顶', () {
      final initial = SunshineRunState.initial();
      final initResult = initial.calculate();
      expect(initial.grade, 2);
      expect(initial.exemption, SunshineRunExemption.none);
      expect(initial.activities.values, everyElement(0));
      expect(initial.customActivities, isEmpty);
      expect(initResult.total, 0);
      expect(initResult.morning, 0);
      expect(initResult.percentage, 0);
      expect(initResult.morningPercentage, 0);
      expect(initResult.status, SunshineRunStatus.incomplete);
      expect(initResult.fullTotal, 48);
      expect(initResult.passingTotal, 24);
      expect(initResult.requiredMorning, 15);
      expect(initResult.remainingFullTotal, 48);
      expect(initResult.remainingPassingTotal, 24);
      expect(initResult.remainingMorning, 15);

      var allFixed = SunshineRunState.initial();
      for (final activity in kSunshineRunActivities) {
        final single = SunshineRunState()
            .withActivity(activity.id, 1)
            .calculate();
        expect(single.total, activity.total);
        expect(single.morning, activity.morning);
        allFixed = allFixed.withActivity(activity.id, 1);
      }
      final allFixedResult = allFixed.calculate();
      expect(allFixedResult.total, 6);
      expect(allFixedResult.morning, 5);
      expect(allFixedResult.addedTotal, 6);
      expect(allFixedResult.addedMorning, 5);

      final combined = _baseline(10, 4)
          .withActivity('regular', 2)
          .withActivity('morning', 3)
          .withActivity('fluorescent', 1)
          .withActivity('monday', 1)
          .calculate();
      expect(combined.total, 19);
      expect(combined.morning, 11);
      expect(combined.addedTotal, 9);
      expect(combined.addedMorning, 7);
      expect(combined.percentage, 40);

      final oneRegular = SunshineRunState()
          .withActivity('regular', 1)
          .calculate();
      expect(oneRegular.percentage, 2);
      expect(oneRegular.status, SunshineRunStatus.incomplete);

      final missingMorning = _baseline(48, 14).calculate();
      expect(missingMorning.percentage, 100);
      expect(missingMorning.morningPercentage, 93);
      expect(missingMorning.status, SunshineRunStatus.incomplete);
      expect(missingMorning.remainingFullTotal, 0);
      expect(missingMorning.remainingPassingTotal, 0);
      expect(missingMorning.remainingMorning, 1);

      final overflow = _baseline(60, 20).calculate();
      expect(overflow.total, 60);
      expect(overflow.morning, 20);
      expect(overflow.percentage, 100);
      expect(overflow.morningPercentage, 100);
      expect(overflow.remainingFullTotal, 0);
      expect(overflow.remainingMorning, 0);
    });

    test('大一与大二普通及半免达标矩阵', () {
      for (final row in <(int, int, SunshineRunStatus)>[
        (23, 15, SunshineRunStatus.incomplete),
        (24, 14, SunshineRunStatus.incomplete),
        (24, 15, SunshineRunStatus.passed),
        (47, 15, SunshineRunStatus.passed),
        (48, 15, SunshineRunStatus.full),
      ]) {
        expect(_baseline(row.$1, row.$2).calculate().status, row.$3);
      }

      for (final row in <(int, int, SunshineRunStatus)>[
        (12, 12, SunshineRunStatus.passed),
        (35, 12, SunshineRunStatus.passed),
        (36, 11, SunshineRunStatus.incomplete),
        (36, 12, SunshineRunStatus.full),
      ]) {
        final result = _baseline(row.$1, row.$2, grade: 1).calculate();
        expect(result.status, row.$3);
        expect(result.passingTotal, isNull);
        expect(result.remainingPassingTotal, 0);
        expect(result.requiredMorning, 12);
      }

      for (final row in <(int, int, SunshineRunStatus)>[
        (12, 12, SunshineRunStatus.incomplete),
        (15, 15, SunshineRunStatus.passed),
        (24, 14, SunshineRunStatus.incomplete),
        (24, 15, SunshineRunStatus.full),
      ]) {
        final result = _baseline(
          row.$1,
          row.$2,
          exemption: SunshineRunExemption.half,
        ).calculate();
        expect(result.status, row.$3);
        expect(result.fullTotal, 24);
        expect(result.passingTotal, 12);
        expect(result.requiredMorning, 15);
      }

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

    test('全免保留标准目标且剩余为零，切换年级减免与集合隔离不污染快照', () {
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

      final before = _baseline(10, 4).withActivity('morning', 2);
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
      expect(full.calculate().status, SunshineRunStatus.exempt);
      expect(restored.calculate().percentage, 25);

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

    test('十进制输入、活动约束与乘法/累计上界溢出校验', () {
      expect(parseSunshineRunCount(12), 12);
      expect(parseSunshineRunCount(' 012 '), 12);
      expect(parseSunshineRunCount('0000'), 0);
      expect(parseSunshineRunCount('5', positive: true), 5);
      expect(
        parseSunshineRunCount(kSunshineRunMaxCount.toString()),
        kSunshineRunMaxCount,
      );

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

      final maxState = _baseline(kSunshineRunMaxCount, 0);
      expect(maxState.calculate().total, kSunshineRunMaxCount);
      expect(() => maxState.withActivity('regular', 1), throwsFormatException);
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

    test('自定义活动增删改、校验规则与50项上限，清空与重置行为', () {
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
      final singleState = SunshineRunState().withCustomAdded(item);
      expect(() => singleState.withCustomAdded(item), throwsFormatException);
      expect(
        () => singleState.withCustomAdded(
          SunshineRunCustomActivity(id: 'regular'),
        ),
        throwsFormatException,
      );
      expect(
        () => singleState.withCustomCount('missing', 1),
        throwsFormatException,
      );
      expect(
        () => singleState.withCustomRemoved('missing'),
        throwsFormatException,
      );
      expect(
        () => singleState.withCustomUpdated(
          SunshineRunCustomActivity(id: 'missing'),
        ),
        throwsFormatException,
      );

      final maxItems = [
        for (var i = 0; i < 50; i++) SunshineRunCustomActivity(id: 'custom-$i'),
      ];
      final fullList = SunshineRunState(customActivities: maxItems);
      expect(fullList.customActivities.length, 50);
      expect(fullList.calculate().total, 0);
      expect(
        () => fullList.withCustomAdded(
          SunshineRunCustomActivity(id: 'custom-51'),
        ),
        throwsFormatException,
      );

      final toClear =
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
      final cleared = toClear.clearActivities();
      expect(cleared.baseTotal, 5);
      expect(cleared.baseMorning, 2);
      expect(cleared.grade, 1);
      expect(cleared.exemption, SunshineRunExemption.half);
      expect(cleared.activities.values, everyElement(0));
      expect(cleared.customActivities.single.total, 3);
      expect(cleared.customActivities.single.count, 0);
      expect(cleared.calculate().addedTotal, 0);
      expect(toClear.resetAll(), SunshineRunState(grade: 1));
      expect(toClear.calculate().total, 13);
    });

    test('JSON 严格往返、兼容旧记录，并拒绝损坏字段与累计溢出', () {
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
      expect(
        SunshineRunState.fromJson(targetOverride).calculate().fullTotal,
        48,
      );

      final overflowJson = SunshineRunState(
        exemption: SunshineRunExemption.full,
      ).toJson();
      overflowJson['baseTotal'] = kSunshineRunMaxCount;
      (overflowJson['activities'] as Map)['regular'] = 1;
      expect(
        () => SunshineRunState.fromJson(overflowJson),
        throwsFormatException,
      );
    });
  });

  group('SunshineRunStore', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory directory;

    final state = SunshineRunState(
      grade: 1,
      exemption: SunshineRunExemption.half,
      baseTotal: 10,
      baseMorning: 3,
      activities: {'regular': 4, 'morning': 5, 'fluorescent': 2, 'monday': 1},
      customActivities: [
        SunshineRunCustomActivity(
          id: 'custom-test',
          label: '测试活动',
          total: 3,
          morning: 1,
          count: 2,
        ),
      ],
    );

    File stateFile() => File('${directory.path}/state.json');

    setUp(() async {
      AppDirectories.resetForTesting();
      await AppLog.resetForTesting();
      directory = await Directory.systemTemp.createTemp('sunshine_run_store_');
      SunshineRunStore.debugDirectory = directory;
    });

    tearDown(() async {
      SunshineRunStore.debugDirectory = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      AppDirectories.resetForTesting();
      await AppLog.resetForTesting();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('首次为空，正常读写往返与兼容缺 customActivities 旧记录，普通保存不创建备份', () async {
      final empty = await SunshineRunStore.read();
      expect(empty.state, isNull);
      expect(empty.warning, isNull);
      expect(empty.corrupt, isFalse);
      expect(empty.available, isTrue);
      expect(await directory.list().toList(), isEmpty);

      expect(await SunshineRunStore.save(SunshineRunState.initial()), isTrue);
      expect(await SunshineRunStore.save(state), isTrue);
      final result = await SunshineRunStore.read();
      expect(result.state, state);
      expect(result.state!.calculate().total, 31);
      expect(result.state!.calculate().morning, 16);
      expect(result.warning, isNull);
      expect(result.corrupt, isFalse);
      expect(result.available, isTrue);
      expect(jsonDecode(await stateFile().readAsString()), state.toJson());
      expect(await directory.list().toList(), hasLength(1));
      expect(await File('${stateFile().path}.tmp').exists(), isFalse);
      expect(await File('${stateFile().path}.backup').exists(), isFalse);

      final legacy = state.toJson()..remove('customActivities');
      await stateFile().writeAsString(jsonEncode(legacy));
      final legacyResult = await SunshineRunStore.read();
      expect(legacyResult.state, state.copyWith(customActivities: []));
      expect(legacyResult.warning, isNull);
      expect(await stateFile().readAsString(), jsonEncode(legacy));
    });

    test('有效记录显式重试备份原始字节、防覆盖已有备份，无旧文件时不生成空备份', () async {
      // 无旧文件直接保存，不生成空备份。
      expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
      expect(await directory.list().toList(), hasLength(1));
      expect(await File('${stateFile().path}.backup').exists(), isFalse);
      expect(await File('${stateFile().path}.corrupt').exists(), isFalse);

      // 替换有效旧记录前先完整备份原始字节。
      final previous = state.withActivity('regular', 1);
      final original =
          '${const JsonEncoder.withIndent('  ').convert(previous.toJson())}\n';
      await stateFile().writeAsString(original);
      expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
      expect((await SunshineRunStore.read()).state, state);
      expect(
        await File('${stateFile().path}.backup').readAsBytes(),
        utf8.encode(original),
      );
      expect(await File('${stateFile().path}.corrupt').exists(), isFalse);
      expect(await File('${stateFile().path}.tmp').exists(), isFalse);

      // 再次显式重试不覆盖已有 .backup，自动生成带后缀新备份。
      final secondOriginal = await stateFile().readAsString();
      final latest = state.withActivity('regular', 6);
      expect(await SunshineRunStore.save(latest, replaceCorrupt: true), isTrue);
      final addedBackups = await directory
          .list()
          .where(
            (file) =>
                file.uri.pathSegments.last.startsWith('state.json.backup.'),
          )
          .cast<File>()
          .toList();
      expect(addedBackups, hasLength(1));
      expect(await addedBackups.single.readAsString(), secondOriginal);
      expect((await SunshineRunStore.read()).state, latest);
    });

    test('损坏字节读取保留原文件、记录原因与堆栈，普通保存拒绝覆盖', () async {
      final corruptRecords = <String, List<int>>{
        '坏 JSON': utf8.encode('{broken'),
        '非对象根节点': utf8.encode('[]'),
        '损坏字段': utf8.encode('{"version":1}'),
        '无效 UTF-8': [0xc3, 0x28],
      };
      for (final entry in corruptRecords.entries) {
        final records = <Map<String, Object?>>[];
        AppLog.recordListenerForTesting = records.add;
        await stateFile().writeAsBytes(entry.value);
        final result = await SunshineRunStore.read();

        expect(result.state, isNull, reason: entry.key);
        expect(result.warning, isNotEmpty, reason: entry.key);
        expect(result.corrupt, isTrue, reason: entry.key);
        expect(result.available, isTrue, reason: entry.key);
        expect(await stateFile().readAsBytes(), entry.value, reason: entry.key);
        expect(
          await directory.list().toList(),
          hasLength(1),
          reason: entry.key,
        );

        if (entry.key == '坏 JSON') {
          final failure = records.singleWhere(
            (record) => record['event'] == 'state.corrupt',
          );
          final attrs = failure['attrs'] as Map;
          expect(attrs['error_type'], 'FormatException');
          expect(attrs['error_chain'], isNotEmpty);
          expect(
            attrs['stack_trace'],
            allOf(
              contains('_ChunkedJsonParser'),
              contains('SunshineRunStore._readFile'),
            ),
          );
          expect(await SunshineRunStore.save(state), isFalse);
          expect(await stateFile().readAsBytes(), entry.value);
        }
      }
    });

    test('损坏记录显式重试备份原始字节、防覆盖已有备份与同名目录占位', () async {
      final original = [0xc3, 0x28, 0xff];
      await stateFile().writeAsBytes(original);
      expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
      expect((await SunshineRunStore.read()).state, state);
      expect(await File('${stateFile().path}.corrupt').readAsBytes(), original);
      expect(await File('${stateFile().path}.tmp').exists(), isFalse);

      // 多次重试不覆盖已有 .corrupt。
      await stateFile().writeAsString('{first-broken');
      expect(
        await SunshineRunStore.save(
          state.withActivity('regular', 6),
          replaceCorrupt: true,
        ),
        isTrue,
      );
      // .corrupt 被目录占用时保留目录并使用新名称。
      await File('${stateFile().path}.corrupt').delete();
      final occupied = Directory('${stateFile().path}.corrupt');
      await occupied.create();
      await stateFile().writeAsString('{second-broken');
      expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
      expect(await occupied.exists(), isTrue);

      final addedBackups = await directory
          .list()
          .where(
            (file) =>
                file.uri.pathSegments.last.startsWith('state.json.corrupt.'),
          )
          .cast<File>()
          .toList();
      expect(addedBackups, hasLength(2));
      expect(
        await Future.wait(addedBackups.map((file) => file.readAsString())),
        unorderedEquals(['{first-broken', '{second-broken']),
      );
    });

    test('备份创建或写入失败时拒绝替换并保留原件及失败诊断', () async {
      for (final failCreate in [true, false]) {
        final previous = state.withActivity('regular', 1);
        expect(await SunshineRunStore.save(previous), isTrue);
        final original = await stateFile().readAsBytes();
        final backup = File('${stateFile().path}.backup');
        final failingBackup = _FailingBackupFile(
          backup,
          failCreate: failCreate,
        );
        final records = <Map<String, Object?>>[];
        AppLog.recordListenerForTesting = records.add;

        final saved = await IOOverrides.runWithIOOverrides(
          () => SunshineRunStore.save(state, replaceCorrupt: true),
          _BackupFailureOverrides(failingBackup),
        );

        expect(saved, isFalse);
        expect(failingBackup.createAttempted, isTrue);
        expect(failingBackup.writeAttempted, !failCreate);
        expect(await stateFile().readAsBytes(), original);
        expect((await SunshineRunStore.read()).state, previous);
        expect(await backup.exists(), isFalse);
        expect(await File('${stateFile().path}.tmp').exists(), isFalse);
        final failure = records.singleWhere(
          (record) => record['event'] == 'state.save_failed',
        );
        final attrs = failure['attrs'] as Map;
        expect(attrs['stage'], 'valid_backup');
        expect(attrs['error_chain'], isNotEmpty);
        expect(attrs['stack_trace'], isNotEmpty);
      }
    });

    test('平台存储不可用或路径被反向类型占用时降级为不可用且保留原路径', () async {
      // 1. 平台通道不可用。
      SunshineRunStore.debugDirectory = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (_) async => throw PlatformException(code: 'storage_unavailable'),
          );
      final noPlatform = await SunshineRunStore.read();
      expect(noPlatform.state, isNull);
      expect(noPlatform.warning, isNotEmpty);
      expect(noPlatform.corrupt, isFalse);
      expect(noPlatform.available, isFalse);
      expect(await SunshineRunStore.save(state), isFalse);

      // 2. 存储目录被文件占用。
      final obstruction = File('${directory.path}/blocked');
      await obstruction.writeAsString('keep');
      SunshineRunStore.debugDirectory = Directory(obstruction.path);
      final fileBlocked = await SunshineRunStore.read();
      expect(fileBlocked.available, isFalse);
      expect(fileBlocked.corrupt, isFalse);
      expect(await SunshineRunStore.save(state), isFalse);
      expect(await obstruction.readAsString(), 'keep');

      // 3. 记录文件位置被目录占用。
      SunshineRunStore.debugDirectory = directory;
      await Directory(stateFile().path).create();
      final dirBlocked = await SunshineRunStore.read();
      expect(dirBlocked.available, isFalse);
      expect(dirBlocked.corrupt, isFalse);
      expect(await SunshineRunStore.save(state), isFalse);
      expect(await Directory(stateFile().path).exists(), isTrue);
    });

    test('临时文件写入失败时有效与损坏原件均保持原样，解除阻塞后可恢复', () async {
      final previous = state.withActivity('regular', 1);
      expect(await SunshineRunStore.save(previous), isTrue);
      final originalBytes = await stateFile().readAsBytes();
      final obstruction = Directory('${stateFile().path}.tmp');
      await obstruction.create();

      expect(await SunshineRunStore.save(state), isFalse);
      expect(await stateFile().readAsBytes(), originalBytes);
      expect((await SunshineRunStore.read()).state, previous);

      // 损坏文件重试写入 .tmp 失败时同样保留原损坏文件且不生成 .corrupt。
      await stateFile().writeAsString('{broken');
      expect(await SunshineRunStore.save(state, replaceCorrupt: true), isFalse);
      expect(await stateFile().readAsString(), '{broken');
      expect(await File('${stateFile().path}.corrupt').exists(), isFalse);

      await obstruction.delete();
      expect(await SunshineRunStore.save(state, replaceCorrupt: true), isTrue);
      expect((await SunshineRunStore.read()).state, state);
    });

    test('连续并发保存按调用顺序完成，最终恢复最后一次状态', () async {
      final completed = <int>[];
      final operations = [
        for (var count = 1; count <= 12; count++)
          SunshineRunStore.save(state.withActivity('morning', count))
              .then((saved) {
                completed.add(count);
                return saved;
              }),
      ];

      expect(await Future.wait(operations), everyElement(isTrue));
      expect(completed, [for (var count = 1; count <= 12; count++) count]);
      expect((await SunshineRunStore.read()).state!.activities['morning'], 12);
      expect(await File('${stateFile().path}.tmp').exists(), isFalse);
    });

    test('队列前一次失败不会阻断后续保存，目录按调用时确定', () async {
      final obstruction = File('${directory.path}/blocked');
      await obstruction.writeAsString('keep');
      SunshineRunStore.debugDirectory = Directory(obstruction.path);
      final failed = SunshineRunStore.save(SunshineRunState.initial());

      SunshineRunStore.debugDirectory = directory;
      final succeeded = SunshineRunStore.save(state);

      expect(await Future.wait([failed, succeeded]), [false, true]);
      expect((await SunshineRunStore.read()).state, state);
      expect(await obstruction.readAsString(), 'keep');
    });
  });

  group('SunshineRunController', () {
    test('首次恢复本机记录并合并重复启动', () async {
      final saved = SunshineRunState(grade: 1, baseTotal: 18, baseMorning: 12);
      final h = _Harness(restored: SunshineRunStoreReadResult(state: saved));
      addTearDown(h.controller.dispose);
      expect(h.controller.restoringState, isTrue);
      await Future.wait([
        h.controller.ensureStarted(),
        h.controller.ensureStarted(),
      ]);
      expect(h.reads, 1);
      expect(h.controller.state, saved.copyWith(grade: 2));
      expect(h.controller.result.total, 18);
      expect(h.controller.restoringState, isFalse);
      expect(h.controller.canUndo, isFalse);
      expect(h.saved, isEmpty);
    });

    test('恢复期间相对加一保留旧基数、各活动和自定义定义', () async {
      final read = Completer<SunshineRunStoreReadResult>();
      final cached = SunshineRunState(
        baseTotal: 10,
        baseMorning: 7,
        activities: const {
          'regular': 4,
          'morning': 3,
          'fluorescent': 2,
          'monday': 1,
        },
        customActivities: [
          SunshineRunCustomActivity(
            id: 'saved-custom',
            total: 4,
            morning: 2,
            count: 3,
          ),
        ],
      );
      final h = _Harness(readOverride: () => read.future);
      addTearDown(h.controller.dispose);
      final starting = h.controller.ensureStarted();
      final first = h.controller.adjustActivityCount('regular', 1);
      final second = h.controller.adjustCustomCount('saved-custom', 1);
      expect(h.controller.restoringState, isTrue);
      expect(h.saved, isEmpty);
      read.complete(SunshineRunStoreReadResult(state: cached));
      await starting;
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(h.controller.state.baseTotal, 10);
      expect(h.controller.state.baseMorning, 7);
      expect(h.controller.state.activities, {
        ...cached.activities,
        'regular': 5,
      });
      expect(h.controller.state.customActivities.single.count, 4);
      expect(h.controller.state.customActivities.single.total, 4);
      expect(h.saved.last, h.controller.state);
      await h.controller.undo();
      await h.controller.undo();
      expect(h.controller.state, cached);
    });

    test('恢复期间绝对设值从旧记录按字段修改，不覆盖其它活动', () async {
      final read = Completer<SunshineRunStoreReadResult>();
      final h = _Harness(readOverride: () => read.future);
      addTearDown(h.controller.dispose);
      final editing = h.controller.setActivityCount('regular', 2);
      read.complete(
        SunshineRunStoreReadResult(
          state: SunshineRunState(
            baseTotal: 20,
            baseMorning: 5,
          ).withActivity('morning', 4),
        ),
      );
      await editing;
      expect(h.controller.state.baseTotal, 20);
      expect(h.controller.state.activities['regular'], 2);
      expect(h.controller.state.activities['morning'], 4);
    });

    test('恢复超时、读取异常或不可用时普通编辑不覆盖未知旧记录，明确重试才解锁', () async {
      final delayed = Completer<SunshineRunStoreReadResult>();
      final timeoutH = _Harness(
        readOverride: () => delayed.future,
        restoreTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(timeoutH.controller.dispose);
      await timeoutH.controller.ensureStarted();
      expect(timeoutH.controller.restoringState, isFalse);
      expect(timeoutH.controller.storageWarning, isNotNull);
      expect(
        await timeoutH.controller.adjustActivityCount('regular', 1),
        isFalse,
      );
      expect(timeoutH.controller.result.total, 1);
      expect(timeoutH.saved, isEmpty);
      delayed.complete(
        SunshineRunStoreReadResult(state: SunshineRunState(baseTotal: 20)),
      );
      await _flush();
      expect(timeoutH.controller.result.total, 1);
      expect(await timeoutH.controller.retrySave(), isTrue);
      expect(timeoutH.replacements, [true]);
      expect(timeoutH.controller.storageWarning, isNull);
      expect(
        await timeoutH.controller.adjustActivityCount('regular', 1),
        isTrue,
      );
      expect(timeoutH.controller.result.total, 2);

      for (final read in <Future<SunshineRunStoreReadResult> Function()>[
        () async => throw StateError('合成读取失败'),
        () async => const SunshineRunStoreReadResult(available: false),
      ]) {
        final source = _AcademicSource(value: _knownGrade(1));
        final h = _Harness(source: source, readOverride: read);
        await h.controller.ensureStarted();
        await _flush();
        expect(h.controller.state.grade, 1);
        expect(h.controller.storageWarning, isNotNull);
        expect(await h.controller.setBaseline(8, 3), isFalse);
        await h.controller.ensureStarted();
        expect(h.reads, 1);
        expect(h.controller.result.total, 8);
        expect(h.saved, isEmpty);
        expect(await h.controller.retrySave(), isTrue);
        expect(h.replacements, [true]);
        expect(h.saved.single.grade, 1);
        h.controller.dispose();
      }
    });

    test('恢复后连续编辑同步计算，并按顺序保存不可变快照', () async {
      final gate = Completer<bool>();
      final h = _Harness(
        saveOverride: (state, {replaceCorrupt = false}) => gate.future,
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      final first = h.controller.adjustActivityCount('regular', 1);
      expect(h.controller.result.total, 1);
      final second = h.controller.adjustActivityCount('regular', 1);
      expect(h.controller.result.total, 2);
      await _flush();
      expect(h.saved.map((state) => state.calculate().total), [1]);
      gate.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(h.saved.map((state) => state.calculate().total), [1, 2]);
      expect(h.controller.result.total, 2);
    });

    test('旧保存失败不回退最新内存，后续保存成功清除警告', () async {
      final first = Completer<bool>();
      var writes = 0;
      final h = _Harness(
        saveOverride: (state, {replaceCorrupt = false}) =>
            ++writes == 1 ? first.future : Future.value(true),
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      final a = h.controller.setBaseline(10, 2);
      final b = h.controller.adjustActivityCount('morning', 3);
      expect(h.controller.result.total, 13);
      first.complete(false);
      expect(await a, isFalse);
      expect(await b, isTrue);
      expect(h.controller.result.total, 13);
      expect(h.controller.result.morning, 5);
      expect(h.controller.storageWarning, isNull);
    });

    test('写入抛错不打断队列，失败修改仍可撤销和重试', () async {
      var writes = 0;
      final h = _Harness(
        saveOverride: (state, {replaceCorrupt = false}) async {
          if (++writes == 1) throw StateError('合成写入失败');
          return true;
        },
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      expect(await h.controller.setActivityCount('morning', 3), isFalse);
      expect(h.controller.result.total, 3);
      expect(h.controller.canUndo, isTrue);
      expect(h.controller.storageWarning, isNotNull);
      expect(await h.controller.undo(), isTrue);
      expect(h.controller.result.total, 0);
      expect(h.controller.storageWarning, isNull);
      expect(await h.controller.retrySave(), isTrue);
    });

    test('损坏缓存不被普通修改替换，明确重试后解除警告', () async {
      final h = _Harness(
        restored: const SunshineRunStoreReadResult(
          corrupt: true,
          warning: '原始记录损坏且已保留',
        ),
        saveOverride: (state, {replaceCorrupt = false}) async => replaceCorrupt,
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      expect(h.controller.storageCorrupt, isTrue);
      expect(await h.controller.setBaseline(12, 8), isFalse);
      expect(h.controller.result.total, 12);
      expect(h.replacements, [false]);
      expect(h.controller.storageCorrupt, isTrue);
      expect(h.controller.storageWarning, contains('损坏'));
      expect(await h.controller.retrySave(), isTrue);
      expect(h.replacements, [false, true]);
      expect(h.controller.storageCorrupt, isFalse);
      expect(h.controller.storageWarning, isNull);
    });

    test('一次长按多个步骤只记录一个撤销点，并复用业务Trace', () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      await h.controller.adjustActivityCount('fluorescent', 1);
      await _flush();
      await h.controller.adjustActivityCount(
        'fluorescent',
        1,
        recordUndo: false,
      );
      await h.controller.adjustActivityCount(
        'fluorescent',
        1,
        recordUndo: false,
      );
      expect(h.controller.result.total, 6);
      expect(h.traceIds, everyElement(isNotNull));
      expect(h.traceIds.toSet().length, 1);
      h.controller.finishActivityAdjustment();
      await h.controller.adjustActivityCount('fluorescent', 1);
      expect(h.traceIds.last, isNot(h.traceIds.first));
      await h.controller.undo();
      expect(h.controller.result.total, 6);
      await h.controller.undo();
      expect(h.controller.result.total, 0);
      expect(h.controller.canUndo, isFalse);
    });

    test('自定义活动可编辑、计数、删除、撤销，标识不会复用已有项目', () async {
      final cached = SunshineRunState(
        customActivities: [SunshineRunCustomActivity(id: 'custom-1', count: 1)],
      );
      final h = _Harness(restored: SunshineRunStoreReadResult(state: cached));
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      await h.controller.saveCustomActivity(
        label: '拓展活动',
        total: 4,
        morning: 2,
        count: 2,
      );
      final id = h.controller.state.customActivities.last.id;
      expect(id, isNot('custom-1'));
      expect(h.controller.result.total, 9);
      await h.controller.saveCustomActivity(
        id: id,
        label: '修改活动',
        total: 3,
        morning: 3,
        count: 2,
      );
      await h.controller.adjustCustomCount(id, 1);
      expect(h.controller.state.customActivities.last.count, 3);
      expect(h.controller.result.morning, 9);
      final beforeDelete = h.controller.state;
      await h.controller.removeCustomActivity(id);
      expect(h.controller.state.customActivities.length, 1);
      await h.controller.undo();
      expect(h.controller.state, beforeDelete);
    });

    test('清新增保留定义和基数，全清保留年级，均可撤销', () async {
      final cached =
          SunshineRunState(
                grade: 1,
                exemption: SunshineRunExemption.half,
                baseTotal: 8,
                baseMorning: 4,
              )
              .withActivity('monday', 2)
              .withCustomAdded(
                SunshineRunCustomActivity(
                  id: 'custom-saved',
                  total: 2,
                  morning: 1,
                  count: 3,
                ),
              );
      final h = _Harness(
        restored: SunshineRunStoreReadResult(state: cached),
        source: _AcademicSource(value: _knownGrade(1)),
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      await h.controller.resetActivities();
      expect(h.controller.state.baseTotal, 8);
      expect(h.controller.state.exemption, SunshineRunExemption.half);
      expect(h.controller.state.customActivities.single.count, 0);
      expect(h.controller.state.customActivities.single.total, 2);
      await h.controller.undo();
      expect(h.controller.state, cached);
      await h.controller.resetAll();
      expect(h.controller.state, SunshineRunState(grade: 1));
      await h.controller.undo();
      expect(h.controller.state, cached);
    });

    test('半免全免互斥且再次选择关闭，不改已有次数', () async {
      final h = _Harness(
        restored: SunshineRunStoreReadResult(
          state: SunshineRunState(baseTotal: 10, baseMorning: 5),
        ),
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      await h.controller.toggleExemption(SunshineRunExemption.half);
      expect(h.controller.result.fullTotal, 24);
      await h.controller.toggleExemption(SunshineRunExemption.full);
      expect(h.controller.result.status, SunshineRunStatus.exempt);
      expect(h.controller.result.total, 10);
      await h.controller.toggleExemption(SunshineRunExemption.full);
      expect(h.controller.state.exemption, SunshineRunExemption.none);
    });

    test('非法编辑不改变记录、撤销点或持久化', () async {
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      expect(() => h.controller.setBaseline(3, 4), throwsFormatException);
      expect(
        () => h.controller.setActivityCount('unknown', 1),
        throwsFormatException,
      );
      expect(
        () => h.controller.adjustActivityCount('regular', -1),
        throwsFormatException,
      );
      expect(
        () => h.controller.saveCustomActivity(
          label: '错误活动',
          total: 1,
          morning: 2,
          count: 1,
        ),
        throwsFormatException,
      );
      expect(h.controller.state, SunshineRunState.initial());
      expect(h.controller.canUndo, isFalse);
      expect(h.saved, isEmpty);
    });

    test('可靠本地大一大二信息生效，缺失/不可靠/异常/超时统一回退大二且不污染记录', () async {
      for (final grade in [1, 2]) {
        final source = _AcademicSource(value: _knownGrade(grade));
        final h = _Harness(source: source);
        addTearDown(h.controller.dispose);
        await h.controller.ensureStarted();
        await _flush();
        expect(h.controller.state.grade, grade);
        expect(h.controller.result.fullTotal, grade == 1 ? 36 : 48);
        expect(h.controller.canUndo, isFalse);
        expect(source.reads, 1);
        expect(h.reads, 1);
      }

      final cached = SunshineRunState(
        grade: 1,
        baseTotal: 12,
        baseMorning: 6,
        exemption: SunshineRunExemption.half,
        customActivities: [
          SunshineRunCustomActivity(id: 'saved-custom', total: 2, count: 3),
        ],
      ).withActivity('morning', 2);
      for (final info in [
        const StudentAcademicInfo(),
        const StudentAcademicInfo(
          identityMatches: true,
          undergraduate: true,
          academicYear: 2025,
          enrollmentYear: 2025,
        ),
        const StudentAcademicInfo(
          portalBound: true,
          undergraduate: true,
          academicYear: 2025,
          enrollmentYear: 2025,
        ),
        const StudentAcademicInfo(
          portalBound: true,
          identityMatches: true,
          academicYear: 2025,
          enrollmentYear: 2025,
        ),
        const StudentAcademicInfo(
          portalBound: true,
          identityMatches: true,
          undergraduate: true,
        ),
        const StudentAcademicInfo(
          portalBound: true,
          identityMatches: true,
          undergraduate: true,
          academicYear: 2024,
          enrollmentYear: 2025,
        ),
        const StudentAcademicInfo(
          portalBound: true,
          identityMatches: true,
          undergraduate: true,
          academicYear: 2200,
          enrollmentYear: 2025,
        ),
        const StudentAcademicInfo(
          portalBound: true,
          identityMatches: true,
          undergraduate: true,
          academicYear: 2025,
          enrollmentYear: 2025,
          loading: true,
        ),
        const StudentAcademicInfo(
          portalBound: true,
          identityMatches: true,
          undergraduate: true,
          academicYear: 2025,
          enrollmentYear: 2025,
          error: '合成本地信息错误',
        ),
        _knownGrade(3),
      ]) {
        final source = _AcademicSource(value: info);
        final h = _Harness(
          source: source,
          restored: SunshineRunStoreReadResult(state: cached),
        );
        addTearDown(h.controller.dispose);
        await h.controller.ensureStarted();
        await _flush();
        expect(h.controller.state, cached.copyWith(grade: 2));
        expect(h.controller.result.total, cached.calculate().total);
        expect(h.controller.canUndo, isFalse);
        expect(h.saved, isEmpty);
        expect(source.reads, 1);
      }

      // 读取异常或超时默认大二，迟到结果不改变计数。
      final failedH = _Harness(
        source: _AcademicSource(
          readOverride: () async => throw StateError('合成本地年级读取失败'),
        ),
        restored: SunshineRunStoreReadResult(
          state: SunshineRunState(grade: 1, baseTotal: 11, baseMorning: 4),
        ),
      );
      addTearDown(failedH.controller.dispose);
      await failedH.controller.ensureStarted();
      await _flush();
      expect(failedH.controller.state.grade, 2);
      expect(failedH.controller.result.total, 11);
      expect(failedH.saved, isEmpty);

      final delayed = Completer<StudentAcademicInfo>();
      final timed = _AcademicSource(readOverride: () => delayed.future);
      final timedH = _Harness(
        source: timed,
        gradeReadTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(timedH.controller.dispose);
      await timedH.controller.ensureStarted();
      await timedH.controller.ensureStarted();
      expect(timedH.controller.state.grade, 2);
      expect(timed.reads, 1);
      await timedH.controller.setBaseline(9, 3);
      delayed.complete(_knownGrade(1));
      await _flush();
      expect(timedH.controller.state.grade, 2);
      expect(timedH.controller.result.total, 9);
    });

    test('重进仅读本地年级且并发去重，不重新恢复次数，自动年级不进撤销栈', () async {
      final local = Completer<StudentAcademicInfo>();
      var pending = true;
      late final _AcademicSource source;
      source = _AcademicSource(
        value: _knownGrade(1),
        readOverride: () => pending ? local.future : Future.value(source.value),
      );
      final h = _Harness(
        source: source,
        restored: SunshineRunStoreReadResult(
          state: SunshineRunState(baseTotal: 9, baseMorning: 4),
        ),
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      final first = h.controller.ensureStarted();
      final second = h.controller.ensureStarted();
      expect(source.reads, 1);
      local.complete(_knownGrade(1));
      await Future.wait([first, second]);
      pending = false;
      expect(h.controller.state.grade, 1);

      await h.controller.adjustActivityCount('morning', 2);
      source.value = _knownGrade(2);
      await h.controller.ensureStarted();
      expect(h.controller.state.grade, 2);
      source.value = const StudentAcademicInfo();
      await h.controller.ensureStarted();
      expect(h.controller.state.grade, 2);
      expect(h.controller.result.total, 11);
      expect(h.reads, 1);
      expect(source.reads, 3);

      // 撤销只回退用户编辑，始终沿用最新自动年级。
      source.value = _knownGrade(1);
      await h.controller.ensureStarted();
      await h.controller.undo();
      expect(
        h.controller.state,
        SunshineRunState(grade: 1, baseTotal: 9, baseMorning: 4),
      );
      expect(h.controller.canUndo, isFalse);
    });

    test('延迟本地年级不阻塞编辑，晚到结果保留新记录与长按 Trace', () async {
      final local = Completer<StudentAcademicInfo>();
      final source = _AcademicSource(readOverride: () => local.future);
      final cached = SunshineRunState(
        baseTotal: 7,
        baseMorning: 3,
      ).withActivity('morning', 1);
      final h = _Harness(
        source: source,
        restored: SunshineRunStoreReadResult(state: cached),
      );
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      expect(h.controller.restoringState, isFalse);
      expect(h.controller.state.grade, 2);
      expect(await h.controller.adjustActivityCount('fluorescent', 1), isTrue);
      final adjustmentTrace = h.traceIds.single;
      local.complete(_knownGrade(1));
      await _flush();
      expect(h.controller.state.grade, 1);
      expect(
        await h.controller.adjustActivityCount(
          'fluorescent',
          1,
          recordUndo: false,
        ),
        isTrue,
      );
      expect(h.traceIds.last, adjustmentTrace);
      expect(h.controller.result.total, 12);
      h.controller.finishActivityAdjustment();
      await h.controller.undo();
      expect(h.controller.state, cached.copyWith(grade: 1));
      expect(h.controller.canUndo, isFalse);
      expect(source.reads, 1);
    });

    test('绑定变化使旧本地结果失效，旧读取完成不能清掉新在途读取', () async {
      for (final oldCompletesFirst in [true, false]) {
        final oldLocal = Completer<StudentAcademicInfo>();
        final newLocal = Completer<StudentAcademicInfo>();
        var calls = 0;
        final source = _AcademicSource(
          readOverride: () => ++calls == 1 ? oldLocal.future : newLocal.future,
        );
        final h = _Harness(source: source);
        addTearDown(h.controller.dispose);
        await h.controller.ensureStarted();
        expect(source.reads, 1);
        final rebinding = h.controller.onPortalBindingChanged(true);
        expect(source.reads, 2);
        expect(await h.controller.setBaseline(13, 5), isTrue);
        if (oldCompletesFirst) {
          oldLocal.complete(_knownGrade(1));
          await _flush();
          expect(h.controller.state.grade, 2);
          final entering = h.controller.ensureStarted();
          expect(source.reads, 2);
          newLocal.complete(_knownGrade(2));
          await Future.wait([rebinding, entering]);
        } else {
          newLocal.complete(_knownGrade(2));
          await rebinding;
          oldLocal.complete(_knownGrade(1));
          await _flush();
        }
        expect(h.controller.state.grade, 2);
        expect(h.controller.result.total, 13);
        expect(h.controller.result.morning, 5);
        expect(source.reads, 2);
        expect(h.reads, 1);
        expect(h.saved.single.baseTotal, 13);
      }
    });

    test('恢复期间与恢复后解绑/重绑保留记录、按最新绑定决定是否读本地', () async {
      // 1. 恢复期间先绑后解绑再绑，只用最新身份且不丢编辑。
      final read1 = Completer<SunshineRunStoreReadResult>();
      final source1 = _AcademicSource(value: _knownGrade(1));
      final cached = SunshineRunState(
        grade: 1,
        baseTotal: 13,
        baseMorning: 5,
      ).withActivity('regular', 4);
      final h1 = _Harness(source: source1, readOverride: () => read1.future);
      addTearDown(h1.controller.dispose);
      final starting = h1.controller.ensureStarted();
      final b1 = h1.controller.onPortalBindingChanged(true);
      final u1 = h1.controller.onPortalBindingChanged(false);
      final r1 = h1.controller.onPortalBindingChanged(true);
      final editing = h1.controller.adjustActivityCount('regular', 1);
      expect(h1.saved, isEmpty);
      expect(source1.reads, 0);
      read1.complete(SunshineRunStoreReadResult(state: cached));
      await Future.wait([starting, b1, u1, r1, editing]);
      expect(h1.controller.state.grade, 1);
      expect(h1.controller.result.total, 18);
      expect(source1.reads, 1);
      expect(h1.saved.every((state) => state.baseTotal == 13), isTrue);

      // 恢复后解绑回退大二，重进不读取，重新绑定仅读本地缓存。
      await h1.controller.onPortalBindingChanged(false);
      expect(h1.controller.state.grade, 2);
      expect(h1.controller.result.total, 18);
      await h1.controller.ensureStarted();
      expect(source1.reads, 1);
      await h1.controller.onPortalBindingChanged(true);
      expect(source1.reads, 2);
      expect(h1.controller.state.grade, 1);
      await h1.controller.undo();
      expect(h1.controller.state, cached);

      // 2. 初始恢复期间最终停在解绑时阻止本地读取。
      final read2 = Completer<SunshineRunStoreReadResult>();
      final source2 = _AcademicSource(value: _knownGrade(1));
      final h2 = _Harness(source: source2, readOverride: () => read2.future);
      addTearDown(h2.controller.dispose);
      final b2 = h2.controller.onPortalBindingChanged(true);
      final u2 = h2.controller.onPortalBindingChanged(false);
      read2.complete(
        SunshineRunStoreReadResult(
          state: SunshineRunState(grade: 1, baseTotal: 13, baseMorning: 5),
        ),
      );
      await Future.wait([b2, u2]);
      expect(h2.controller.state.grade, 2);
      expect(source2.reads, 0);
      expect(h2.controller.result.total, 13);
      expect(h2.saved, isEmpty);
    });

    test('业务日志不会记录自定义活动名称', () async {
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;
      addTearDown(() => AppLog.recordListenerForTesting = null);
      final h = _Harness();
      addTearDown(h.controller.dispose);
      await h.controller.ensureStarted();
      await h.controller.saveCustomActivity(
        label: '私密活动名称',
        total: 2,
        morning: 1,
        count: 3,
      );
      expect(jsonEncode(records), isNot(contains('私密活动名称')));
      expect(
        records.where((record) => record['event'] == 'custom.add.completed'),
        isNotEmpty,
      );
    });

    test('dispose 后晚到恢复、晚到本地年级与撤销/重试均安全静默结束', () async {
      // 1. 恢复未完成即 dispose：后续操作立即返回 false 且不通知/不保存/不读年级。
      final read = Completer<SunshineRunStoreReadResult>();
      final source1 = _AcademicSource(value: _knownGrade(1));
      final h1 = _Harness(source: source1, readOverride: () => read.future);
      var notifications1 = 0;
      h1.controller.addListener(() => notifications1++);
      final starting = h1.controller.ensureStarted();
      final editing = h1.controller.adjustActivityCount('regular', 1);
      h1.controller.dispose();
      expect(await h1.controller.undo(), isFalse);
      expect(await h1.controller.retrySave(), isFalse);
      await h1.controller.onPortalBindingChanged(true);
      read.complete(
        SunshineRunStoreReadResult(state: SunshineRunState(baseTotal: 7)),
      );
      await starting;
      expect(await editing, isFalse);
      expect(notifications1, 0);
      expect(h1.saved, isEmpty);
      expect(source1.reads, 0);

      // 2. 晚到本地年级到达时已 dispose：不通知、不保存、不重新读取。
      final local = Completer<StudentAcademicInfo>();
      final source2 = _AcademicSource(readOverride: () => local.future);
      final h2 = _Harness(
        source: source2,
        restored: SunshineRunStoreReadResult(
          state: SunshineRunState(baseTotal: 7),
        ),
      );
      var notifications2 = 0;
      h2.controller.addListener(() => notifications2++);
      await h2.controller.ensureStarted();
      final beforeDispose = notifications2;
      h2.controller.dispose();
      local.complete(_knownGrade(1));
      await _flush();
      await h2.controller.ensureStarted();
      await h2.controller.onPortalBindingChanged(true);
      expect(h2.controller.state.grade, 2);
      expect(h2.controller.result.total, 7);
      expect(notifications2, beforeDispose);
      expect(h2.saved, isEmpty);
      expect(source2.reads, 1);
    });
  });
}

final class _BackupFailureOverrides extends IOOverrides {
  _BackupFailureOverrides(this.backup);

  final File backup;

  @override
  File createFile(String path) =>
      path.endsWith('state.json.backup') ? backup : super.createFile(path);
}

class _FailingBackupFile implements File {
  _FailingBackupFile(this.file, {required this.failCreate});

  final File file;
  final bool failCreate;
  bool createAttempted = false;
  bool writeAttempted = false;

  @override
  String get path => file.path;

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    createAttempted = true;
    if (failCreate) {
      throw FileSystemException('synthetic backup create failure', path);
    }
    await file.create(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    writeAttempted = true;
    await file.writeAsBytes(bytes.take(3).toList(), mode: mode, flush: flush);
    throw FileSystemException('synthetic backup write failure', path);
  }

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

StudentAcademicInfo _knownGrade(int grade) => StudentAcademicInfo(
  portalBound: true,
  identityMatches: true,
  undergraduate: true,
  academicYear: 2025 + grade - 1,
  enrollmentYear: 2025,
  fromCache: true,
);

class _AcademicSource implements StudentAcademicSource {
  _AcademicSource({
    this.value = const StudentAcademicInfo(),
    this.readOverride,
  });

  StudentAcademicInfo value;
  final Future<StudentAcademicInfo> Function()? readOverride;
  int reads = 0;

  @override
  Future<StudentAcademicInfo> readLocal() async {
    reads++;
    return readOverride == null ? value : await readOverride!();
  }
}

class _Harness {
  _Harness({
    SunshineRunStoreReadResult restored = const SunshineRunStoreReadResult(),
    StudentAcademicSource? source,
    Future<SunshineRunStoreReadResult> Function()? readOverride,
    Future<bool> Function(SunshineRunState, {bool replaceCorrupt})?
    saveOverride,
    Duration restoreTimeout = const Duration(seconds: 5),
    Duration gradeReadTimeout = const Duration(seconds: 2),
  }) {
    controller = SunshineRunController.forTesting(
      read: () async {
        reads++;
        return readOverride == null ? restored : await readOverride();
      },
      save: (state, {replaceCorrupt = false}) async {
        saved.add(state);
        replacements.add(replaceCorrupt);
        traceIds.add(AppLog.currentTraceId);
        return saveOverride == null
            ? true
            : await saveOverride(state, replaceCorrupt: replaceCorrupt);
      },
      gradeSource: source,
      restoreTimeout: restoreTimeout,
      gradeReadTimeout: gradeReadTimeout,
    );
  }

  late final SunshineRunController controller;
  final List<SunshineRunState> saved = [];
  final List<bool> replacements = [];
  final List<String?> traceIds = [];
  int reads = 0;
}
