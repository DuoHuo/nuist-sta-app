import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/auth/passkey_bundle.dart';
import '../../../core/auth/passkey_store.dart';
import '../../../core/auth/passkey_transfer.dart';
import '../../../core/colors.dart';
import 'portal_bind_widgets.dart';

/// 导出通行密钥：设置 PIN → 生成加密文本 → 以二维码 / 复制 / 文件三种方式给出。
class PortalExportPage extends StatefulWidget {
  const PortalExportPage({super.key});

  @override
  State<PortalExportPage> createState() => _PortalExportPageState();
}

class _PortalExportPageState extends State<PortalExportPage> {
  PasskeyBundle? _bundle;
  bool _loading = true;
  bool _generating = false;
  String? _text;
  QrCode? _qr;

  @override
  void initState() {
    super.initState();
    PasskeyStore.read().then((bundle) {
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    });
  }

  Future<void> _generate() async {
    final bundle = _bundle;
    if (bundle == null) return;
    final pin = await showPinDialog(
      context,
      title: '设置 PIN',
      message: '导入时需要输入同一个 PIN。请记牢，忘了就只能重新导出。',
      confirm: true,
      confirmText: '生成',
    );
    if (pin == null || !mounted) return;

    setState(() => _generating = true);
    final stopwatch = Stopwatch()..start();
    try {
      final text = await PasskeyTransfer.encrypt(bundle, pin);
      if (kDebugMode) {
        debugPrint(
          '[PasskeyTransfer] encrypt ${stopwatch.elapsedMilliseconds} ms, '
          '${text.length} chars',
        );
      }
      if (!mounted) return;
      setState(() {
        _text = text;
        _qr = exportQrCode(text);
      });
    } on PasskeyTransferError catch (e) {
      _message(e.message);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _copy() async {
    final text = _text;
    if (text == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _message('已复制，传完记得清空剪贴板');
    } catch (_) {
      _message('复制失败');
    }
  }

  Future<void> _shareFile() async {
    final text = _text;
    final bundle = _bundle;
    if (text == null || bundle == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp = '${now.year}${two(now.month)}${two(now.day)}';
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'nuist-passkey-${bundle.studentId ?? 'unknown'}-$stamp.nuistkey',
      );
      await file.writeAsString(text, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          subject: 'NUIST++ 通行密钥',
        ),
      );
    } catch (e) {
      _message('分享失败：$e');
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(title: const Text('导出通行密钥')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: _text == null ? _setupChildren() : _resultChildren(),
            ),
    );
  }

  List<Widget> _setupChildren() {
    final bundle = _bundle;
    return [
      PortalCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '导出后怎么用',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.titleText,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '生成的内容会用你设置的六位 PIN 加密。在另一台设备上打开 NUIST++，'
                '进入「我的 → 绑定统一门户 → 导入通行密钥」，扫码、粘贴或选择文件，'
                '再输入同一个 PIN 即可。',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.labelText,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: (bundle == null || _generating) ? null : _generate,
                  child: _generating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(bundle == null ? '本机没有通行密钥' : '设置 PIN 并生成'),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _resultChildren() {
    return [
      PortalCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) => QrImageView.withQr(
                  qr: _qr!,
                  size: min(
                    constraints.maxWidth,
                    _qr!.moduleCount * qrModuleSide,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '在另一台设备的导入页扫描此二维码',
                style: TextStyle(fontSize: 12, color: AppColors.hint),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      PortalCard(
        child: Column(
          children: [
            PortalActionRow(
              icon: Icons.copy_outlined,
              label: '复制到剪贴板',
              hint: '通过聊天软件等发给自己',
              onTap: _copy,
              showDivider: true,
            ),
            PortalActionRow(
              icon: Icons.insert_drive_file_outlined,
              label: '分享为文件',
              hint: '保存或发送一个 .nuistkey 文件',
              onTap: _shareFile,
              showDivider: false,
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '这段内容等同于你的门户登录凭据，只受六位 PIN 保护。传到新设备后请立即删除，'
          '不要留在聊天记录或云盘里。',
          style: TextStyle(fontSize: 12, color: AppColors.hint, height: 1.5),
        ),
      ),
    ];
  }
}
