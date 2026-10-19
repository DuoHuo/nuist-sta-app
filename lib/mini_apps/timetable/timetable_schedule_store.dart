import 'dart:convert';
import 'dart:io';

import 'timetable_date_edits.dart';
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

  static const scheduleEventsFile = 'schedule_events.json';
  static const courseEditsFile = 'course_edits.json';
  static const examOverridesFile = 'exam_overrides.json';
  static const syncStateFile = 'sync_state.json';
  static const daySwapsFile = 'day_swaps.json';
  static const int schemaVersion = 1;

  /// `course_edits.json` 的内容版本：2 = 含单日修改 `dateEdits`；3 = 含 weeks/scope。
  static const int courseEditsVersion = 3;

  static Future<Map<String, dynamic>> _read(String name) async {
    final file = await TimetableStore.fileFor(name);
    if (file == null) return {};
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 落到下面的备份逻辑。
    }
    await _backupCorrupt(file);
    return {};
  }

  /// 文件损坏（解析失败或顶层不是对象）时先改名留底，再按空继续，
  /// 免得下次保存把用户的编辑 / 删除 / 手动日程覆盖掉。
  /// 备份名为 `<name>.corrupt`；已有同名备份时追加毫秒时间戳，不覆盖旧备份。
  static Future<void> _backupCorrupt(File file) async {
    try {
      var target = File('${file.path}.corrupt');
      if (await target.exists()) {
        target = File(
          '${file.path}.corrupt.${DateTime.now().millisecondsSinceEpoch}',
        );
      }
      await file.rename(target.path);
    } catch (_) {
      // 改名失败（只读等）就保持原样，不影响启动。
    }
  }

  /// 合并写（保留未知顶层键）+ 原子替换。
  static Future<void> _write(String name, Map<String, dynamic> values) async {
    final file = await TimetableStore.fileFor(name);
    if (file == null) return;
    final raw = await _read(name);
    raw.addAll(values);
    raw['schemaVersion'] = schemaVersion;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(raw), flush: true);
    await tmp.rename(file.path);
  }

  static List<Object?> _list(Map<String, dynamic> raw, String key) {
    final v = raw[key];
    return v is List ? v : const [];
  }

  // ---- 日程 ----

  static Future<List<ScheduleEvent>> readEvents() async {
    final raw = await _read(scheduleEventsFile);
    return [
      for (final item in _list(raw, 'events'))
        if (item is Map<String, dynamic>) ?ScheduleEvent.tryFromJson(item),
    ];
  }

  /// 只写 `events`（合并写：`otherColors` 与未知顶层键保留）。
  /// 只写日程；文件里已有的 `otherColors` 原样保留（不丢「其他」固定色）。
  static Future<void> saveEvents(List<ScheduleEvent> events) async =>
      saveEventsAndOtherColors(events, await readOtherColors());

  /// 「其他」日程按名称固定的色号（`schedule_events.json` 顶层 `otherColors`，
  /// `{名称: 色号}`）。缺失/类型不对 → 空；坏条目跳过。
  static Future<Map<String, int>> readOtherColors() async {
    final v = (await _read(scheduleEventsFile))['otherColors'];
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
    Map<String, int> otherColors,
  ) => _write(scheduleEventsFile, {
    'events': [for (final e in events) e.toJson()],
    'otherColors': otherColors,
  });

  // ---- 教务课编辑 / 删除 ----

  static Future<Map<String, CourseEdit>> readCourseEdits() async {
    final raw = await _read(courseEditsFile);
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
  static Future<List<CourseDateEdit>> readCourseDateEdits() async {
    final raw = await _read(courseEditsFile);
    return [
      for (final item in _list(raw, 'dateEdits'))
        ?CourseDateEdit.tryParse(item),
    ];
  }

  /// 只写 `dateEdits`（合并写：`edits` 与未知顶层键保留）。
  static Future<void> saveCourseDateEdits(List<CourseDateEdit> list) =>
      _write(courseEditsFile, {
        'version': courseEditsVersion,
        'dateEdits': [for (final e in list) e.toJson()],
      });

  // ---- 整天调课（第 8 条）----

  /// 读 `day_swaps.json`；坏文件按 [_read] 备份为 `.corrupt` 后按空，坏条目跳过。
  static Future<List<DaySwap>> readDaySwaps() async {
    final raw = await _read(daySwapsFile);
    return [for (final item in _list(raw, 'swaps')) ?DaySwap.tryParse(item)];
  }

  static Future<void> saveDaySwaps(List<DaySwap> swaps) =>
      _write(daySwapsFile, {
        'swaps': [for (final s in swaps) s.toJson()],
      });

  // ---- 教务考试覆盖 ----

  static Future<Map<String, ExamOverride>> readExamOverrides() async {
    final raw = await _read(examOverridesFile);
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
  static Future<DateTime?> readLastSyncSuccess() async {
    final v = (await _read(syncStateFile))['lastSuccessAt'];
    return v is String ? DateTime.tryParse(v) : null;
  }

  static Future<void> saveLastSyncSuccess(DateTime at) =>
      _write(syncStateFile, {'lastSuccessAt': at.toIso8601String()});

  /// 门户 / 教务登录是否已过期（`sync_state.json` 的 `portalSessionExpired`）。
  /// 缺失 / 类型不对 → false；文件坏按 [_read] 的备份规则处理。
  static Future<bool> readPortalSessionExpired() async =>
      (await _read(syncStateFile))['portalSessionExpired'] == true;

  /// 合并写（保留 `lastSuccessAt` 等其他键）。
  static Future<void> savePortalSessionExpired(bool expired) =>
      _write(syncStateFile, {'portalSessionExpired': expired});
}
