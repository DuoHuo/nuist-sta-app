import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'logging/app_log.dart';

/// App 的明暗模式：跟随系统 / 浅色 / 深色。
///
/// 全局单例，[NuistApp] 监听它切换 `MaterialApp.themeMode`。选择存在应用支持
/// 目录的 `settings/theme_mode`，内容就是 [ThemeMode.name]。数据不敏感，不占安全存储。
class AppThemeMode extends ValueNotifier<ThemeMode> {
  AppThemeMode._() : super(ThemeMode.system);

  static final instance = AppThemeMode._();
  static final _log = AppLog.logger('core.theme_mode');

  static const _fileName = 'theme_mode';

  static Future<File?> _file() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}settings');
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}$_fileName');
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      // widget 测试等没有平台通道的环境，退化成「没有存储」。
      return null;
    }
  }

  /// 冷启动读一次本地选择；读不到保持跟随系统。
  Future<void> load() async {
    final file = await _file();
    if (file == null || !await file.exists()) return;
    try {
      final name = (await file.readAsString()).trim();
      value = ThemeMode.values.firstWhere(
        (m) => m.name == name,
        orElse: () => ThemeMode.system,
      );
    } catch (error, stackTrace) {
      _log.warning('load_failed', error: error, stackTrace: stackTrace);
      // 文件损坏就当没选过。
    }
  }

  /// 切换并落盘。界面先变，写盘失败不回滚。
  Future<void> set(ThemeMode mode) async {
    if (mode == value) return;
    value = mode;
    final file = await _file();
    if (file == null) return;
    try {
      await file.writeAsString(mode.name, flush: true);
    } catch (error, stackTrace) {
      _log.warning('save_failed', error: error, stackTrace: stackTrace);
    }
  }
}
