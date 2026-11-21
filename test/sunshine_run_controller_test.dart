import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/student_academic_info.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_controller.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_models.dart';
import 'package:nuist_sta_app/mini_apps/sunshine_run/sunshine_run_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    expect(h.controller.state, saved);
    expect(h.controller.result.total, 18);
    expect(h.controller.restoringState, isFalse);
    expect(h.controller.canUndo, isFalse);
    expect(h.saved, isEmpty);
    expect(h.controller.gradeMessage, contains('手动选择'));
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
    expect(h.controller.state.activities, {...cached.activities, 'regular': 5});
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

  test('恢复超时解除限制，普通编辑不覆盖未知旧记录，明确重试才解锁', () async {
    final delayed = Completer<SunshineRunStoreReadResult>();
    final h = _Harness(
      readOverride: () => delayed.future,
      restoreTimeout: const Duration(milliseconds: 1),
    );
    addTearDown(h.controller.dispose);
    await h.controller.ensureStarted();
    expect(h.controller.restoringState, isFalse);
    expect(h.controller.storageWarning, isNotNull);
    expect(await h.controller.adjustActivityCount('regular', 1), isFalse);
    expect(h.controller.result.total, 1);
    expect(h.saved, isEmpty);
    delayed.complete(
      SunshineRunStoreReadResult(state: SunshineRunState(baseTotal: 20)),
    );
    await _flush();
    expect(h.controller.result.total, 1);
    expect(await h.controller.retrySave(), isTrue);
    expect(h.replacements, [true]);
    expect(h.controller.storageWarning, isNull);
    expect(await h.controller.adjustActivityCount('regular', 1), isTrue);
    expect(h.controller.result.total, 2);
  });

  test('缓存异常或不可用时不重复恢复，保留内存和原文件', () async {
    for (final read in <Future<SunshineRunStoreReadResult> Function()>[
      () async => throw StateError('合成读取失败'),
      () async => const SunshineRunStoreReadResult(available: false),
    ]) {
      final h = _Harness(readOverride: read);
      await h.controller.ensureStarted();
      expect(h.controller.storageWarning, isNotNull);
      expect(await h.controller.setBaseline(8, 3), isFalse);
      await h.controller.ensureStarted();
      expect(h.reads, 1);
      expect(h.controller.result.total, 8);
      expect(h.saved, isEmpty);
      expect(await h.controller.retrySave(), isTrue);
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
    // 模拟后续步骤来自首次操作作用域以外的 Timer 回调。
    await _flush();
    await h.controller.adjustActivityCount('fluorescent', 1, recordUndo: false);
    await h.controller.adjustActivityCount('fluorescent', 1, recordUndo: false);
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
    final h = _Harness(restored: SunshineRunStoreReadResult(state: cached));
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
    expect(() => h.controller.setGrade(3), throwsFormatException);
    expect(h.controller.state, SunshineRunState.initial());
    expect(h.controller.canUndo, isFalse);
    expect(h.saved, isEmpty);
  });

  test('后台学年识别不会阻塞本机恢复或编辑，并说明缓存来源', () async {
    final source = _AcademicSource(initialGate: Completer<void>());
    final h = _Harness(source: source);
    addTearDown(h.controller.dispose);
    addTearDown(source.dispose);
    await h.controller.ensureStarted();
    expect(h.controller.restoringState, isFalse);
    expect(h.controller.identifyingGrade, isTrue);
    await h.controller.setBaseline(9, 4);
    source.set(_knownGrade(1, fromCache: true));
    expect(h.controller.state.grade, 1);
    expect(h.controller.state.baseTotal, 9);
    expect(h.controller.gradeMessage, contains('本机缓存'));
    expect(h.controller.gradeMessage, contains('2025—2026'));
    source.initialGate!.complete();
    await _flush();
    expect(h.controller.identifyingGrade, isFalse);
    await h.controller.undo();
    expect(h.controller.state.grade, 1);
    expect(h.controller.result.total, 0);
  });

  test('手动年级优先于晚到自动来源，明确重新识别后可更新', () async {
    final source = _AcademicSource(initialGate: Completer<void>());
    final h = _Harness(source: source);
    addTearDown(h.controller.dispose);
    addTearDown(source.dispose);
    await h.controller.ensureStarted();
    await h.controller.setGrade(2);
    source.set(_knownGrade(1));
    source.initialGate!.complete();
    await _flush();
    expect(h.controller.state.grade, 2);
    expect(h.controller.gradeMessage, contains('手动选择'));
    await h.controller.identifyGrade();
    expect(h.controller.state.grade, 1);
    expect(h.controller.gradeMessage, contains('门户信息'));
  });

  test('等待本机恢复时发起识别不能覆盖随后手动年级', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final source = _AcademicSource(value: _knownGrade(1));
    final h = _Harness(source: source, readOverride: () => read.future);
    addTearDown(h.controller.dispose);
    addTearDown(source.dispose);
    final identifying = h.controller.identifyGrade();
    final manual = h.controller.setGrade(2);
    read.complete(
      SunshineRunStoreReadResult(
        state: SunshineRunState(grade: 1, baseTotal: 11, baseMorning: 3),
      ),
    );
    await Future.wait([identifying, manual]);
    expect(h.controller.state.grade, 2);
    expect(h.controller.state.baseTotal, 11);
    expect(source.refreshes, 0);
    expect(h.controller.gradeMessage, contains('手动选择'));
  });

  test('在途重新识别期间手动年级不会被结果或finally覆盖', () async {
    final source = _AcademicSource(
      value: _knownGrade(2),
      refreshGate: Completer<void>(),
    );
    final h = _Harness(source: source);
    addTearDown(h.controller.dispose);
    addTearDown(source.dispose);
    await h.controller.ensureStarted();
    final identifying = h.controller.identifyGrade();
    await _flush();
    await h.controller.setGrade(2);
    source.set(_knownGrade(1));
    source.refreshGate!.complete();
    await identifying;
    expect(h.controller.state.grade, 2);
    expect(h.controller.identifyingGrade, isFalse);
    expect(h.controller.gradeMessage, contains('手动选择'));
  });

  test('来源缺失或年级不支持时沿用当前选择并说明原因', () async {
    final source = _AcademicSource();
    final h = _Harness(
      source: source,
      restored: SunshineRunStoreReadResult(
        state: SunshineRunState(grade: 1, baseTotal: 12, baseMorning: 6),
      ),
    );
    addTearDown(h.controller.dispose);
    addTearDown(source.dispose);
    await h.controller.ensureStarted();
    await _flush();
    expect(h.controller.gradeMessage, contains('未绑定'));
    source.set(_knownGrade(3));
    expect(h.controller.state.grade, 1);
    expect(h.controller.gradeMessage, contains('范围'));
    source.set(
      const StudentAcademicInfo(portalBound: true, identityMatches: false),
    );
    expect(h.controller.gradeMessage, contains('当前账号'));
    source.set(
      const StudentAcademicInfo(portalBound: true, identityMatches: true),
    );
    expect(h.controller.gradeMessage, contains('用户类别'));
    source.set(
      const StudentAcademicInfo(
        portalBound: true,
        identityMatches: true,
        undergraduate: true,
      ),
    );
    expect(h.controller.gradeMessage, contains('不完整'));
    expect(h.controller.result.total, 12);
  });

  test('解绑保留记录，旧绑定回调不重启识别，重新绑定可更新年级', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final source = _AcademicSource(value: _knownGrade(1));
    final h = _Harness(source: source, readOverride: () => read.future);
    addTearDown(h.controller.dispose);
    addTearDown(source.dispose);
    final binding = h.controller.onPortalBindingChanged(true);
    final unbinding = h.controller.onPortalBindingChanged(false);
    read.complete(
      SunshineRunStoreReadResult(
        state: SunshineRunState(baseTotal: 13, baseMorning: 5),
      ),
    );
    await Future.wait([binding, unbinding]);
    expect(h.controller.state.grade, 2);
    expect(h.controller.gradeMessage, contains('未绑定'));
    expect(source.starts, 0);
    expect(h.controller.result.total, 13);
    await h.controller.onPortalBindingChanged(true);
    await _flush();
    expect(h.controller.state.grade, 1);
    expect(h.controller.result.total, 13);
  });

  test('重新识别失败明确降级并保留已选择年级', () async {
    final source = _AcademicSource(
      value: _knownGrade(2),
      refreshFailure: StateError('合成年级刷新失败'),
    );
    final h = _Harness(source: source);
    addTearDown(h.controller.dispose);
    addTearDown(source.dispose);
    await h.controller.ensureStarted();
    await h.controller.identifyGrade();
    expect(h.controller.state.grade, 2);
    expect(h.controller.identifyingGrade, isFalse);
    expect(h.controller.gradeMessage, contains('暂不可用'));
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

  test('dispose后晚到恢复和后台识别不会通知或保存', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final source = _AcademicSource(value: _knownGrade(1));
    final h = _Harness(source: source, readOverride: () => read.future);
    addTearDown(source.dispose);
    var notifications = 0;
    h.controller.addListener(() => notifications++);
    final starting = h.controller.ensureStarted();
    final editing = h.controller.adjustActivityCount('regular', 1);
    h.controller.dispose();
    read.complete(
      SunshineRunStoreReadResult(state: SunshineRunState(baseTotal: 7)),
    );
    await starting;
    expect(await editing, isFalse);
    source.set(_knownGrade(2));
    expect(notifications, 0);
    expect(h.saved, isEmpty);
  });

  test('恢复尚未完成就dispose后撤销与重试立即结束，不递归等待', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final h = _Harness(readOverride: () => read.future);
    final starting = h.controller.ensureStarted();
    h.controller.dispose();
    expect(await h.controller.undo(), isFalse);
    expect(await h.controller.retrySave(), isFalse);
    await h.controller.identifyGrade();
    read.complete(const SunshineRunStoreReadResult());
    await starting;
    expect(h.saved, isEmpty);
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

StudentAcademicInfo _knownGrade(int grade, {bool fromCache = false}) =>
    StudentAcademicInfo(
      portalBound: true,
      identityMatches: true,
      undergraduate: true,
      academicYear: 2025 + grade - 1,
      enrollmentYear: 2025,
      fromCache: fromCache,
    );

class _AcademicSource extends ChangeNotifier implements StudentAcademicSource {
  _AcademicSource({
    this._value = const StudentAcademicInfo(),
    this.initialGate,
    this.refreshGate,
    this.refreshFailure,
  });

  StudentAcademicInfo _value;
  final Completer<void>? initialGate;
  final Completer<void>? refreshGate;
  final Object? refreshFailure;
  int starts = 0;
  int refreshes = 0;

  @override
  StudentAcademicInfo get value => _value;

  void set(StudentAcademicInfo value) {
    _value = value;
    notifyListeners();
  }

  @override
  Future<void> ensureStarted() {
    starts++;
    return initialGate?.future ?? Future.value();
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    if (refreshFailure case final failure?) throw failure;
    await refreshGate?.future;
  }
}

class _Harness {
  _Harness({
    SunshineRunStoreReadResult restored = const SunshineRunStoreReadResult(),
    _AcademicSource? source,
    Future<SunshineRunStoreReadResult> Function()? readOverride,
    Future<bool> Function(SunshineRunState, {bool replaceCorrupt})?
    saveOverride,
    Duration restoreTimeout = const Duration(seconds: 5),
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
    );
  }

  late final SunshineRunController controller;
  final List<SunshineRunState> saved = [];
  final List<bool> replacements = [];
  final List<String?> traceIds = [];
  int reads = 0;
}
