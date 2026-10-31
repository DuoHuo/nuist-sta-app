import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'app_log.dart';

/// 生成用户主动分享的单文件诊断日志，不执行任何网络上传。
class LogExportService {
  LogExportService._();

  static Future<File> createExport() async {
    String? version;
    String? buildNumber;
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
      buildNumber = info.buildNumber;
    } catch (_) {
      // 测试环境没有平台通道时省略版本信息。
    }
    final now = DateTime.now().toUtc();
    final metadata = <String, Object?>{
      'record_type': 'diagnostics_metadata',
      'exported_at': now.toIso8601String(),
      'log_format_version': AppLog.formatVersion,
      'app_version': ?version,
      'build_number': ?buildNumber,
      'platform': Platform.operatingSystem,
      'platform_version': _singleLine(Platform.operatingSystemVersion),
      'locale': Platform.localeName,
    };
    final file = await AppLog.createExport(metadata);
    AppLog.logger('app.logging')
        .info('export.created', fields: {'bytes': await file.length()});
    return file;
  }

  static String _singleLine(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    return cleaned.length <= 256 ? cleaned : cleaned.substring(0, 256);
  }
}
