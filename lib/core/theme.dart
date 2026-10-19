import 'package:flutter/material.dart';

import 'colors.dart';

/// 浅色主题。
ThemeData appLightTheme() => _buildTheme(Brightness.light);

/// 深色主题。
ThemeData appDarkTheme() => _buildTheme(Brightness.dark);

/// 按明暗构造主题。
///
/// 两套主题只有色板不同，结构保持一致，避免明暗下控件尺寸、圆角出现差异。
/// 色板挂在 `extensions` 上，业务代码用 [AppPalette.of] 取。
ThemeData _buildTheme(Brightness brightness) {
  final palette = AppPalette.forBrightness(brightness);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    // 品牌色不走 M3 seed 推导：seed 会把 primary 调成算法生成的近似色，
    // 和设计稿的 accent 对不上。这里直接指定 primary / surface。
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: brightness,
        ).copyWith(
          primary: palette.accent,
          surface: palette.surface,
          error: palette.danger,
        ),
    scaffoldBackgroundColor: palette.pageBg,
    dividerColor: palette.divider,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: palette.titleText,
      centerTitle: true,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: palette.titleText,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[palette],
  );
}
