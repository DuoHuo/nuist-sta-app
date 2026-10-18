import 'timetable_schedule_event.dart';

/// 教务「我的考试安排」（studentWdksapApp / cxxsksap）响应解析（第 11 条，
/// 本目录 README.md「教务考试安排接口」§2–§3）。纯函数，不做 IO、不打日志。
///
/// 只取需要的字段：KCH / KCM / KSRQ / KSKSSJ / KSJSSJ / JASMC / JXLMC / ZWH / BZ /
/// SFAPSJ。学号（XH / XSBH）、监考或主讲教师（ZJJSXM）与内部 ID 一律不读、不入库。
class ExamParser {
  ExamParser._();

  /// 解析结果：[exams] 为可入库的考试（kind=exam、source=jwxt，按 examKey 去重，
  /// 先出现的保留）；[skippedCourseCodes] 为因格式不对被丢弃的行的课程号
  /// （仅供脱敏日志；缺课程号的行记为空串）。未排时间（SFAPSJ≠1 或时间为空）
  /// 属于正常跳过，不计入。
  static ({List<ScheduleEvent> exams, List<String> skippedCourseCodes}) parse(
    Object? decoded,
  ) {
    if (decoded is! Map) {
      throw const ExamResponseError('教务考试接口未返回 JSON');
    }
    if ('${decoded['code'] ?? ''}' != '0') {
      throw const ExamResponseError('教务考试接口返回错误');
    }
    final datas = decoded['datas'];
    final section = datas is Map ? datas['cxxsksap'] : null;
    final rows = section is Map ? section['rows'] : null;
    if (rows is! List) {
      throw const ExamResponseError('教务考试接口缺少 rows');
    }
    return parseRows(rows);
  }

  /// 逐行解析；坏行只丢这一行。
  static ({List<ScheduleEvent> exams, List<String> skippedCourseCodes})
  parseRows(List<Object?> rows) {
    final exams = <ScheduleEvent>[];
    final skipped = <String>[];
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map) {
        skipped.add('');
        continue;
      }
      final ExamRowResult r;
      try {
        r = parseRow(row);
      } catch (_) {
        skipped.add(_str(row['KCH']));
        continue;
      }
      switch (r) {
        case ExamRowOk(:final exam):
          if (seen.add(exam.jwxtKey!)) exams.add(exam);
        case ExamRowUnscheduled():
          break;
        case ExamRowMalformed(:final courseCode):
          skipped.add(courseCode);
      }
    }
    return (exams: exams, skippedCourseCodes: skipped);
  }

  /// 单行映射。
  static ExamRowResult parseRow(Map<Object?, Object?> row) {
    final kch = _str(row['KCH']);
    final ksrq = _str(row['KSRQ']);
    final kssj = _str(row['KSKSSJ']);
    final jssj = _str(row['KSJSSJ']);
    // 还没排时间：正常跳过。
    if (_str(row['SFAPSJ']) != '1' ||
        ksrq.isEmpty ||
        kssj.isEmpty ||
        jssj.isEmpty) {
      return const ExamRowUnscheduled();
    }
    // 缺课程号：examKey 拼不出来，无法和覆盖记录对应。
    if (kch.isEmpty) return const ExamRowMalformed('');
    final date = parseExamDate(ksrq);
    final start = _parseTime(kssj);
    final end = _parseTime(jssj);
    if (date == null ||
        start == null ||
        end == null ||
        end.compareTo(start) < 0) {
      return ExamRowMalformed(kch);
    }
    final title = _str(row['KCM']);
    final room = _str(row['JASMC']);
    final building = _str(row['JXLMC']);
    final exam = ScheduleEvent(
      id: examEventId(kch, date, start),
      kind: ScheduleKind.exam,
      source: ScheduleSource.jwxt,
      title: title.isEmpty ? kch : title,
      date: date,
      start: start,
      end: end,
      location: room.isNotEmpty ? room : building,
      note: composeNote(seat: _str(row['ZWH']), remark: _str(row['BZ'])),
      courseCode: kch,
    );
    return ExamRowOk(exam);
  }

  /// 本地 id 由 examKey 决定：同一场考试再次拉到 id 不变（EX14），教务改了日期 /
  /// 开始时间则是新 id（EX15）。
  static String examEventId(
    String courseCode,
    DateTime date,
    TimeOfDayMinutes start,
  ) => 'jwxt-exam:${ScheduleEvent.examKeyOf(courseCode, date, start)}';

  /// 「座位号 12」+ 换行 + 备注；都为空 → 空串。
  static String composeNote({required String seat, required String remark}) => [
    if (seat.isNotEmpty) '座位号 $seat',
    if (remark.isNotEmpty) remark,
  ].join('\n');

  static final _dateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
  static final _timeRe = RegExp(r'^(\d{2}):(\d{2})$');

  /// 只认 `yyyy-MM-dd`（含合法性校验，如 2027-02-30 → null）。
  static DateTime? parseExamDate(String raw) {
    final m = _dateRe.firstMatch(raw);
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final date = DateTime(y, mo, d);
    if (date.year != y || date.month != mo || date.day != d) return null;
    return date;
  }

  /// 只认 `HH:mm`。
  static TimeOfDayMinutes? _parseTime(String raw) {
    if (!_timeRe.hasMatch(raw)) return null;
    return TimeOfDayMinutes.tryParse(raw);
  }

  static String _str(Object? v) => v == null ? '' : '$v'.trim();
}

/// 单行解析结果。
sealed class ExamRowResult {
  const ExamRowResult();
}

class ExamRowOk extends ExamRowResult {
  const ExamRowOk(this.exam);
  final ScheduleEvent exam;
}

/// 未排时间（SFAPSJ≠1 或日期/时间为空）。
class ExamRowUnscheduled extends ExamRowResult {
  const ExamRowUnscheduled();
}

/// 格式不对或缺课程号。
class ExamRowMalformed extends ExamRowResult {
  const ExamRowMalformed(this.courseCode);
  final String courseCode;
}

/// 考试接口响应不可用（code≠0、非 JSON、结构不对）：整批视为失败，已有考试不动。
class ExamResponseError implements Exception {
  const ExamResponseError(this.message);
  final String message;
  @override
  String toString() => message;
}
