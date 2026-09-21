import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 空教室小程序的主色。
const kClassroomColor = Color(0xFF722ED1);

/// 白底圆角卡。用 Material 而不是 Container 画底色，内部 InkWell 的水波纹
/// 才不会被底色盖住。
class ClassroomCard extends StatelessWidget {
  const ClassroomCard({super.key, required this.child, this.borderRadius});

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
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
    final Color bg;
    final Color fg;
    if (selected) {
      bg = kClassroomColor.withValues(alpha: 0.12);
      fg = kClassroomColor;
    } else if (muted) {
      bg = const Color(0xFFF7F8FA);
      fg = const Color(0xFFC9CDD4);
    } else {
      bg = AppColors.pageBg;
      fg = AppColors.labelText;
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
