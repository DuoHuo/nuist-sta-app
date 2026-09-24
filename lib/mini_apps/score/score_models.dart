/// 教务 EMAP「学生成绩」查询结果。
///
/// 教务不同年份的字段名偶尔会有细微差别，所以模型在 [fromRow] 里兼容
/// 常见的 *_DISPLAY / 原始字段。展示层只依赖这里整理后的字段，不直接碰
/// 教务返回的 Map。
class ScoreRecord {
  const ScoreRecord({
    required this.term,
    required this.courseName,
    required this.courseCode,
    required this.score,
    required this.credit,
    required this.gradePoint,
    required this.passStatus,
    required this.examType,
    required this.usualScore,
    required this.finalScore,
    required this.retakeType,
  });

  final String term;
  final String courseName;
  final String courseCode;
  final String score;
  final String credit;
  final String gradePoint;
  final String passStatus;
  final String examType;
  final String usualScore;
  final String finalScore;
  final String retakeType;

  String get displayCourseName => courseName.isEmpty ? '未命名课程' : courseName;

  double? get numericScore {
    final value = double.tryParse(score.replaceAll('分', '').trim());
    if (value != null) return value;
    return switch (score.trim()) {
      '优秀' || '优' => 95,
      '良好' || '良' => 85,
      '中等' || '中' => 75,
      '及格' || '合格' || '通过' => 60,
      '不及格' || '不合格' || '不通过' => 0,
      _ => null,
    };
  }

  bool get passed {
    final status = passStatus.trim();
    if (status.contains('不及格') ||
        status.contains('不合格') ||
        status.contains('不通过') ||
        status == '否') {
      return false;
    }
    if (status.contains('及格') ||
        status.contains('合格') ||
        status.contains('通过') ||
        status == '是') {
      return true;
    }
    final value = numericScore;
    return value != null && value >= 60;
  }

  bool get failed {
    final status = passStatus.trim();
    if (status.contains('不及格') ||
        status.contains('不合格') ||
        status.contains('不通过')) {
      return true;
    }
    final value = numericScore;
    return value != null && value < 60;
  }

  factory ScoreRecord.fromRow(Map<String, dynamic> row) {
    String text(List<String> keys) {
      for (final key in keys) {
        final value = row[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
      return '';
    }

    return ScoreRecord(
      term: text(['XNXQDM_DISPLAY', 'XNXQDM', 'XNXQ']),
      courseName: text(['XSKCM', 'KCM', 'KCMC', 'KCM_DISPLAY']),
      courseCode: text(['XSKCH', 'KCH', 'KCH_DISPLAY']),
      score: text(['ZCJ_DISPLAY', 'ZCJ', 'ZCJMC']),
      credit: text(['XF_DISPLAY', 'XF']),
      gradePoint: text(['XFJD_DISPLAY', 'XFJD', 'JDF']),
      passStatus: text(['SFJG_DISPLAY', 'SFJG', 'SFJGMC']),
      examType: text(['KSLXDM_DISPLAY', 'KSXZDM_DISPLAY', 'KSLX', 'KSXZ']),
      usualScore: text(['PSCJ_DISPLAY', 'PSCJ']),
      finalScore: text(['QMCJ_DISPLAY', 'QMCJ']),
      retakeType: text(['CXCKDM_DISPLAY', 'CXCKDM']),
    );
  }

  factory ScoreRecord.fromJson(Map<String, dynamic> json) => ScoreRecord(
    term: '${json['term'] ?? ''}',
    courseName: '${json['courseName'] ?? ''}',
    courseCode: '${json['courseCode'] ?? ''}',
    score: '${json['score'] ?? ''}',
    credit: '${json['credit'] ?? ''}',
    gradePoint: '${json['gradePoint'] ?? ''}',
    passStatus: '${json['passStatus'] ?? ''}',
    examType: '${json['examType'] ?? ''}',
    usualScore: '${json['usualScore'] ?? ''}',
    finalScore: '${json['finalScore'] ?? ''}',
    retakeType: '${json['retakeType'] ?? ''}',
  );

  Map<String, dynamic> toJson() => {
    'term': term,
    'courseName': courseName,
    'courseCode': courseCode,
    'score': score,
    'credit': credit,
    'gradePoint': gradePoint,
    'passStatus': passStatus,
    'examType': examType,
    'usualScore': usualScore,
    'finalScore': finalScore,
    'retakeType': retakeType,
  };
}

class ScoreTermSummary {
  const ScoreTermSummary({
    required this.term,
    required this.total,
    required this.passed,
    required this.failed,
    required this.credits,
    required this.averageScore,
  });

  final String term;
  final int total;
  final int passed;
  final int failed;
  final double credits;
  final double? averageScore;

  String get creditsText {
    if (credits == credits.roundToDouble()) return credits.toStringAsFixed(0);
    return credits.toStringAsFixed(1);
  }
}

class ScoreReport {
  const ScoreReport({required this.records, required this.fetchedAt});

  final List<ScoreRecord> records;
  final DateTime fetchedAt;

  List<String> get terms {
    final result = <String>{
      for (final record in records)
        if (record.term.isNotEmpty) record.term,
    }.toList();
    result.sort(_compareTerms);
    return result;
  }

  String? get latestTerm => terms.isEmpty ? null : terms.first;

  List<ScoreRecord> recordsFor(String? term) {
    if (term == null || term.isEmpty) return records;
    return records.where((record) => record.term == term).toList();
  }

  ScoreTermSummary summaryFor(String? term) {
    final selected = recordsFor(term);
    final numeric = <double>[];
    var credits = 0.0;
    for (final record in selected) {
      final score = record.numericScore;
      if (score != null) numeric.add(score);
      final credit = double.tryParse(record.credit);
      if (credit != null) credits += credit;
    }
    return ScoreTermSummary(
      term: term ?? '',
      total: selected.length,
      passed: selected.where((record) => record.passed).length,
      failed: selected.where((record) => record.failed).length,
      credits: credits,
      averageScore: numeric.isEmpty
          ? null
          : numeric.reduce((a, b) => a + b) / numeric.length,
    );
  }

  factory ScoreReport.fromJson(Map<String, dynamic> json) {
    final rows = json['records'];
    final fetchedAt = DateTime.tryParse('${json['fetchedAt'] ?? ''}');
    return ScoreReport(
      records: rows is List
          ? [
              for (final row in rows)
                if (row is Map<String, dynamic>) ScoreRecord.fromJson(row),
            ]
          : const [],
      fetchedAt: fetchedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() => {
    'records': [for (final record in records) record.toJson()],
    'fetchedAt': fetchedAt.toIso8601String(),
  };

  static int _compareTerms(String a, String b) {
    final aParts = RegExp(r'^(\d{4})-(\d{4})-(\d+)$').firstMatch(a);
    final bParts = RegExp(r'^(\d{4})-(\d{4})-(\d+)$').firstMatch(b);
    if (aParts != null && bParts != null) {
      for (var i = 1; i <= 3; i++) {
        final diff = int.parse(bParts.group(i)!) - int.parse(aParts.group(i)!);
        if (diff != 0) return diff;
      }
    }
    return b.compareTo(a);
  }
}
