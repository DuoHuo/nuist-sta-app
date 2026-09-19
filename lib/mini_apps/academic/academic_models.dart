/// 信息门户「学业概览」接口（`/cus/jxmh/czjl`）的一条结果。
///
/// 接口字段全是字符串，这里原样保留，格式化交给展示层；`BY1`/`BY2` 是备用
/// 字段，忽略。
class AcademicSummary {
  const AcademicSummary({
    required this.studentId,
    required this.requiredCredits,
    required this.earnedCredits,
    required this.averageGradePoint,
    required this.gpa,
    required this.averageScore,
    required this.weightedAverageScore,
    required this.classRank,
    required this.majorRank,
    required this.passRate,
    required this.creditProgress,
    required this.fetchedAt,
  });

  /// 学号（XH）。
  final String studentId;

  /// 应修总学分（YXZXF）。
  final String requiredCredits;

  /// 已获学分（YHXF）。
  final String earnedCredits;

  /// 平均绩点（PJJD）。
  final String averageGradePoint;

  /// GPA。
  final String gpa;

  /// 平均分（PJF）。
  final String averageScore;

  /// 学分加权平均分（JQPJF）。
  final String weightedAverageScore;

  /// 班级排名（BJPM）。
  final String classRank;

  /// 专业排名（ZYPM）。
  final String majorRank;

  /// 课程通过率（KCTGL），接口给的是 0~1 的比例，如 `"1"`。
  final String passRate;

  /// 学分进度（XFJD），接口已带百分号，如 `"32.9%"`。
  final String creditProgress;

  /// 这条数据是什么时候拉到的。
  final DateTime fetchedAt;

  factory AcademicSummary.fromJson(
    Map<String, dynamic> json, {
    required DateTime fetchedAt,
  }) {
    String s(String key) => (json[key] ?? '').toString().trim();
    return AcademicSummary(
      studentId: s('XH'),
      requiredCredits: s('YXZXF'),
      earnedCredits: s('YHXF'),
      averageGradePoint: s('PJJD'),
      gpa: s('GPA'),
      averageScore: s('PJF'),
      weightedAverageScore: s('JQPJF'),
      classRank: s('BJPM'),
      majorRank: s('ZYPM'),
      passRate: s('KCTGL'),
      creditProgress: s('XFJD'),
      fetchedAt: fetchedAt,
    );
  }

  /// 落盘格式与接口原始字段同名，方便对照。
  Map<String, dynamic> toJson() => {
    'XH': studentId,
    'YXZXF': requiredCredits,
    'YHXF': earnedCredits,
    'PJJD': averageGradePoint,
    'GPA': gpa,
    'PJF': averageScore,
    'JQPJF': weightedAverageScore,
    'BJPM': classRank,
    'ZYPM': majorRank,
    'KCTGL': passRate,
    'XFJD': creditProgress,
    'fetchedAt': fetchedAt.toIso8601String(),
  };

  /// 「100%」：把 0~1 的比例转成百分数，最多一位小数。解析不了就原样返回。
  String get passRateText {
    final ratio = double.tryParse(passRate);
    if (ratio == null) return passRate.isEmpty ? '--' : passRate;
    final pct = (ratio * 100).toStringAsFixed(1);
    return '${pct.replaceFirst(RegExp(r'\.0$'), '')}%';
  }
}
