import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'score_models.dart';

/// 成绩本地缓存：`scores/report.json`。
///
/// 成绩不是凭据，放普通应用文档目录即可；读写失败时退化成无缓存，不影响
/// widget 测试和首次在线查询。
class ScoreStore {
  ScoreStore._();

  static Future<File?> _file() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}scores');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}report.json');
    } catch (_) {
      return null;
    }
  }

  static Future<ScoreReport?> read() async {
    final file = await _file();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final report = ScoreReport.fromJson(decoded);
      if (report.fetchedAt.millisecondsSinceEpoch == 0) return null;
      return report;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(ScoreReport report) async {
    final file = await _file();
    if (file == null) return;
    await file.writeAsString(jsonEncode(report.toJson()), flush: true);
  }
}
