import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/navigation/app_navigation.dart';
import '../../../core/app_snack_bar.dart';
import '../../../core/auth/passkey_bundle.dart';
import '../../../core/auth/passkey_store.dart';
import '../../../core/auth/passkey_transfer.dart';
import '../../../core/colors.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/ui/miuix_dialog.dart';
import 'portal_bind_widgets.dart';
import 'portal_binding_actions.dart';

/// 导入通行密钥：三种来源拿到导出文本 → 输 PIN 解密 → 预览确认 → 覆盖本机凭据。
/// 保存成功后清理旧会话并通知各模块，再 `pop(true)` 更新状态页展示。
class PortalImportPage extends StatefulWidget {
  const PortalImportPage({super.key});

  @override
  State<PortalImportPage> createState() => _PortalImportPageState();
}

class _PortalImportPageState extends State<PortalImportPage> {
  static final _log = AppLog.logger('shell.profile.portal_import');
  bool _busy = false;

  // ==================== 三种来源 ====================

  Future<void> _fromText() async {
    String initial = '';
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (PasskeyTransfer.looksLikeExport(clip?.text)) {
        initial = clip!.text!.trim();
      }
    } catch (error, stackTrace) {
      _log.warning(
        'clipboard.read_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'stage': 'passkey.import.read'},
      );
    }
    if (!mounted) return;
    final text = await showMiuixDialog<String>(
      context,
      title: '粘贴文本',
      centered: true,
      builder: (dialogContext, dialog) =>
          _PasteDialog(initial: initial, onClose: dialog.close),
    );
    if (text != null) await _handle(text, source: 'clipboard');
  }

  Future<void> _fromScan() async {
    final text = await AppNavigation.push<String>(
      context,
      '/portal-bind/import/scan',
    );
    if (text != null) await _handle(text, source: 'qr');
  }

  Future<void> _fromFile() async {
    try {
      final file = await FilePicker.pickFile(dialogTitle: '选择 .nuistkey 文件');
      if (file == null) return;
      final bytes = await _log.operation(
        'file.read',
        file.readAsBytes,
        fields: const {'stage': 'passkey.import.read'},
      );
      await _handle(utf8.decode(bytes, allowMalformed: true), source: 'file');
    } catch (error, stackTrace) {
      _log.warning(
        'import.file_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'stage': 'passkey.import.read'},
      );
      _message('读取文件失败，请重试');
    }
  }

  // ==================== 解密与落盘 ====================

  Future<void> _handle(String text, {required String source}) =>
      _log.startSpan().run(() async {
        if (!mounted || _busy) return;
        if (!PasskeyTransfer.looksLikeExport(text)) {
          _log.warning(
            'import.format_rejected',
            fields: {
              'reason_code': 'passkey_prefix_missing',
              'details': {'source': source},
            },
          );
          _message('这不是 NUIST++ 导出的通行密钥');
          return;
        }
        final pin = await showPinDialog(
          context,
          title: '输入 PIN',
          message: '输入导出时设置的六位数字 PIN。',
          confirmText: '解密',
        );
        if (pin == null || !mounted) return;

        setState(() => _busy = true);
        final PasskeyBundle bundle;
        try {
          bundle = await _log.operation(
            'import.decrypt',
            () => PasskeyTransfer.decrypt(text, pin),
            fields: {
              'stage': 'passkey.decrypt',
              'details': {'source': source},
            },
          );
        } on PasskeyTransferError catch (e) {
          _message(e.message);
          return;
        } catch (_) {
          _message('无法完成通行密钥解密，请重试');
          return;
        } finally {
          if (mounted) setState(() => _busy = false);
        }
        if (!mounted) return;

        final existing = await PasskeyStore.read();
        if (!mounted) return;
        final confirmed = await _preview(bundle, replacing: existing != null);
        if (!confirmed) return;

        try {
          await _log.operation(
            'import.save',
            () => PortalBindingActions.instance.bind(bundle),
            fields: {
              'stage': 'passkey.import.save',
              'details': {'source': source, 'replacing': existing != null},
            },
          );
        } catch (_) {
          if (mounted) _message('绑定未完成，请重试');
          return;
        }
        if (mounted) AppNavigation.pop(context, true);
      });

  Future<bool> _preview(PasskeyBundle bundle, {required bool replacing}) async {
    final createdAt = bundle.createdAt;
    final rows = <(String, String)>[
      ('学号', bundle.studentId ?? '未知'),
      ('凭据名称', bundle.deviceName.isEmpty ? '未记录' : bundle.deviceName),
      (
        '绑定时间',
        createdAt.millisecondsSinceEpoch == 0
            ? '未记录'
            : _formatDateTime(createdAt),
      ),
    ];
    return showMiuixConfirmDialog(
      context,
      title: '确认导入',
      content: _ImportPreviewRows(rows: rows, replacing: replacing),
      confirmLabel: replacing ? '替换' : '导入',
      cancelLabel: '取消',
    );
  }

  static String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        AppSnackBar(tone: AppSnackBarTone.error, content: Text(text)),
      );
  }

  // ==================== 界面 ====================

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      backgroundColor: palette.pageBg,
      appBar: AppBar(title: const Text('导入通行密钥')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  '在另一台设备的「导出通行密钥」页生成内容后，选择一种方式读入。',
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.labelText,
                    height: 1.5,
                  ),
                ),
              ),
              PortalCard(
                child: Column(
                  children: [
                    PortalActionRow(
                      icon: Icons.qr_code_scanner,
                      label: '扫描二维码',
                      hint: '对准另一台设备屏幕上的二维码',
                      onTap: _busy ? null : _fromScan,
                      showDivider: true,
                    ),
                    PortalActionRow(
                      icon: Icons.content_paste_outlined,
                      label: '粘贴文本',
                      hint: '粘贴以 nuistkey1: 开头的内容',
                      onTap: _busy ? null : _fromText,
                      showDivider: true,
                    ),
                    PortalActionRow(
                      icon: Icons.folder_open_outlined,
                      label: '选择文件',
                      hint: '读取 .nuistkey 文件',
                      onTap: _busy ? null : _fromFile,
                      showDivider: false,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_busy)
            ColoredBox(
              // 半透明遮罩取页面底色：浅色下还是原来的白纱，深色下不会糊成一片白。
              color: palette.pageBg.withValues(alpha: 0.4),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

/// 导入确认里的信息行：标签左、值右，替换时追加提醒。
class _ImportPreviewRows extends StatelessWidget {
  const _ImportPreviewRows({required this.rows, required this.replacing});

  final List<(String, String)> rows;
  final bool replacing;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final labelStyle = theme.textStyles.body1.copyWith(
      color: theme.colors.onSurfaceVariantSummary,
    );
    final valueStyle = theme.textStyles.body1.copyWith(
      color: theme.colors.onBackground,
      fontWeight: FontWeight.w500,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Text(label, style: labelStyle),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: valueStyle,
                  ),
                ),
              ],
            ),
          ),
        if (replacing) ...[
          const SizedBox(height: 6),
          Text(
            '本机已有一份通行密钥，导入后会被替换。',
            style: theme.textStyles.body2.copyWith(
              color: theme.colors.onSurfaceVariantSummary,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

/// 粘贴导出文本的弹窗，会预填剪贴板里的导出内容。
class _PasteDialog extends StatefulWidget {
  const _PasteDialog({required this.initial, required this.onClose});

  final String initial;
  final ValueChanged<String?> onClose;

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = MiuixButtonDefaults.buttonColorsPrimary(context);
    final empty = _controller.text.trim().isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MiuixTextField(
          controller: _controller,
          autofocus: widget.initial.isEmpty,
          maxLines: 6,
          label: 'nuistkey1:…',
          useLabelAsPlaceholder: true,
          textStyle: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          onChanged: (_) => setState(() {}),
        ),
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
                enabled: !empty,
                onPressed: empty
                    ? null
                    : () => widget.onClose(_controller.text.trim()),
                child: const Text('下一步'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
