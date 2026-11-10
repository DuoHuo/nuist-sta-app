import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';

/// 只持久化检查时间与已读修订；稍后提醒仅在当前进程生效。
class UpdatePreferences {
  const UpdatePreferences({this.lastAttempt, this.readRevision});

  final DateTime? lastAttempt;
  final String? readRevision;

  factory UpdatePreferences.fromJson(Object? value) {
    if (value is! Map) return const UpdatePreferences();
    DateTime? date(String key) =>
        value[key] is String ? DateTime.tryParse(value[key]) : null;
    return UpdatePreferences(
      lastAttempt: date('lastAttempt'),
      readRevision: value['readRevision'] is String
          ? value['readRevision']
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'lastAttempt': lastAttempt?.toUtc().toIso8601String(),
    'readRevision': readRevision,
  };
}

/// 更新偏好存储失败时退化为本次进程内状态。
class UpdateStore {
  static final _log = AppLog.logger('shell.update.store');
  static Future<void> _writing = Future.value();

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/updates');
    await dir.create(recursive: true);
    return File('${dir.path}/preferences.json');
  }

  static Future<UpdatePreferences> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const UpdatePreferences();
      return UpdatePreferences.fromJson(jsonDecode(await file.readAsString()));
    } catch (error, stackTrace) {
      _log.warning('cache.read_failed', error: error, stackTrace: stackTrace);
      return const UpdatePreferences();
    }
  }

  /// 同进程顺序写入，保留最新的检查时间与已读记录。
  static Future<void> save(UpdatePreferences value) =>
      _writing = _writing.then((_) async {
        try {
          final file = await _file();
          await file.writeAsString(jsonEncode(value.toJson()), flush: true);
        } catch (error, stackTrace) {
          _log.warning(
            'cache.write_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      });
}
