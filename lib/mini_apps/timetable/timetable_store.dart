import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'timetable_colors.dart';
import 'timetable_models.dart';
import 'timetable_overrides.dart';

/// 课表本地 JSON 存储：`ApplicationDocuments/timetable/`。
class TimetableStore {
  TimetableStore._();

  static const _snapshotFile = 'snapshot.json';
  static const _settingsFile = 'settings.json';

  /// 手动课程独立存储：同步/清教务缓存/退出登录都不触碰。
  static const _manualFile = 'manual_courses.json';

  /// 测试用：指定存储目录（flutter_test 下默认无磁盘存储）。
  @visibleForTesting
  static Directory? debugDirectory;

  static Future<Directory?> _dir() async {
    final override = debugDirectory;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    // flutter_test 无可靠平台通道；直接退化，避免 timeout Timer 残留。
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}timetable');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _file(String name) async {
    final dir = await _dir();
    return dir == null
        ? null
        : File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// 课表目录下的文件（无存储时 null）。供 [ScheduleStore] 等同目录存储复用。
  static Future<File?> fileFor(String name) => _file(name);

  static Future<Map<String, dynamic>> _readJson(String name) async {
    final file = await _file(name);
    if (file == null || !await file.exists()) return {};
    try {
      // 解析放到后台 isolate，避免启动时阻塞主线程。
      final decoded = await compute(_decode, await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  static Object? _decode(String raw) => jsonDecode(raw);

  static Future<void> _writeJson(String name, Map<String, dynamic> data) async {
    final file = await _file(name);
    if (file == null) return;
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  static Future<TimetableSnapshot?> readSnapshot() async {
    final json = await _readJson(_snapshotFile);
    if (json.isEmpty) return null;
    try {
      return TimetableSnapshot.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSnapshot(TimetableSnapshot snapshot) =>
      _writeJson(_snapshotFile, snapshot.toJson());

  static Future<TimetableSettings> readSettings() async {
    final json = await _readJson(_settingsFile);
    if (json.isEmpty) return const TimetableSettings();
    try {
      return TimetableSettings.fromJson(json);
    } catch (_) {
      return const TimetableSettings();
    }
  }

  static Future<void> saveSettings(TimetableSettings settings) =>
      _writeJson(_settingsFile, settings.toJson());

  /// settings.json 中由教务同步写入的学期元数据键。
  static const termSettingKeys = <String>{
    'termCode',
    'termStartDate',
    'maxWeeks',
    'termStartFromJwxt',
  };

  /// 原样读取 settings.json（不经 [TimetableSettings] 解析/钳制）。
  static Future<Map<String, dynamic>> readRawSettings() async {
    final file = await _file(_settingsFile);
    return file == null ? {} : _readRawSync(file);
  }

  /// 原样写回 settings.json。
  static Future<void> writeRawSettings(Map<String, dynamic> raw) async {
    final file = await _file(_settingsFile);
    if (file != null) _writeRawSync(file, raw);
  }

  // settings.json 很小：同步读写、当前 isolate 解码（不走 compute）。
  // 读-改-写在一段同步代码内完成，不让出事件循环，连续修改不会互相覆盖。
  static Map<String, dynamic> _readRawSync(File file) {
    try {
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  static void _writeRawSync(File file, Map<String, dynamic> raw) =>
      file.writeAsStringSync(jsonEncode(raw), flush: true);

  /// 对原始 Map 做编辑；[edit] 返回 true 才写盘。
  static Future<void> _editRawSettings(
    bool Function(Map<String, dynamic> raw) edit,
  ) async {
    final file = await _file(_settingsFile);
    if (file == null) return;
    final raw = _readRawSync(file);
    if (edit(raw)) _writeRawSync(file, raw);
  }

  /// 逐键比较 [previous] 与 [next]，只把变化的键写入原始 settings.json；
  /// 未变化的键（含钳制前的原值）与未知键保持不变。
  static Future<void> mergeSettingsChanges(
    TimetableSettings previous,
    TimetableSettings next,
  ) {
    final before = previous.toJson();
    final after = next.toJson();
    return _editRawSettings((raw) {
      var changed = false;
      for (final key in {...before.keys, ...after.keys}) {
        if (before.containsKey(key) == after.containsKey(key) &&
            before[key] == after[key]) {
          continue;
        }
        changed = true;
        if (after.containsKey(key)) {
          raw[key] = after[key];
        } else {
          raw.remove(key);
        }
      }
      return changed;
    });
  }

  /// 同步成功后把 [settings] 的学期四键合并进原始 settings.json：
  /// 只覆盖这四个键，其他键原样保留；与磁盘值一致时不写盘。
  static Future<void> mergeTermSettings(TimetableSettings settings) {
    final json = settings.toJson();
    return _editRawSettings((raw) {
      var changed = false;
      for (final key in termSettingKeys) {
        if (json.containsKey(key)) {
          if (!raw.containsKey(key) || raw[key] != json[key]) {
            raw[key] = json[key];
            changed = true;
          }
        } else if (raw.containsKey(key)) {
          raw.remove(key);
          changed = true;
        }
      }
      return changed;
    });
  }

  /// 仅移除学期相关键；periodHeight 原值、开关与未知键全部保留。
  /// 文件不存在或不含学期键时不写盘。
  static Future<void> removeTermSettingKeys() => _editRawSettings((raw) {
    if (!raw.keys.any(termSettingKeys.contains)) return false;
    raw.removeWhere((k, _) => termSettingKeys.contains(k));
    return true;
  });

  /// 手动课程文件版本。
  static const int manualSchemaVersion = 2;

  static Future<List<Course>> readManualCourses() async {
    final json = await _readJson(_manualFile);
    final list = json['courses'];
    if (list is! List) return [];
    final result = <Course>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      try {
        result.add(Course.fromJson(item).copyWith(source: CourseSource.manual));
      } catch (_) {}
    }
    return result;
  }

  /// 合并写：保留文件里的未知顶层键，以及同 id 课程条目里的未知键。
  /// v2：课程新增可选 colorIndex / assignedColorIndex（0..15）；旧文件缺字段按 null 读取。
  static Future<void> saveManualCourses(List<Course> courses) async {
    final file = await _file(_manualFile);
    if (file == null) return;
    final raw = _readRawSync(file);
    final oldById = <String, Map<String, dynamic>>{};
    final old = raw['courses'];
    if (old is List) {
      for (final item in old) {
        if (item is Map<String, dynamic>) oldById['${item['id']}'] = item;
      }
    }
    raw['schemaVersion'] = manualSchemaVersion;
    raw['courses'] = [
      for (final c in courses)
        {...?oldById[c.id], ...c.toJson()}..removeWhere(
          (k, _) =>
              (k == 'colorIndex' && c.colorIndex == null) ||
              (k == 'assignedColorIndex' && c.assignedColorIndex == null) ||
              (k == 'credit' && c.credit == null),
        ),
    ];
    _writeRawSync(file, raw);
  }

  /// 教务课调课记录（spec §13.2 / jwxt §3.2）：同步、解绑都不触碰。
  static const _overridesFile = 'overrides.json';
  static const int overridesSchemaVersion = 1;

  /// 读取调课记录；解析不了的条目跳过（写回时原样保留）。
  static Future<List<SlotOverride>> readOverrides() async {
    final file = await _file(_overridesFile);
    if (file == null) return [];
    final list = _readRawSync(file)['overrides'];
    if (list is! List) return [];
    return [for (final item in list) ?SlotOverride.tryParse(item)];
  }

  /// 合并写：保留文件里的未知顶层键与解析不了的条目，`overrides` 换成 [list]。
  static Future<void> saveOverrides(List<SlotOverride> list) async {
    final file = await _file(_overridesFile);
    if (file == null) return;
    final raw = _readRawSync(file);
    final old = raw['overrides'];
    final unknown = [
      if (old is List)
        for (final item in old)
          if (SlotOverride.tryParse(item) == null) item,
    ];
    raw['schemaVersion'] = overridesSchemaVersion;
    raw['overrides'] = [for (final o in list) o.toJson(), ...unknown];
    _writeRawSync(file, raw);
  }

  /// 全学期配色表（[TimetableController.courseColorMap]）：
  /// `{schemaVersion: 1, scheme: <方案名，如 soft>, map: {规范化课名: 色号}}`。
  /// 只在重算配色（教务同步、手动课增删、换配色方案）后写；重启直接读，避免惰性
  /// 重建时因调课/编辑改了相邻关系而换色。同步/解绑/清教务缓存都不删它。
  static const courseColorsFile = 'course_colors.json';
  static const int courseColorsSchemaVersion = 1;

  /// 读配色表。文件不存在、JSON 坏、版本/方案名不认识、map 不是 {String: 0..15}
  /// 任一情况 → null（调用方重建并落盘）。不抛异常。
  static Future<StoredCourseColors?> readCourseColors() async {
    final file = await _file(courseColorsFile);
    if (file == null) return null;
    final raw = _readRawSync(file);
    if (raw['schemaVersion'] != courseColorsSchemaVersion) return null;
    final schemeName = raw['scheme'];
    CoursePaletteScheme? scheme;
    for (final s in CoursePaletteScheme.values) {
      if (s.name == schemeName) scheme = s;
    }
    if (scheme == null) return null;
    final map = raw['map'];
    if (map is! Map) return null;
    final out = <String, int>{};
    for (final e in map.entries) {
      final v = e.value;
      if (e.key is! String || v is! int || v < 0 || v >= kCoursePaletteSize) {
        return null;
      }
      out[e.key as String] = v;
    }
    return StoredCourseColors(scheme, out);
  }

  /// 合并写：保留文件里的未知顶层键，替换 schemaVersion / scheme / map。
  static Future<void> saveCourseColors(
    CoursePaletteScheme scheme,
    Map<String, int> map,
  ) async {
    final file = await _file(courseColorsFile);
    if (file == null) return;
    final raw = _readRawSync(file);
    raw['schemaVersion'] = courseColorsSchemaVersion;
    raw['scheme'] = scheme.name;
    raw['map'] = Map<String, int>.of(map);
    _writeRawSync(file, raw);
  }

  /// 清除教务快照（保留手动课程与设置）。
  static Future<void> clearJwxtSnapshot() async {
    final file = await _file(_snapshotFile);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 清空整个课表目录（**含手动课程**），仅用于彻底重置。
  static Future<void> clearAll() async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// [TimetableStore.readCourseColors] 的结果。
class StoredCourseColors {
  const StoredCourseColors(this.scheme, this.map);
  final CoursePaletteScheme scheme;
  final Map<String, int> map;
}
