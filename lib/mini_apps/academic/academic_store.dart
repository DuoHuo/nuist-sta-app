import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import 'academic_models.dart';

/// 学业概览的本地缓存：只存最近一次结果，放在应用文档目录下的
/// `academic/summary.json`。数据不敏感，不占安全存储。
class AcademicStore {
  AcademicStore._();
  static final _log = AppLog.logger('academic.store');

  static const _summaryFile = 'summary.json';

  static Future<File?> _file() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}academic');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_summaryFile');
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<AcademicSummary?> read() => _log.inSpan(() async {
    final file = await _file();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final fetchedAt = DateTime.tryParse(
        decoded['fetchedAt']?.toString() ?? '',
      );
      if (fetchedAt == null) return null;
      return AcademicSummary.fromJson(decoded, fetchedAt: fetchedAt);
    } catch (error, stackTrace) {
      _log.warning('cache.read_failed', error: error, stackTrace: stackTrace);
      return null;
    }
  });

  static Future<void> save(AcademicSummary summary) => _log.inSpan(() async {
    final file = await _file();
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(summary.toJson()), flush: true);
    } catch (error, stackTrace) {
      _log.warning('cache.write_failed', error: error, stackTrace: stackTrace);
    }
  });
}
