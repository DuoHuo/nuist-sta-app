import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/refresh/silent_refresh.dart';
import 'electricity_models.dart';

/// 电费小程序的本地存储：绑定的宿舍 + 历史电量，都是普通 JSON 文件，放在应用
/// 文档目录下的 `electricity/`。数据不敏感，不占安全存储。
///
/// 历史文件结构（按宿舍分区，换宿舍不清旧数据）：
/// ```json
/// {
///   "<room.key>": {
///     "2026-09-19": [ {"t": "14:32", "kwh": 23.45}, ... ],
///     "2026-09-18": [ ... ]
///   }
/// }
/// ```
class ElectricityStore {
  ElectricityStore._();
  static final _log = AppLog.logger('electricity.store');

  static Future<Directory?> _dir() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}electricity');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (error, stackTrace) {
      _log.warning(
        'storage.unavailable',
        error: error,
        stackTrace: stackTrace,
        fields: {
          'reason_code': 'electricity_storage_unavailable',
          'outcome': 'memory_fallback',
        },
      );
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<File?> _file(String name) async {
    final dir = await _dir();
    return dir == null
        ? null
        : File('${dir.path}${Platform.pathSeparator}$name');
  }

  static Future<Map<String, dynamic>> _readJson(String name) =>
      _log.inSpan(() async {
        try {
          final file = await _file(name);
          if (file == null || !await file.exists()) return {};
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) return decoded;
          _log.warning(
            'cache.schema_invalid',
            fields: {
              'file_kind': name,
              'reason_code': 'cache_root_not_object',
              'outcome': 'cache_fallback',
            },
          );
          return {};
        } catch (error, stackTrace) {
          _log.warning(
            'cache.read_failed',
            error: error,
            stackTrace: stackTrace,
            fields: {'file_kind': name, 'outcome': 'cache_fallback'},
          );
          return {};
        }
      });

  static Future<void> _writeJson(String name, Map<String, dynamic> data) =>
      _log.inSpan(() async {
        final file = await _file(name);
        if (file == null) {
          SilentRefresh.degradeCurrent(reason: 'storage_unavailable');
          return;
        }
        try {
          await file.writeAsString(jsonEncode(data), flush: true);
        } catch (error, stackTrace) {
          SilentRefresh.degradeCurrent(reason: 'cache_write_failed');
          _log.warning(
            'cache.write_failed',
            error: error,
            stackTrace: stackTrace,
            fields: {'file_kind': name, 'outcome': 'memory_fallback'},
          );
        }
      });

  // ==================== 宿舍 ====================

  static const _roomFile = 'room.json';

  static Future<ElecRoom?> readRoom() async {
    final json = await _readJson(_roomFile);
    if (json.isEmpty) return null;
    try {
      return ElecRoom.fromJson(json);
    } catch (error, stackTrace) {
      _log.warning(
        'room_cache.parse_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static Future<void> saveRoom(ElecRoom room) =>
      _writeJson(_roomFile, room.toJson());

  // ==================== 历史 ====================

  static const _historyFile = 'history.json';

  static Future<void> appendReading(ElecRoom room, ElecReading reading) async {
    final all = await _readJson(_historyFile);
    final byDay = _asMap(all[room.key]);
    final day = _dayKey(reading.time);
    final list = List<Map<String, dynamic>>.from(
      (byDay[day] as List?)?.whereType<Map<String, dynamic>>() ?? const [],
    );
    list.add({'t': _timeKey(reading.time), 'kwh': reading.kwh});
    byDay[day] = list;
    all[room.key] = byDay;
    await _writeJson(_historyFile, all);
  }

  /// 某宿舍的全部记录，按时间升序。
  static Future<List<ElecReading>> readHistory(ElecRoom room) async {
    final all = await _readJson(_historyFile);
    final byDay = _asMap(all[room.key]);
    final readings = <ElecReading>[];
    for (final entry in byDay.entries) {
      final list = entry.value;
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final time = _parse(entry.key, item['t']?.toString());
        final kwh = item['kwh'];
        if (time == null || kwh is! num) continue;
        readings.add(ElecReading(time: time, kwh: kwh.toDouble()));
      }
    }
    readings.sort((a, b) => a.time.compareTo(b.time));
    return readings;
  }

  /// 最近一条记录，首页冷启动先显示它。
  static Future<ElecReading?> latest(ElecRoom room) async {
    final history = await readHistory(room);
    return history.isEmpty ? null : history.last;
  }

  static Map<String, dynamic> _asMap(Object? value) =>
      value is Map<String, dynamic> ? Map.of(value) : <String, dynamic>{};

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _dayKey(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)}';

  static String _timeKey(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

  static DateTime? _parse(String day, String? time) {
    if (time == null) return null;
    return DateTime.tryParse('$day $time');
  }
}
