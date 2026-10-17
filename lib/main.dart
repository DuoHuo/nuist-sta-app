import 'package:flutter/material.dart';

import 'app.dart';
import 'core/config/campus_config.dart';

void main() {
  // 配置解码异常会让所有校内地址拼成非法 URL，开发期直接断言拦下。
  assert(kCampusRootDomain.isNotEmpty, '校园根域配置为空');
  runApp(const NuistApp());
}
