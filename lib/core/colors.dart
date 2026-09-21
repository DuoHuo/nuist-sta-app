import 'package:flutter/material.dart';

/// 与设计稿 design/home.op 保持一致的颜色。
abstract final class AppColors {
  static const pageBg = Color(0xFFF5F6F8);
  static const titleText = Color(0xFF171A1F);
  static const labelText = Color(0xFF4A4F66);
  static const hint = Color(0xFF9AA0B4);
  static const rowDivider = Color(0xFFF0F1F3);
  static const accent = Color(0xFF0082EF);
  static const tabInactive = Color(0xFF8A8F99);
  static const divider = Color(0xFFE5E6EB);

  // 状态语义色：审核通过 / 待审核·未确认 / 驳回·欠费之类。
  static const success = Color(0xFF00B42A);
  static const warning = Color(0xFFFF7D00);
  static const danger = Color(0xFFF53F3F);
}
