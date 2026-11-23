import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/auth/portal_http.dart';
import 'core/config/campus_config.dart';
import 'core/logging/app_log.dart';
import 'core/privacy/privacy_consent.dart';
import 'core/theme_mode.dart';
import 'shell/profile/about/native_licenses.dart';

/// 首帧前并行预加载手动明暗设置与隐私政策选择，各自独立限时放行、互不拖累。
@visibleForTesting
Future<void> preloadBeforeFirstFrame({
  Future<void> Function()? loadThemeMode,
  Future<void> Function()? loadPrivacyConsent,
  Duration timeout = const Duration(milliseconds: 300),
}) => Future.wait<void>([
  (loadThemeMode ?? AppThemeMode.instance.load)().timeout(
    timeout,
    onTimeout: () {},
  ),
  (loadPrivacyConsent ?? PrivacyConsent.instance.load)().timeout(
    timeout,
    onTimeout: () {},
  ),
]);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  portalEventLogger = (event, fields) =>
      AppLog.logger('core.auth.portal').debug(event, fields: fields);
  AppLog.installErrorHandlers();
  registerNativeLicenses();
  // 配置解码异常会让所有校内地址拼成非法 URL，开发期直接断言拦下。
  assert(kCampusRootDomain.isNotEmpty, '校园根域配置为空');
  // 首帧前并行读入手动选择的明暗与隐私政策选择：
  // 明暗避免先按系统主题绘制一帧再切换造成闪屏，隐私在首个自有服务请求前生效；
  // 任一项读取异常缓慢时各自独立 300ms 超时放行、互不拖累，
  // 主题读到后仍会切换，隐私读取缓慢时按未选择处理（只发匿名元数据）。
  await preloadBeforeFirstFrame();
  runApp(const NuistApp());
  // 日志轮转和旧附件恢复不阻塞首帧；初始化前事件由日志出口按序暂存。
  unawaited(AppLog.initialize());
}
