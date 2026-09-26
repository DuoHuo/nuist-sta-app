import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/passkey_bundle.dart';
import '../../../core/auth/passkey_store.dart';
import '../../../core/auth/passkey_transfer.dart';
import '../../../core/colors.dart';
import 'portal_bind_widgets.dart';

/// 导入通行密钥：三种来源拿到导出文本 → 输 PIN 解密 → 预览确认 → 覆盖本机凭据。
/// 成功后 `pop(true)`，由状态页负责清会话并刷新。
class PortalImportPage extends StatefulWidget {
  const PortalImportPage({super.key});

  @override
  State<PortalImportPage> createState() => _PortalImportPageState();
}

class _PortalImportPageState extends State<PortalImportPage> {
  bool _busy = false;

  // ==================== 三种来源 ====================

  Future<void> _fromText() async {
    String initial = '';
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (PasskeyTransfer.looksLikeExport(clip?.text)) {
        initial = clip!.text!.trim();
      }
    } catch (_) {}
    if (!mounted) return;
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _PasteDialog(initial: initial),
    );
    if (text != null) await _handle(text);
  }

  Future<void> _fromScan() async {
    final text = await context.push<String>('/portal-bind/import/scan');
    if (text != null) await _handle(text);
  }

  Future<void> _fromFile() async {
    try {
      final file = await FilePicker.pickFile(dialogTitle: '选择 .nuistkey 文件');
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _handle(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      _message('读取文件失败：$e');
    }
  }

  // ==================== 解密与落盘 ====================

  Future<void> _handle(String text) async {
    if (!mounted || _busy) return;
    if (!PasskeyTransfer.looksLikeExport(text)) {
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
      bundle = await PasskeyTransfer.decrypt(text, pin);
    } on PasskeyTransferError catch (e) {
      _message(e.message);
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    final existing = await PasskeyStore.read();
    if (!mounted) return;
    final confirmed = await _preview(bundle, replacing: existing != null);
    if (!confirmed) return;

    await PasskeyStore.save(bundle);
    if (mounted) context.pop(true);
  }

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
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
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
                    Expanded(
                      child: Text(
                        value,
                        textAlign: TextAlign.right,
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
            if (replacing) ...[
              const SizedBox(height: 6),
              const Text(
                '本机已有一份通行密钥，导入后会被替换。',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.hint,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(replacing ? '替换' : '导入'),
          ),
        ],
      ),
    );
    return result ?? false;
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
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ==================== 界面 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(title: const Text('导入通行密钥')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  '在另一台设备的「导出通行密钥」页生成内容后，选择一种方式读入。',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.labelText,
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
            const ColoredBox(
              color: Color(0x66FFFFFF),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

/// 粘贴导出文本的弹窗，会预填剪贴板里的导出内容。
class _PasteDialog extends StatefulWidget {
  const _PasteDialog({required this.initial});

  final String initial;

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
    return AlertDialog(
      title: const Text('粘贴文本'),
      content: TextField(
        controller: _controller,
        autofocus: widget.initial.isEmpty,
        maxLines: 6,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'nuistkey1:…',
          isDense: true,
          filled: true,
          fillColor: AppColors.pageBg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('下一步'),
        ),
      ],
    );
  }
}
