import 'package:flutter/material.dart';

// 时间格式化已上收到 core，这里转发一份，电费页面的 import 不用改。
export '../../core/time_format.dart' show formatShortTime, formatFullTime;

/// 电费小程序自己的配色。
abstract final class ElecColors {
  /// 低电量 / 警戒线。
  static const warning = Color(0xFFFF7D00);

  /// 已欠费（余额为负）。
  static const danger = Color(0xFFF53F3F);
}

/// 「23.45」：最多两位小数，去掉无意义的尾零。
String formatKwh(double kwh) {
  final s = kwh.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}
