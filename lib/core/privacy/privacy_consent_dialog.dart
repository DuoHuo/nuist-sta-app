import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app_info.dart';
import '../ui/miuix_bottom_dialog.dart';
import 'privacy_consent.dart';

/// 首次启动（或隐私政策版本更新后）的同意弹窗，从下半屏弹出。
///
/// 不可关闭：点遮罩和系统返回都没有反应，只能点「同意」或「拒绝」，点击后记录选择并关闭。
/// 选择前（包括应用被杀）按未选择处理，不发送设备标识，下次冷启动再询问。
Future<void> showPrivacyConsentDialog(
  BuildContext context, {
  PrivacyConsent? consent,
}) async {
  final store = consent ?? PrivacyConsent.instance;
  final accepted = await showMiuixBottomDialog(
    context,
    messageBuilder: (_) => const _PolicyMessage(
      before: '欢迎使用 $kAppName，在使用本应用的过程中，我们将联网提供必要服务。请您阅读并同意我们的',
      after: '',
    ),
    confirmLabel: '同意',
    cancelLabel: '拒绝',
    // 必须在「同意」和「拒绝」中选一个：点遮罩和系统返回都不关闭，选择后立即解除。
    dismissible: false,
  );
  if (accepted == null) return;
  await store.set(
    accepted ? PrivacyDecision.accepted : PrivacyDecision.declined,
  );
}

/// 使用需要同意隐私政策的功能（如课表分享）前调用。
///
/// [reason] 是正文，说明为什么需要同意；末尾会自动接上可点击的《隐私政策》链接，
/// 所以 [reason] 不要自己写「隐私政策」，以「需要先同意」这类半句结尾。
///
/// 已同意直接返回 `true`；否则弹出说明，用户同意后记录并返回 `true`，
/// 取消、返回或关闭时返回 `false`，不改变已有的选择。
Future<bool> ensurePrivacyConsent(
  BuildContext context, {
  required String reason,
  PrivacyConsent? consent,
}) async {
  final store = consent ?? PrivacyConsent.instance;
  if (store.accepted) return true;
  final accepted = await showMiuixBottomDialog(
    context,
    title: '需要同意隐私政策',
    messageBuilder: (_) => _PolicyMessage(before: reason, after: '。'),
    confirmLabel: '同意并继续',
    cancelLabel: '取消',
  );
  if (accepted != true) return false;
  await store.set(PrivacyDecision.accepted);
  return true;
}

/// 撤回同意前的确认弹窗。确认后改为拒绝状态并返回 `true`，其余情况不改变选择。
///
/// 防误触：「撤回」按钮先倒计时 10 秒才能点，主色（蓝）按钮是「取消」。
Future<bool> confirmWithdrawPrivacyConsent(
  BuildContext context, {
  PrivacyConsent? consent,
}) async {
  final store = consent ?? PrivacyConsent.instance;
  final confirmed = await showMiuixBottomDialog(
    context,
    title: '撤回同意',
    messageBuilder: (_) => const _PolicyMessage(
      before: '如果您撤回对',
      after: '的同意，则视为您不同意我们继续向您提供的网络服务。撤回后不影响您使用 $kAppName 的大部分功能，确认撤回？',
    ),
    confirmLabel: '撤回',
    cancelLabel: '取消',
    confirmPrimary: false,
    confirmDestructive: true,
    confirmCountdown: 10,
  );
  if (confirmed != true) return false;
  await store.set(PrivacyDecision.declined);
  return true;
}

/// 弹窗正文：`before` + 可点击的《隐私政策》 + `after`，点击链接打开隐私政策页。
class _PolicyMessage extends StatefulWidget {
  const _PolicyMessage({required this.before, required this.after});

  final String before;
  final String after;

  @override
  State<_PolicyMessage> createState() => _PolicyMessageState();
}

class _PolicyMessageState extends State<_PolicyMessage> {
  late final TapGestureRecognizer _tap = TapGestureRecognizer()
    ..onTap = () => PrivacyConsent.openPolicy?.call(context);

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final style = theme.textStyles.body1.copyWith(
      color: theme.colors.onSurfaceSecondary,
    );
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: widget.before),
          TextSpan(
            text: '《隐私政策》',
            style: style.copyWith(color: theme.colors.primary),
            recognizer: _tap,
          ),
          if (widget.after.isNotEmpty) TextSpan(text: widget.after),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
