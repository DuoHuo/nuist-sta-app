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
/// 识别键：[courseId] + [date]（修改时这次课显示所在的日期，已套用整天调课）+
/// [origStart]/[origEnd]（修改前的显示节次）。展示时这一天对不上（课已不在这天 /
/// 节次变了）就忽略这条记录，不删（同步也不删）。
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
    this.name,
    this.teacher,
    this.location,
    this.note,
    this.toDate,
    this.toStart,
    this.toEnd,
    this.createdAt = '',
    this.extra = const {},
  });

  final String id;
  final String courseId;

  /// 只取年月日。
  final DateTime date;
  final int origStart;
  final int origEnd;
  final DateEditKind kind;
  final String? name;
  final String? teacher;
  final String? location;
  final String? note;
  final DateTime? toDate;
  final int? toStart;
  final int? toEnd;
  final String createdAt;

  /// 读到的未知键，写回时原样保留。
  final Map<String, dynamic> extra;

  bool get isDelete => kind == DateEditKind.delete;

  /// 这次课最终显示的日期。
  DateTime get targetDate => toDate ?? date;

  /// 是否把这次课挪到了别的日期。
  bool get movesToOtherDate => toDate != null && !isSameDate(toDate!, date);

  /// 是否改了节次或日期。
  bool get movesTime =>
      movesToOtherDate ||
      (toStart != null && toStart != origStart) ||
      (toEnd != null && toEnd != origEnd);

  bool get hasFieldEdits =>
      name != null || teacher != null || location != null || note != null;

  /// 编辑记录什么都没改（应删除）。
  bool get isEmpty => !isDelete && !hasFieldEdits && !movesTime;

  bool matches(String courseId, DateTime date, int start, int end) =>
      this.courseId == courseId &&
      isSameDate(this.date, date) &&
      origStart == start &&
      origEnd == end;

  CourseDateEdit copyWith({
    DateEditKind? kind,
    String? name,
    String? teacher,
    String? location,
    String? note,
    DateTime? toDate,
    int? toStart,
    int? toEnd,
    bool clearMove = false,
    bool clearName = false,
    bool clearTeacher = false,
    bool clearLocation = false,
    bool clearNote = false,
    String? createdAt,
  }) => CourseDateEdit(
    id: id,
    courseId: courseId,
    date: date,
    origStart: origStart,
    origEnd: origEnd,
    kind: kind ?? this.kind,
    name: clearName ? null : (name ?? this.name),
    teacher: clearTeacher ? null : (teacher ?? this.teacher),
    location: clearLocation ? null : (location ?? this.location),
    note: clearNote ? null : (note ?? this.note),
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
    if (name != null) 'name': name,
    if (teacher != null) 'teacher': teacher,
    if (location != null) 'location': location,
    if (note != null) 'note': note,
    if (toDate != null) 'toDate': dateKeyOf(toDate!),
    if (toStart != null) 'toStart': toStart,
    if (toEnd != null) 'toEnd': toEnd,
    'createdAt': createdAt,
  };

  static const _known = {
    'id', 'courseId', 'date', 'origStart', 'origEnd', 'kind', 'name', //
    'teacher', 'location', 'note', 'toDate', 'toStart', 'toEnd', 'createdAt',
  };

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
    if (date == null || os == null || oe == null || os < 1 || oe < os) {
      return null;
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
      name: s('name'),
      teacher: s('teacher'),
      location: s('location'),
      note: s('note'),
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
