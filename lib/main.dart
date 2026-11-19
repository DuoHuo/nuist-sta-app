import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/auth/portal_http.dart';
import 'core/config/campus_config.dart';
import 'core/logging/app_log.dart';
import 'core/theme_mode.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  portalEventLogger = (event, fields) =>
      AppLog.logger('core.auth.portal').debug(event, fields: fields);
  AppLog.installErrorHandlers();
  // 配置解码异常会让所有校内地址拼成非法 URL，开发期直接断言拦下。
  assert(kCampusRootDomain.isNotEmpty, '校园根域配置为空');
  // 首帧前读入手动选择的明暗，避免先按系统主题绘制一帧再切换造成闪屏；
  // 读取异常缓慢时不阻塞启动，读到后仍会切换。
  await AppThemeMode.instance.load().timeout(
    const Duration(milliseconds: 300),
    onTimeout: () {},
  );
  runApp(const NuistApp());
  // 日志轮转和旧附件恢复不阻塞首帧；初始化前事件由日志出口按序暂存。
  unawaited(AppLog.initialize());
}
