import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'innovation_credit_models.dart';

/// 双创学分的本地缓存：只存最近一次结果，放在应用文档目录下的
/// `innovation_credit/credit.json`。数据不敏感，不占安全存储。
class InnovationCreditStore {
  InnovationCreditStore._();

  static const _file = 'credit.json';

  static Future<File?> _resolve() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${base.path}${Platform.pathSeparator}innovation_credit',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_file');
    } catch (_) {
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<InnovationCredit?> read() async {
    final file = await _resolve();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final fetchedAt = DateTime.tryParse(
        decoded['fetchedAt']?.toString() ?? '',
      );
      if (fetchedAt == null) return null;
      return InnovationCredit.fromJson(decoded, fetchedAt: fetchedAt);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(InnovationCredit credit) async {
    final file = await _resolve();
    if (file == null) return;
    await file.writeAsString(jsonEncode(credit.toJson()), flush: true);
  }
}
