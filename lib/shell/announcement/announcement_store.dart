import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import 'announcement_models.dart';

/// 公告本地存储，放在应用文档目录下的 `announcement/`：
/// `cache.json`（列表 + 校验头）与 `read_ids.json`（已读 id）分开存。
/// 所有读写失败都退化成「没有存储」。
abstract final class AnnouncementStore {
  static final _log = AppLog.logger('shell.announcement.store');

  static Future<File?> _file(String name) async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${base.path}${Platform.pathSeparator}announcement',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$name');
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      // widget 测试等没有平台通道的环境。
      return null;
    }
  }

  /// 读缓存；不存在或损坏返回 null。
  static Future<AnnouncementCache?> readCache() async {
    try {
      final file = await _file('cache.json');
      if (file == null || !await file.exists()) return null;
      return AnnouncementCache.fromJson(jsonDecode(await file.readAsString()));
    } catch (error, stackTrace) {
      _log.warning('cache.read_failed', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// 写缓存，失败静默。
  static Future<void> saveCache(AnnouncementCache cache) async {
    try {
      final file = await _file('cache.json');
      if (file == null) return;
      await file.writeAsString(jsonEncode(cache.toJson()), flush: true);
    } catch (error, stackTrace) {
      _log.warning('cache.write_failed', error: error, stackTrace: stackTrace);
    }
  }

  /// 删除缓存，失败静默。
  static Future<void> clearCache() async {
    try {
      final file = await _file('cache.json');
      if (file != null && await file.exists()) await file.delete();
    } catch (error, stackTrace) {
      _log.warning('cache.clear_failed', error: error, stackTrace: stackTrace);
    }
  }

  /// 读已读 id；失败返回空集。
  static Future<Set<String>> readReadIds() async {
    try {
      final file = await _file('read_ids.json');
      if (file == null || !await file.exists()) return <String>{};
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return <String>{};
      return raw.whereType<String>().toSet();
    } catch (error, stackTrace) {
      _log.warning(
        'read_state.read_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return <String>{};
    }
  }

  /// 写已读 id，失败静默。
  static Future<void> saveReadIds(Set<String> ids) async {
    try {
      final file = await _file('read_ids.json');
      if (file == null) return;
      await file.writeAsString(jsonEncode(ids.toList()), flush: true);
    } catch (error, stackTrace) {
      _log.warning(
        'read_state.write_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
