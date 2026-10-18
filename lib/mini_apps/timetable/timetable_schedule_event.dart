/// 按日期的一次性日程（§14）：考试或「其他」。
///
/// - [kind]：`exam` 考试 / `other` 其他。
/// - [source]：`jwxt` 教务拉取 / `manual` 手动添加。
/// 旧数据缺字段时按「其他」「手动」读，不做迁移。
library;

enum ScheduleKind { exam, other }

enum ScheduleSource { jwxt, manual }

/// 一天内的时刻（分钟精度）。
class TimeOfDayMinutes implements Comparable<TimeOfDayMinutes> {
  const TimeOfDayMinutes(this.hour, this.minute);

  final int hour;
  final int minute;

  int get totalMinutes => hour * 60 + minute;

  /// 'HH:mm'；非法 → null。
  static TimeOfDayMinutes? tryParse(Object? raw) {
    if (raw is! String) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return TimeOfDayMinutes(h, mi);
  }

  String format() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  @override
  int compareTo(TimeOfDayMinutes other) =>
      totalMinutes.compareTo(other.totalMinutes);

  @override
  bool operator ==(Object other) =>
      other is TimeOfDayMinutes && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

class ScheduleEvent {
  const ScheduleEvent({
    required this.id,
    required this.kind,
    required this.source,
    required this.title,
    required this.date,
    required this.start,
    required this.end,
    this.location = '',
    this.note = '',
    this.courseCode,
  });

  final String id;
  final ScheduleKind kind;
  final ScheduleSource source;
  final String title;

  /// 只取年月日。
  final DateTime date;
  final TimeOfDayMinutes start;
  final TimeOfDayMinutes end;
  final String location;
  final String note;

  /// 教务考试的课程号（手动日程可空）。
  final String? courseCode;

  bool get isExam => kind == ScheduleKind.exam;
  bool get isFromJwxt => source == ScheduleSource.jwxt;

  /// 教务考试的唯一键：课程号 + 日期 + 开始时间。手动日程返回 null。
  String? get jwxtKey =>
      isFromJwxt ? examKeyOf(courseCode ?? '', date, start) : null;

  static String examKeyOf(
    String courseCode,
    DateTime date,
    TimeOfDayMinutes start,
  ) => '$courseCode|${_dateKey(date)}|${start.format()}';

  ScheduleEvent copyWith({
    String? id,
    ScheduleKind? kind,
    ScheduleSource? source,
    String? title,
    DateTime? date,
    TimeOfDayMinutes? start,
    TimeOfDayMinutes? end,
    String? location,
    String? note,
    String? courseCode,
  }) => ScheduleEvent(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    source: source ?? this.source,
    title: title ?? this.title,
    date: date ?? this.date,
    start: start ?? this.start,
    end: end ?? this.end,
    location: location ?? this.location,
    note: note ?? this.note,
    courseCode: courseCode ?? this.courseCode,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'source': source.name,
    'title': title,
    'date': _dateKey(date),
    'start': start.format(),
    'end': end.format(),
    'location': location,
    'note': note,
    if (courseCode != null) 'courseCode': courseCode,
  };

  /// 宽松读取；日期或时间不合法 → null（调用方丢弃这条）。
  static ScheduleEvent? tryFromJson(Map<String, dynamic> json) {
    final date = _parseDate(json['date']);
    final start = TimeOfDayMinutes.tryParse(json['start']);
    final end = TimeOfDayMinutes.tryParse(json['end']);
    final id = json['id'];
    if (date == null || start == null || end == null || id is! String) {
      return null;
    }
    return ScheduleEvent(
      id: id,
      kind: json['kind'] == 'exam' ? ScheduleKind.exam : ScheduleKind.other,
      source: json['source'] == 'jwxt'
          ? ScheduleSource.jwxt
          : ScheduleSource.manual,
      title: '${json['title'] ?? ''}',
      date: date,
      start: start,
      end: end.compareTo(start) < 0 ? start : end,
      location: '${json['location'] ?? ''}',
      note: '${json['note'] ?? ''}',
      courseCode: json['courseCode'] is String
          ? json['courseCode'] as String
          : null,
    );
  }
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _parseDate(Object? raw) {
  if (raw is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw.trim());
  if (m == null) return null;
  final d = DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  );
  if (_dateKey(d) != raw.trim()) return null;
  return d;
}

/// 教务考试的本地覆盖（按原始 [ScheduleEvent.jwxtKey]）：编辑或删除。
/// 字段为 null 表示未改。
class ExamOverride {
  const ExamOverride({
    required this.key,
    this.deleted = false,
    this.title,
    this.date,
    this.start,
    this.end,
    this.location,
    this.note,
  });

  final String key;
  final bool deleted;
  final String? title;
  final DateTime? date;
  final TimeOfDayMinutes? start;
  final TimeOfDayMinutes? end;
  final String? location;
  final String? note;

  /// 把覆盖套到教务原考试上（删除的返回 null）。id 与原考试相同。
  ScheduleEvent? applyTo(ScheduleEvent e) {
    if (deleted) return null;
    final s = start ?? e.start;
    var en = end ?? e.end;
    if (en.compareTo(s) < 0) en = s;
    return e.copyWith(
      title: title,
      date: date,
      start: s,
      end: en,
      location: location,
      note: note,
    );
  }

  /// 由编辑后的考试 [edited] 与原考试 [orig] 生成覆盖（只记不同的字段）。
  static ExamOverride diff(ScheduleEvent orig, ScheduleEvent edited) {
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    return ExamOverride(
      key: orig.jwxtKey!,
      title: edited.title == orig.title ? null : edited.title,
      date: sameDay(edited.date, orig.date)
          ? null
          : DateTime(edited.date.year, edited.date.month, edited.date.day),
      start: edited.start == orig.start ? null : edited.start,
      end: edited.end == orig.end ? null : edited.end,
      location: edited.location == orig.location ? null : edited.location,
      note: edited.note == orig.note ? null : edited.note,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'deleted': deleted,
    if (title != null) 'title': title,
    if (date != null) 'date': _dateKey(date!),
    if (start != null) 'start': start!.format(),
    if (end != null) 'end': end!.format(),
    if (location != null) 'location': location,
    if (note != null) 'note': note,
  };

  static ExamOverride? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    if (key is! String || key.isEmpty) return null;
    String? s(String k) => raw[k] is String ? raw[k] as String : null;
    return ExamOverride(
      key: key,
      deleted: raw['deleted'] == true,
      title: s('title'),
      date: _parseDate(raw['date']),
      start: TimeOfDayMinutes.tryParse(raw['start']),
      end: TimeOfDayMinutes.tryParse(raw['end']),
      location: s('location'),
      note: s('note'),
    );
  }
}
