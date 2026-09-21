import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'student_info_models.dart';

/// 学生卡的本地缓存：只存最近一次结果，放在应用文档目录下的
/// `student_info/profile.json`。只有姓名、学号、院系班级和校历，不进安全存储。
class StudentInfoStore {
  StudentInfoStore._();

  static const _file = 'profile.json';

  static Future<File?> _resolve() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${base.path}${Platform.pathSeparator}student_info',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_file');
    } catch (_) {
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  static Future<StudentInfo?> read() async {
    final file = await _resolve();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final fetchedAt = DateTime.tryParse(
        decoded['fetchedAt']?.toString() ?? '',
      );
      if (fetchedAt == null) return null;
      return StudentInfo.fromJson(decoded, fetchedAt: fetchedAt);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(StudentInfo info) async {
    final file = await _resolve();
    if (file == null) return;
    await file.writeAsString(jsonEncode(info.toJson()), flush: true);
  }
}
