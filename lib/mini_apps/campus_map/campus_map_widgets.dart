import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 地图小程序的界面配色，全部由 [AppPalette] 派生，随系统明暗切换。
///
/// 只管面板、浮层按钮、弹层、详情页这类 UI 外壳；原生底图和自绘图层的颜色在
/// `campus_map_native.dart` 里，底图素材目前只有浅色版，不随主题变。
@immutable
class MapPalette {
  const MapPalette._({
    required this.isDark,
    required this.blue,
    required this.ink,
    required this.secondary,
    required this.muted,
    required this.surface,
    required this.panel,
    required this.field,
    required this.line,
    required this.handle,
    required this.green,
    required this.shadow,
  });

  /// 按当前主题取地图配色。
  factory MapPalette.of(BuildContext context) =>
      MapPalette.from(AppPalette.of(context));

  /// 由 [palette] 派生；[palette] 通常来自 `AppPalette.of(context)`。
  factory MapPalette.from(AppPalette palette) => MapPalette._(
    isDark: palette.isDark,
    blue: palette.accent,
    ink: palette.titleText,
    secondary: palette.labelText,
    muted: palette.hint,
    surface: palette.pageBg,
    panel: palette.surface,
    field: Color.alphaBlend(
      palette.titleText.withValues(alpha: palette.isDark ? .08 : .05),
      palette.surface,
    ),
    line: palette.divider,
    handle: palette.chevron,
    green: palette.success,
    shadow: palette.isDark ? const Color(0x66000000) : const Color(0x14252F3D),
  );

  /// 是否为深色模式。
  final bool isDark;

  /// 强调色：选中态、主按钮、链接。
  final Color blue;

  /// 主文字。
  final Color ink;

  /// 次级文字、图标。
  final Color secondary;

  /// 更淡的占位图标。
  final Color muted;

  /// 页面 / 弹层底色。
  final Color surface;

  /// 浮在地图上的卡片、面板、列表项底色。
  final Color panel;

  /// 输入框、图片占位这类凹陷区域的底色。
  final Color field;

  /// 描边、分隔线。
  final Color line;

  /// 面板顶部拖动条。
  final Color handle;

  /// 「有室内图」等正向标签。
  final Color green;

  /// 浮层投影。
  final Color shadow;
}

class MapSurface extends StatelessWidget {
  const MapSurface({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.panel.withValues(alpha: .97),
        borderRadius: BorderRadius.circular(radius),
        // 深色下面板压在浅色底图上，用细描边代替浅色下的白边勾出轮廓。
        border: Border.all(
          color: colors.isDark
              ? colors.line
              : colors.panel.withValues(alpha: .9),
        ),
        boxShadow: [
          BoxShadow(
            color: colors.shadow,
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Material(
          color: Colors.transparent,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class MapIconButton extends StatelessWidget {
  const MapIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.color,
    this.busy = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;
  final Color? color;

  /// 进行中：显示进度圈并禁止重复触发，但不改变按钮配色。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      isSelected: active,
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: color ?? (active ? colors.blue : colors.ink),
        backgroundColor: active
            ? colors.blue.withValues(alpha: colors.isDark ? .18 : .09)
            : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            )
          : Icon(icon, size: 23),
    );
  }
}

class MapAction extends StatelessWidget {
  const MapAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = MapPalette.of(context);
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 21),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        backgroundColor: primary
            ? colors.blue
            : colors.blue.withValues(alpha: colors.isDark ? .18 : .09),
        // 品牌色实心按钮上的白字，底色不随主题变，所以字色也固定白色。
        foregroundColor: primary ? Colors.white : colors.blue,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    );
  }
}

class MapSectionTitle extends StatelessWidget {
  const MapSectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -.3,
          ),
        ),
      ),
      ?trailing,
    ],
  );
}
