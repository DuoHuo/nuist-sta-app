/// 双创学分明细页（`XueFen/Summary/Index`）表格里的一行。
///
/// 全是页面单元格文本，原样保留，格式化交给展示层。
class InnovationCreditItem {
  const InnovationCreditItem({
    required this.name,
    required this.date,
    required this.category1,
    required this.category2,
    required this.level,
    required this.standardScore,
    required this.score,
    required this.batch,
    required this.status,
  });

  /// 项目名称。
  final String name;

  /// 取得成果日期，如「2026-03-11」。
  final String date;

  /// 认定大类，如「竞赛实验班」。
  final String category1;

  /// 认定小类，如「竞赛实验班期末成绩」。
  final String category2;

  /// 获奖等级或排名，如「60分及以上」。
  final String level;

  /// 参照分值。
  final String standardScore;

  /// 实际分值。
  final String score;

  /// 所属批次，如「学分申请」。
  final String batch;

  /// 状态，如「学校审核学分通过」。
  final String status;

  /// 「竞赛实验班 › 竞赛实验班期末成绩 › 60分及以上」，空段自动省略。
  String get categoryPath =>
      [category1, category2, level].where((s) => s.isNotEmpty).join(' › ');

  /// 实际分值与参照分值不一致（被打了折），详情页据此标注参照分。
  bool get isDiscounted =>
      standardScore.isNotEmpty && score.isNotEmpty && standardScore != score;

  /// 按状态文案归类的语义：通过 / 驳回 / 审核中。
  InnovationStatusKind get statusKind {
    if (status.contains('不通过') ||
        status.contains('驳回') ||
        status.contains('退回')) {
      return InnovationStatusKind.rejected;
    }
    if (status.contains('通过')) return InnovationStatusKind.approved;
    return InnovationStatusKind.pending;
  }

  factory InnovationCreditItem.fromRow(Map<String, String> row) {
    String s(String key) => (row[key] ?? '').trim();
    return InnovationCreditItem(
      name: s('项目名称'),
      date: s('取得成果日期'),
      category1: s('认定大类'),
      category2: s('认定小类'),
      level: s('获奖等级或排名'),
      standardScore: s('参照分值'),
      score: s('实际分值'),
      batch: s('所属批次'),
      status: s('状态'),
    );
  }

  factory InnovationCreditItem.fromJson(Map<String, dynamic> json) {
    String s(String key) => (json[key] ?? '').toString().trim();
    return InnovationCreditItem(
      name: s('name'),
      date: s('date'),
      category1: s('category1'),
      category2: s('category2'),
      level: s('level'),
      standardScore: s('standardScore'),
      score: s('score'),
      batch: s('batch'),
      status: s('status'),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'date': date,
    'category1': category1,
    'category2': category2,
    'level': level,
    'standardScore': standardScore,
    'score': score,
    'batch': batch,
    'status': status,
  };
}

enum InnovationStatusKind { approved, pending, rejected }

/// 双创学分：汇总页（`SummaryQuery/Index`）的总分与成绩 + 明细页的全部条目。
class InnovationCredit {
  const InnovationCredit({
    required this.total,
    required this.grade,
    required this.items,
    required this.fetchedAt,
  });

  /// 总学分。
  final String total;

  /// 成绩评定，如「不及格」「及格」。
  final String grade;

  final List<InnovationCreditItem> items;
  final DateTime fetchedAt;

  /// 成绩评定的语义：合格 / 不合格 / 无法判断。
  InnovationStatusKind? get gradeKind {
    if (grade.isEmpty) return null;
    if (grade.contains('不及格') || grade.contains('不合格')) {
      return InnovationStatusKind.rejected;
    }
    if (grade.contains('及格') || grade.contains('合格') || grade.contains('通过')) {
      return InnovationStatusKind.approved;
    }
    return null;
  }

  /// 汇总页对本人只有一行；没有行时视为 0 分。
  factory InnovationCredit.fromRows({
    required List<Map<String, String>> summary,
    required List<Map<String, String>> detail,
    required DateTime fetchedAt,
  }) {
    final row = summary.isEmpty ? const <String, String>{} : summary.first;
    return InnovationCredit(
      total: (row['总学分'] ?? '0').trim(),
      grade: (row['成绩'] ?? '').trim(),
      items: [
        for (final r in detail)
          if ((r['项目名称'] ?? '').trim().isNotEmpty)
            InnovationCreditItem.fromRow(r),
      ],
      fetchedAt: fetchedAt,
    );
  }

  factory InnovationCredit.fromJson(
    Map<String, dynamic> json, {
    required DateTime fetchedAt,
  }) {
    final items = json['items'];
    return InnovationCredit(
      total: (json['total'] ?? '').toString(),
      grade: (json['grade'] ?? '').toString(),
      items: [
        if (items is List)
          for (final item in items)
            if (item is Map<String, dynamic>)
              InnovationCreditItem.fromJson(item),
      ],
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'total': total,
    'grade': grade,
    'items': [for (final item in items) item.toJson()],
    'fetchedAt': fetchedAt.toIso8601String(),
  };
}
