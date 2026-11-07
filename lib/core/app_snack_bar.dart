import 'package:flutter/material.dart';

import 'colors.dart';

/// 底部反馈的语义；由业务结果显式指定，不解析提示文案。
enum AppSnackBarTone { info, success, warning, error }

/// 统一的底部反馈，保留原生提示的队列、操作与自动收起行为。
class AppSnackBar extends SnackBar {
  AppSnackBar({
    super.key,
    required Widget content,
    AppSnackBarTone tone = AppSnackBarTone.info,
    super.duration,
    super.persist,
    super.action,
    super.behavior = SnackBarBehavior.floating,
  }) : super(
         content: AppSnackBarContent(tone: tone, child: content),
         // 按钮自带触达高度，正文自己留白，避免叠加整条提示的上下内边距。
         padding: const EdgeInsets.only(left: 16, right: 4),
         actionOverflowThreshold: 1,
       );
}

/// 提示正文：状态图标与可换行的文字；也供短暂的地图提示复用。
class AppSnackBarContent extends StatelessWidget {
  const AppSnackBarContent({
    super.key,
    required this.child,
    this.tone = AppSnackBarTone.info,
  });

  /// 提示文字。
  final Widget child;

  /// 反馈语义。
  final AppSnackBarTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final (icon, color) = switch (tone) {
      AppSnackBarTone.info => (Icons.info_outline_rounded, palette.accent),
      AppSnackBarTone.success => (
        Icons.check_circle_outline_rounded,
        palette.success,
      ),
      AppSnackBarTone.warning => (Icons.error_outline_rounded, palette.warning),
      AppSnackBarTone.error => (Icons.error_outline_rounded, palette.danger),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: DefaultTextStyle(
        style: TextStyle(color: palette.titleText, fontSize: 15, height: 1.35),
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
            const SizedBox(width: 10),
            Expanded(child: child),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// 从色板派生可读的操作蓝，供主题及独立提示使用。
Color appSnackBarActionColor(AppPalette palette) => palette.isDark
    ? palette.accent
    : Color.lerp(palette.accent, palette.titleText, 0.24)!;
