import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'campus_map_source.dart';

/// 校园快照的本地缓存：打开页面先展示缓存秒开，网络返回后再刷新落盘
/// （stale-while-revalidate）。缓存损坏或版本不符一律视为未命中。
class CampusMapCache {
  static const _version = 1;

  Future<File> _file(String key) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/campus_map_snapshot_$key.json');
  }

  Future<CampusMapSnapshot?> read(String key) async {
    try {
      final file = await _file(key);
      if (!file.existsSync()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['version'] != _version) return null;
      final data = raw['data'];
      if (data is! Map) return null;
      return CampusMapSnapshot.fromJson(Map<String, dynamic>.from(data));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, CampusMapSnapshot snapshot) async {
    try {
      final file = await _file(key);
      await file.writeAsString(
        jsonEncode({
          'version': _version,
          'cachedAt': DateTime.now().toIso8601String(),
          'data': snapshot.toJson(),
        }),
      );
    } catch (_) {
      // 落盘失败不影响正常加载
    }
  }
}
