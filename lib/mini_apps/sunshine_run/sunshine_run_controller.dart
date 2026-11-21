import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/auth/student_academic_info.dart';
import '../../core/logging/app_log.dart';
import 'sunshine_run_models.dart';
import 'sunshine_run_store.dart';

/// 阳光跑本机计算状态；编辑即时生效，持久化串行执行，年级来自 core 只读来源。
class SunshineRunController extends ChangeNotifier {
  SunshineRunController._()
    : _read = SunshineRunStore.read,
      _save = SunshineRunStore.save,
      _injectedGradeSource = null,
      _useRegisteredGradeSource = true,
      _restoreTimeout = const Duration(seconds: 5);

  /// 测试使用独立状态和存储，不读取真实跑步记录或门户身份。
  @visibleForTesting
  SunshineRunController.forTesting({
    required this._read,
    required this._save,
    StudentAcademicSource? gradeSource,
    this._restoreTimeout = const Duration(seconds: 5),
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
  final List<SunshineRunState> _undo = [];
  SunshineRunState _state = SunshineRunState.initial();
  StudentAcademicSource? _gradeSource;
  Future<void>? _starting;
  Future<void> _writeTail = Future.value();
  bool _started = false;
  bool _restoringState = true;
  bool _disposed = false;
  bool _storageCorrupt = false;
  bool _storageUnavailable = false;
  bool _manualGrade = false;
  bool _bindingBlocked = false;
  bool _gradeRefreshing = false;
  bool _identifyingGrade = false;
  String? _storageWarning;
  String? _gradeMessage = '年级尚未识别，请确认当前年级。';
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

  /// 年级来源或无法识别的原因。
  String? get gradeMessage => _gradeMessage;

  /// 年级正在确认；不影响计算器的离线编辑。
  bool get identifyingGrade => _identifyingGrade;

  /// 仅本机记录尚未恢复时暂停编辑；失败或超时后也会恢复离线计算。
  bool get restoringState => _restoringState;

  /// 先恢复本机记录；学生信息及绑定读取在后台启动，不阻塞离线计算。
  Future<void> ensureStarted() {
    if (_disposed) return Future.value();
    if (_started) return _starting ?? Future.value();
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
        _state = restored.state!;
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
    _attachGradeSource();
    unawaited(_startGradeSource());
  }

  void _attachGradeSource() {
    final source =
        _injectedGradeSource ??
        (_useRegisteredGradeSource ? StudentAcademics.source : null);
    if (identical(source, _gradeSource)) return;
    _gradeSource?.removeListener(_onAcademicInfoChanged);
    _gradeSource = source;
    source?.addListener(_onAcademicInfoChanged);
  }

  Future<void> _startGradeSource() async {
    if (_disposed || _bindingBlocked) return;
    final generation = _gradeGeneration;
    final source = _gradeSource;
    if (source == null) {
      if (!_manualGrade) {
        _gradeMessage = '暂无学生信息来源，请手动选择年级。';
        _identifyingGrade = false;
        _notify();
      }
      return;
    }
    if (!_manualGrade && !_bindingBlocked) {
      _identifyingGrade = true;
      _gradeMessage = '正在识别年级，可先手动选择。';
      _notify();
    }
    try {
      await source.ensureStarted();
      if (!_disposed) _onAcademicInfoChanged();
    } catch (error, stackTrace) {
      _log.warning('grade.source_failed', error: error, stackTrace: stackTrace);
      if (!_disposed &&
          generation == _gradeGeneration &&
          !_manualGrade &&
          !_bindingBlocked) {
        _identifyingGrade = false;
        _gradeMessage = '学生信息暂不可用，请手动选择年级。';
        _notify();
      }
    }
  }

  void _onAcademicInfoChanged() {
    if (_disposed || _manualGrade || _bindingBlocked) return;
    final info = _gradeSource?.value;
    if (info == null) return;
    _identifyingGrade = _gradeRefreshing || info.loading;
    if (info.loading) {
      _gradeMessage = '正在识别年级，可先手动选择。';
      _notify();
      return;
    }
    final grade = info.grade;
    if (info.error != null) {
      _gradeMessage = info.error;
    } else if (!info.portalBound) {
      _gradeMessage = '门户未绑定，请手动选择年级。';
    } else if (!info.identityMatches) {
      _gradeMessage = '暂无与当前账号一致的学生信息，请手动选择年级。';
    } else if (!info.undergraduate) {
      _gradeMessage = '暂不支持自动识别该用户类别，请手动选择年级。';
    } else if (grade != 1 && grade != 2) {
      _gradeMessage = grade == null
          ? '学生学年信息不完整，请手动选择年级。'
          : '当前识别年级不在大一、大二范围内，请手动选择。';
    } else {
      final source = info.fromCache ? '本机缓存' : '门户信息';
      _gradeMessage =
          '依据$source中的 ${info.academicYear}—${info.academicYear! + 1} 学年识别为${grade == 1 ? '大一' : '大二'}。';
      if (_state.grade != grade) {
        unawaited(
          _edit(
            (state) => state.copyWith(grade: grade),
            event: 'grade.identified',
            recordUndo: false,
          ),
        );
        return;
      }
    }
    _notify();
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

  /// 手动选择年级；已在途的自动识别不能覆盖这次选择。
  Future<bool> setGrade(int grade) {
    // 先校验年级再改变来源标记，非法输入不影响正在进行的识别。
    _state.copyWith(grade: grade);
    _manualGrade = true;
    _gradeGeneration++;
    _gradeRefreshing = false;
    _identifyingGrade = false;
    _gradeMessage = '已手动选择${grade == 1 ? '大一' : '大二'}，可重新识别。';
    return _edit(
      (state) => state.copyWith(grade: grade),
      event: 'grade.select',
    );
  }

  /// 恢复上一次用户操作的完整快照，并重新保存。
  Future<bool> undo() {
    if (_disposed) return Future.value(false);
    if (_restoringState) {
      return ensureStarted().then((_) => undo());
    }
    if (_undo.isEmpty) return Future.value(_storageWarning == null);
    final previous = _undo.removeLast();
    if (previous.grade != _state.grade) {
      _manualGrade = true;
      _gradeGeneration++;
      _gradeRefreshing = false;
      _identifyingGrade = false;
      _gradeMessage = '已恢复${previous.grade == 1 ? '大一' : '大二'}设置，可重新识别。';
    }
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

  /// 使用现有学生信息来源重新识别；手动修改会使旧请求结果失效。
  Future<void> identifyGrade() async {
    if (_disposed) return;
    final generation = ++_gradeGeneration;
    _manualGrade = false;
    _gradeRefreshing = true;
    _identifyingGrade = true;
    _gradeMessage = '正在识别年级，可先手动选择。';
    _notify();
    await ensureStarted();
    if (_disposed || generation != _gradeGeneration || _manualGrade) return;
    _attachGradeSource();
    final source = _gradeSource;
    if (source == null) {
      _gradeMessage = '暂无学生信息来源，请手动选择年级。';
      _gradeRefreshing = false;
      _identifyingGrade = false;
      _notify();
      return;
    }
    _bindingBlocked = false;
    var failed = false;
    try {
      await _log.operation('grade.identify', source.refresh);
    } catch (error, stackTrace) {
      _log.warning(
        'grade.identify_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_disposed && generation == _gradeGeneration && !_manualGrade) {
        failed = true;
        _gradeMessage = '学生信息暂不可用，请手动选择年级。';
      }
    } finally {
      if (!_disposed && generation == _gradeGeneration && !_manualGrade) {
        _gradeRefreshing = false;
        if (failed) {
          _identifyingGrade = false;
          _notify();
        } else {
          _onAcademicInfoChanged();
        }
      }
    }
  }

  /// 绑定变化只重新核对年级来源，不清除跑步记录或手动年级。
  Future<void> onPortalBindingChanged(bool bound) async {
    final generation = ++_gradeGeneration;
    _bindingBlocked = !bound;
    _gradeRefreshing = false;
    if (!bound) {
      _identifyingGrade = false;
      _gradeMessage = _manualGrade ? '门户未绑定，当前按手动选择的年级计算。' : '门户未绑定，请手动选择年级。';
      _notify();
    }
    await ensureStarted();
    if (_disposed || !bound || generation != _gradeGeneration) return;
    _attachGradeSource();
    // 学生信息自己的绑定回调负责刷新；这里订阅结果，避免重复拉取。
    unawaited(_startGradeSource());
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
    } else if (event == 'grade.identified') {
      // 自动来源更新不属于用户撤销操作，旧次数快照沿用新识别的年级。
      for (var index = 0; index < _undo.length; index++) {
        _undo[index] = _undo[index].copyWith(grade: next.grade);
      }
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
    finishActivityAdjustment();
    _gradeSource?.removeListener(_onAcademicInfoChanged);
    super.dispose();
  }
}
