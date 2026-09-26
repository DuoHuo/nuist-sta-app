import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'academic_models.dart';

/// 学业概览的本地缓存：只存最近一次结果，放在应用文档目录下的
/// `academic/summary.json`。数据不敏感，不占安全存储。
class AcademicStore {
  AcademicStore._();

  static const _summaryFile = 'summary.json';

  static Future<File?> _file() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}academic');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_summaryFile');
    } catch (_) {
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<AcademicSummary?> read() async {
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
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(AcademicSummary summary) async {
    final file = await _file();
    if (file == null) return;
    await file.writeAsString(jsonEncode(summary.toJson()), flush: true);
  }
}
