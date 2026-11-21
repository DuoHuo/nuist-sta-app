// 多课表元数据模型、学期命名与学年学期比较（纯 Dart，不依赖 Flutter）。

export '../../core/auth/enrollment_year.dart' show enrollmentYearFromStudentId;

/// 默认（当前学期/初始）课表标识；数据仍保存在 `timetable/` 根目录以保持向后兼容。
const String kDefaultScheduleId = 'default';

/// 课表来源分类，用于区分用户自己的教务课表与从 WakeUp 口令导入的他人课表。
enum TimetableSourceKind {
  /// 教务同步课表（当前学期或往年学期）。
  jwxt,

  /// 从 WakeUp 分享口令导入的课表。
  wakeupImport,
}

TimetableSourceKind parseTimetableSourceKind(Object? raw) {
  for (final kind in TimetableSourceKind.values) {
    if (kind.name == raw) return kind;
  }
  return TimetableSourceKind.jwxt;
}

/// 教务可选学年学期条目（来自 `jshkcb/xnxqcx.do`）。
class JwxtTermOption {
  const JwxtTermOption({required this.termCode, this.displayName = ''});

  final String termCode;
  final String displayName;

  /// 展示用统一短名（如 `25秋`、`26春`、`26暑假学期`）。
  String get formattedName => formatTermScheduleName(termCode);
}

/// 将教务学年学期代码格式化为简洁中文名：
/// - `2025-2026-1` → `25秋`（第一学期，秋季入学）
/// - `2025-2026-2` → `26春`（第二学期，春季）
/// - `2025-2026-3` → `26暑假学期`（第三学期/小学期）
/// - 其他格式直接返回原代码兜底。
String formatTermScheduleName(String termCode) {
  final trimmed = termCode.trim();
  if (trimmed.isEmpty) return '我的课表';
  final match = RegExp(r'^(\d{4})-(\d{4})-(\d+)$').firstMatch(trimmed);
  if (match == null) return trimmed;
  final startYear = match.group(1)!;
  final endYear = match.group(2)!;
  final term = match.group(3)!;
  final startShort = startYear.substring(2);
  final endShort = endYear.substring(2);
  return switch (term) {
    '1' => '$startShort秋',
    '2' => '$endShort春',
    '3' => '$endShort暑假学期',
    _ => trimmed,
  };
}

({int startYear, int endYear, int term})? _parseTermTuple(String termCode) {
  final match = RegExp(r'^(\d{4})-(\d{4})-(\d+)$').firstMatch(termCode.trim());
  if (match == null) return null;
  final s = int.tryParse(match.group(1)!);
  final e = int.tryParse(match.group(2)!);
  final t = int.tryParse(match.group(3)!);
  if (s == null || e == null || t == null) return null;
  return (startYear: s, endYear: e, term: t);
}

/// 按时间先后比较两个教务学期代码；无法解析时按字典序回退。
int compareTermCodes(String a, String b) {
  final pa = _parseTermTuple(a);
  final pb = _parseTermTuple(b);
  if (pa != null && pb != null) {
    final byStart = pa.startYear.compareTo(pb.startYear);
    if (byStart != 0) return byStart;
    final byEnd = pa.endYear.compareTo(pb.endYear);
    if (byEnd != 0) return byEnd;
    return pa.term.compareTo(pb.term);
  }
  return a.trim().compareTo(b.trim());
}

/// 判断 [termCode] 是否严格早于当前学期 [currentTermCode]（即往年/已过去学期）。
bool isHistoricalTerm(String termCode, {required String currentTermCode}) {
  final target = termCode.trim();
  final current = currentTermCode.trim();
  if (target.isEmpty || current.isEmpty) return false;
  if (_parseTermTuple(target) == null || _parseTermTuple(current) == null) {
    return false;
  }
  return compareTermCodes(target, current) < 0;
}

/// 判断学期 [termCode] 是否在入学年份 [enrollmentYear] 及之后。
/// 入学年份未知或学期代码无法解析学年时返回 true（不过度误杀）。
bool isTermAtOrAfterEnrollment(String termCode, {int? enrollmentYear}) {
  if (enrollmentYear == null) return true;
  final parsed = _parseTermTuple(termCode);
  if (parsed == null) return true;
  return parsed.startYear >= enrollmentYear;
}

/// 校检并规范化课表目录名，只保留安全字符。
String sanitizeScheduleId(String raw) {
  final cleaned = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return cleaned.isEmpty ? kDefaultScheduleId : cleaned;
}

/// 单张课表的索引元信息。
class ScheduleMetadata {
  const ScheduleMetadata({
    required this.id,
    required this.name,
    required this.sourceKind,
    this.customName = false,
    this.termCode = '',
    this.createdAt,
    this.syncedAt,
    this.courseCount,
  });

  final String id;
  final String name;

  /// 是否为用户手工命名/重命名；为 true 时教务同步不再覆盖名称。
  final bool customName;
  final TimetableSourceKind sourceKind;
  final String termCode;
  final DateTime? createdAt;
  final DateTime? syncedAt;
  final int? courseCount;

  /// 是否属于用户自己的教务课表（含当前与往年）。
  bool get isOwnSchedule => sourceKind == TimetableSourceKind.jwxt;

  /// 是否为从 WakeUp 口令导入的他人课表。
  bool get isImportedSchedule => sourceKind == TimetableSourceKind.wakeupImport;

  ScheduleMetadata copyWith({
    String? id,
    String? name,
    bool? customName,
    TimetableSourceKind? sourceKind,
    String? termCode,
    DateTime? createdAt,
    DateTime? syncedAt,
    bool clearSyncedAt = false,
    int? courseCount,
  }) => ScheduleMetadata(
    id: id ?? this.id,
    name: name ?? this.name,
    customName: customName ?? this.customName,
    sourceKind: sourceKind ?? this.sourceKind,
    termCode: termCode ?? this.termCode,
    createdAt: createdAt ?? this.createdAt,
    syncedAt: clearSyncedAt ? null : (syncedAt ?? this.syncedAt),
    courseCount: courseCount ?? this.courseCount,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'customName': customName,
    'sourceKind': sourceKind.name,
    if (termCode.isNotEmpty) 'termCode': termCode,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (syncedAt != null) 'syncedAt': syncedAt!.toIso8601String(),
    if (courseCount != null) 'courseCount': courseCount,
  };

  static ScheduleMetadata? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final name = raw['name']?.toString().trim() ?? '';
    final sourceKind = parseTimetableSourceKind(raw['sourceKind']);
    final termCode = raw['termCode']?.toString().trim() ?? '';
    return ScheduleMetadata(
      id: id,
      name: name.isNotEmpty
          ? name
          : (termCode.isNotEmpty ? formatTermScheduleName(termCode) : '我的课表'),
      customName: raw['customName'] == true,
      sourceKind: sourceKind,
      termCode: termCode,
      createdAt: DateTime.tryParse('${raw['createdAt'] ?? ''}'),
      syncedAt: DateTime.tryParse('${raw['syncedAt'] ?? ''}'),
      courseCount: raw['courseCount'] is int ? raw['courseCount'] as int : null,
    );
  }
}

/// 多课表全局索引（存在 `timetable/schedules_index.json`）。
class SchedulesIndex {
  const SchedulesIndex({
    this.primaryScheduleId = kDefaultScheduleId,
    this.currentTermCode = '',
    this.schedules = const [],
    this.checkedEmptyTerms = const [],
  });

  static const int schemaVersion = 1;

  /// 主课表 id：驱动首页卡片、桌面小组件、上课/明日提醒和校园地图。
  final String primaryScheduleId;

  /// 最近一次从教务确认到的当前学期代码（如 `2026-2027-1`）。
  final String currentTermCode;

  /// 全部已纳入多课表管理的课表元信息。
  final List<ScheduleMetadata> schedules;

  /// 已探测过且无课的往年学期代码，避免重复无效探测。
  final List<String> checkedEmptyTerms;

  ScheduleMetadata? byId(String id) {
    for (final s in schedules) {
      if (s.id == id) return s;
    }
    return null;
  }

  SchedulesIndex copyWith({
    String? primaryScheduleId,
    String? currentTermCode,
    List<ScheduleMetadata>? schedules,
    List<String>? checkedEmptyTerms,
  }) => SchedulesIndex(
    primaryScheduleId: primaryScheduleId ?? this.primaryScheduleId,
    currentTermCode: currentTermCode ?? this.currentTermCode,
    schedules: schedules ?? this.schedules,
    checkedEmptyTerms: checkedEmptyTerms ?? this.checkedEmptyTerms,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'primaryScheduleId': primaryScheduleId,
    if (currentTermCode.isNotEmpty) 'currentTermCode': currentTermCode,
    'schedules': [for (final s in schedules) s.toJson()],
    if (checkedEmptyTerms.isNotEmpty) 'checkedEmptyTerms': checkedEmptyTerms,
  };

  factory SchedulesIndex.fromJson(Map<String, dynamic> json) {
    final parsed = <ScheduleMetadata>[];
    final seenIds = <String>{};
    final rawList = json['schedules'];
    if (rawList is List) {
      for (final item in rawList) {
        final meta = ScheduleMetadata.tryFromJson(item);
        if (meta != null && seenIds.add(meta.id)) {
          parsed.add(meta);
        }
      }
    }
    final primaryRaw = json['primaryScheduleId']?.toString().trim() ?? '';
    final primary =
        primaryRaw.isNotEmpty &&
            (parsed.isEmpty || parsed.any((s) => s.id == primaryRaw))
        ? primaryRaw
        : (parsed.isNotEmpty ? parsed.first.id : kDefaultScheduleId);
    final emptyRaw = json['checkedEmptyTerms'];
    final emptyTerms = <String>[
      if (emptyRaw is List)
        for (final item in emptyRaw)
          if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
    return SchedulesIndex(
      primaryScheduleId: primary,
      currentTermCode: json['currentTermCode']?.toString().trim() ?? '',
      schedules: List.unmodifiable(parsed),
      checkedEmptyTerms: List.unmodifiable(emptyTerms),
    );
  }
}
