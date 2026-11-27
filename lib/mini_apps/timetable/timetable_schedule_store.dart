import '../../core/logging/app_log.dart';
import 'timetable_date_edits.dart';
import 'timetable_exam_parser.dart';
import 'timetable_schedule_event.dart';
import 'timetable_overrides.dart';
import 'timetable_store.dart';

/// 日程与教务覆盖层的本地存储，与 [TimetableStore] 同目录（`timetable/`）、同约定：
/// 每个文件带 schemaVersion；读取宽松（坏条目跳过；文件坏/类型不对 → 改名为
/// `.corrupt` 备份后按空）；
/// 写入先写临时文件再 rename（原子替换），并保留未知顶层键。
///
/// - `schedule_events.json`：`{schemaVersion: 1, events: [ScheduleEvent.toJson()],
///   otherColors: {名称: 色号}}`（教务考试与手动日程都在这里；同步只批量替换
///   source=jwxt 的；`otherColors` 为「其他」日程按名称固定的颜色）。
/// - `course_edits.json`：`{schemaVersion: 1, version: 2, edits: [CourseEdit.toJson()],
///   dateEdits: [CourseDateEdit.toJson()]}`。`version` 缺失（旧文件）照旧读 `edits`；
///   `dateEdits` 缺失 = 没有单日修改。
/// - `day_swaps.json`：`{schemaVersion: 1, swaps: [DaySwap.toJson()]}`（整天调课）。
/// - `exam_overrides.json`：`{schemaVersion: 1, overrides: [ExamOverride.toJson()]}`。
/// - `sync_state.json`：`{schemaVersion: 1, lastSuccessAt: ISO8601 | null,
///   portalSessionExpired: bool}`（后者缺失 = false）。
class ScheduleStore {
  ScheduleStore._();
  static final _log = AppLog.logger('timetable.schedule_store');

  static const scheduleEventsFile = 'schedule_events.json';
  static const courseEditsFile = 'course_edits.json';
  static const examOverridesFile = 'exam_overrides.json';
  static const syncStateFile = 'sync_state.json';
  static const daySwapsFile = 'day_swaps.json';
  static const int schemaVersion = 1;

  /// `course_edits.json` 的内容版本：2 = 含单日修改 `dateEdits`；3 = 含 weeks/scope。
  static const int courseEditsVersion = 3;

  static Future<Map<String, dynamic>> _read(String name) =>
      _log.inSpan(() async {
        try {
          final file = await TimetableStore.fileFor(name);
          return file == null ? {} : TimetableStore.readJsonFile(file);
        } catch (error, stackTrace) {
          _log.warning(
            'json.read_failed',
            fields: {'file_kind': name},
            error: error,
            stackTrace: stackTrace,
          );
          return {};
        }
      });

  /// 合并写（保留未知顶层键）+ 原子替换。
  static Future<void> _write(String name, Map<String, dynamic> values) =>
      _log.inSpan(() async {
        try {
          // 批次内同步合并；批次外放到串行后台队列/Isolate 完成读盘、校验与原子替换。
          await TimetableStore.modifyNamedJsonFile(name, (raw) {
            raw.addAll(values);
            raw['schemaVersion'] = schemaVersion;
            return true;
          });
        } catch (error, stackTrace) {
          _log.error(
            'json.write_failed',
            fields: {'file_kind': name},
            error: error,
            stackTrace: stackTrace,
            errorKind: 'storage_write',
          );
          throw TimetablePersistenceException(
            cause: error,
            causeStackTrace: stackTrace,
          );
        }
      });

  static List<Object?> _list(Map<String, dynamic> raw, String key) {
    final v = raw[key];
    return v is List ? v : const [];
  }

  // ---- 日程 ----

  static Future<List<ScheduleEvent>> readEvents() async =>
      parseEvents(await _read(scheduleEventsFile));

  /// 从已解码 JSON 解析日程。
  static List<ScheduleEvent> parseEvents(Map<String, dynamic> raw) => [
    for (final item in _list(raw, 'events'))
      if (item is Map<String, dynamic>)
        if (ScheduleEvent.tryFromJson(item) case final event?)
          ExamParser.cleanImportedExam(event),
  ];

  /// 只写 `events`（合并写：`otherColors` 与未知顶层键保留）。
  /// 只写日程；文件里已有的 `otherColors` 原样保留（不丢「其他」固定色）。
  static Future<void> saveEvents(List<ScheduleEvent> events) =>
      _write(scheduleEventsFile, {
        'events': [for (final e in events) e.toJson()],
      });

  /// 「其他」日程按名称固定的色号（`schedule_events.json` 顶层 `otherColors`，
  /// `{名称: 色号}`）。缺失/类型不对 → 空；坏条目跳过。
  static Future<Map<String, int>> readOtherColors() async =>
      parseOtherColors(await _read(scheduleEventsFile));

  /// 从已解码 JSON 解析「其他」日程颜色映射。
  static Map<String, int> parseOtherColors(Map<String, dynamic> raw) {
    final v = raw['otherColors'];
    if (v is! Map) return {};
    return {
      for (final e in v.entries)
        if (e.key is String && e.value is int && (e.value as int) >= 0)
          e.key as String: e.value as int,
    };
  }

  /// 同时写日程与 `otherColors`（一次原子替换）。
  static Future<void> saveEventsAndOtherColors(
    List<ScheduleEvent> events,
    Map<String, int> otherColors, {
    bool clearJwxtExamsBaselinePending = false,
  }) => _write(scheduleEventsFile, {
    'events': [for (final e in events) e.toJson()],
    'otherColors': otherColors,
    if (clearJwxtExamsBaselinePending) _jwxtExamsBaselinePendingKey: null,
  });

  static const _jwxtExamsBaselinePendingKey = 'jwxtExamsBaselinePending';

  /// 读取「尚未建立教务考试基线」标记；缺失或非 true 均为 false。
  static bool parseJwxtExamsBaselinePending(Map<String, dynamic> raw) =>
      raw[_jwxtExamsBaselinePendingKey] == true;

  /// 记录或清除「尚未建立教务考试基线」标记（首次同步或跨学期时考试失败置 true）。
  static Future<void> saveJwxtExamsBaselinePending(bool pending) =>
      _log.inSpan(() async {
        try {
          await TimetableStore.modifyNamedJsonFile(scheduleEventsFile, (raw) {
            if (pending) {
              if (raw[_jwxtExamsBaselinePendingKey] == true) return false;
              raw[_jwxtExamsBaselinePendingKey] = true;
            } else {
              if (!raw.containsKey(_jwxtExamsBaselinePendingKey)) return false;
              raw.remove(_jwxtExamsBaselinePendingKey);
            }
            raw['schemaVersion'] = schemaVersion;
            return true;
          });
        } catch (error, stackTrace) {
          _log.error(
            'json.write_failed',
            fields: {'file_kind': scheduleEventsFile},
            error: error,
            stackTrace: stackTrace,
            errorKind: 'storage_write',
          );
          throw TimetablePersistenceException(
            cause: error,
            causeStackTrace: stackTrace,
          );
        }
      });

  // ---- 教务课编辑 / 删除 ----

  static Future<Map<String, CourseEdit>> readCourseEdits() async =>
      parseCourseEdits(await _read(courseEditsFile));

  /// 从已解码 JSON 解析教务课编辑记录。
  static Map<String, CourseEdit> parseCourseEdits(Map<String, dynamic> raw) {
    final out = <String, CourseEdit>{};
    for (final item in _list(raw, 'edits')) {
      final e = CourseEdit.tryParse(item);
      if (e != null) out[e.courseId] = e;
    }
    return out;
  }

  static Future<void> saveCourseEdits(Map<String, CourseEdit> edits) =>
      _write(courseEditsFile, {
        'version': courseEditsVersion,
        'edits': [for (final e in edits.values) e.toJson()],
      });

  // ---- 单日修改（第 1 条）----

  /// `course_edits.json` 的 `dateEdits`；缺失 / 类型不对 → 空，坏条目跳过。
  static Future<List<CourseDateEdit>> readCourseDateEdits() async =>
      parseCourseDateEdits(await _read(courseEditsFile));

  /// 从已解码 JSON 解析单日修改记录。
  static List<CourseDateEdit> parseCourseDateEdits(
    Map<String, dynamic> raw,
  ) => [
    for (final item in _list(raw, 'dateEdits')) ?CourseDateEdit.tryParse(item),
  ];

  /// 只写 `dateEdits`（合并写：`edits` 与未知顶层键保留）。
  static Future<void> saveCourseDateEdits(List<CourseDateEdit> list) =>
      _write(courseEditsFile, {
        'version': courseEditsVersion,
        'dateEdits': [for (final e in list) e.toJson()],
      });

  // ---- 整天调课（第 8 条）----

  /// 读 `day_swaps.json`；坏文件按 [_read] 备份为 `.corrupt` 后按空，坏条目跳过。
  static Future<List<DaySwap>> readDaySwaps() async =>
      parseDaySwaps(await _read(daySwapsFile));

  /// 从已解码 JSON 解析整天调课记录。
  static List<DaySwap> parseDaySwaps(Map<String, dynamic> raw) => [
    for (final item in _list(raw, 'swaps')) ?DaySwap.tryParse(item),
  ];

  static Future<void> saveDaySwaps(List<DaySwap> swaps) =>
      _write(daySwapsFile, {
        'swaps': [for (final s in swaps) s.toJson()],
      });

  // ---- 教务考试覆盖 ----

  static Future<Map<String, ExamOverride>> readExamOverrides() async =>
      parseExamOverrides(await _read(examOverridesFile));

  /// 从已解码 JSON 解析考试覆盖记录。
  static Map<String, ExamOverride> parseExamOverrides(
    Map<String, dynamic> raw,
  ) {
    final out = <String, ExamOverride>{};
    for (final item in _list(raw, 'overrides')) {
      final o = ExamOverride.tryParse(item);
      if (o != null) out[o.key] = o;
    }
    return out;
  }

  static Future<void> saveExamOverrides(Map<String, ExamOverride> map) =>
      _write(examOverridesFile, {
        'overrides': [for (final o in map.values) o.toJson()],
      });

  // ---- 自动同步节流 ----

  /// 最近一次同步成功时间；无/坏 → null（视为首次安装）。
  static Future<DateTime?> readLastSyncSuccess() async =>
      parseLastSyncSuccess(await _read(syncStateFile));

  /// 从已解码 JSON 解析最近一次同步成功时间。
  static DateTime? parseLastSyncSuccess(Map<String, dynamic> raw) {
    final v = raw['lastSuccessAt'];
    return v is String ? DateTime.tryParse(v) : null;
  }

  static Future<void> saveLastSyncSuccess(DateTime at) =>
      _write(syncStateFile, {'lastSuccessAt': at.toIso8601String()});

  /// 最近一次自动拉取尝试；失败也保存，重启后继续限制重复自动请求。
  static Future<DateTime?> readLastAutomaticAttempt() async =>
      parseLastAutomaticAttempt(await _read(syncStateFile));

  /// 从已解码 JSON 解析最近一次自动拉取尝试时间。
  static DateTime? parseLastAutomaticAttempt(Map<String, dynamic> raw) {
    final value = raw['lastAutomaticAttemptAt'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  /// 只合并尝试时间，不改上次成功时间、过期标记或未来扩展键。
  static Future<void> saveLastAutomaticAttempt(DateTime at) =>
      _write(syncStateFile, {'lastAutomaticAttemptAt': at.toIso8601String()});

  /// 门户 / 教务登录是否已过期（`sync_state.json` 的 `portalSessionExpired`）。
  /// 缺失 / 类型不对 → false；文件坏按 [_read] 的备份规则处理。
  static Future<bool> readPortalSessionExpired() async =>
      parsePortalSessionExpired(await _read(syncStateFile));

  /// 从已解码 JSON 解析门户登录过期标记。
  static bool parsePortalSessionExpired(Map<String, dynamic> raw) =>
      raw['portalSessionExpired'] == true;

  /// 合并写（保留 `lastSuccessAt` 等其他键）。
  static Future<void> savePortalSessionExpired(bool expired) =>
      _write(syncStateFile, {'portalSessionExpired': expired});
}
