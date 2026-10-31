import 'package:flutter/material.dart';

import 'app.dart';
import 'core/auth/portal_http.dart';
import 'core/config/campus_config.dart';
import 'core/logging/app_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.initialize();
  portalEventLogger = (event, fields) =>
      AppLog.logger('core.auth.portal').debug(event, fields: fields);
  AppLog.installErrorHandlers();
  // 配置解码异常会让所有校内地址拼成非法 URL，开发期直接断言拦下。
  assert(kCampusRootDomain.isNotEmpty, '校园根域配置为空');
  runApp(const NuistApp());
}
