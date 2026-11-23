import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/app_directories.dart';
import '../../core/logging/app_log.dart';
import 'campus_map_source.dart';

/// 校园快照的本地缓存：打开页面先展示缓存秒开，网络返回后再刷新落盘
/// （stale-while-revalidate）。缓存损坏或版本不符一律视为未命中。
class CampusMapCache {
  static const _version = 1;
  static final _log = AppLog.logger('campus_map.store');

  Future<File> _file(String key) async {
    final dir = await AppDirectories.applicationDocuments();
    return File('${dir.path}/campus_map_snapshot_$key.json');
  }

  Future<CampusMapSnapshot?> read(String key) => _log.inSpan(() async {
    try {
      final file = await _file(key);
      if (!await file.exists()) return null;
      return await compute(_decodeSnapshot, await file.readAsString());
    } catch (error, stackTrace) {
      _log.warning(
        'snapshot.read_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  });

  Future<void> write(String key, CampusMapSnapshot snapshot) =>
      _log.inSpan(() async {
        try {
          final file = await _file(key);
          // 几何可达数 MB，模型遍历和 JSON 编码都在后台完成，不阻塞地图首帧。
          final raw = await compute(_encodeSnapshot, snapshot);
          await file.writeAsString(raw);
        } catch (error, stackTrace) {
          _log.warning(
            'snapshot.write_failed',
            error: error,
            stackTrace: stackTrace,
          );
          // 落盘失败不影响正常加载
        }
      });
}

CampusMapSnapshot? _decodeSnapshot(String contents) {
  final raw = jsonDecode(contents);
  if (raw is! Map || raw['version'] != CampusMapCache._version) return null;
  final data = raw['data'];
  if (data is! Map) return null;
  return CampusMapSnapshot.fromJson(Map<String, dynamic>.from(data));
}

String _encodeSnapshot(CampusMapSnapshot snapshot) => jsonEncode({
  'version': CampusMapCache._version,
  'cachedAt': DateTime.now().toIso8601String(),
  'data': snapshot.toJson(),
});
