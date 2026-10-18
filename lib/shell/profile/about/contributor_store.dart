import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'contributor_models.dart';

/// 贡献者名单的本地缓存，放在应用文档目录下的 `about/contributors.json`。
class ContributorStore {
  const ContributorStore();

  static const _fileName = 'contributors.json';

  Future<File?> _file() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}about');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_fileName');
    } catch (_) {
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  Future<ContributorCache?> read() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return null;
      return ContributorCache.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(ContributorCache cache) async {
    try {
      final file = await _file();
      if (file == null) return;
      await file.writeAsString(jsonEncode(cache.toJson()), flush: true);
    } catch (_) {
      // 写不进去就算了，下次打开再拉。
    }
  }
}
