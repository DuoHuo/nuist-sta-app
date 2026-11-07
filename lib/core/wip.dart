import 'package:flutter/material.dart';

import 'app_snack_bar.dart';

/// 未实现功能的统一占位反馈。
void showWipSnackBar(BuildContext context, String label) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(AppSnackBar(content: Text('「$label」开发中')));
}
