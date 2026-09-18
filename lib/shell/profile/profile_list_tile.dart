import 'package:flutter/material.dart';

import '../../core/colors.dart';

/// 「我的」页的功能入口行数据。
class ProfileTile {
  const ProfileTile({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 「我的」页的功能入口行。
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
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                Icon(tile.icon, color: AppColors.labelText, size: 20),
                const SizedBox(width: 12),
                Text(
                  tile.label,
                  style: const TextStyle(
                    color: Color(0xFF1F2329),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
              ],
            ),
          ),
          if (showDivider)
            const Divider(height: 1, color: AppColors.rowDivider),
        ],
      ),
    );
  }
}
