import 'dart:async';
import 'dart:convert';

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

  test('可靠本地大一大二信息可用，自动年级不创建撤销点', () async {
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
  });

  test('缺失、不可靠或不支持的本地信息统一大二，不沿用旧手选年级', () async {
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
  });

  test('重进仅读本地年级，不重新恢复次数，失效缓存回退大二', () async {
    final source = _AcademicSource(value: _knownGrade(1));
    final h = _Harness(
      source: source,
      restored: SunshineRunStoreReadResult(
        state: SunshineRunState(baseTotal: 9, baseMorning: 4),
      ),
    );
    addTearDown(h.controller.dispose);
    await h.controller.ensureStarted();
    await _flush();
    expect(h.controller.state.grade, 1);
    await h.controller.adjustActivityCount('morning', 2);
    source.value = _knownGrade(2);
    await h.controller.ensureStarted();
    expect(h.controller.state.grade, 2);
    source.value = _knownGrade(1);
    await h.controller.ensureStarted();
    expect(h.controller.state.grade, 1);
    source.value = const StudentAcademicInfo();
    await h.controller.ensureStarted();
    expect(h.controller.state.grade, 2);
    expect(h.controller.result.total, 11);
    expect(h.controller.result.morning, 6);
    expect(h.controller.state.activities['morning'], 2);
    expect(h.reads, 1);
    expect(source.reads, 4);
  });

  test('并发进入合并同一份本地读取，完成后再次进入会重新核对', () async {
    final local = Completer<StudentAcademicInfo>();
    final source = _AcademicSource(readOverride: () => local.future);
    final h = _Harness(source: source);
    addTearDown(h.controller.dispose);
    await h.controller.ensureStarted();
    final first = h.controller.ensureStarted();
    final second = h.controller.ensureStarted();
    expect(source.reads, 1);
    local.complete(_knownGrade(1));
    await Future.wait([first, second]);
    expect(h.controller.state.grade, 1);
    expect(source.reads, 1);
    await h.controller.ensureStarted();
    expect(source.reads, 2);
    expect(h.reads, 1);
  });

  test('延迟本地年级不阻塞次数编辑，晚到结果保留新记录及撤销内容', () async {
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
    expect(await h.controller.adjustActivityCount('morning', 2), isTrue);
    expect(h.controller.result.total, 10);
    expect(h.controller.result.morning, 6);
    local.complete(_knownGrade(1));
    await _flush();
    expect(h.controller.state.grade, 1);
    expect(h.controller.result.total, 10);
    expect(h.controller.state.baseTotal, 7);
    expect(h.controller.state.activities['morning'], 3);
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

  test('恢复期间多次绑定变化只用最新本地身份，不以初始状态覆盖旧次数', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final source = _AcademicSource(value: _knownGrade(1));
    final cached = SunshineRunState(
      grade: 1,
      baseTotal: 13,
      baseMorning: 5,
    ).withActivity('regular', 4);
    final h = _Harness(source: source, readOverride: () => read.future);
    addTearDown(h.controller.dispose);
    final starting = h.controller.ensureStarted();
    final binding = h.controller.onPortalBindingChanged(true);
    final unbinding = h.controller.onPortalBindingChanged(false);
    final rebinding = h.controller.onPortalBindingChanged(true);
    final editing = h.controller.adjustActivityCount('regular', 1);
    expect(h.saved, isEmpty);
    expect(source.reads, 0);
    read.complete(SunshineRunStoreReadResult(state: cached));
    await Future.wait([starting, binding, unbinding, rebinding, editing]);
    expect(h.controller.state.grade, 1);
    expect(h.controller.state.baseTotal, 13);
    expect(h.controller.state.activities['regular'], 5);
    expect(h.controller.result.total, 18);
    expect(source.reads, 1);
    expect(h.reads, 1);
    expect(h.saved, isNotEmpty);
    expect(h.saved.every((state) => state.baseTotal == 13), isTrue);
    await h.controller.undo();
    expect(h.controller.state, cached);
  });

  test('解绑保留记录并回退大二，重进不读取，重新绑定仅读本地缓存', () async {
    final source = _AcademicSource(value: _knownGrade(1));
    final cached = SunshineRunState(baseTotal: 9, baseMorning: 3);
    final h = _Harness(
      source: source,
      restored: SunshineRunStoreReadResult(state: cached),
    );
    addTearDown(h.controller.dispose);
    await h.controller.ensureStarted();
    await _flush();
    await h.controller.adjustActivityCount('morning', 2);
    expect(h.controller.state.grade, 1);
    await h.controller.onPortalBindingChanged(false);
    expect(h.controller.state.grade, 2);
    expect(h.controller.result.total, 11);
    await h.controller.ensureStarted();
    expect(source.reads, 1);
    await h.controller.onPortalBindingChanged(true);
    expect(source.reads, 2);
    expect(h.controller.state.grade, 1);
    expect(h.controller.result.total, 11);
    expect(h.reads, 1);
    await h.controller.undo();
    expect(h.controller.state, cached.copyWith(grade: 1));
    expect(h.controller.canUndo, isFalse);
  });

  test('初始恢复期间解绑阻止本地读取，旧绑定回调不重启读取', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final source = _AcademicSource(value: _knownGrade(1));
    final h = _Harness(source: source, readOverride: () => read.future);
    addTearDown(h.controller.dispose);
    final binding = h.controller.onPortalBindingChanged(true);
    final unbinding = h.controller.onPortalBindingChanged(false);
    read.complete(
      SunshineRunStoreReadResult(
        state: SunshineRunState(grade: 1, baseTotal: 13, baseMorning: 5),
      ),
    );
    await Future.wait([binding, unbinding]);
    expect(h.controller.state.grade, 2);
    expect(source.reads, 0);
    expect(h.controller.result.total, 13);
    expect(h.saved, isEmpty);
    await h.controller.onPortalBindingChanged(true);
    expect(h.controller.state.grade, 1);
    expect(source.reads, 1);
    expect(h.controller.result.total, 13);
  });

  test('自动年级不会成为撤销项，次数快照始终使用最新年级', () async {
    final source = _AcademicSource(value: _knownGrade(2));
    final h = _Harness(source: source);
    addTearDown(h.controller.dispose);
    await h.controller.ensureStarted();
    await _flush();
    await h.controller.setBaseline(8, 3);
    await h.controller.adjustActivityCount('morning', 2);
    source.value = _knownGrade(1);
    await h.controller.ensureStarted();
    expect(h.controller.result.total, 10);
    expect(h.controller.state.grade, 1);
    await h.controller.undo();
    expect(
      h.controller.state,
      SunshineRunState(grade: 1, baseTotal: 8, baseMorning: 3),
    );
    source.value = const StudentAcademicInfo();
    await h.controller.ensureStarted();
    await h.controller.undo();
    expect(h.controller.state, SunshineRunState.initial());
    expect(h.controller.canUndo, isFalse);
    await h.controller.undo();
    expect(h.controller.state.grade, 2);
  });

  test('自动年级变化不中断长按的业务Trace或增加撤销点', () async {
    final local = Completer<StudentAcademicInfo>();
    final source = _AcademicSource(readOverride: () => local.future);
    final h = _Harness(source: source);
    addTearDown(h.controller.dispose);
    await h.controller.ensureStarted();
    await h.controller.adjustActivityCount('fluorescent', 1);
    final adjustmentTrace = h.traceIds.single;
    local.complete(_knownGrade(1));
    await _flush();
    expect(h.controller.state.grade, 1);
    await h.controller.adjustActivityCount('fluorescent', 1, recordUndo: false);
    expect(h.traceIds.last, adjustmentTrace);
    expect(h.controller.result.total, 4);
    h.controller.finishActivityAdjustment();
    await h.controller.undo();
    expect(h.controller.state, SunshineRunState(grade: 1));
    expect(h.controller.canUndo, isFalse);
  });

  test('本地年级读取异常或超时默认大二，迟到结果不改变计数', () async {
    final failed = _AcademicSource(
      readOverride: () async => throw StateError('合成本地年级读取失败'),
    );
    final failedHarness = _Harness(
      source: failed,
      restored: SunshineRunStoreReadResult(
        state: SunshineRunState(grade: 1, baseTotal: 11, baseMorning: 4),
      ),
    );
    addTearDown(failedHarness.controller.dispose);
    await failedHarness.controller.ensureStarted();
    await _flush();
    expect(failedHarness.controller.state.grade, 2);
    expect(failedHarness.controller.result.total, 11);
    expect(failedHarness.saved, isEmpty);

    final delayed = Completer<StudentAcademicInfo>();
    final timed = _AcademicSource(readOverride: () => delayed.future);
    final timedHarness = _Harness(
      source: timed,
      gradeReadTimeout: const Duration(milliseconds: 1),
    );
    addTearDown(timedHarness.controller.dispose);
    await timedHarness.controller.ensureStarted();
    await timedHarness.controller.ensureStarted();
    expect(timedHarness.controller.state.grade, 2);
    expect(timed.reads, 1);
    await timedHarness.controller.setBaseline(9, 3);
    delayed.complete(_knownGrade(1));
    await _flush();
    expect(timedHarness.controller.state.grade, 2);
    expect(timedHarness.controller.result.total, 9);
  });

  test('恢复失败后的本地年级更新不会自动覆盖未知跑步记录', () async {
    final source = _AcademicSource(value: _knownGrade(1));
    final h = _Harness(
      source: source,
      restored: const SunshineRunStoreReadResult(available: false),
    );
    addTearDown(h.controller.dispose);
    await h.controller.ensureStarted();
    await _flush();
    expect(h.controller.state.grade, 1);
    expect(h.controller.storageWarning, isNotNull);
    expect(h.saved, isEmpty);
    expect(await h.controller.adjustActivityCount('morning', 2), isFalse);
    expect(h.saved, isEmpty);
    expect(await h.controller.retrySave(), isTrue);
    expect(h.replacements, [true]);
    expect(h.saved.single.grade, 1);
    expect(h.saved.single.activities['morning'], 2);
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

  test('dispose后晚到恢复不会通知、保存或启动本地来源', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final source = _AcademicSource(value: _knownGrade(1));
    final h = _Harness(source: source, readOverride: () => read.future);
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
    expect(notifications, 0);
    expect(h.saved, isEmpty);
    expect(source.reads, 0);
  });

  test('dispose后晚到本地年级不会通知、保存或重新读取', () async {
    final local = Completer<StudentAcademicInfo>();
    final source = _AcademicSource(readOverride: () => local.future);
    final h = _Harness(
      source: source,
      restored: SunshineRunStoreReadResult(
        state: SunshineRunState(baseTotal: 7),
      ),
    );
    var notifications = 0;
    h.controller.addListener(() => notifications++);
    await h.controller.ensureStarted();
    final beforeDispose = notifications;
    h.controller.dispose();
    local.complete(_knownGrade(1));
    await _flush();
    await h.controller.ensureStarted();
    await h.controller.onPortalBindingChanged(true);
    expect(h.controller.state.grade, 2);
    expect(h.controller.result.total, 7);
    expect(notifications, beforeDispose);
    expect(h.saved, isEmpty);
    expect(source.reads, 1);
  });

  test('恢复尚未完成就dispose后撤销与重试立即结束，不递归等待', () async {
    final read = Completer<SunshineRunStoreReadResult>();
    final h = _Harness(readOverride: () => read.future);
    final starting = h.controller.ensureStarted();
    h.controller.dispose();
    expect(await h.controller.undo(), isFalse);
    expect(await h.controller.retrySave(), isFalse);
    await h.controller.onPortalBindingChanged(true);
    read.complete(const SunshineRunStoreReadResult());
    await starting;
    expect(h.saved, isEmpty);
  });
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
