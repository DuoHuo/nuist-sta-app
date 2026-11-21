import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/auth/enrollment_year.dart';
import '../../core/auth/passkey_store.dart';
import '../../core/auth/student_academic_info.dart';
import '../../core/logging/app_log.dart';
import 'student_info_controller.dart';

/// 向 core 提供已核对绑定账号的学年信息，不向其他小程序公开学生身份。
class StudentInfoAcademicSource extends ChangeNotifier
    implements StudentAcademicSource {
  StudentInfoAcademicSource._()
    : _controller = StudentInfoController.instance,
      _readBoundAccount = _currentBoundAccount;

  /// 测试注入学生信息和绑定读取，避免访问真实缓存及凭据。
  @visibleForTesting
  StudentInfoAcademicSource.forTesting({
    required this._controller,
    required this._readBoundAccount,
  });

  static final StudentInfoAcademicSource instance =
      StudentInfoAcademicSource._();
  static final _log = AppLog.logger('student_info.academic_source');

  static Future<String?> _currentBoundAccount() async =>
      (await PasskeyStore.read())?.studentId;

  final StudentInfoController _controller;
  final Future<String?> Function() _readBoundAccount;
  StudentAcademicInfo _value = const StudentAcademicInfo();
  Future<void>? _starting;
  Future<void>? _syncing;
  bool _started = false;
  bool _disposed = false;
  int _generation = 0;

  @override
  StudentAcademicInfo get value => _value;

  @override
  Future<void> ensureStarted() {
    if (_disposed) return Future.value();
    if (_started) return _starting ?? Future.value();
    _started = true;
    _controller.addListener(_onStudentInfoChanged);
    _onStudentInfoChanged();
    return _starting = _start();
  }

  Future<void> _start() async {
    try {
      await _controller.ensureStarted();
      await _syncing;
    } catch (error, stackTrace) {
      _reportUnavailable(error, stackTrace);
    }
  }

  @override
  Future<void> refresh() async {
    await ensureStarted();
    if (_disposed) return;
    try {
      await _controller.refresh();
      await _syncing;
    } catch (error, stackTrace) {
      _reportUnavailable(error, stackTrace);
    }
  }

  void _onStudentInfoChanged() {
    final generation = ++_generation;
    if (!_controller.portalBound) {
      _value = const StudentAcademicInfo();
      notifyListeners();
      return;
    }
    // 同为「已绑定」的换账号也会通知；先撤回旧身份，重新核对安全存储。
    _value = const StudentAcademicInfo(loading: true);
    notifyListeners();
    _syncing = _sync(generation);
  }

  Future<void> _sync(int generation) async {
    try {
      final boundAccount = (await _readBoundAccount())?.trim();
      if (_disposed || generation != _generation) return;
      final info = _controller.info;
      final studentId = info?.user.studentId.trim();
      final matches =
          boundAccount != null &&
          studentId == boundAccount &&
          RegExp(r'^\d{12}$').hasMatch(studentId ?? '');
      final undergraduate =
          info?.user.categoryName
              .split('/')
              .map((part) => part.trim())
              .contains('本科生') ??
          false;
      _value = StudentAcademicInfo(
        portalBound: _controller.portalBound && boundAccount != null,
        identityMatches: matches,
        undergraduate: undergraduate,
        academicYear: matches ? info?.semester?.year : null,
        enrollmentYear: matches ? enrollmentYearFromStudentId(studentId) : null,
        fetchedAt: matches ? info?.fetchedAt : null,
        fromCache: _controller.infoFromCache,
        loading: _controller.loading,
        error: _controller.error == null ? null : '门户凭据暂不可用，请重新绑定或手动选择年级。',
      );
      notifyListeners();
    } catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;
      _reportUnavailable(error, stackTrace);
    }
  }

  void _reportUnavailable(Object error, StackTrace stackTrace) {
    _log.warning(
      'grade_source.unavailable',
      error: error,
      stackTrace: stackTrace,
    );
    if (_disposed) return;
    _value = const StudentAcademicInfo(error: '学生信息暂不可用，请手动选择年级。');
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    if (_started) _controller.removeListener(_onStudentInfoChanged);
    super.dispose();
  }
}
