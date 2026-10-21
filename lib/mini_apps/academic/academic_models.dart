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
    // 新生的字段可能是 JSON null 或字符串 "null"，统一归为空串，展示层显示 `--`。
    String s(String key) {
      final v = (json[key] ?? '').toString().trim();
      return v.toLowerCase() == 'null' ? '' : v;
    }

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
    if (!ratio.isFinite) return '--';
    final pct = (ratio * 100).toStringAsFixed(1);
    return '${pct.replaceFirst(RegExp(r'\.0$'), '')}%';
  }

  /// 学分进度条用的 0~1 比例，永远是有限值。
  ///
  /// 优先解析 XFJD：带 `%` 按百分数；不带 `%` 时 `>1` 视为百分数、`0~1`
  /// 视为比例。XFJD 解析不了再用「已获 / 应修」推算。都不行（如大一新生
  /// 字段全空或全为 `"0"`）返回 0，避免进度条拿到 null 变成无限转圈。
  double get creditProgressRatio =>
      _creditProgressFromApi ?? _creditProgressByCredits;

  /// 「32.9%」：学分进度的展示文本，与 [creditProgressRatio] 同源。
  ///
  /// 没有数据时不是 `--` 而是 `0%`：进度条此时就是 0，文本显示 `--`
  /// 会让人以为是解析失败。
  String get creditProgressText {
    final ratio = creditProgressRatio;
    final pct = (ratio * 100).toStringAsFixed(1);
    return '${pct.replaceFirst(RegExp(r'\.0$'), '')}%';
  }

  /// XFJD 解析出的比例；解析不了为 null。
  double? get _creditProgressFromApi {
    final fromText = _parseProgress(creditProgress);
    return fromText?.clamp(0.0, 1.0);
  }

  /// 用「已获 / 应修」推算的比例，应修缺失或为 0 时为 0。
  double get _creditProgressByCredits {
    final earned = double.tryParse(earnedCredits);
    final required = double.tryParse(requiredCredits);
    if (earned != null && required != null && required > 0) {
      final r = earned / required;
      if (r.isFinite) return r.clamp(0.0, 1.0);
    }
    return 0;
  }

  /// 「32.9%」/「32.9」→ 0.329，「0.5」→ 0.5；非数字或非有限值返回 null。
  static double? _parseProgress(String text) {
    var t = text.trim();
    final hasPercent = t.endsWith('%');
    if (hasPercent) t = t.substring(0, t.length - 1).trim();
    final n = double.tryParse(t);
    if (n == null || !n.isFinite) return null;
    return hasPercent || n > 1 ? n / 100 : n;
  }
}
