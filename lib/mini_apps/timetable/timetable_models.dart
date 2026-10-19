// 课表纯数据模型（不依赖 Flutter）。解析教务 EMAP 行与本地 JSON。

import 'dart:convert';

import 'timetable_date_edits.dart';

/// 一节课的上课时段。
class CourseSlot {
  const CourseSlot({
    required this.day,
    required this.startNode,
    required this.endNode,
    required this.weeks,
    this.weeksLabel = '',
    this.teacher = '',
    this.location = '',
    this.note = '',
    this.splitFrom,
  });

  /// 星期 1=周一 … 7=周日；0 或 null 表示无固定时间。
  final int day;
  final int startNode;
  final int endNode;

  /// 周次位串，下标 0=第1周，'1' 表示有课。
  final String weeks;
  final String weeksLabel;
  final String teacher;
  final String location;
  final String note;

  /// 手动课拖动拆出的时段（「只改本周」/「改以后所有周」）记下它来自哪个原时段
  /// （按同一门课内的星期 + 起止节识别，见 [SlotRef]）。仅用于周视图：第 w 周本时段
  /// 有课时，原时段不再画「[非本周]」虚影。不参与配色。旧数据无此字段 → null（普通时段）。
  final SlotRef? splitFrom;

  /// 本时段的位置标识（星期 + 起止节）。
  SlotRef get ref => SlotRef(day: day, startNode: startNode, endNode: endNode);

  /// 复制并替换 [splitFrom]（[clear] 为 true 时置空）。
  CourseSlot withSplitFrom(SlotRef? value, {bool clear = false}) => CourseSlot(
    day: day,
    startNode: startNode,
    endNode: endNode,
    weeks: weeks,
    weeksLabel: weeksLabel,
    teacher: teacher,
    location: location,
    note: note,
    splitFrom: clear ? null : (value ?? splitFrom),
  );

  bool get hasFixedTime =>
      day >= 1 && day <= 7 && startNode >= 1 && endNode >= startNode;

  int get span => endNode - startNode + 1;

  bool occursInWeek(int week) {
    if (week < 1 || week > weeks.length) return false;
    return weeks[week - 1] == '1';
  }

  /// 第 [w] 周是否有课：SKZC 位串 weeks[w-1]（第 1 周 = 下标 0）；
  /// w < 1 或超出位串长度一律 false（教务与手动课程都存位串）。
  bool hasClassInWeek(int w) => occursInWeek(w);

  /// 单周 / 双周 / 全周（仅看位串内出现的周）。
  WeekParity get parity {
    var odd = false;
    var even = false;
    for (var i = 0; i < weeks.length; i++) {
      if (weeks[i] != '1') continue;
      if ((i + 1).isOdd) {
        odd = true;
      } else {
        even = true;
      }
    }
    if (odd && even) return WeekParity.all;
    if (odd) return WeekParity.odd;
    if (even) return WeekParity.even;
    return WeekParity.all;
  }

  Map<String, dynamic> toJson() => {
    'day': day,
    'startNode': startNode,
    'endNode': endNode,
    'weeks': weeks,
    'weeksLabel': weeksLabel,
    'teacher': teacher,
    'location': location,
    'note': note,
    if (splitFrom != null) 'splitFrom': splitFrom!.toJson(),
  };

  factory CourseSlot.fromJson(Map<String, dynamic> json) => CourseSlot(
    day: _asInt(json['day']) ?? 0,
    startNode: _asInt(json['startNode']) ?? 0,
    endNode: _asInt(json['endNode']) ?? 0,
    weeks: '${json['weeks'] ?? ''}',
    weeksLabel: '${json['weeksLabel'] ?? ''}',
    teacher: '${json['teacher'] ?? ''}',
    location: '${json['location'] ?? ''}',
    note: '${json['note'] ?? ''}',
    splitFrom: SlotRef.tryParse(json['splitFrom']),
  );
}

/// 同一门课内时段的位置标识：星期 + 起止节（手动时段没有独立 id；同一门课同一
/// 位置的时段拖回时会合并成一个，所以位置在课内唯一）。JSON：
/// `{"day":1,"startNode":3,"endNode":4}`。
class SlotRef {
  const SlotRef({
    required this.day,
    required this.startNode,
    required this.endNode,
  });

  final int day;
  final int startNode;
  final int endNode;

  /// [slot] 是否就在这个位置。
  bool matches(CourseSlot slot) =>
      slot.day == day && slot.startNode == startNode && slot.endNode == endNode;

  Map<String, dynamic> toJson() => {
    'day': day,
    'startNode': startNode,
    'endNode': endNode,
  };

  /// 解析不了（缺键/类型不对）→ null，按普通时段处理。
  static SlotRef? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final d = raw['day'], s = raw['startNode'], e = raw['endNode'];
    if (d is! int || s is! int || e is! int) return null;
    return SlotRef(day: d, startNode: s, endNode: e);
  }

  @override
  bool operator ==(Object other) =>
      other is SlotRef &&
      other.day == day &&
      other.startNode == startNode &&
      other.endNode == endNode;

  @override
  int get hashCode => Object.hash(day, startNode, endNode);

  @override
  String toString() => 'SlotRef($day, $startNode-$endNode)';
}

enum WeekParity { all, odd, even }

/// 一门课（可含多个时段）。
class Course {
  const Course({
    required this.id,
    required this.name,
    this.code = '',
    this.classId = '',
    this.credit,
    this.colorIndex,
    this.assignedColorIndex,
    this.source = CourseSource.manual,
    this.slots = const [],
    this.hidden = false,
  });

  final String id;
  final String name;
  final String code;
  final String classId;
  final double? credit;

  /// 用户自选色号；null 则按课名哈希。
  final int? colorIndex;

  /// 手动课已定的自动色号（近色顺延后的结果，持久化）。仅在教务同步 / 增删手动课 /
  /// 换配色方案时重算写入；拖动、恢复、拆分时段、编辑、解绑、重启只读不算（编辑时若既无
  /// 自选色也无此值，只给这门课补算一次）。[colorIndex] 优先。
  /// 旧文件无此字段 → null，启动时算一次并落盘。
  final int? assignedColorIndex;
  final CourseSource source;
  final List<CourseSlot> slots;
  final bool hidden;

  int get resolvedColorIndex => colorIndex ?? courseColorIndexForName(name);

  /// 用户手动添加的课程（可编辑/删除）；教务课程只读。
  bool get isManual => source == CourseSource.manual;

  /// 第 [w] 周是否有课（任一节次在该周有课）；越界 / ≤0 为 false。
  /// UI 按周次判断有没有课时统一用它，不直接读 SKZC 位串。
  bool hasClassInWeek(int w) => slots.any((s) => s.hasClassInWeek(w));

  /// 最后一个有课的周（1 起）；无有效周次返回 0。
  int get lastActiveWeek {
    var max = 0;
    for (final s in slots) {
      final i = s.weeks.lastIndexOf('1');
      if (i + 1 > max) max = i + 1;
    }
    return max;
  }

  Course copyWith({
    String? id,
    String? name,
    String? code,
    String? classId,
    double? credit,
    int? colorIndex,
    bool clearColor = false,
    int? assignedColorIndex,
    bool clearAssignedColor = false,
    CourseSource? source,
    List<CourseSlot>? slots,
    bool? hidden,
  }) => Course(
    id: id ?? this.id,
    name: name ?? this.name,
    code: code ?? this.code,
    classId: classId ?? this.classId,
    credit: credit ?? this.credit,
    colorIndex: clearColor ? null : (colorIndex ?? this.colorIndex),
    assignedColorIndex: clearAssignedColor
        ? null
        : (assignedColorIndex ?? this.assignedColorIndex),
    source: source ?? this.source,
    slots: slots ?? this.slots,
    hidden: hidden ?? this.hidden,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'code': code,
    'classId': classId,
    if (credit != null) 'credit': credit,
    if (colorIndex != null) 'colorIndex': colorIndex,
    if (assignedColorIndex != null) 'assignedColorIndex': assignedColorIndex,
    'source': source.name,
    'slots': [for (final s in slots) s.toJson()],
    'hidden': hidden,
  };

  factory Course.fromJson(Map<String, dynamic> json) => Course(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    code: '${json['code'] ?? ''}',
    classId: '${json['classId'] ?? ''}',
    credit: (json['credit'] as num?)?.toDouble(),
    colorIndex: _asColorIndex(json['colorIndex']),
    assignedColorIndex: _asColorIndex(json['assignedColorIndex']),
    source: CourseSource.values.firstWhere(
      (e) => e.name == json['source'],
      orElse: () => CourseSource.manual,
    ),
    slots: [
      for (final item in (json['slots'] as List? ?? const []))
        if (item is Map<String, dynamic>) CourseSlot.fromJson(item),
    ],
    hidden: json['hidden'] == true,
  );
}

enum CourseSource { jwxt, manual }

/// 作息表一节。
class PeriodTime {
  const PeriodTime({
    required this.node,
    required this.start,
    required this.end,
  });

  final int node;

  /// "08:00"
  final String start;
  final String end;

  String get label => '$start-$end';

  Map<String, dynamic> toJson() => {'node': node, 'start': start, 'end': end};

  factory PeriodTime.fromJson(Map<String, dynamic> json) => PeriodTime(
    node: _asInt(json['node']) ?? 0,
    start: '${json['start'] ?? ''}',
    end: '${json['end'] ?? ''}',
  );
}

/// 考试默认颜色（§14.3）。
const int kDefaultExamColor = 0xFFC62828;

/// 首页今日课表最多显示条数默认值（spec-next-1020 item 4）。
const int kDefaultHomeMaxItems = 2;

/// 外观与学期设置（本地）。
class TimetableSettings {
  const TimetableSettings({
    this.scheduleName = '我的课表',
    this.termCode = '',
    this.termStartDate,
    this.maxWeeks = 30,
    this.nodesPerDay = 11,
    this.periodHeight = 64,
    this.cellRadius = 4,
    this.showSaturday = true,
    this.showSunday = true,
    this.showNonCurrentWeek = false,
    this.showGridLines = true,
    this.weekStartsOnMonday = true,
    this.termStartFromJwxt = false,
    this.showLocation = true,
    this.showTeacher = false,
    this.fontScale = CellFontScale.standard,
    this.cellOpacity = 100,
    this.paletteScheme = 'A',
    this.showTomorrowOnHome = true,
    this.reminderEnabled = false,
    this.reminderLeadMinutes = 15,
    this.showExams = true,
    this.examColor = kDefaultExamColor,
    this.cellTextColor = CellTextColorMode.auto,
    this.homeMaxItems = kDefaultHomeMaxItems,
  });

  final String scheduleName;
  final String termCode;
  final DateTime? termStartDate;
  final int maxWeeks;
  final int nodesPerDay;
  final double periodHeight;
  final double cellRadius;
  final bool showSaturday;
  final bool showSunday;
  final bool showNonCurrentWeek;
  final bool showGridLines;
  final bool weekStartsOnMonday;

  /// 开学日是否由教务 dqzc 推算（仅此来源的缓存值可信；旧版写入的默认值不可信）。
  final bool termStartFromJwxt;

  /// 格子里显示地点（§13.3，默认开）。
  final bool showLocation;

  /// 格子里显示老师（默认关；排在地点下面，空间不够先截掉）。
  final bool showTeacher;

  /// 格子文字大小（默认标准，系数见 [CellFontScale.factor]）。
  final CellFontScale fontScale;

  /// 格子底色不透明度 30–100（整数，默认 100）。
  final int cellOpacity;

  /// 配色方案 'A' 柔和 / 'B' 马卡龙 / 'C' 莫兰迪（默认 A）。
  final String paletteScheme;

  /// 首页卡片显示明天的课（默认开）。
  final bool showTomorrowOnHome;

  /// 上课提醒（默认关；本版只存设置，不排提醒）。
  final bool reminderEnabled;

  /// 提前提醒分钟数：5/10/15/20/30（默认 15）。
  final int reminderLeadMinutes;

  /// 课表和首页显示考试（默认开；关掉只隐藏，数据照常拉取保存）。
  final bool showExams;

  /// 考试格子底色 ARGB（默认深红 0xFFC62828）。
  final int examColor;

  /// item 14「文字颜色」：自动（色板字色 + 深色规则）/ 白字 / 黑字。缺省自动。
  final CellTextColorMode cellTextColor;

  /// spec-next-1020 item 4：首页今日课表最多显示条数（1–4，默认 2）。
  final int homeMaxItems;

  /// 每周第一天是周日（设置 9；只影响列顺序）。存储键仍是 `weekStartsOnMonday`。
  bool get weekStartsSunday => !weekStartsOnMonday;

  static const paletteSchemes = ['A', 'B', 'C'];
  static const reminderLeadOptions = [5, 10, 15, 20, 30];

  TimetableSettings copyWith({
    String? scheduleName,
    String? termCode,
    DateTime? termStartDate,
    int? maxWeeks,
    int? nodesPerDay,
    double? periodHeight,
    double? cellRadius,
    bool? showSaturday,
    bool? showSunday,
    bool? showNonCurrentWeek,
    bool? showGridLines,
    bool? weekStartsOnMonday,
    bool? termStartFromJwxt,
    bool clearTermStart = false,
    bool? showLocation,
    bool? showTeacher,
    CellFontScale? fontScale,
    int? cellOpacity,
    String? paletteScheme,
    bool? showTomorrowOnHome,
    bool? reminderEnabled,
    int? reminderLeadMinutes,
    bool? showExams,
    int? examColor,
    CellTextColorMode? cellTextColor,
    int? homeMaxItems,
  }) => TimetableSettings(
    scheduleName: scheduleName ?? this.scheduleName,
    termCode: termCode ?? this.termCode,
    termStartDate: clearTermStart
        ? null
        : (termStartDate ?? this.termStartDate),
    maxWeeks: maxWeeks ?? this.maxWeeks,
    nodesPerDay: nodesPerDay ?? this.nodesPerDay,
    periodHeight: periodHeight ?? this.periodHeight,
    cellRadius: cellRadius ?? this.cellRadius,
    showSaturday: showSaturday ?? this.showSaturday,
    showSunday: showSunday ?? this.showSunday,
    showNonCurrentWeek: showNonCurrentWeek ?? this.showNonCurrentWeek,
    showGridLines: showGridLines ?? this.showGridLines,
    weekStartsOnMonday: weekStartsOnMonday ?? this.weekStartsOnMonday,
    termStartFromJwxt: clearTermStart
        ? false
        : (termStartFromJwxt ?? this.termStartFromJwxt),
    showLocation: showLocation ?? this.showLocation,
    showTeacher: showTeacher ?? this.showTeacher,
    fontScale: fontScale ?? this.fontScale,
    cellOpacity: cellOpacity ?? this.cellOpacity,
    paletteScheme: paletteScheme ?? this.paletteScheme,
    showTomorrowOnHome: showTomorrowOnHome ?? this.showTomorrowOnHome,
    reminderEnabled: reminderEnabled ?? this.reminderEnabled,
    reminderLeadMinutes: reminderLeadMinutes ?? this.reminderLeadMinutes,
    showExams: showExams ?? this.showExams,
    examColor: examColor ?? this.examColor,
    cellTextColor: cellTextColor ?? this.cellTextColor,
    homeMaxItems: homeMaxItems ?? this.homeMaxItems,
  );

  /// 用 [o] 的用户偏好（显示/外观/提醒/首页开关）覆盖本对象，学期字段不变。
  TimetableSettings withDisplayPrefsFrom(TimetableSettings o) => copyWith(
    periodHeight: o.periodHeight,
    cellRadius: o.cellRadius,
    showSaturday: o.showSaturday,
    showSunday: o.showSunday,
    showNonCurrentWeek: o.showNonCurrentWeek,
    showGridLines: o.showGridLines,
    weekStartsOnMonday: o.weekStartsOnMonday,
    showLocation: o.showLocation,
    showTeacher: o.showTeacher,
    fontScale: o.fontScale,
    cellOpacity: o.cellOpacity,
    paletteScheme: o.paletteScheme,
    showTomorrowOnHome: o.showTomorrowOnHome,
    reminderEnabled: o.reminderEnabled,
    reminderLeadMinutes: o.reminderLeadMinutes,
    showExams: o.showExams,
    examColor: o.examColor,
    cellTextColor: o.cellTextColor,
    homeMaxItems: o.homeMaxItems,
  );

  Map<String, dynamic> toJson() => {
    'scheduleName': scheduleName,
    'termCode': termCode,
    if (termStartDate != null) 'termStartDate': _dateKey(termStartDate!),
    'maxWeeks': maxWeeks,
    'nodesPerDay': nodesPerDay,
    'periodHeight': periodHeight,
    'cellRadius': cellRadius,
    'showSaturday': showSaturday,
    'showSunday': showSunday,
    'showNonCurrentWeek': showNonCurrentWeek,
    'showGridLines': showGridLines,
    'weekStartsOnMonday': weekStartsOnMonday,
    'termStartFromJwxt': termStartFromJwxt,
    'showLocation': showLocation,
    'showTeacher': showTeacher,
    'fontScale': fontScale.name,
    'cellOpacity': cellOpacity,
    'paletteScheme': paletteScheme,
    'showTomorrowOnHome': showTomorrowOnHome,
    'reminderEnabled': reminderEnabled,
    'reminderLeadMinutes': reminderLeadMinutes,
    'showExams': showExams,
    'examColor': examColor,
    'cellTextColor': cellTextColor.name,
    'homeMaxItems': homeMaxItems,
  };

  // ---- 宽松读取（只在内存纠正，不回写磁盘）----

  static bool _bool(Object? raw, bool fallback) => raw is bool ? raw : fallback;

  /// 不透明度：数字四舍五入取整后钳到 30–100；非数字/非有限值 → 100。
  static int sanitizeOpacity(Object? raw) {
    if (raw is! num || !raw.isFinite) return 100;
    return raw.round().clamp(30, 100);
  }

  /// 提前时间：吸附到 5/10/15/20/30 中最近的一档，距离相同取较大；
  /// 非数字/非有限值 → 15。
  static int sanitizeLeadMinutes(Object? raw) {
    if (raw is! num || !raw.isFinite) return 15;
    var best = reminderLeadOptions.first;
    for (final o in reminderLeadOptions) {
      if ((o - raw).abs() <= (best - raw).abs()) best = o;
    }
    return best;
  }

  /// 考试颜色：整数 ARGB 原样用（补满不透明）；其他 → 默认深红。
  static int parseExamColor(Object? raw) =>
      raw is int ? (raw | 0xFF000000) : kDefaultExamColor;

  /// 首页最多显示：1–4 整数；缺失 / 非整数 / 越界 → 默认 2（spec-next-1020 item 4）。
  static int sanitizeHomeMaxItems(Object? raw) {
    if (raw is! num || !raw.isFinite) return kDefaultHomeMaxItems;
    final v = raw.round();
    if (v < 1 || v > 4) return kDefaultHomeMaxItems;
    return v;
  }

  /// 文字颜色：'auto'/'white'/'black'；缺失或其他 → 自动（旧文件无此键）。
  static CellTextColorMode parseCellTextColor(Object? raw) {
    for (final v in CellTextColorMode.values) {
      if (raw == v.name) return v;
    }
    return CellTextColorMode.auto;
  }

  /// 文字大小：'small'/'standard'/'large'；其他 → 标准。
  static CellFontScale parseFontScale(Object? raw) {
    for (final v in CellFontScale.values) {
      if (raw == v.name) return v;
    }
    return CellFontScale.standard;
  }

  /// 配色方案：'A'/'B'/'C'；其他 → 'A'。
  static String parsePaletteScheme(Object? raw) =>
      raw is String && paletteSchemes.contains(raw) ? raw : 'A';

  /// 读取时把格子高度钳到 52..90；非数字/非有限值 → 64。只影响读，不回写。
  static double _parsePeriodHeight(Object? raw) {
    final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
    if (v == null || !v.isFinite) return 64;
    return v.clamp(52, 90).toDouble();
  }

  factory TimetableSettings.fromJson(Map<String, dynamic> json) =>
      TimetableSettings(
        scheduleName: '${json['scheduleName'] ?? '我的课表'}',
        termCode: '${json['termCode'] ?? ''}',
        termStartDate: _parseDate(json['termStartDate']?.toString()),
        maxWeeks: _asInt(json['maxWeeks']) ?? 30,
        nodesPerDay: _asInt(json['nodesPerDay']) ?? 11,
        periodHeight: _parsePeriodHeight(json['periodHeight']),
        cellRadius: (json['cellRadius'] as num?)?.toDouble() ?? 4,
        showSaturday: json['showSaturday'] != false,
        showSunday: json['showSunday'] != false,
        showNonCurrentWeek: json['showNonCurrentWeek'] == true,
        showGridLines: json['showGridLines'] != false,
        weekStartsOnMonday: json['weekStartsOnMonday'] != false,
        termStartFromJwxt: json['termStartFromJwxt'] == true,
        showLocation: _bool(json['showLocation'], true),
        showTeacher: _bool(json['showTeacher'], false),
        fontScale: parseFontScale(json['fontScale']),
        cellOpacity: sanitizeOpacity(json['cellOpacity']),
        paletteScheme: parsePaletteScheme(json['paletteScheme']),
        showTomorrowOnHome: _bool(json['showTomorrowOnHome'], true),
        reminderEnabled: _bool(json['reminderEnabled'], false),
        reminderLeadMinutes: sanitizeLeadMinutes(json['reminderLeadMinutes']),
        showExams: _bool(json['showExams'], true),
        examColor: parseExamColor(json['examColor']),
        cellTextColor: parseCellTextColor(json['cellTextColor']),
        homeMaxItems: sanitizeHomeMaxItems(json['homeMaxItems']),
      );
}

/// 格子文字大小三档（§13.3）：系数乘以系统字号，最小 10sp（UI 负责）。
/// 课程格 / 考试格文字颜色（item 14）。
enum CellTextColorMode { auto, white, black }

enum CellFontScale {
  small(0.9),
  standard(1.0),
  large(1.15);

  const CellFontScale(this.factor);
  final double factor;
}

/// 本地课表快照。
class TimetableSnapshot {
  const TimetableSnapshot({
    this.courses = const [],
    this.periods = const [],
    this.settings = const TimetableSettings(),
    this.syncedAt,
    this.lastError,
  });

  final List<Course> courses;
  final List<PeriodTime> periods;
  final TimetableSettings settings;
  final DateTime? syncedAt;
  final String? lastError;

  bool get isEmpty => courses.where((c) => !c.hidden).isEmpty;

  TimetableSnapshot copyWith({
    List<Course>? courses,
    List<PeriodTime>? periods,
    TimetableSettings? settings,
    DateTime? syncedAt,
    String? lastError,
    bool clearError = false,
  }) => TimetableSnapshot(
    courses: courses ?? this.courses,
    periods: periods ?? this.periods,
    settings: settings ?? this.settings,
    syncedAt: syncedAt ?? this.syncedAt,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'courses': [for (final c in courses) c.toJson()],
    'periods': [for (final p in periods) p.toJson()],
    'settings': settings.toJson(),
    if (syncedAt != null) 'syncedAt': syncedAt!.toIso8601String(),
    if (lastError != null) 'lastError': lastError,
  };

  factory TimetableSnapshot.fromJson(Map<String, dynamic> json) =>
      TimetableSnapshot(
        courses: [
          for (final item in (json['courses'] as List? ?? const []))
            if (item is Map<String, dynamic>) Course.fromJson(item),
        ],
        periods: [
          for (final item in (json['periods'] as List? ?? const []))
            if (item is Map<String, dynamic>) PeriodTime.fromJson(item),
        ],
        settings: json['settings'] is Map<String, dynamic>
            ? TimetableSettings.fromJson(
                json['settings'] as Map<String, dynamic>,
              )
            : const TimetableSettings(),
        syncedAt: DateTime.tryParse('${json['syncedAt'] ?? ''}'),
        lastError: json['lastError']?.toString(),
      );
}

/// 网格上可渲染的一格（已按周过滤、合并冲突计数）。
class GridCell {
  const GridCell({
    required this.course,
    required this.slot,
    required this.conflictCount,
    required this.activeThisWeek,
    this.date,
    this.dateEdit,
    this.swappedFrom,
  });

  final Course course;
  final CourseSlot slot;
  final int conflictCount;
  final bool activeThisWeek;

  /// 这一格所在列的日期（[TimetableController.cellsForDay] 填；手工构造可为 null，
  /// 此时编辑 / 拖动只能按「所有周」处理）。
  final DateTime? date;

  /// 套用在这一格上的单日修改（第 1 条；格子右上角圆点、详情「已修改·恢复」）。
  final CourseDateEdit? dateEdit;

  /// 整天调课换过来的课：原本在这一天上课的日期（第 8 条）；否则 null。
  final DateTime? swappedFrom;
}

/// 首页「今日课表」一行。
enum TodayCourseStatus { upcoming, ongoing, done }

class TodayCourseItem {
  const TodayCourseItem({
    required this.course,
    required this.slot,
    required this.status,
    this.minutesUntilStart,
    this.progress,
  });

  final Course course;
  final CourseSlot slot;
  final TodayCourseStatus status;
  final int? minutesUntilStart;
  final double? progress;
}

/// 从教务 `cxxszhxqkb.rows` / `xswpkc.rows` 解析课程。
///
/// 字段映射（抓包确认）：
/// - KCM 课名 · KCH 课号 · **KXH 课序号（网格 `[02]`，不用 JXBID）**
/// - JXBID 教学班 ID（过长，仅去重指纹）
/// - SKZC 周次位串 · SKXQ 星期 · KSJC/JSJC 起止节次
/// - JASMC 教室（常为 **null** → 空串；UI 无地点时不显示 `@`）
/// - SKJS 教师 · XF 学分
/// - SKBJ 上课班级名单（过长，不进网格/详情主列表）
class TimetableParser {
  TimetableParser._();

  static ParseResult parseKbRows(
    List<dynamic> rows, {
    int maxWeeks = 30,
    int maxNode = 20,
  }) {
    final coursesByKey = <String, Course>{};
    final skips = <ParseSkip>[];
    final seenFingerprints = <String>{};

    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final name = _text(row, ['KCM', 'KCMC', 'XSKCM']);
      final code = _text(row, ['KCH', 'XSKCH']);
      if (name.isEmpty) {
        skips.add(const ParseSkip(reason: 'empty_name'));
        continue;
      }

      final dayRaw = _asInt(row['SKXQ']);
      final startRaw = _asInt(row['KSJC']);
      final endRaw = _asInt(row['JSJC']);
      // SKZC 可能为 null（未排课行）
      final weeksRaw = row['SKZC'] == null ? '' : row['SKZC'].toString();

      // SKZC：01 位串 → 网格课；null / 中文（如「2-17周」）→ 「其他课程」，不丢弃
      final weeksBit = _normalizeWeeks(weeksRaw, maxWeeks);
      final noScheduleBits = weeksBit == null; // null、空、或非 01 串

      final noFixed =
          noScheduleBits ||
          ((dayRaw == null || dayRaw == 0) &&
              (startRaw == null || startRaw == 0) &&
              (endRaw == null || endRaw == 0));

      var day = dayRaw ?? 0;
      var start = startRaw ?? 0;
      var end = endRaw ?? 0;
      var weeks = '';
      var fixed = false;
      // 中文周次描述留给 weeksLabel（下方还会拼 ZCMC）
      var skzcLabel = noScheduleBits && weeksRaw.isNotEmpty ? weeksRaw : '';

      if (!noFixed) {
        if (day < 1 || day > 7) {
          skips.add(ParseSkip(reason: 'bad_day', courseCode: code));
          continue;
        }
        if (start < 1 || start > maxNode) {
          skips.add(ParseSkip(reason: 'bad_node', courseCode: code));
          continue;
        }
        if (end < start) {
          skips.add(ParseSkip(reason: 'bad_node', courseCode: code));
          continue;
        }
        if (end > maxNode) {
          end = maxNode;
          fixed = true;
          skips.add(
            ParseSkip(reason: 'bad_node', courseCode: code, fixed: true),
          );
        }
        weeks = weeksBit.weeks;
        if (weeksBit.fixed) {
          fixed = true;
          skips.add(
            ParseSkip(reason: 'weeks_trimmed', courseCode: code, fixed: true),
          );
        }
      } else {
        // 「其他课程」：无网格定位
        day = 0;
        start = 0;
        end = 0;
        weeks = '';
      }

      // 展示用课序号：KXH（如 "02"）。不用 JXBID（超长教学班 ID）。
      final classId = _text(row, ['KXH']);
      final jxbId = _text(row, ['JXBID', 'JXBH']); // 仅指纹去重
      final teacher = _text(row, ['SKJS', 'JSXM']);
      // JASMC 常为 JSON null → _text 得到 ''，网格不渲染 @
      final location = _text(row, ['JASMC', 'JASMC_DISPLAY']);
      final weeksLabel = () {
        final zcmc = _text(row, ['ZCMC']);
        if (zcmc.isNotEmpty) return zcmc;
        return skzcLabel;
      }();
      final credit = _asDouble(row['XF']);
      // SKBJ 故意不读入模型（过长，不进网格/详情）
      final fingerprint =
          '$code|$classId|$jxbId|$day|$start|$end|$weeks|$teacher|$location';
      if (!seenFingerprints.add(fingerprint)) {
        skips.add(ParseSkip(reason: 'duplicate', courseCode: code));
        continue;
      }

      // 网格课：同课号+课序号合并多时段。
      // 「其他课程」（无位串/中文周次）：独立成课，不并入网格课。
      final String key;
      if (noFixed) {
        key = 'other:${code.isNotEmpty ? code : name}|$classId|$jxbId';
      } else if (code.isNotEmpty) {
        key = classId.isNotEmpty ? '$code|$classId' : code;
      } else {
        key = 'name:$name';
      }
      final slot = CourseSlot(
        day: day,
        startNode: start,
        endNode: end,
        weeks: weeks,
        weeksLabel: weeksLabel,
        teacher: teacher,
        location: location,
      );
      final existing = coursesByKey[key];
      if (existing == null) {
        coursesByKey[key] = Course(
          id: key,
          name: name,
          code: code,
          classId: classId,
          credit: credit,
          source: CourseSource.jwxt,
          slots: [slot],
        );
      } else {
        coursesByKey[key] = Course(
          id: existing.id,
          name: existing.name,
          code: existing.code,
          classId: existing.classId.isEmpty ? classId : existing.classId,
          credit: existing.credit ?? credit,
          colorIndex: existing.colorIndex,
          source: existing.source,
          slots: [...existing.slots, slot],
          hidden: existing.hidden,
        );
      }
      if (fixed) {
        // already recorded in skips
      }
    }

    return ParseResult(courses: coursesByKey.values.toList(), skips: skips);
  }

  /// 解析教务节次 `jc.rows` / `cxjcs.rows`。
  ///
  /// [onlyEnabled] 默认 true：跳过 `SFSY==0`（抓包第12节 SFSY=0，默认不展示）。
  static List<PeriodTime> parsePeriods(
    List<dynamic> rows, {
    bool onlyEnabled = true,
  }) {
    final list = <PeriodTime>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      if (onlyEnabled) {
        final sfsy = row['SFSY'];
        if (sfsy == 0 || sfsy == '0') continue;
      }
      final node = _asInt(row['DM'] ?? row['n'] ?? row['node']);
      if (node == null || node < 1) continue;
      final start = _hhmm(row['KSSJ'] ?? row['start']);
      final end = _hhmm(row['JSSJ'] ?? row['end']);
      if (start == null || end == null) continue;
      list.add(PeriodTime(node: node, start: start, end: end));
    }
    list.sort((a, b) => a.node.compareTo(b.node));
    return list;
  }

  /// 由 dqzc 行推算第 1 周周一（开学日）。
  ///
  /// `termStart = date(RQ) - (XQJ - 1) days - (ZC - 1) weeks`
  /// 样例：RQ=2026-10-11、XQJ=7（周日）、ZC=6 → 2026-08-31。
  static DateTime? computeTermStartDate({
    required DateTime refDate,
    required int weekday, // XQJ 1=周一 … 7=周日
    required int week, // ZC
  }) {
    if (weekday < 1 || weekday > 7 || week < 1) return null;
    final daysBack = (weekday - 1) + (week - 1) * 7;
    final d = DateTime(
      refDate.year,
      refDate.month,
      refDate.day,
    ).subtract(Duration(days: daysBack));
    return d;
  }

  /// 从课表行 SKZC 位串估总周数（取最长有效位串长度）。
  static int maxWeeksFromSkzc(List<dynamic> rows, {int fallback = 30}) {
    var maxLen = 0;
    for (final raw in rows) {
      if (raw is! Map) continue;
      final skzc = raw['SKZC'];
      if (skzc == null) continue;
      final s = skzc.toString();
      if (!RegExp(r'^[01]+$').hasMatch(s)) continue;
      if (s.length > maxLen) maxLen = s.length;
    }
    return maxLen > 0 ? maxLen : fallback;
  }

  /// 从周课表行的 KSJC/JSJC + KSSJ/JSSJ 推导作息（MVP，无需单独教历接口）。
  static List<PeriodTime> parsePeriodsFromKbRows(List<dynamic> rows) {
    final starts = <int, String>{};
    final ends = <int, String>{};
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final ks = _asInt(row['KSJC']);
      final js = _asInt(row['JSJC']);
      final kssj = _hhmm(row['KSSJ']);
      final jssj = _hhmm(row['JSSJ']);
      if (ks != null && kssj != null) starts[ks] = kssj;
      if (js != null && jssj != null) ends[js] = jssj;
    }
    final nodes = {...starts.keys, ...ends.keys}.toList()..sort();
    return [
      for (final n in nodes)
        if (starts[n] != null && ends[n] != null)
          PeriodTime(node: n, start: starts[n]!, end: ends[n]!),
    ];
  }

  /// 应用 dqxnxq 学期代码（抓包仅有 DM/XNDM/XQQM，**无**开学日字段）。
  static TimetableSettings _applyTermMeta(
    TimetableSettings settings,
    Map<dynamic, dynamic> term,
  ) {
    final termRows = term['rows'] as List? ?? const [];
    Map<dynamic, dynamic>? row;
    if (termRows.isNotEmpty && termRows.first is Map) {
      row = termRows.first as Map;
    } else if (term['DM'] != null || term['XNXQDM'] != null) {
      row = term;
    }
    if (row == null) return settings;

    final code =
        (row['DM'] ?? row['XNXQDM'] ?? row['code'])?.toString().trim() ?? '';
    // 开学日由 dqzc 的 RQ/XQJ/ZC 推算，不在此读取。
    return settings.copyWith(termCode: code.isNotEmpty ? code : null);
  }

  /// 应用 dqzc 行：推算开学日（第1周周一）。
  static TimetableSettings _applyDqzcMeta(
    TimetableSettings settings,
    Map<dynamic, dynamic> dqzc,
  ) {
    final zcRows = dqzc['rows'] as List? ?? const [];
    if (zcRows.isEmpty || zcRows.first is! Map) return settings;
    final row = zcRows.first as Map;
    final zc = _asInt(row['ZC']);
    final xqj = _asInt(row['XQJ']);
    final rq = _parseDate(row['RQ']?.toString().split(' ').first);
    if (zc == null || xqj == null || rq == null) return settings;
    final start = computeTermStartDate(refDate: rq, weekday: xqj, week: zc);
    if (start == null) return settings;
    return settings.copyWith(termStartDate: start, termStartFromJwxt: true);
  }

  /// 解析本地/debug JSON：既支持教务原始结构，也支持 [TimetableSnapshot]。
  static TimetableSnapshot parseImportJson(
    Map<String, dynamic> json, {
    TimetableSettings? baseSettings,
  }) {
    if (json.containsKey('courses') && json['courses'] is List) {
      return TimetableSnapshot.fromJson(json);
    }

    final datas = json['datas'];
    if (datas is Map<String, dynamic>) {
      final kb = datas['cxxszhxqkb'];
      final weekRows = kb is Map ? (kb['rows'] as List? ?? const []) : const [];
      // 未排课（抓包 xswpkc.do）
      final wp = datas['xswpkc'];
      final unschedRows = wp is Map
          ? (wp['rows'] as List? ?? const [])
          : const [];
      final mergedRows = [...weekRows, ...unschedRows];
      final parsed = parseKbRows(
        mergedRows,
        maxWeeks: (baseSettings ?? const TimetableSettings()).maxWeeks,
      );
      // 节次：优先 cxjcs/jc；否则从课表行 KSSJ/JSSJ 推导（MVP 不依赖单独教历）
      var periods = const <PeriodTime>[];
      final jcs = datas['cxjcs'] ?? datas['jc'];
      if (jcs is Map) {
        periods = parsePeriods(jcs['rows'] as List? ?? const []);
      }
      if (periods.isEmpty) {
        periods = parsePeriodsFromKbRows(weekRows);
      }
      var settings = baseSettings ?? const TimetableSettings();
      // 学期代码：dqxnxq（仅 DM/XNDM/XQQM，无开学日）
      final term = datas['dqxnxq'] ?? datas['dqxnxq'];
      if (term is Map) {
        settings = _applyTermMeta(settings, term);
      }
      // 开学日：由 dqzc RQ/XQJ/ZC 推算
      final dqzc = datas['dqzc'];
      if (dqzc is Map) {
        settings = _applyDqzcMeta(settings, dqzc);
      }
      // 总周：配置 maxWeeks 与最长 SKZC 位串取较大值（无单独教历）
      final fromSkzc = maxWeeksFromSkzc(weekRows, fallback: settings.maxWeeks);
      if (fromSkzc > settings.maxWeeks) {
        settings = settings.copyWith(maxWeeks: fromSkzc);
      }
      // 若刚抬高了 maxWeeks，用新长度重解析周次位串
      final reparsed =
          fromSkzc > (baseSettings ?? const TimetableSettings()).maxWeeks
          ? parseKbRows(mergedRows, maxWeeks: settings.maxWeeks)
          : parsed;
      return TimetableSnapshot(
        courses: reparsed.courses,
        periods: periods,
        settings: settings,
        syncedAt: DateTime.now(),
      );
    }

    // 配置草案：含 timetables.nodes
    if (json['timetables'] is List) {
      final tables = json['timetables'] as List;
      final periods = <PeriodTime>[];
      if (tables.isNotEmpty && tables.first is Map) {
        final nodes = (tables.first as Map)['nodes'] as List? ?? const [];
        for (final n in nodes) {
          if (n is! Map) continue;
          final node = _asInt(n['n']);
          final start = n['start']?.toString();
          final end = n['end']?.toString();
          if (node == null || start == null || end == null) continue;
          periods.add(PeriodTime(node: node, start: start, end: end));
        }
      }
      var settings = baseSettings ?? const TimetableSettings();
      final defaults = json['defaults'];
      if (defaults is Map) {
        settings = settings.copyWith(
          nodesPerDay: _asInt(defaults['nodesPerDay']) ?? settings.nodesPerDay,
          maxWeeks: _asInt(defaults['maxWeeks']) ?? settings.maxWeeks,
          showSaturday: defaults['showWeekend'] != false,
          showSunday: defaults['showWeekend'] != false,
          showNonCurrentWeek: defaults['showNonCurrentWeek'] == true,
        );
      }
      final terms = json['terms'];
      if (terms is List && terms.isNotEmpty && terms.first is Map) {
        final t = terms.first as Map;
        settings = settings.copyWith(
          termCode: t['code']?.toString() ?? settings.termCode,
          termStartDate:
              _parseDate(t['startDate']?.toString()) ?? settings.termStartDate,
          maxWeeks: _asInt(t['weeks']) ?? settings.maxWeeks,
        );
      }
      return TimetableSnapshot(periods: periods, settings: settings);
    }

    throw const FormatException('无法识别的课表 JSON 结构');
  }
}

class ParseResult {
  const ParseResult({required this.courses, required this.skips});
  final List<Course> courses;
  final List<ParseSkip> skips;
}

class ParseSkip {
  const ParseSkip({
    required this.reason,
    this.courseCode = '',
    this.fixed = false,
  });
  final String reason;
  final String courseCode;
  final bool fixed;
}

class _WeeksNorm {
  const _WeeksNorm(this.weeks, {this.fixed = false});
  final String weeks;
  final bool fixed;
}

/// 将 SKZC 规范到 [maxWeeks] 长度：过长截断、过短右侧补 0。
/// 非 `01` 位串（含中文「2-17周」、空）返回 null，由调用方归入「其他课程」。
_WeeksNorm? _normalizeWeeks(String raw, int maxWeeks) {
  if (raw.isEmpty) return null;
  if (!RegExp(r'^[01]+$').hasMatch(raw)) return null;
  if (maxWeeks < 1) maxWeeks = 30;
  if (raw.length > maxWeeks) {
    return _WeeksNorm(raw.substring(0, maxWeeks), fixed: true);
  }
  if (raw.length < maxWeeks) {
    return _WeeksNorm(raw.padRight(maxWeeks, '0'));
  }
  return _WeeksNorm(raw);
}

/// 课程色板大小（[Course.colorIndex] 取值 0..15）。
const int kCoursePaletteSize = 16;

/// 课名归一化（仅用于配色哈希）：去首尾空白，半角括号转全角。
String normalizeCourseName(String name) =>
    name.trim().replaceAll('(', '（').replaceAll(')', '）');

/// 课名 → 默认色号：FNV-1a 32 位哈希（UTF-8 字节）对 16 取模。
///
/// 不用 String.hashCode（不保证跨版本/平台稳定）；教务课与手动课同名同色。
/// 先经 [normalizeCourseName]，「学术英语(1)」与「 学术英语（1） 」同色。
int courseColorIndexForName(String name) {
  var hash = 0x811c9dc5;
  for (final b in utf8.encode(normalizeCourseName(name))) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % kCoursePaletteSize;
}

int? _asColorIndex(Object? v) {
  final i = _asInt(v);
  return i != null && i >= 0 && i < kCoursePaletteSize ? i : null;
}

String _text(Map<String, dynamic> row, List<String> keys) {
  for (final key in keys) {
    final value = row[key];
    if (value != null && value.toString().trim().isNotEmpty) {
      return value.toString().trim();
    }
  }
  return '';
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim());
}

double? _asDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim());
}

String? _hhmm(Object? value) {
  if (value == null) return null;
  final s = value.toString().trim();
  if (s.contains(':')) return s;
  if (RegExp(r'^\d{3,4}$').hasMatch(s)) {
    final padded = s.padLeft(4, '0');
    return '${padded.substring(0, 2)}:${padded.substring(2)}';
  }
  return null;
}

DateTime? _parseDate(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 内置学期配置：教务 dqzc 不可用且无可信缓存时的开学日（第 1 周周一）。
const Map<String, String> kBuiltinTermStartDates = {
  '2026-2027-1': '2026-08-31',
};

/// 开学日来源。
enum TermStartSource { jwxt, cache, builtin, none }

/// 开学日决议结果；[weekPending] 为 true 时周次未知（按第 1 周展示）。
class TermStartResolution {
  const TermStartResolution(this.start, this.source);
  final DateTime? start;
  final TermStartSource source;
  bool get weekPending => start == null;
}

/// 开学日优先级：本次 dqzc 推算 > 缓存（仅限 dqzc 来源）> 内置配置 > 待同步。
TermStartResolution resolveTermStart({
  required String termCode,
  DateTime? fromDqzc,
  TimetableSettings? cached,
  Map<String, String> builtin = kBuiltinTermStartDates,
}) {
  if (fromDqzc != null) {
    return TermStartResolution(_dayOnly(fromDqzc), TermStartSource.jwxt);
  }
  final c = cached;
  if (c != null &&
      c.termStartFromJwxt &&
      c.termStartDate != null &&
      (c.termCode.isEmpty || c.termCode == termCode)) {
    return TermStartResolution(
      _dayOnly(c.termStartDate!),
      TermStartSource.cache,
    );
  }
  final b = _parseDate(builtin[termCode]);
  if (b != null) return TermStartResolution(b, TermStartSource.builtin);
  return const TermStartResolution(null, TermStartSource.none);
}

/// 某日期所在周的周一（周日属于其前一个周一开始的那周）。
DateTime mondayOfWeek(DateTime d) {
  final date = _dayOnly(d);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}

/// [today] 相对 [termStart] 的教学周次（未 clamp，可能 <1）。
int teachingWeekOf(DateTime termStart, DateTime today) {
  DateTime utc(DateTime d) => DateTime.utc(d.year, d.month, d.day);
  final days = utc(mondayOfWeek(today))
      .difference(utc(mondayOfWeek(termStart)))
      .inDays;
  return (days / 7).floor() + 1;
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
