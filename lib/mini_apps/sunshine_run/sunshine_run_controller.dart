import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/auth/student_academic_info.dart';
import '../../core/logging/app_log.dart';
import 'sunshine_run_models.dart';
import 'sunshine_run_store.dart';

/// 阳光跑本机计算状态；编辑即时生效，持久化串行执行，年级只读本地缓存。
class SunshineRunController extends ChangeNotifier {
  SunshineRunController._()
    : _read = SunshineRunStore.read,
      _save = SunshineRunStore.save,
      _injectedGradeSource = null,
      _useRegisteredGradeSource = true,
      _restoreTimeout = const Duration(seconds: 5),
      _gradeReadTimeout = const Duration(seconds: 2);

  /// 测试使用独立状态和存储，不读取真实跑步记录或门户身份。
  @visibleForTesting
  SunshineRunController.forTesting({
    required this._read,
    required this._save,
    StudentAcademicSource? gradeSource,
    this._restoreTimeout = const Duration(seconds: 5),
    this._gradeReadTimeout = const Duration(seconds: 2),
  }) : _injectedGradeSource = gradeSource,
       _useRegisteredGradeSource = false;

  static final SunshineRunController instance = SunshineRunController._();
  static final _log = AppLog.logger('sunshine_run.controller');
  static const _storageFailure = '本次修改未能保存，当前计算仍可使用，请重试保存。';
  static const _corruptStorage = '本地跑步记录损坏，原文件已保留，当前计算仍可使用。';
  static const _undoLimit = 50;

  final Future<SunshineRunStoreReadResult> Function() _read;
  final Future<bool> Function(SunshineRunState, {bool replaceCorrupt}) _save;
  final StudentAcademicSource? _injectedGradeSource;
  final bool _useRegisteredGradeSource;
  final Duration _restoreTimeout;
  final Duration _gradeReadTimeout;
  final List<SunshineRunState> _undo = [];
  SunshineRunState _state = SunshineRunState.initial();
  Future<void>? _starting;
  Future<void>? _gradeReading;
  Future<void> _writeTail = Future.value();
  bool _started = false;
  bool _restoringState = true;
  bool _disposed = false;
  bool _storageCorrupt = false;
  bool _storageUnavailable = false;
  bool _bindingBlocked = false;
  String? _storageWarning;
  int _resolvedGrade = 2;
  int _revision = 0;
  int _gradeGeneration = 0;
  int _customSequence = 0;
  AppLogSpan? _adjustmentSpan;
  String? _adjustmentKey;

  /// 当前不可变记录。
  SunshineRunState get state => _state;

  /// 根据当前记录实时计算的次数、完成率及成绩状态。
  SunshineRunResult get result => _state.calculate();

  /// 是否有可撤销的用户操作。
  bool get canUndo => _undo.isNotEmpty;

  /// 本机存储降级提示；为空表示最近一份记录已保存。
  String? get storageWarning => _storageWarning;

  /// 原始记录损坏时保留文件，直到用户明确重试保存。
  bool get storageCorrupt => _storageCorrupt;

  /// 仅本机记录尚未恢复时暂停编辑；失败或超时后也会恢复离线计算。
  bool get restoringState => _restoringState;

  /// 首次恢复跑步记录；每次进入仅读本地年级，不发起门户请求。
  ///
  /// 首次年级读取在后台执行，延迟或失败都不阻塞离线编辑。
  Future<void> ensureStarted() {
    if (_disposed) return Future.value();
    if (_started) {
      return _restoringState ? _starting ?? Future.value() : _readLocalGrade();
    }
    _started = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    final revision = _revision;
    final restoreSpan = _log.startSpan(collectEvidence: true);
    try {
      final restored = await restoreSpan.run(
        () => _log.operation(
          'state.restore',
          () => _read().timeout(_restoreTimeout),
          resultFields: (value) => {
            'has_record': value.state != null,
            'corrupt': value.corrupt,
            'available': value.available,
          },
          outcomeForResult: (value) =>
              value.corrupt || !value.available ? 'degraded' : 'success',
        ),
      );
      if (_disposed) return;
      if (revision == _revision && restored.state != null) {
        // 旧文件中的手选年级不再作为来源，其余次数与活动原样恢复。
        _state = restored.state!.copyWith(grade: _resolvedGrade);
      }
      _storageCorrupt = restored.corrupt;
      _storageUnavailable = !restored.available;
      _storageWarning =
          restored.warning ??
          (restored.corrupt
              ? _corruptStorage
              : restored.available
              ? null
              : _storageFailure);
    } catch (error, stackTrace) {
      restoreSpan.run(
        () => _log.warning(
          'state.restore_failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      if (_disposed) return;
      _storageUnavailable = true;
      _storageWarning = _storageFailure;
    } finally {
      _restoringState = false;
    }
    _notify();
    unawaited(_readLocalGrade());
  }

  Future<void> _readLocalGrade() {
    if (_disposed || _bindingBlocked) return Future.value();
    if (_gradeReading case final pending?) return pending;
    final source =
        _injectedGradeSource ??
        (_useRegisteredGradeSource ? StudentAcademics.source : null);
    if (source == null) {
      _applyDerivedGrade(null);
      return Future.value();
    }
    final generation = _gradeGeneration;
    late final Future<void> reading;
    reading = _readGrade(source, generation).whenComplete(() {
      // 旧绑定的读取完成时不能清除新绑定正在进行的读取。
      if (identical(_gradeReading, reading)) _gradeReading = null;
    });
    _gradeReading = reading;
    return reading;
  }

  Future<void> _readGrade(StudentAcademicSource source, int generation) async {
    StudentAcademicInfo? info;
    try {
      info = await source.readLocal().timeout(_gradeReadTimeout);
    } catch (error, stackTrace) {
      _log.warning(
        'grade.local_source_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (_disposed || _bindingBlocked || generation != _gradeGeneration) return;
    _applyDerivedGrade(
      info == null || info.loading || info.error != null ? null : info.grade,
    );
  }

  void _applyDerivedGrade(int? grade) {
    if (_disposed) return;
    final resolved = grade == 1 ? 1 : 2;
    _resolvedGrade = resolved;
    // 年级由当前本地身份推导，不属于撤销内容。
    for (var index = 0; index < _undo.length; index++) {
      _undo[index] = _undo[index].copyWith(grade: resolved);
    }
    if (_restoringState || _state.grade == resolved) return;
    _state = _state.copyWith(grade: resolved);
    final revision = ++_revision;
    _notify();
    // 自动年级变化不结束长按，也不占用其撤销点或业务 Trace。
    unawaited(_queueSave(_state, revision, event: 'grade.local_update'));
  }

  /// 修改使用前已有的总次数和晨跑次数；晨跑不能超过总次数。
  Future<bool> setBaseline(int total, int morning) => _edit(
    (state) => state.withBaseline(total, morning),
    event: 'baseline.update',
  );

  /// 按绝对场次修改固定活动；长按后续步骤不重复记录撤销点。
  Future<bool> setActivityCount(
    String id,
    int count, {
    bool recordUndo = true,
  }) => _edit(
    (state) => state.withActivity(id, count),
    event: 'activity.update',
    recordUndo: recordUndo,
    adjustmentKey: 'fixed:$id',
  );

  /// 相对增加或减少固定活动场次，恢复尚未完成时也不会丢失旧场次。
  Future<bool> adjustActivityCount(
    String id,
    int delta, {
    bool recordUndo = true,
  }) => _edit(
    (state) {
      parseSunshineRunCount(delta.abs(), label: '调整场次');
      final current = state.activities[id];
      if (current == null) throw const FormatException('未找到对应的固定活动');
      return state.withActivity(id, current + delta);
    },
    event: 'activity.update',
    recordUndo: recordUndo,
    adjustmentKey: 'fixed:$id',
  );

  /// 创建或编辑一个自定义活动，并校验折算规则与当前累计次数。
  Future<bool> saveCustomActivity({
    String? id,
    required String label,
    required int total,
    required int morning,
    required int count,
  }) {
    return _edit((state) {
      final item = SunshineRunCustomActivity(
        id: id ?? _newCustomId(),
        label: label,
        total: total,
        morning: morning,
        count: count,
      );
      return id == null
          ? state.withCustomAdded(item)
          : state.withCustomUpdated(item);
    }, event: id == null ? 'custom.add' : 'custom.update');
  }

  String _newCustomId() {
    String id;
    do {
      id = 'custom-${++_customSequence}';
    } while (_state.customActivities.any((item) => item.id == id));
    return id;
  }

  /// 按绝对场次修改自定义活动。
  Future<bool> setCustomCount(String id, int count, {bool recordUndo = true}) =>
      _edit(
        (state) => state.withCustomCount(id, count),
        event: 'custom.count_update',
        recordUndo: recordUndo,
        adjustmentKey: 'custom:$id',
      );

  /// 相对调整自定义活动场次，使用恢复后的最新记录计算。
  Future<bool> adjustCustomCount(
    String id,
    int delta, {
    bool recordUndo = true,
  }) => _edit(
    (state) {
      parseSunshineRunCount(delta.abs(), label: '调整场次');
      final matches = state.customActivities.where((item) => item.id == id);
      if (matches.isEmpty) throw const FormatException('未找到对应的自定义活动');
      return state.withCustomCount(id, matches.first.count + delta);
    },
    event: 'custom.count_update',
    recordUndo: recordUndo,
    adjustmentKey: 'custom:$id',
  );

  /// 删除活动及它计入的新增次数，可通过撤销恢复。
  Future<bool> removeCustomActivity(String id) =>
      _edit((state) => state.withCustomRemoved(id), event: 'custom.remove');

  /// 长按结束后释放连续调整的追踪上下文，下一次操作重新建立 Trace。
  void finishActivityAdjustment() {
    _adjustmentSpan = null;
    _adjustmentKey = null;
  }

  /// 半免、全免互斥；再次选择当前减免时恢复为无减免。
  Future<bool> toggleExemption(SunshineRunExemption exemption) => _edit(
    (state) => state.copyWith(
      exemption: state.exemption == exemption
          ? SunshineRunExemption.none
          : exemption,
    ),
    event: 'exemption.update',
  );

  /// 撤销上一次用户操作的次数与活动，始终沿用当前本地年级。
  Future<bool> undo() {
    if (_disposed) return Future.value(false);
    if (_restoringState) {
      return ensureStarted().then((_) => undo());
    }
    if (_undo.isEmpty) return Future.value(_storageWarning == null);
    final previous = _undo.removeLast().copyWith(grade: _resolvedGrade);
    return _edit((_) => previous, event: 'state.undo', recordUndo: false);
  }

  /// 清空新增场次，保留已有次数、活动定义、年级与减免。
  Future<bool> resetActivities() =>
      _edit((state) => state.clearActivities(), event: 'activities.reset');

  /// 清空全部跑步记录及减免，自定义活动也删除；当前年级保留。
  Future<bool> resetAll() =>
      _edit((state) => state.resetAll(), event: 'state.reset');

  /// 用户明确重试保存时，允许先备份再替换损坏记录。
  Future<bool> retrySave() {
    if (_disposed) return Future.value(false);
    if (_restoringState) {
      return ensureStarted().then((_) => retrySave());
    }
    return _queueSave(
      _state,
      _revision,
      event: 'storage.retry',
      replaceCorrupt: true,
    );
  }

  /// 绑定变化只重新核对本地年级，次数与活动保留，未知时回退大二。
  Future<void> onPortalBindingChanged(bool bound) async {
    if (_disposed) return;
    final generation = ++_gradeGeneration;
    _bindingBlocked = !bound;
    _gradeReading = null;
    _applyDerivedGrade(null);
    await ensureStarted();
    if (_disposed || !bound || generation != _gradeGeneration) return;
    await _gradeReading;
  }

  Future<bool> _edit(
    SunshineRunState Function(SunshineRunState) update, {
    required String event,
    bool recordUndo = true,
    String? adjustmentKey,
  }) {
    if (_disposed) return Future.value(false);
    if (_restoringState) {
      return ensureStarted().then(
        (_) => _edit(
          update,
          event: event,
          recordUndo: recordUndo,
          adjustmentKey: adjustmentKey,
        ),
      );
    }
    final next = update(_state);
    if (next == _state) {
      _notify();
      return Future.value(_storageWarning == null);
    }
    if (recordUndo) {
      _undo.add(_state);
      if (_undo.length > _undoLimit) _undo.removeAt(0);
    }
    _state = next;
    final revision = ++_revision;
    if (adjustmentKey == null) {
      finishActivityAdjustment();
    } else if (recordUndo ||
        adjustmentKey != _adjustmentKey ||
        _adjustmentSpan == null) {
      _adjustmentKey = adjustmentKey;
      _adjustmentSpan = _log.startSpan(collectEvidence: true);
    }
    _notify();
    return _queueSave(
      next,
      revision,
      event: event,
      trace:
          recordUndo ||
          (event != 'activity.update' && event != 'custom.count_update'),
      traceSpan: _adjustmentSpan,
    );
  }

  Future<bool> _queueSave(
    SunshineRunState snapshot,
    int revision, {
    required String event,
    bool replaceCorrupt = false,
    bool trace = true,
    AppLogSpan? traceSpan,
  }) {
    final previous = _writeTail;
    Future<bool> write() async {
      await previous;
      await _starting;
      if (_disposed) return false;
      if (_storageUnavailable && !replaceCorrupt) {
        // 初始恢复失败时还不知道原文件内容，不能用空基线自动覆盖它。
        AppLog.reportOutcome('degraded', reason: 'initial_storage_unavailable');
        return false;
      }
      bool saved;
      try {
        saved = await _save(snapshot, replaceCorrupt: replaceCorrupt);
      } catch (error, stackTrace) {
        _log.warning('state.save_failed', error: error, stackTrace: stackTrace);
        saved = false;
      }
      if (!_disposed) {
        if (saved) {
          if (replaceCorrupt) {
            _storageCorrupt = false;
            _storageUnavailable = false;
          }
          if (revision == _revision && !_storageCorrupt) _storageWarning = null;
        } else {
          _storageWarning ??= _storageCorrupt
              ? _corruptStorage
              : _storageFailure;
        }
        _notify();
      }
      return saved;
    }

    Future<bool> runWrite() => trace
        ? _log.operation(
            event,
            write,
            outcomeForResult: (saved) => saved ? 'success' : 'degraded',
          )
        : _log.inSpan(write);
    final pending = traceSpan == null ? runWrite() : traceSpan.run(runWrite);
    _writeTail = pending.then<void>((_) {});
    return pending;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _gradeGeneration++;
    _gradeReading = null;
    finishActivityAdjustment();
    super.dispose();
  }
}
