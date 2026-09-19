import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_session.dart';
import '../../core/wip.dart';
import 'profile_list_tile.dart';
import 'user_card.dart';

/// 「我的」页。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const _wipTiles = <ProfileTile>[
    ProfileTile(icon: Icons.groups, label: '我的社团'),
    ProfileTile(icon: Icons.event, label: '我的活动'),
    ProfileTile(icon: Icons.settings_outlined, label: '设置'),
    ProfileTile(icon: Icons.info_outline, label: '关于'),
  ];

  // null = 还没读到安全存储的结果。
  bool? _portalBound;

  @override
  void initState() {
    super.initState();
    _loadPortalBound();
  }

  Future<void> _loadPortalBound() async {
    final bundle = await PasskeyStore.read();
    if (mounted) setState(() => _portalBound = bundle != null);
  }

  Future<void> _openPortalBind() async {
    await context.push('/portal-bind');
    _loadPortalBound();
  }

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
                // 凭据被门户拒绝过的话，这一行要能看出来，否则用户只会觉得
                // 「明明绑了，功能却用不了」。
                ValueListenableBuilder<PortalCredentialError?>(
                  valueListenable: PortalSession.instance.credentialError,
                  builder: (context, credentialError, _) => ProfileListTile(
                    tile: ProfileTile(
                      icon: Icons.verified_user_outlined,
                      label: '绑定统一门户',
                      trailing: switch (_portalBound) {
                        null => null,
                        true => credentialError == null ? '已绑定' : '已失效',
                        false => '未绑定',
                      },
                    ),
                    showDivider: true,
                    onTap: _openPortalBind,
                  ),
                ),
                for (final tile in _wipTiles)
                  ProfileListTile(
                    tile: tile,
                    showDivider: tile != _wipTiles.last,
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
