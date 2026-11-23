import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/auth/passkey_transfer.dart';
import '../../../core/colors.dart';
import '../../../core/ui/miuix_dialog.dart';

/// 「我的」页那套圆角卡片，统一门户相关的几个页面共用；底色随主题明暗切换。
class PortalCard extends StatelessWidget {
  const PortalCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // 用 Material 画底色：里面行的 InkWell 水波纹画在它上面才看得见，
    // 并随圆角裁剪。
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 卡片里的一行操作：图标 + 标题 + 小字说明 + 右箭头。
class PortalActionRow extends StatelessWidget {
  const PortalActionRow({
    super.key,
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
  final VoidCallback? onTap;
  final bool showDivider;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = destructive
        ? Theme.of(context).colorScheme.error
        : palette.labelText;
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
                  SizedBox.square(
                    dimension: 24,
                    child: Center(child: Icon(icon, size: 20, color: color)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: destructive ? color : palette.titleText,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: palette.hint),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: palette.chevron),
                ],
              ),
            ),
          ),
          if (showDivider)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Divider(height: 1, color: palette.rowDivider),
            ),
        ],
      ),
    );
  }
}

/// 六位数字 PIN 的输入弹窗。返回 null 表示取消。
///
/// [confirm] 为 true 时要求输入两遍（导出时防手误：PIN 输错了自己都解不开）。
Future<String?> showPinDialog(
  BuildContext context, {
  required String title,
  required String message,
  bool confirm = false,
  String confirmText = '确定',
}) {
  return showMiuixDialog<String>(
    context,
    title: title,
    centered: true,
    builder: (dialogContext, dialog) => _PinDialog(
      message: message,
      confirm: confirm,
      confirmText: confirmText,
      onClose: dialog.close,
    ),
  );
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({
    required this.message,
    required this.confirm,
    required this.confirmText,
    required this.onClose,
  });

  final String message;
  final bool confirm;
  final String confirmText;
  final ValueChanged<String?> onClose;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  static bool _isPin(String text) => RegExp(r'^\d{6}$').hasMatch(text);

  bool get _valid {
    if (!_isPin(_first.text)) return false;
    return !widget.confirm || _second.text == _first.text;
  }

  String? get _mismatchHint {
    if (!widget.confirm || _second.text.length < 6) return null;
    return _second.text == _first.text ? null : '两次输入不一致';
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final primary = MiuixButtonDefaults.buttonColorsPrimary(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.message,
          style: theme.textStyles.body1.copyWith(
            color: theme.colors.onSurfaceSecondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        MiuixTextField(
          controller: _first,
          autofocus: true,
          singleLine: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          label: widget.confirm ? '设置六位数字 PIN' : '六位数字 PIN',
          onChanged: (_) => setState(() {}),
        ),
        if (widget.confirm) ...[
          const SizedBox(height: 10),
          MiuixTextField(
            controller: _second,
            singleLine: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            label: '再输入一遍',
            onChanged: (_) => setState(() {}),
          ),
          if (_mismatchHint case final hint?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                hint,
                style: theme.textStyles.body2.copyWith(
                  color: theme.colors.error,
                ),
              ),
            ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: MiuixButton(
                colors: primary,
                onPressed: () => widget.onClose(null),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MiuixButton(
                enabled: _valid,
                onPressed: _valid ? () => widget.onClose(_first.text) : null,
                child: Text(widget.confirmText),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 二维码每个模块占的逻辑像素：V8 铺满卡片（360dp 屏约 296px）也就是每模块
/// 6px，按这个密度把尺寸收回来，扫起来不会更费劲。
const double qrModuleSide = 6;

/// 把导出文本编成二维码。
///
/// 前缀走 byte 段，Base45 主体走 alphanumeric 段：Base45 的 45 个字符恰好就是
/// 二维码 alphanumeric 模式的字符集，但 `QrCode.fromData` 只按 byte 模式编码，
/// 会把 Base45 的 1.5 倍膨胀原样吃进二维码——手动分段后同一份数据少两个版本
/// （V8 49×49 → V6 41×41）。
///
/// 版本号自己找：qr 包没有暴露容量表，从 byte 模式的版本（一定装得下，是上界）
/// 往下试，记住最后一个装得下的。alphanumeric 比 byte 密，通常往下两三个版本
/// 就到了。
QrCode exportQrCode(String text) {
  final prefix = PasskeyTransfer.prefix;
  final body = text.substring(prefix.length);
  final byteVersion = QrCode.fromData(
    data: text,
    errorCorrectLevel: QrErrorCorrectLevel.L,
  ).typeNumber;
  QrCode? smallest;
  for (var version = byteVersion; version >= 1; version--) {
    final candidate = QrCode(version, QrErrorCorrectLevel.L)
      ..addData(prefix)
      ..addAlphaNumeric(body);
    try {
      // QrImage 构造时才会碰 dataCache，容量不够就在这里抛 InputTooLongException。
      QrImage(candidate);
    } on InputTooLongException {
      // 容量随版本单调递增，装不下就停，上一个装得下的已经记住了。
      break;
    }
    smallest = candidate;
  }
  return smallest!;
}
