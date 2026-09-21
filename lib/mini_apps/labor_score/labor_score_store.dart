import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'labor_score_models.dart';

/// 劳动积分的本地缓存：只存最近一次结果，放在应用文档目录下的
/// `labor_score/score.json`。数据不敏感，不占安全存储。
class LaborScoreStore {
  LaborScoreStore._();

  static const _file = 'score.json';

  static Future<File?> _resolve() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}labor_score');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_file');
    } catch (_) {
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<LaborScore?> read() async {
    final file = await _resolve();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final fetchedAt = DateTime.tryParse(
        decoded['fetchedAt']?.toString() ?? '',
      );
      if (fetchedAt == null) return null;
      return LaborScore.fromJson(decoded, fetchedAt: fetchedAt);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(LaborScore score) async {
    final file = await _resolve();
    if (file == null) return;
    await file.writeAsString(jsonEncode(score.toJson()), flush: true);
  }
}
