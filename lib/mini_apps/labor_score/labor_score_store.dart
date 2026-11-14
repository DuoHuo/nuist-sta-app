import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/refresh/silent_refresh.dart';
import 'labor_score_models.dart';

/// 劳动积分的本地缓存：只存最近一次结果，放在应用文档目录下的
/// `labor_score/score.json`。数据不敏感，不占安全存储。
class LaborScoreStore {
  LaborScoreStore._();
  static final _log = AppLog.logger('labor_score.store');

  static const _file = 'score.json';

  static Future<File?> _resolve() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}labor_score');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_file');
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<LaborScore?> read() => _log.inSpan(() async {
    try {
      final file = await _resolve();
      if (file == null || !await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('缓存顶层不是对象');
      }
      final fetchedAt = DateTime.tryParse(
        decoded['fetchedAt']?.toString() ?? '',
      );
      if (fetchedAt == null) return null;
      return LaborScore.fromJson(decoded, fetchedAt: fetchedAt);
    } catch (error, stackTrace) {
      _log.warning('cache.read_failed', error: error, stackTrace: stackTrace);
      return null;
    }
  });

  static Future<void> save(LaborScore score) => _log.inSpan(() async {
    final file = await _resolve();
    if (file == null) {
      SilentRefresh.degradeCurrent(reason: 'storage_unavailable');
      AppLog.reportOutcome('degraded', reason: 'storage_unavailable');
      return;
    }
    try {
      await file.writeAsString(jsonEncode(score.toJson()), flush: true);
    } catch (error, stackTrace) {
      SilentRefresh.degradeCurrent(reason: 'cache_write_failed');
      AppLog.reportOutcome('degraded', reason: 'cache_write_failed');
      _log.warning('cache.write_failed', error: error, stackTrace: stackTrace);
    }
  });
}
