import 'package:flutter/material.dart';

import '../../core/wip.dart';
import 'profile_list_tile.dart';
import 'user_card.dart';

/// 「我的」页。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  static const _tiles = <ProfileTile>[
    ProfileTile(icon: Icons.groups, label: '我的社团'),
    ProfileTile(icon: Icons.event, label: '我的活动'),
    ProfileTile(icon: Icons.settings_outlined, label: '设置'),
    ProfileTile(icon: Icons.info_outline, label: '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          // 用户卡片：登录前展示占位态，接好账号体系后替换成真实资料。
          UserCard(onTap: () => showWipSnackBar(context, '登录')),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                for (final tile in _tiles)
                  ProfileListTile(
                    tile: tile,
                    showDivider: tile != _tiles.last,
                    onTap: () => showWipSnackBar(context, tile.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
