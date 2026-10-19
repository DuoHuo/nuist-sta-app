import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 「我的」页的功能入口行数据。
class ProfileTile {
  const ProfileTile({required this.icon, required this.label, this.trailing});

  final IconData icon;
  final String label;

  /// 右侧灰色状态文字（如「已绑定」），没有则只显示箭头。
  final String? trailing;
}

/// 「我的」页的功能入口行。外层卡片需用 Material 画底色，水波纹才可见。
class ProfileListTile extends StatelessWidget {
  const ProfileListTile({
    super.key,
    required this.tile,
    required this.showDivider,
    required this.onTap,
  });

  final ProfileTile tile;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 52,
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 24,
                    child: Center(
                      child: Icon(
                        tile.icon,
                        color: palette.labelText,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tile.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.titleText,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (tile.trailing != null) ...[
                    Text(
                      tile.trailing!,
                      style: TextStyle(color: palette.hint, fontSize: 13),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(Icons.chevron_right, color: palette.chevron),
                ],
              ),
            ),
          ),
          if (showDivider)
            Divider(height: 1, indent: 52, color: palette.rowDivider),
        ],
      ),
    );
  }
}
