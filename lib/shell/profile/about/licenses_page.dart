import 'package:flutter/material.dart';

import '../../../core/app_info.dart';

/// 开源许可页：列出 Flutter 自动收集的 Dart 依赖许可证，以及 [registerNativeLicenses]
/// 登记的原生组件。
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const LicensePage(applicationName: kAppName);
  }
}
