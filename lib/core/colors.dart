import 'package:flutter/material.dart';

/// 与设计稿 design/home.op 保持一致的颜色，作为**浅色基准**。
///
/// 业务代码请改用 [AppPalette.of]，它会跟随系统明暗返回对应色值；
/// 这里的常量只用于构造主题、以及确实需要 `const` 的浅色场景。
abstract final class AppColors {
  static const pageBg = Color(0xFFF5F6F8);
  static const surface = Color(0xFFFFFFFF);
  static const titleText = Color(0xFF171A1F);
  static const labelText = Color(0xFF4A4F66);
  static const hint = Color(0xFF9AA0B4);
  static const rowDivider = Color(0xFFF0F1F3);
  static const accent = Color(0xFF0082EF);
  static const tabInactive = Color(0xFF8A8F99);
  static const divider = Color(0xFFE5E6EB);

  /// 列表行右侧箭头，比 [hint] 更淡。
  static const chevron = Color(0xFFC9CDD4);

  // 状态语义色：审核通过 / 待审核·未确认 / 驳回·欠费之类。
  static const success = Color(0xFF00B42A);
  static const warning = Color(0xFFFF7D00);
  static const danger = Color(0xFFF53F3F);
}

/// 深色色值，与 [AppColors] 一一对应。
///
/// 取值沿用 `TimetableTheme` 里预留的那套暗色 token，保证课表与其余页面同色。
abstract final class AppColorsDark {
  static const pageBg = Color(0xFF121316);
  static const surface = Color(0xFF1C1D21);
  static const titleText = Color(0xFFF2F3F5);
  static const labelText = Color(0xFFC8CBD2);
  static const hint = Color(0xFF8A8F99);
  static const rowDivider = Color(0xFF24262B);
  static const accent = Color(0xFF4DA3F5);
  static const tabInactive = Color(0xFF8A8F99);
  static const divider = Color(0xFF2A2C32);

  /// 深色下设计稿那个浅灰箭头会过亮，压到与 hint 同级。
  static const chevron = Color(0xFF6E7480);

  // 语义色在深色下保持色相，仅提亮以保证对比度。
  static const success = Color(0xFF23C343);
  static const warning = Color(0xFFFF9A2E);
  static const danger = Color(0xFFF76965);
}

/// 随主题明暗切换的色板。
///
/// 挂在 `ThemeData.extensions` 上，用 `AppPalette.of(context)` 取：
///
/// ```dart
/// final palette = AppPalette.of(context);
/// Text('…', style: TextStyle(color: palette.hint));
/// ```
///
/// 取不到扩展时（例如测试里单独 pump 一个没带主题的页面）退化成浅色，
/// 不抛异常。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.pageBg,
    required this.surface,
    required this.titleText,
    required this.labelText,
    required this.hint,
    required this.rowDivider,
    required this.accent,
    required this.tabInactive,
    required this.divider,
    required this.chevron,
    required this.success,
    required this.warning,
    required this.danger,
  });

  /// 这套色板对应的明暗，供少数需要按明暗分叉的逻辑判断（如图表、阴影）。
  final Brightness brightness;

  /// 页面底色。
  final Color pageBg;

  /// 卡片 / 顶栏 / 底栏等前景面的底色，浅色下是纯白。
  final Color surface;

  /// 主文字。
  final Color titleText;

  /// 次级文字、图标。
  final Color labelText;

  /// 占位、辅助说明文字。
  final Color hint;

  /// 列表行内分隔线，比 [divider] 更淡。
  final Color rowDivider;

  /// 品牌强调色。
  final Color accent;

  /// 底部页签未选中态。
  final Color tabInactive;

  /// 区块分隔线、描边。
  final Color divider;

  /// 列表行右侧箭头，比 [hint] 更淡。
  final Color chevron;

  /// 语义色：通过 / 正常。
  final Color success;

  /// 语义色：待处理 / 提醒。
  final Color warning;

  /// 语义色：失败 / 欠费。
  final Color danger;

  /// 是否为深色模式。
  bool get isDark => brightness == Brightness.dark;

  /// 浅色色板。
  static const light = AppPalette(
    brightness: Brightness.light,
    pageBg: AppColors.pageBg,
    surface: AppColors.surface,
    titleText: AppColors.titleText,
    labelText: AppColors.labelText,
    hint: AppColors.hint,
    rowDivider: AppColors.rowDivider,
    accent: AppColors.accent,
    tabInactive: AppColors.tabInactive,
    divider: AppColors.divider,
    chevron: AppColors.chevron,
    success: AppColors.success,
    warning: AppColors.warning,
    danger: AppColors.danger,
  );

  /// 深色色板。
  static const dark = AppPalette(
    brightness: Brightness.dark,
    pageBg: AppColorsDark.pageBg,
    surface: AppColorsDark.surface,
    titleText: AppColorsDark.titleText,
    labelText: AppColorsDark.labelText,
    hint: AppColorsDark.hint,
    rowDivider: AppColorsDark.rowDivider,
    accent: AppColorsDark.accent,
    tabInactive: AppColorsDark.tabInactive,
    divider: AppColorsDark.divider,
    chevron: AppColorsDark.chevron,
    success: AppColorsDark.success,
    warning: AppColorsDark.warning,
    danger: AppColorsDark.danger,
  );

  /// 取当前主题的色板；没挂扩展时退化成 [light]。
  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? light;

  /// 按 [brightness] 取对应色板。
  static AppPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? pageBg,
    Color? surface,
    Color? titleText,
    Color? labelText,
    Color? hint,
    Color? rowDivider,
    Color? accent,
    Color? tabInactive,
    Color? divider,
    Color? chevron,
    Color? success,
    Color? warning,
    Color? danger,
  }) {
    return AppPalette(
      brightness: brightness ?? this.brightness,
      pageBg: pageBg ?? this.pageBg,
      surface: surface ?? this.surface,
      titleText: titleText ?? this.titleText,
      labelText: labelText ?? this.labelText,
      hint: hint ?? this.hint,
      rowDivider: rowDivider ?? this.rowDivider,
      accent: accent ?? this.accent,
      tabInactive: tabInactive ?? this.tabInactive,
      divider: divider ?? this.divider,
      chevron: chevron ?? this.chevron,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
    );
  }

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      pageBg: Color.lerp(pageBg, other.pageBg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      titleText: Color.lerp(titleText, other.titleText, t)!,
      labelText: Color.lerp(labelText, other.labelText, t)!,
      hint: Color.lerp(hint, other.hint, t)!,
      rowDivider: Color.lerp(rowDivider, other.rowDivider, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      tabInactive: Color.lerp(tabInactive, other.tabInactive, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      chevron: Color.lerp(chevron, other.chevron, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}
