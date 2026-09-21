/// 劳动教育平台「学生成绩」（`ResultManage/StudentResult`）表格里本人的一行：
/// 官方核算出来的劳动积分，按批次生成，带核算日期与确认 / 归档状态。
///
/// 全是页面单元格文本，原样保留，格式化交给展示层。
class LaborResult {
  const LaborResult({
    required this.theory,
    required this.life,
    required this.service,
    required this.majorCourse,
    required this.majorContest,
    required this.majorTotal,
    required this.total,
    required this.confirmed,
    required this.updatedAt,
    required this.filed,
    required this.filedAt,
  });

  /// 理论积分。
  final String theory;

  /// 生活劳动。
  final String life;

  /// 服务劳动。
  final String service;

  /// 专业劳动课程积分。
  final String majorCourse;

  /// 竞赛积分。
  final String majorContest;

  /// 专业劳动（隐藏列，= 课程 + 竞赛）。
  final String majorTotal;

  /// 总积分。
  final String total;

  /// 是否确认，页面给「是」/「否」。
  final String confirmed;

  /// 更新（核算）日期，如「2026-06-30 16:25:27」。
  final String updatedAt;

  /// 是否归档，「是」/「否」。
  final String filed;

  /// 归档时间。
  final String filedAt;

  bool get isConfirmed => confirmed == '是';
  bool get isFiled => filed == '是';

  /// 核算日期只留到「月-日」，卡片上够用；解析不了就原样返回。
  String get updatedShort {
    final m = RegExp(r'^\d{4}-(\d{2}-\d{2})').firstMatch(updatedAt);
    return m?.group(1) ?? updatedAt;
  }

  factory LaborResult.fromRow(Map<String, String> row) {
    String s(String key) => (row[key] ?? '').trim();
    return LaborResult(
      theory: s('理论积分'),
      life: s('生活劳动'),
      service: s('服务劳动'),
      majorCourse: s('专业劳动课程积分'),
      majorContest: s('竞赛积分'),
      majorTotal: s('专业劳动'),
      total: s('总积分'),
      confirmed: s('是否确认'),
      updatedAt: s('更新日期'),
      filed: s('是否归档'),
      filedAt: s('归档时间'),
    );
  }

  factory LaborResult.fromJson(Map<String, dynamic> json) {
    String s(String key) => (json[key] ?? '').toString().trim();
    return LaborResult(
      theory: s('theory'),
      life: s('life'),
      service: s('service'),
      majorCourse: s('majorCourse'),
      majorContest: s('majorContest'),
      majorTotal: s('majorTotal'),
      total: s('total'),
      confirmed: s('confirmed'),
      updatedAt: s('updatedAt'),
      filed: s('filed'),
      filedAt: s('filedAt'),
    );
  }

  Map<String, dynamic> toJson() => {
    'theory': theory,
    'life': life,
    'service': service,
    'majorCourse': majorCourse,
    'majorContest': majorContest,
    'majorTotal': majorTotal,
    'total': total,
    'confirmed': confirmed,
    'updatedAt': updatedAt,
    'filed': filed,
    'filedAt': filedAt,
  };
}

/// 专业劳动积分汇总页（`ZYLDScoreHZ`）本人的一行。
class LaborMajorLive {
  const LaborMajorLive({
    required this.course,
    required this.contest,
    required this.total,
  });

  /// 专业劳动课程积分。
  final String course;

  /// 竞赛项目积分。
  final String contest;

  /// 专业劳动累计积分。
  final String total;

  factory LaborMajorLive.fromRow(Map<String, String> row) {
    String s(String key) => (row[key] ?? '').trim();
    return LaborMajorLive(
      course: s('专业劳动课程积分'),
      contest: s('竞赛项目积分'),
      total: s('专业劳动累计积分'),
    );
  }

  factory LaborMajorLive.fromJson(Map<String, dynamic> json) {
    String s(String key) => (json[key] ?? '').toString().trim();
    return LaborMajorLive(
      course: s('course'),
      contest: s('contest'),
      total: s('total'),
    );
  }

  Map<String, dynamic> toJson() => {
    'course': course,
    'contest': contest,
    'total': total,
  };
}

/// 劳动积分：官方核算结果 + 三个分项页面的实时统计。
///
/// 核算结果是按批次生成的快照（有「更新日期」），实时统计是各分项页面当下的
/// 数字，两者可能不一致——新参加的活动往往先出现在实时统计里。卡片只看核算
/// 结果，详情页把两者并列。
class LaborScore {
  const LaborScore({
    required this.official,
    required this.liveLife,
    required this.liveService,
    required this.liveMajor,
    required this.fetchedAt,
  });

  /// 官方核算；平台还没为本人生成过结果时为 null。
  final LaborResult? official;

  /// 生活劳动活动的实时总积分；页面没给出本人的行时为 null。
  final String? liveLife;

  /// 服务劳动活动的实时总积分。
  final String? liveService;

  /// 专业劳动实时汇总；页面「暂无数据」时为 null。
  final LaborMajorLive? liveMajor;

  final DateTime fetchedAt;

  factory LaborScore.fromRows({
    required List<Map<String, String>> result,
    required List<Map<String, String>>? life,
    required List<Map<String, String>>? service,
    required List<Map<String, String>>? major,
    required DateTime fetchedAt,
  }) {
    String? total(List<Map<String, String>>? rows) =>
        rows == null || rows.isEmpty ? null : rows.first['总积分']?.trim();
    return LaborScore(
      official: result.isEmpty ? null : LaborResult.fromRow(result.first),
      liveLife: total(life),
      liveService: total(service),
      liveMajor: major == null || major.isEmpty
          ? null
          : LaborMajorLive.fromRow(major.first),
      fetchedAt: fetchedAt,
    );
  }

  factory LaborScore.fromJson(
    Map<String, dynamic> json, {
    required DateTime fetchedAt,
  }) {
    final official = json['official'];
    final major = json['liveMajor'];
    return LaborScore(
      official: official is Map<String, dynamic>
          ? LaborResult.fromJson(official)
          : null,
      liveLife: json['liveLife']?.toString(),
      liveService: json['liveService']?.toString(),
      liveMajor: major is Map<String, dynamic>
          ? LaborMajorLive.fromJson(major)
          : null,
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'official': official?.toJson(),
    'liveLife': liveLife,
    'liveService': liveService,
    'liveMajor': liveMajor?.toJson(),
    'fetchedAt': fetchedAt.toIso8601String(),
  };
}
