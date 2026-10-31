import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import 'score_models.dart';

/// 成绩本地缓存：`scores/report.json`。
///
/// 成绩不是凭据，放普通应用文档目录即可；读写失败时退化成无缓存，不影响
/// widget 测试和首次在线查询。
class ScoreStore {
  ScoreStore._();
  static final _log = AppLog.logger('score.store');

  static Future<File?> _file() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}scores');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}report.json');
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      return null;
    }
  }

  static Future<ScoreReport?> read() => _log.inSpan(() async {
    final file = await _file();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final report = ScoreReport.fromJson(decoded);
      if (report.fetchedAt.millisecondsSinceEpoch == 0) return null;
      return report;
    } catch (error, stackTrace) {
      _log.warning('cache.read_failed', error: error, stackTrace: stackTrace);
      return null;
    }
  });

  static Future<void> save(ScoreReport report) => _log.inSpan(() async {
    final file = await _file();
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(report.toJson()), flush: true);
    } catch (error, stackTrace) {
      _log.warning('cache.write_failed', error: error, stackTrace: stackTrace);
    }
  });
}
