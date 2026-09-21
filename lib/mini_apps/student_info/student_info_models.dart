/// 信息门户 `getLoginUserAndGuest` 里值得展示的身份字段。
///
/// 接口还会给证件号、手机、邮箱等脱敏残片，没有展示价值又有截图泄露风险，
/// 一律不解析、不落盘。
class PortalUser {
  const PortalUser({
    required this.name,
    required this.studentId,
    required this.categoryName,
    required this.deptName,
  });

  /// 姓名（userName）。
  final String name;

  /// 学号（userAccount）。
  final String studentId;

  /// 用户类别路径，如「学生/本科生」（categoryName）。
  final String categoryName;

  /// 组织路径，如「学生/本科生/长望学院/25国科大计科1班」（deptName）。
  final String deptName;

  /// 「长望学院 · 25国科大计科1班」：去掉与 [categoryName] 重复的前缀后，
  /// 把剩余层级用「·」连起来。
  String get orgLine {
    var rest = deptName;
    if (categoryName.isNotEmpty && rest.startsWith(categoryName)) {
      rest = rest.substring(categoryName.length);
    }
    final parts = rest.split('/').where((p) => p.trim().isNotEmpty);
    return parts.map((p) => p.trim()).join(' · ');
  }

  /// 头像用的首字；姓名为空时用「?」。
  String get initial =>
      name.isEmpty ? '?' : String.fromCharCode(name.runes.first);

  factory PortalUser.fromJson(Map<String, dynamic> json) {
    String s(String key) => (json[key] ?? '').toString().trim();
    return PortalUser(
      name: s('userName'),
      studentId: s('userAccount'),
      categoryName: s('categoryName'),
      deptName: s('deptName'),
    );
  }

  Map<String, dynamic> toJson() => {
    'userName': name,
    'userAccount': studentId,
    'categoryName': categoryName,
    'deptName': deptName,
  };
}

/// 校历（`execTemplateMethod` / `getXLInfo`）给出的当前学期。
///
/// 存开学日期与总周数而不是「当前周」：周次按日期本地计算，缓存放一周也不会
/// 过时，还能画学期进度。
class SemesterInfo {
  const SemesterInfo({
    required this.year,
    required this.term,
    required this.start,
    required this.end,
    required this.maxWeeks,
  });

  /// 学年起始年份（xn），如 2026。
  final int year;

  /// 学期序号（xq），如「1」。
  final String term;

  /// 开学日期（ksrq），第 1 周的周一。
  final DateTime start;

  /// 学期结束日期（jsrq）。
  final DateTime end;

  /// 总周数（maxWeeks）。
  final int maxWeeks;

  /// 「2026-2027-1」。
  String get label => '$year-${year + 1}-$term';

  bool isBeforeStart(DateTime date) => _day(date).isBefore(_day(start));

  bool isEnded(DateTime date) => _day(date).isAfter(_day(end));

  /// [date] 是第几周（从 1 起）。开学前会得到 0 或负数，调用方先用
  /// [isBeforeStart] / [isEnded] 判断阶段。
  int weekOf(DateTime date) =>
      _day(date).difference(_day(start)).inDays ~/ 7 + 1;

  /// 学期进度 0~1，按周数算。
  double progressAt(DateTime date) {
    if (maxWeeks <= 0) return 0;
    return (weekOf(date) / maxWeeks).clamp(0.0, 1.0);
  }

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  /// 字段缺失或格式不对时返回 null（如假期里接口可能没有当前学期）。
  static SemesterInfo? tryFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final year = int.tryParse('${json['xn'] ?? ''}');
    final term = '${json['xq'] ?? ''}'.trim();
    final start = DateTime.tryParse('${json['ksrq'] ?? ''}');
    final end = DateTime.tryParse('${json['jsrq'] ?? ''}');
    final maxWeeks = int.tryParse('${json['maxWeeks'] ?? ''}');
    if (year == null || term.isEmpty || start == null || end == null) {
      return null;
    }
    return SemesterInfo(
      year: year,
      term: term,
      start: start,
      end: end,
      maxWeeks: maxWeeks ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'xn': '$year',
    'xq': term,
    'ksrq': start.toIso8601String(),
    'jsrq': end.toIso8601String(),
    'maxWeeks': maxWeeks,
  };
}

/// 学习页头部「学生卡」的一次拉取结果。
class StudentInfo {
  const StudentInfo({
    required this.user,
    required this.semester,
    required this.fetchedAt,
  });

  final PortalUser user;

  /// 为 null 表示校历接口没有给出当前学期（假期等）。
  final SemesterInfo? semester;

  final DateTime fetchedAt;

  factory StudentInfo.fromJson(
    Map<String, dynamic> json, {
    required DateTime fetchedAt,
  }) {
    final user = json['user'];
    final semester = json['semester'];
    return StudentInfo(
      user: PortalUser.fromJson(user is Map<String, dynamic> ? user : const {}),
      semester: SemesterInfo.tryFromJson(
        semester is Map<String, dynamic> ? semester : null,
      ),
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'user': user.toJson(),
    'semester': semester?.toJson(),
    'fetchedAt': fetchedAt.toIso8601String(),
  };
}
