import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/passkey_store.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_session.dart';
import '../../core/auth/student_id_mask.dart';
import '../../core/colors.dart';
import 'profile_list_tile.dart';
import 'user_card.dart';

/// 「我的」页。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const _settingsTile = ProfileTile(
    icon: Icons.settings_outlined,
    label: '设置',
  );
  static const _aboutTile = ProfileTile(icon: Icons.info_outline, label: '关于');

  // null = 还没读到安全存储的结果。
  bool? _portalBound;
  // 只存脱敏后的学号，原文不留在状态里，也绝不打印。
  String? _maskedStudentId;

  @override
  void initState() {
    super.initState();
    _loadPortalBound();
  }

  Future<void> _loadPortalBound() async {
    final bundle = await PasskeyStore.read();
    final id = bundle?.studentId;
    if (mounted) {
      setState(() {
        _portalBound = bundle != null;
        _maskedStudentId = id == null ? null : maskStudentId(id);
      });
    }
  }

  Future<void> _openPortalBind() async {
    await context.push('/portal-bind');
    _loadPortalBound();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          // 凭据被门户拒绝过的话，表头要能看出来，否则用户只会觉得
          // 「明明绑了，功能却用不了」。
          ValueListenableBuilder<PortalCredentialError?>(
            valueListenable: PortalSession.instance.credentialError,
            builder: (context, credentialError, _) => PortalStatusCard(
              bound: _portalBound,
              maskedStudentId: _maskedStudentId,
              revoked: credentialError != null,
              onTap: _openPortalBind,
            ),
          ),
          const SizedBox(height: 10),
          Material(
            color: palette.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ProfileListTile(
                  tile: _settingsTile,
                  showDivider: true,
                  onTap: () => context.push('/settings'),
                ),
                ProfileListTile(
                  tile: _aboutTile,
                  showDivider: false,
                  onTap: () => context.push('/about'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
