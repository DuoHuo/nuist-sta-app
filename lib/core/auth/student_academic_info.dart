import 'package:flutter/foundation.dart';

/// 跨小程序使用的学生学年信息，不公开姓名、学号或门户凭据。
class StudentAcademicInfo {
  const StudentAcademicInfo({
    this.portalBound = false,
    this.identityMatches = false,
    this.undergraduate = false,
    this.academicYear,
    this.enrollmentYear,
    this.fetchedAt,
    this.fromCache = false,
    this.loading = false,
    this.error,
  });

  /// 已确认当前安全存储中存在门户绑定。
  final bool portalBound;

  /// 学生信息的账号与当前绑定账号一致，且符合本科生学号格式。
  final bool identityMatches;

  /// 门户用户类别明确包含「本科生」层级。
  final bool undergraduate;

  /// 门户校历给出的学年起始年份。
  final int? academicYear;

  /// 由现有学号规则取得的入学年。
  final int? enrollmentYear;

  /// 信息原始获取时间。
  final DateTime? fetchedAt;

  /// 信息是否来自本机缓存，而非本次运行中的成功刷新。
  final bool fromCache;

  /// 学生信息或绑定身份仍在确认中。
  final bool loading;

  /// 可直接展示的降级提示；不包含账号或原始接口正文。
  final String? error;

  /// 用门户学年与入学年计算年级；缺少可靠身份或年份时不推测。
  int? get grade {
    final academic = academicYear;
    final enrollment = enrollmentYear;
    if (!portalBound ||
        !identityMatches ||
        !undergraduate ||
        academic == null ||
        enrollment == null ||
        academic < 1990 ||
        academic > 2100 ||
        enrollment < 1990 ||
        enrollment > 2100) {
      return null;
    }
    final result = academic - enrollment + 1;
    return result > 0 ? result : null;
  }
}

/// 学生信息模块实现的只读学年来源；使用方只依赖 core 接口。
abstract interface class StudentAcademicSource implements Listenable {
  /// 当前快照及其来源、身份确认状态。
  StudentAcademicInfo get value;

  /// 初始化学生信息；重复调用复用同一次初始化。
  Future<void> ensureStarted();

  /// 通过已有门户会话刷新学生信息，不增加网络出口。
  Future<void> refresh();
}

/// 由应用启动时登记的学生学年来源；未登记时允许离线手动选择。
abstract final class StudentAcademics {
  static StudentAcademicSource? source;
}
