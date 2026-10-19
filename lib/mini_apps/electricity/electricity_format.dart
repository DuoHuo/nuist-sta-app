import 'package:flutter/material.dart';

import '../../core/colors.dart';

// 时间格式化已上收到 core，这里转发一份，电费页面的 import 不用改。
export '../../core/time_format.dart' show formatShortTime, formatFullTime;

/// 电费小程序自己的配色。
///
/// 浅色取值与设计稿一致（也就是 [AppColors] 的那两个语义色），深色下跟随
/// [AppPalette] 提亮，所以这里只做一层按色板取值的转发：调用方用
/// [ElecColors.of] 拿到一份配色，不必在各处自己判断明暗。
@immutable
class ElecColors {
  const ElecColors._({required this.warning, required this.danger});

  /// 低电量 / 警戒线。
  final Color warning;

  /// 已欠费（余额为负）。
  final Color danger;

  /// 按当前色板取电费配色；[palette] 由 `AppPalette.of(context)` 得到。
  factory ElecColors.of(AppPalette palette) =>
      ElecColors._(warning: palette.warning, danger: palette.danger);
}

/// 「23.45」：最多两位小数，去掉无意义的尾零。
String formatKwh(double kwh) {
  final s = kwh.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}
