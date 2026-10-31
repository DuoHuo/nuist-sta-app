import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import 'free_classroom_models.dart';

/// 空教室小程序的本地存储：上次选的教学楼 + 教学楼列表缓存，放在应用文档目录
/// 下的 `free_classroom/`。教室占用随时在变，不落盘，只在内存里按次缓存。
class FreeClassroomStore {
  FreeClassroomStore._();
  static final _log = AppLog.logger('free_classroom.store');

  static const _prefsFile = 'prefs.json';
  static const _buildingsFile = 'buildings.json';

  static Future<File?> _file(String name) async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${base.path}${Platform.pathSeparator}free_classroom',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$name');
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<Object?> _readJson(String name) => _log.inSpan(() async {
    final file = await _file(name);
    if (file == null || !await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } catch (error, stackTrace) {
      _log.warning('cache.read_failed', error: error, stackTrace: stackTrace);
      return null;
    }
  });

  static Future<void> _writeJson(String name, Object data) =>
      _log.inSpan(() async {
        final file = await _file(name);
        if (file == null) return;
        try {
          await file.writeAsString(jsonEncode(data), flush: true);
        } catch (error, stackTrace) {
          _log.warning(
            'cache.write_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      });

  /// 上次查询的教学楼；没选过返回 null。
  static Future<Building?> readBuilding() async {
    final json = await _readJson(_prefsFile);
    if (json is! Map<String, dynamic>) return null;
    final building = json['building'];
    if (building is! Map<String, dynamic>) return null;
    final parsed = Building.fromJson(building);
    return parsed.code.isEmpty ? null : parsed;
  }

  static Future<void> saveBuilding(Building building) =>
      _writeJson(_prefsFile, {'building': building.toJson()});

  static Future<List<Building>?> readBuildings() async {
    final json = await _readJson(_buildingsFile);
    if (json is! List) return null;
    final list = [
      for (final item in json)
        if (item is Map<String, dynamic>) Building.fromJson(item),
    ];
    return list.isEmpty ? null : list;
  }

  static Future<void> saveBuildings(List<Building> buildings) =>
      _writeJson(_buildingsFile, [for (final b in buildings) b.toJson()]);
}
