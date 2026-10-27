// 单日修改（第 1 条）与整天调课（第 8 条）的数据模型。纯 Dart，不依赖 Flutter。
//
// - [CourseDateEdit]：某门课在某一天的一次课（按显示位置识别）只改这一天：改字段、
//   改时间（拖动「只改这一天」）或删除。存 `course_edits.json` 的 `dateEdits`。
// - [DaySwap]：两天的课程互换（考试 / 日程不动），存 `day_swaps.json`。
//
// 展示优先级：单日修改 > 整天调课 > 拖动调课（[SlotOverride]）> 教务原始。

/// 编辑 / 拖动保存时的应用范围：只改这一天 / 所有周。默认 [thisDay]。
enum EditScope { thisDay, allWeeks }

/// 单日修改的种类。
enum DateEditKind { edit, delete }

/// 修改 / 删除的应用范围（course-edits-api-1020）。
/// 旧记录无 [scope] 时按 [oneDay]（靠 [date] 匹配）。
enum DateEditScope {
  /// 仅某一天这一节（拖动「只改这一天」、删除菜单第 1 档）。
  oneDay,

  /// 勾选的若干周（编辑页「应用周数」；须带非空 [CourseDateEdit.weeks]）。
  weeks,

  /// 全部同星期 + 同老师同地点（删除菜单第 2 档）；老师或地点为空则同星期同名课。
  weekdayMatch,
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// 只看年月日是否同一天。
bool isSameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 日期 → `yyyy-MM-dd`。
String dateKeyOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// `yyyy-MM-dd` → 日期；格式不对或日期不存在（如 2-30）→ null。
DateTime? parseDateKey(Object? raw) {
  if (raw is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw.trim());
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final date = DateTime(y, mo, d);
  if (date.year != y || date.month != mo || date.day != d) return null;
  return date;
}

/// 某门课某一天的一次课的单日修改记录。
///
/// 识别键（[scope]=[DateEditScope.oneDay]）：[courseId] + [date]（修改时这次课显示
/// 所在的日期，已套用整天调课）+ [origStart]/[origEnd]（修改前的显示节次）。
/// 展示时这一天对不上（课已不在这天 / 节次变了）就忽略这条记录，不删（同步也不删）。
///
/// [scope]=[DateEditScope.weeks]：按 [weeks] 周号 + 与 [date] 相同的星期 + 节次匹配。
/// [scope]=[DateEditScope.weekdayMatch]：按 [weekday] + 老师/地点（或同名课）匹配删除。
///
/// 字段为 null 表示未改。[toDate]/[toStart]/[toEnd] 非空表示这次课挪到别的
/// 日期 / 节次（拖动「只改这一天」或表单改了星期 / 节次）。
class CourseDateEdit {
  const CourseDateEdit({
    required this.id,
    required this.courseId,
    required this.date,
    required this.origStart,
    required this.origEnd,
    this.kind = DateEditKind.edit,
    this.scope = DateEditScope.oneDay,
    this.weeks = const [],
    this.weekday,
    this.matchEmptyTeacherLocation = false,
    this.name,
    this.teacher,
    this.location,
    this.note,
    this.color,
    this.toDate,
    this.toStart,
    this.toEnd,
    this.createdAt = '',
    this.extra = const {},
  });

  final String id;
  final String courseId;

  /// 只取年月日。oneDay 的匹配日；weeks 时作星期模板；weekdayMatch 可作参考日。
  final DateTime date;
  final int origStart;
  final int origEnd;
  final DateEditKind kind;
  final DateEditScope scope;

  /// 去重升序的周号；仅 [scope] == [DateEditScope.weeks] 时非空并生效。
  final List<int> weeks;

  /// 1–7（周一=1）；[scope] == [DateEditScope.weekdayMatch] 时必填。
  final int? weekday;

  /// [weekdayMatch]：老师或地点为空时为 true，匹配放宽为同星期 + 同名课。
  final bool matchEmptyTeacherLocation;

  final String? name;
  final String? teacher;
  final String? location;
  final String? note;

  /// 这次课的自选原始 ARGB；null 时继承课程全局颜色。
  final int? color;
  final DateTime? toDate;
  final int? toStart;
  final int? toEnd;
  final String createdAt;

  /// 读到的未知键，写回时原样保留。
  final Map<String, dynamic> extra;

  bool get isDelete => kind == DateEditKind.delete;

  bool get isWeeksScoped => scope == DateEditScope.weeks && weeks.isNotEmpty;

  bool get isWeekdayMatch => scope == DateEditScope.weekdayMatch;

  /// 这次课最终显示的日期（仅 oneDay / weeks 挪格时有意义）。
  DateTime get targetDate => toDate ?? date;

  /// 是否把这次课挪到了别的日期。
  bool get movesToOtherDate => toDate != null && !isSameDate(toDate!, date);

  /// 是否改了节次或日期。
  bool get movesTime =>
      movesToOtherDate ||
      (toStart != null && toStart != origStart) ||
      (toEnd != null && toEnd != origEnd);

  bool get hasFieldEdits =>
      name != null ||
      teacher != null ||
      location != null ||
      note != null ||
      color != null;

  /// 编辑记录什么都没改（应删除）。weekdayMatch 删除不算空。
  bool get isEmpty =>
      !isDelete && !hasFieldEdits && !movesTime && !isWeekdayMatch;

  /// oneDay：按课程 + 日期 + 节次。
  bool matches(String courseId, DateTime date, int start, int end) =>
      this.courseId == courseId &&
      isSameDate(this.date, date) &&
      origStart == start &&
      origEnd == end;

  /// weeks：周号在列表内，且与模板日同星期、同节次。
  bool matchesWeek(
    String courseId,
    int week,
    int weekday,
    int start,
    int end,
  ) =>
      isWeeksScoped &&
      this.courseId == courseId &&
      weeks.contains(week) &&
      date.weekday == weekday &&
      origStart == start &&
      origEnd == end;

  /// weekdayMatch：同课程、同星期，老师地点匹配；空则同星期同名课。
  bool matchesWeekdaySlot({
    required String courseId,
    required String courseName,
    required int weekday,
    required String teacher,
    required String location,
  }) {
    if (!isWeekdayMatch || this.weekday != weekday) return false;
    if (matchEmptyTeacherLocation) {
      // 放宽：同星期 + 同名（name 写入时为课名快照）。
      final snap = name ?? '';
      return snap.isNotEmpty ? snap == courseName : this.courseId == courseId;
    }
    if (this.courseId != courseId) return false;
    return (this.teacher ?? '') == teacher && (this.location ?? '') == location;
  }

  CourseDateEdit copyWith({
    DateEditKind? kind,
    DateEditScope? scope,
    List<int>? weeks,
    int? weekday,
    bool? matchEmptyTeacherLocation,
    String? name,
    String? teacher,
    String? location,
    String? note,
    int? color,
    bool clearColor = false,
    DateTime? toDate,
    int? toStart,
    int? toEnd,
    bool clearMove = false,
    bool clearName = false,
    bool clearTeacher = false,
    bool clearLocation = false,
    bool clearNote = false,
    bool clearWeeks = false,
    String? createdAt,
  }) => CourseDateEdit(
    id: id,
    courseId: courseId,
    date: date,
    origStart: origStart,
    origEnd: origEnd,
    kind: kind ?? this.kind,
    scope: scope ?? this.scope,
    weeks: clearWeeks ? const [] : (weeks ?? this.weeks),
    weekday: weekday ?? this.weekday,
    matchEmptyTeacherLocation:
        matchEmptyTeacherLocation ?? this.matchEmptyTeacherLocation,
    name: clearName ? null : (name ?? this.name),
    teacher: clearTeacher ? null : (teacher ?? this.teacher),
    location: clearLocation ? null : (location ?? this.location),
    note: clearNote ? null : (note ?? this.note),
    color: clearColor ? null : (color ?? this.color),
    toDate: clearMove ? null : (toDate ?? this.toDate),
    toStart: clearMove ? null : (toStart ?? this.toStart),
    toEnd: clearMove ? null : (toEnd ?? this.toEnd),
    createdAt: createdAt ?? this.createdAt,
    extra: extra,
  );

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'courseId': courseId,
    'date': dateKeyOf(date),
    'origStart': origStart,
    'origEnd': origEnd,
    'kind': kind.name,
    if (scope != DateEditScope.oneDay) 'scope': scope.name,
    if (weeks.isNotEmpty) 'weeks': weeks,
    if (weekday != null) 'weekday': weekday,
    if (matchEmptyTeacherLocation) 'matchEmptyTeacherLocation': true,
    if (name != null) 'name': name,
    if (teacher != null) 'teacher': teacher,
    if (location != null) 'location': location,
    if (note != null) 'note': note,
    if (color != null) 'color': color,
    if (toDate != null) 'toDate': dateKeyOf(toDate!),
    if (toStart != null) 'toStart': toStart,
    if (toEnd != null) 'toEnd': toEnd,
    'createdAt': createdAt,
  };

  static const _known = {
    'id',
    'courseId',
    'date',
    'origStart',
    'origEnd',
    'kind',
    'scope',
    'weeks',
    'weekday',
    'matchEmptyTeacherLocation',
    'name',
    'teacher',
    'location',
    'note',
    'color',
    'toDate',
    'toStart',
    'toEnd',
    'createdAt',
  };

  static List<int> _parseWeeks(Object? raw) {
    if (raw is! List) return const [];
    final out = <int>{};
    for (final e in raw) {
      if (e is int && e >= 1) out.add(e);
    }
    final list = out.toList()..sort();
    return list;
  }

  static DateEditScope? _parseScope(Object? raw, List<int> weeks) {
    return switch (raw) {
      'oneDay' || null => DateEditScope.oneDay,
      'weeks' => DateEditScope.weeks,
      'weekdayMatch' => DateEditScope.weekdayMatch,
      // 旧数据无 scope：有非空 weeks 则视为 weeks，否则 oneDay。
      _ => null,
    };
  }

  /// 宽松解析；关键字段缺失 / 类型不对 → null（调用方跳过）。
  static CourseDateEdit? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    int? i(String k) => m[k] is int ? m[k] as int : null;
    String? s(String k) => m[k] is String ? m[k] as String : null;
    final id = s('id'), courseId = s('courseId');
    final date = parseDateKey(m['date']);
    final os = i('origStart'), oe = i('origEnd');
    if (id == null || id.isEmpty || courseId == null || courseId.isEmpty) {
      return null;
    }
    final weeks = _parseWeeks(m['weeks']);
    var scope = _parseScope(m['scope'], weeks);
    if (scope == null) return null;
    // 旧文件无 scope 但有 weeks → weeks；weekdayMatch 可不要求 orig 节次成对。
    if (m['scope'] == null && weeks.isNotEmpty) scope = DateEditScope.weeks;
    final wd = i('weekday');
    if (scope == DateEditScope.weekdayMatch) {
      if (wd == null || wd < 1 || wd > 7) return null;
      // weekdayMatch 删除：date / orig 可缺省时用占位（兼容）；有则校验。
      final d = date ?? DateTime(1970, 1, 1);
      final start = os ?? 1;
      final end = oe ?? start;
      final kind = switch (m['kind']) {
        'delete' => DateEditKind.delete,
        'edit' || null => DateEditKind.edit,
        _ => null,
      };
      if (kind == null) return null;
      return CourseDateEdit(
        id: id,
        courseId: courseId,
        date: d,
        origStart: start,
        origEnd: end < start ? start : end,
        kind: kind,
        scope: DateEditScope.weekdayMatch,
        weekday: wd,
        matchEmptyTeacherLocation: m['matchEmptyTeacherLocation'] == true,
        name: s('name'),
        teacher: s('teacher'),
        location: s('location'),
        note: s('note'),
        createdAt: s('createdAt') ?? '',
        extra: {
          for (final e in m.entries)
            if (!_known.contains(e.key)) e.key: e.value,
        },
      );
    }
    if (date == null || os == null || oe == null || os < 1 || oe < os) {
      return null;
    }
    if (scope == DateEditScope.weeks && weeks.isEmpty) {
      // 坏的 weeks scope：当 oneDay 读，避免整条丢弃。
      scope = DateEditScope.oneDay;
    }
    final kind = switch (m['kind']) {
      'delete' => DateEditKind.delete,
      'edit' || null => DateEditKind.edit,
      _ => null,
    };
    if (kind == null) return null;
    var ts = i('toStart'), te = i('toEnd');
    // 节次只成对生效；坏值整组丢掉（按没挪处理）。
    if (ts == null || te == null || ts < 1 || te < ts) ts = te = null;
    return CourseDateEdit(
      id: id,
      courseId: courseId,
      date: date,
      origStart: os,
      origEnd: oe,
      kind: kind,
      scope: scope,
      weeks: scope == DateEditScope.weeks ? weeks : const [],
      weekday: wd,
      matchEmptyTeacherLocation: m['matchEmptyTeacherLocation'] == true,
      name: s('name'),
      teacher: s('teacher'),
      location: s('location'),
      note: s('note'),
      color: i('color') == null ? null : i('color')! | 0xFF000000,
      toDate: parseDateKey(m['toDate']),
      toStart: ts,
      toEnd: te,
      createdAt: s('createdAt') ?? '',
      extra: {
        for (final e in m.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }
}

/// 整天调课：[dateA] 与 [dateB] 两天的课程互换（考试 / 日程留在原日期）。
class DaySwap {
  const DaySwap({
    required this.id,
    required this.dateA,
    required this.dateB,
    this.createdAt = '',
  });

  final String id;
  final DateTime dateA;
  final DateTime dateB;
  final String createdAt;

  bool involves(DateTime d) => isSameDate(dateA, d) || isSameDate(dateB, d);

  /// [d] 的对调日期；不涉及 [d] 返回 null。
  DateTime? partnerOf(DateTime d) {
    if (isSameDate(dateA, d)) return _day(dateB);
    if (isSameDate(dateB, d)) return _day(dateA);
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'dateA': dateKeyOf(dateA),
    'dateB': dateKeyOf(dateB),
    'createdAt': createdAt,
  };

  /// 宽松解析：缺字段 / 日期坏 / 两天相同 → null。
  static DaySwap? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final a = parseDateKey(raw['dateA']);
    final b = parseDateKey(raw['dateB']);
    if (id is! String || id.isEmpty || a == null || b == null) return null;
    if (isSameDate(a, b)) return null;
    final at = raw['createdAt'];
    return DaySwap(
      id: id,
      dateA: a,
      dateB: b,
      createdAt: at is String ? at : '',
    );
  }
}

/// 一组调课记录里 [d] 的对调日期（同一天只认第一条有效记录）。
DateTime? swapPartnerIn(List<DaySwap> swaps, DateTime d) {
  for (final s in swaps) {
    final p = s.partnerOf(d);
    if (p != null) return p;
  }
  return null;
}
