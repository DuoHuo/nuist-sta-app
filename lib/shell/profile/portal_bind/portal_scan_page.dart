import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/auth/passkey_transfer.dart';

/// 扫另一台设备屏幕上的导出二维码，识别到就把文本 `pop` 回导入页。
class PortalScanPage extends StatefulWidget {
  const PortalScanPage({super.key});

  @override
  State<PortalScanPage> createState() => _PortalScanPageState();
}

class _PortalScanPageState extends State<PortalScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (PasskeyTransfer.looksLikeExport(value)) {
        _done = true;
        context.pop(value!.trim());
        return;
      }
    }
    // 摄像头会连续上报同一个码，提示只在内容变化时刷新，避免 setState 风暴。
    const hint = '不是通行密钥二维码';
    if (_hint != hint) setState(() => _hint = hint);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫描二维码'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  switch (error.errorCode) {
                    MobileScannerErrorCode.permissionDenied =>
                      '没有相机权限，请到系统设置里允许 NUIST++ 使用相机',
                    _ =>
                      '相机启动失败：${error.errorDetails?.message ?? error.errorCode.name}',
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.5),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Text(
              _hint ?? '对准另一台设备上的二维码',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
