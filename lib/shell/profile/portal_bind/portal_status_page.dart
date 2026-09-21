import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/passkey_bundle.dart';
import '../../../core/auth/passkey_store.dart';
import '../../../core/auth/portal_exceptions.dart';
import '../../../core/auth/portal_session.dart';
import '../../../core/colors.dart';
import '../../../mini_apps/student_info/student_info_models.dart';
import '../../../mini_apps/student_info/student_info_store.dart';

/// 「绑定统一门户」的状态页：展示当前绑定的学号与凭据信息，并提供重新绑定、
/// 解除绑定入口。debug 构建下多一个「测试登录」按钮，用真实流程验证凭据。
class PortalStatusPage extends StatefulWidget {
  const PortalStatusPage({super.key});

  @override
  State<PortalStatusPage> createState() => _PortalStatusPageState();
}

class _PortalStatusPageState extends State<PortalStatusPage> {
  PasskeyBundle? _bundle;

  /// 信息门户给的登录人资料（学习页拉取并缓存的），用来在学号旁边把姓名、
  /// 学院班级也摆出来，「绑的是不是我」一眼就能看出来。
  PortalUser? _user;
  bool _loading = true;

  // 「测试登录」的运行状态，只在 debug 构建下用得到。
  bool _testing = false;
  String? _testStage;
  _TestResult? _testResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bundle = await PasskeyStore.read();
    final info = await StudentInfoStore.read();
    if (!mounted) return;
    setState(() {
      _bundle = bundle;
      // 缓存可能是换绑之前那个账号的，学号对不上就不显示。
      _user = info != null && info.user.studentId == bundle?.studentId
          ? info.user
          : null;
      _loading = false;
    });
  }

  // ==================== 操作 ====================

  /// 进绑定流程。**刻意不清 WebView 的 Cookie**：门户那边还登录着的话，用户
  /// 就不必再输一遍密码。万一残留的是别人的账号，绑定页顶部有「换个账号」，
  /// 绑完状态页也会把学号摆出来，看一眼就知道对不对。
  Future<void> _openRegister() async {
    final done = await context.push<bool>('/portal-bind/register');
    if (done == true) {
      // 新凭据对应的可能是另一个学号，旧会话必须作废。
      await PortalSession.instance.clear();
    }
    if (mounted) _load();
  }

  Future<void> _rebind() async {
    final confirmed = await _confirm(
      title: '重新绑定',
      message:
          '将在门户上注册一个新的通行密钥，并替换本机现有凭据。\n\n'
          '旧的通行密钥不会被自动删除，会作为一条记录留在门户的'
          '「账户安全 → 通行密钥」列表里，需要的话请自行到那里清理。',
      confirmText: '继续',
    );
    if (confirmed) await _openRegister();
  }

  Future<void> _unbind() async {
    final confirmed = await _confirm(
      title: '解除绑定',
      message:
          '将删除本机保存的通行密钥与登录状态，APP 内需要门户身份的功能会停止工作。\n\n'
          '注意：这只会删除本机凭据。门户上那条通行密钥记录依然存在，'
          '如需彻底移除，请到门户的「账户安全 → 通行密钥」页面删除。',
      confirmText: '解除绑定',
      destructive: true,
    );
    if (!confirmed) return;

    await PasskeyStore.delete();
    // 解绑是用户主动断开，WebView 里的登录态也一并清掉，免得看起来还登着。
    await PortalSession.instance.clear(includeWebView: true);
    if (!mounted) return;
    setState(() {
      _bundle = null;
      _user = null;
      _testResult = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已解除绑定')));
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message, style: const TextStyle(fontSize: 14, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: destructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 跑一次真实登录。走 verifyCredential 而不是普通登录，否则 CAS 票根还在时
  /// 会直接走 SSO 快路径，根本验不到 Passkey 本身。
  Future<void> _testLogin() async {
    setState(() {
      _testing = true;
      _testStage = '准备中…';
      _testResult = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      final landing = await PortalSession.instance.verifyCredential(
        onStage: (stage) {
          if (mounted) setState(() => _testStage = _stageText(stage));
        },
      );
      stopwatch.stop();
      final cookies = await PortalSession.instance.debugCookieNames(landing);
      if (!mounted) return;
      setState(() {
        _testResult = _TestResult(
          ok: true,
          title: '登录成功（${stopwatch.elapsedMilliseconds} ms）',
          details: [
            '落地页：$landing',
            if (cookies.isNotEmpty) '会话 Cookie：${cookies.join('、')}',
          ],
        );
      });
    } on PortalException catch (e) {
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _testResult = _TestResult(
          ok: false,
          title: switch (e) {
            PortalNetworkError() => '网络不可用（${stopwatch.elapsedMilliseconds} ms）',
            PortalCredentialError() => '凭据已失效（${stopwatch.elapsedMilliseconds} ms）',
            PortalLoginError() => '登录失败（${stopwatch.elapsedMilliseconds} ms）',
          },
          details: [e.message],
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _testStage = null;
        });
      }
    }
  }

  static String _stageText(String stage) => switch (stage) {
    'opening' => '正在打开登录页…',
    'sso_reused' => '复用已有登录票根…',
    'asserting' => '正在请求断言参数…',
    'submitting' => '正在提交签名…',
    'done' => '正在跳转到目标服务…',
    _ => '处理中…',
  };

  // ==================== 界面 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(title: const Text('统一门户')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<PortalCredentialError?>(
              valueListenable: PortalSession.instance.credentialError,
              builder: (context, credentialError, _) {
                final bundle = _bundle;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _StatusHeader(
                      bundle: bundle,
                      // 没绑定就谈不上失效，避免解绑后还挂着红色横幅。
                      revoked: bundle != null && credentialError != null,
                      revokedMessage: credentialError?.message,
                    ),
                    if (bundle != null) ...[
                      const SizedBox(height: 12),
                      _InfoCard(bundle: bundle, user: _user),
                    ],
                    const SizedBox(height: 12),
                    _actions(bundle),
                    if (kDebugMode) ...[
                      const SizedBox(height: 12),
                      _debugSection(bundle),
                    ],
                  ],
                );
              },
            ),
    );
  }

  Widget _actions(PasskeyBundle? bundle) {
    if (bundle == null) {
      return _Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _openRegister,
              child: const Text('立即绑定'),
            ),
          ),
        ),
      );
    }
    return _Card(
      child: Column(
        children: [
          _ActionRow(
            icon: Icons.refresh,
            label: '重新绑定',
            hint: '注册新的通行密钥',
            onTap: _rebind,
            showDivider: true,
          ),
          _ActionRow(
            icon: Icons.link_off,
            label: '解除绑定',
            hint: '删除本机凭据',
            onTap: _unbind,
            destructive: true,
            showDivider: false,
          ),
        ],
      ),
    );
  }

  Widget _debugSection(PasskeyBundle? bundle) {
    final result = _testResult;
    return _Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bug_report_outlined, size: 18, color: AppColors.hint),
                const SizedBox(width: 6),
                const Text(
                  '调试',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.labelText,
                  ),
                ),
                const Spacer(),
                const Text(
                  '仅 debug 构建可见',
                  style: TextStyle(fontSize: 11, color: AppColors.hint),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '用真实的 Passkey 流程登录教务系统，验证本机凭据是否还能用。',
              style: TextStyle(fontSize: 12, color: AppColors.hint, height: 1.4),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (bundle == null || _testing) ? null : _testLogin,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login, size: 18),
                label: Text(_testing ? (_testStage ?? '登录中…') : '测试登录'),
              ),
            ),
            if (result != null) ...[
              const SizedBox(height: 12),
              _TestResultView(result: result),
            ],
          ],
        ),
      ),
    );
  }
}

// ==================== 子组件 ====================

/// 顶部状态卡：未绑定 / 已绑定 / 已失效三态。
class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.bundle,
    required this.revoked,
    this.revokedMessage,
  });

  final PasskeyBundle? bundle;
  final bool revoked;
  final String? revokedMessage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, title, subtitle) = switch ((bundle, revoked)) {
      (null, _) => (
        Icons.link_off,
        AppColors.hint,
        '未绑定',
        '绑定后即可在 APP 内直接使用教务、电费等需要门户身份的功能。',
      ),
      (_, true) => (
        Icons.error_outline,
        scheme.error,
        '通行密钥已失效',
        revokedMessage ?? '门户拒绝了本机凭据，请重新绑定。',
      ),
      _ => (
        Icons.verified_user,
        const Color(0xFF00B42A),
        '已绑定',
        '本机已保存通行密钥，APP 内需要门户身份时会自动登录。',
      ),
    };

    return _Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: revoked ? color : AppColors.titleText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.hint,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 凭据详情：学号（有缓存资料时还有姓名、院系班级）、设备名、绑定时间、凭据 ID。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.bundle, required this.user});

  final PasskeyBundle bundle;
  final PortalUser? user;

  @override
  Widget build(BuildContext context) {
    final createdAt = bundle.createdAt;
    final org = user?.orgLine ?? '';
    return _Card(
      child: Column(
        children: [
          _InfoRow(label: '学号', value: bundle.studentId ?? '未知'),
          if (user != null && user!.name.isNotEmpty)
            _InfoRow(label: '姓名', value: user!.name),
          if (org.isNotEmpty) _InfoRow(label: '院系班级', value: org),
          _InfoRow(
            label: '设备名',
            value: bundle.deviceName.isEmpty ? '未记录' : bundle.deviceName,
          ),
          _InfoRow(
            label: '绑定时间',
            value: createdAt.millisecondsSinceEpoch == 0
                ? '未记录'
                : _formatDateTime(createdAt),
          ),
          _InfoRow(
            label: '凭据 ID',
            value: bundle.credentialId.length > 12
                ? '${bundle.credentialId.substring(0, 12)}…'
                : bundle.credentialId,
            showDivider: false,
          ),
        ],
      ),
    );
  }

  static String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.showDivider = true,
  });

  final String label;
  final String value;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.labelText,
                  ),
                ),
                const SizedBox(width: 16),
                // 用 Expanded 而不是 Spacer + Flexible：两个弹性组件会平分剩余
                // 宽度，把学号这类本来放得下的值也挤成省略号。
                Expanded(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.titleText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showDivider)
          const Padding(
            padding: EdgeInsets.only(left: 16),
            child: Divider(height: 1, color: AppColors.rowDivider),
          ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
    required this.showDivider,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;
  final bool showDivider;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive
        ? Theme.of(context).colorScheme.error
        : AppColors.labelText;
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: destructive ? color : AppColors.titleText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hint,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.hint,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right, color: Color(0xFFC9CDD4)),
                ],
              ),
            ),
          ),
          if (showDivider)
            const Padding(
              padding: EdgeInsets.only(left: 16),
              child: Divider(height: 1, color: AppColors.rowDivider),
            ),
        ],
      ),
    );
  }
}

class _TestResult {
  const _TestResult({
    required this.ok,
    required this.title,
    required this.details,
  });

  final bool ok;
  final String title;
  final List<String> details;
}

class _TestResultView extends StatelessWidget {
  const _TestResultView({required this.result});

  final _TestResult result;

  @override
  Widget build(BuildContext context) {
    final color = result.ok
        ? const Color(0xFF00B42A)
        : Theme.of(context).colorScheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  result.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          for (final line in result.details) ...[
            const SizedBox(height: 6),
            SelectableText(
              line,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.labelText,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「我的」页那套白色圆角卡片。
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
