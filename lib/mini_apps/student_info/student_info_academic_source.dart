import 'package:flutter/foundation.dart';

import '../../core/auth/enrollment_year.dart';
import '../../core/auth/passkey_store.dart';
import '../../core/auth/student_academic_info.dart';
import '../../core/logging/app_log.dart';
import 'student_info_models.dart';
import 'student_info_store.dart';

/// 只从本地学生缓存及当前绑定提供学年信息，不启动学生信息模块。
class StudentInfoAcademicSource implements StudentAcademicSource {
  StudentInfoAcademicSource._()
    : _readCache = StudentInfoStore.read,
      _readBoundAccount = _currentBoundAccount;

  /// 测试注入缓存和绑定读取，不访问真实存储或学校接口。
  @visibleForTesting
  StudentInfoAcademicSource.forTesting({
    required this._readCache,
    required this._readBoundAccount,
  });

  static final StudentInfoAcademicSource instance =
      StudentInfoAcademicSource._();
  static final _log = AppLog.logger('student_info.academic_source');

  static Future<String?> _currentBoundAccount() async =>
      (await PasskeyStore.read())?.studentId;

  final Future<StudentInfo?> Function() _readCache;
  final Future<String?> Function() _readBoundAccount;

  static String? _account(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<StudentAcademicInfo> readLocal() => _log.inSpan(() async {
    var stage = 'bound_account_before';
    try {
      final before = _account(await _readBoundAccount());
      if (before == null) {
        return const StudentAcademicInfo(fromCache: true);
      }

      stage = 'cache_read';
      final info = await _readCache();
      stage = 'bound_account_after';
      final after = _account(await _readBoundAccount());
      if (before != after) {
        // 读取期间换绑或解绑时不能把旧缓存交给新绑定；由调用方重新读取。
        return StudentAcademicInfo(portalBound: after != null, fromCache: true);
      }

      final studentId = info?.user.studentId.trim();
      final matches =
          studentId == after && RegExp(r'^\d{12}$').hasMatch(studentId ?? '');
      final undergraduate =
          info?.user.categoryName
              .split('/')
              .map((part) => part.trim())
              .contains('本科生') ??
          false;
      return StudentAcademicInfo(
        portalBound: true,
        identityMatches: matches,
        undergraduate: undergraduate,
        academicYear: matches ? info?.semester?.year : null,
        enrollmentYear: matches ? enrollmentYearFromStudentId(studentId) : null,
        fetchedAt: matches ? info?.fetchedAt : null,
        fromCache: true,
      );
    } catch (error, stackTrace) {
      AppLog.reportOutcome(
        'degraded',
        reason: 'student_academic_local_read_failed',
      );
      _log.warning(
        'grade_source.unavailable',
        error: error,
        stackTrace: stackTrace,
        fields: {
          'stage': stage,
          'reason_code': 'student_academic_local_read_failed',
        },
      );
      return const StudentAcademicInfo(fromCache: true, error: '本地学生信息暂不可用');
    }
  });
}
