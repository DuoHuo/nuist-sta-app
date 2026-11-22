import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 弹出 Miuix 风格对话框：手机上从屏幕下半部弹出，大屏居中。
///
/// 点「确认」返回 `true`，点「取消」返回 `false`；点遮罩、系统返回等其他方式关闭
/// 返回 `null`。
///
/// - [message] 是纯文本正文；需要行内链接等富文本时改用 [messageBuilder]。
/// - [extra] 放在按钮上方，用于「查看隐私政策」这类链接。
/// - [confirmPrimary] 为 `false` 时，主色（蓝）按钮是「取消」，「确认」是灰色，
///   用于撤回这类不鼓励的操作。
/// - [dismissible] 为 `false` 时，点遮罩和系统返回都不会关闭，只能点「确认」或「取消」。
///   只用于必须做出选择的弹窗（如首次同意隐私政策），选择后立即解除。
/// - [confirmDestructive] 为 	rue 时，「确认」按钮的文字用红色（倒计时中为浅红）。
/// - [confirmCountdown] 大于 0 时，「确认」先置灰并显示剩余秒数，倒计时结束才可点。
Future<bool?> showMiuixBottomDialog(
  BuildContext context, {
  String? title,
  String? message,
  WidgetBuilder? messageBuilder,
  required String confirmLabel,
  required String cancelLabel,
  Widget? extra,
  bool confirmPrimary = true,
  bool confirmDestructive = false,
  int confirmCountdown = 0,
  bool dismissible = true,
}) {
  assert(message != null || messageBuilder != null);
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _MiuixDialogPage(
      title: title,
      message: message,
      messageBuilder: messageBuilder,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      extra: extra,
      confirmPrimary: confirmPrimary,
      confirmDestructive: confirmDestructive,
      confirmCountdown: confirmCountdown,
      dismissible: dismissible,
    ),
  );
}

class _MiuixDialogPage extends StatefulWidget {
  const _MiuixDialogPage({
    required this.title,
    required this.message,
    required this.messageBuilder,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.extra,
    required this.confirmPrimary,
    required this.confirmDestructive,
    required this.confirmCountdown,
    required this.dismissible,
  });

  final String? title;
  final String? message;
  final WidgetBuilder? messageBuilder;
  final String confirmLabel;
  final String cancelLabel;
  final Widget? extra;
  final bool confirmPrimary;
  final bool confirmDestructive;
  final int confirmCountdown;
  final bool dismissible;

  @override
  State<_MiuixDialogPage> createState() => _MiuixDialogPageState();
}

class _MiuixDialogPageState extends State<_MiuixDialogPage> {
  bool _show = true;
  bool? _result;

  /// 先播放 Miuix 的退出动画，动画结束后再关闭路由。
  void _close(bool? result) {
    if (!_show) return;
    setState(() {
      _show = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixThemeData.of(Theme.of(context).brightness);
    // 不可关闭时同时拦住系统返回；用户点「确认」或「取消」后由 Navigator.pop 关闭，
    // 程序化的 pop 不受 PopScope 影响，所以拦截在选择之后立即解除。
    return PopScope(
      canPop: widget.dismissible,
      child: MiuixTheme(
        data: theme,
        child: MiuixPopupScope(
          establishRoot: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const MiuixPopupHost(),
              MiuixOverlayDialog(
                show: _show,
                title: widget.title,
                summary: widget.messageBuilder == null ? widget.message : null,
                onDismissRequest: widget.dismissible
                    ? () => _close(null)
                    : null,
                onDismissFinished: () {
                  if (mounted) Navigator.of(context).pop(_result);
                },
                // 弹窗内容由 Miuix 注册到浮层里单独渲染，页面的 setState 不会刷新它，
                // 所以倒计时放在内容自己的 State 里。
                content: _DialogContent(
                  messageBuilder: widget.messageBuilder,
                  extra: widget.extra,
                  cancelLabel: widget.cancelLabel,
                  confirmLabel: widget.confirmLabel,
                  confirmPrimary: widget.confirmPrimary,
                  confirmDestructive: widget.confirmDestructive,
                  confirmCountdown: widget.confirmCountdown,
                  onClose: _close,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogContent extends StatefulWidget {
  const _DialogContent({
    required this.messageBuilder,
    required this.extra,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.confirmPrimary,
    required this.confirmDestructive,
    required this.confirmCountdown,
    required this.onClose,
  });

  final WidgetBuilder? messageBuilder;
  final Widget? extra;
  final String cancelLabel;
  final String confirmLabel;
  final bool confirmPrimary;
  final bool confirmDestructive;
  final int confirmCountdown;
  final ValueChanged<bool?> onClose;

  @override
  State<_DialogContent> createState() => _DialogContentState();
}

class _DialogContentState extends State<_DialogContent> {
  late int _remaining = widget.confirmCountdown;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_remaining > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() => _remaining--);
        if (_remaining <= 0) timer.cancel();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = MiuixButtonDefaults.buttonColorsPrimary(context);
    final counting = _remaining > 0;
    final colors = widget.confirmPrimary
        ? primary
        : widget.confirmDestructive
        ? _destructiveColors(context)
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.messageBuilder != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: widget.messageBuilder!(context),
          ),
        if (widget.extra != null) widget.extra!,
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: MiuixButton(
                colors: widget.confirmPrimary ? null : primary,
                onPressed: () => widget.onClose(false),
                child: Text(widget.cancelLabel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              // 倒计时中按钮不可点，Miuix 的禁用态会把它置成更浅的灰。
              child: MiuixButton(
                enabled: !counting,
                colors: colors,
                onPressed: counting ? null : () => widget.onClose(true),
                child: Text(
                  counting
                      ? '${widget.confirmLabel}（${_remaining}s）'
                      : widget.confirmLabel,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 灰底红字：沿用 Miuix 默认的次级按钮底色（禁用态更浅），只把文字换成错误色。
MiuixButtonColors _destructiveColors(BuildContext context) {
  final base = MiuixButtonDefaults.buttonColors(context);
  final error = MiuixTheme.of(context).colors.error;
  return MiuixButtonColors(
    color: base.color,
    disabledColor: base.disabledColor,
    contentColor: error,
    disabledContentColor: error.withValues(alpha: 0.4),
  );
}
