import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 空教室小程序的主色。
///
/// 两套主题下都用同一个紫：它既要当实心块的底色（上面压白字），又要当
/// 12% 透明的淡底与前景文字，提亮会让实心态上的白字对比度掉下来，所以
/// 这里不随明暗变。
const kClassroomColor = Color(0xFF722ED1);

/// 空教室小程序里几处「置灰 / 占用」的填充色。
///
/// 浅色沿用设计稿的浅灰，深色下浅灰会亮过卡片底色，改成按色板取分隔线级别
/// 的灰。集中放在这里，调用方只传 [AppPalette]，不必各自判断明暗。
abstract final class ClassroomFillColors {
  /// 置灰标签、已过时段格的底色。
  static Color muted(AppPalette palette) =>
      palette.isDark ? palette.rowDivider : const Color(0xFFF7F8FA);

  /// 置灰态的前景文字与图标。
  static Color mutedForeground(AppPalette palette) => palette.chevron;

  /// 「所选时段全被占用」状态格的底色，比 [muted] 再深一档。
  static Color busy(AppPalette palette) =>
      palette.isDark ? palette.divider : const Color(0xFFEDEFF2);
}

/// 圆角卡，底色取当前色板的 surface。用 Material 而不是 Container 画底色，
/// 内部 InkWell 的水波纹才不会被底色盖住。
class ClassroomCard extends StatelessWidget {
  const ClassroomCard({super.key, required this.child, this.borderRadius});

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.of(context).surface,
      borderRadius: borderRadius ?? BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 紧凑的可选标签，宽度随文字。
///
/// 不能给 Container 设 alignment：在 Wrap / Row 给的宽松约束下它会把标签
/// 撑满整行。
class ClassroomChip extends StatelessWidget {
  const ClassroomChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.muted = false,
    this.dropdown = false,
  });

  final String label;
  final bool selected;

  /// 置灰并划掉，用于今天已经过去的时段。
  final bool muted;

  /// 尾部带下拉箭头，表示点开是个面板而不是直接切换。
  final bool dropdown;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final Color bg;
    final Color fg;
    if (selected) {
      bg = kClassroomColor.withValues(alpha: 0.12);
      fg = kClassroomColor;
    } else if (muted) {
      bg = ClassroomFillColors.muted(palette);
      fg = ClassroomFillColors.mutedForeground(palette);
    } else {
      bg = palette.pageBg;
      fg = palette.labelText;
    }
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 28,
        padding: EdgeInsets.only(left: 10, right: dropdown ? 6 : 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: fg,
                decoration: muted && !selected
                    ? TextDecoration.lineThrough
                    : null,
                decorationColor: fg,
              ),
            ),
            if (dropdown) Icon(Icons.expand_more, size: 16, color: fg),
          ],
        ),
      ),
    );
  }
}
