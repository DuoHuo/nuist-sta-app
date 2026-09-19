import 'package:flutter/material.dart';

/// 电费小程序自己的配色。
abstract final class ElecColors {
  /// 低电量 / 警戒线。
  static const warning = Color(0xFFFF7D00);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// 「23.45」：最多两位小数，去掉无意义的尾零。
String formatKwh(double kwh) {
  final s = kwh.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// 「09-19 14:32」，首页卡片右上角用。
String formatShortTime(DateTime t) =>
    '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// 「2026-09-19 14:32」。
String formatFullTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} '
    '${_two(t.hour)}:${_two(t.minute)}';
