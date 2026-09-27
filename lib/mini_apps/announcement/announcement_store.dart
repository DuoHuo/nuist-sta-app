import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'announcement_models.dart';

/// 在应用文档目录中保存公告缓存和订阅状态。
class AnnouncementStore {
  /// 创建公告存储，可注入应用目录解析器。
  AnnouncementStore({Future<Directory?> Function()? resolveDirectory})
    : _resolveDirectory = resolveDirectory ?? _applicationDirectory;

  static const _fileName = 'announcements.json';
  final Future<Directory?> Function() _resolveDirectory;

  static Future<Directory?> _applicationDirectory() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  Future<File?> _file() async {
    try {
      final base = await _resolveDirectory();
      if (base == null) return null;
      final directory = Directory(
        '${base.path}${Platform.pathSeparator}announcements',
      );
      if (!await directory.exists()) await directory.create(recursive: true);
      return File('${directory.path}${Platform.pathSeparator}$_fileName');
    } catch (_) {
      return null;
    }
  }

  /// 读取本地数据；不可用时返回空数据。
  Future<AnnouncementLocalData> read() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) {
        return const AnnouncementLocalData();
      }
      final json = jsonDecode(await file.readAsString());
      return AnnouncementLocalData.fromJson(
        json is Map<String, dynamic> ? json : null,
      );
    } catch (_) {
      return const AnnouncementLocalData();
    }
  }

  /// 保存本地数据；存储不可用时安静降级。
  Future<void> save(AnnouncementLocalData data) async {
    try {
      final file = await _file();
      if (file == null) return;
      await file.writeAsString(jsonEncode(data.toJson()), flush: true);
    } catch (_) {}
  }
}
