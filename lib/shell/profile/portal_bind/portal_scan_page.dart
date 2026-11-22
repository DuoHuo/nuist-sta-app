import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../../../core/navigation/app_navigation.dart';
import '../../../core/auth/passkey_transfer.dart';
import '../../../core/logging/app_log.dart';

/// 扫另一台设备屏幕上的导出二维码，识别到就把文本 `pop` 回导入页。
///
/// 扫码页固定深色，不随主题切换：纯黑底 + 白字是相机取景框的固有设计。
class PortalScanPage extends StatefulWidget {
  const PortalScanPage({super.key});

  @override
  State<PortalScanPage> createState() => _PortalScanPageState();
}

class _PortalScanPageState extends State<PortalScanPage> {
  static final _log = AppLog.logger('shell.profile.portal_scan');

  Object? _cameraError;
  String? _lastErrorKey;
  bool _done = false;
  String? _hint;

  void _onScan(Code code) {
    if (_done) return;
    final value = code.text;
    if (code.isValid && PasskeyTransfer.looksLikeExport(value)) {
      _done = true;
      AppNavigation.pop(context, value!.trim());
      return;
    }
    // 摄像头会连续上报同一个码，提示只在内容变化时刷新，避免 setState 风暴。
    const hint = '不是通行密钥二维码';
    if (_hint != hint) setState(() => _hint = hint);
  }

  void _onControllerCreated(CameraController? controller, Exception? error) {
    if (error == null) return;
    final key = error is CameraException
        ? error.code
        : error.runtimeType.toString();
    if (_lastErrorKey != key) {
      _lastErrorKey = key;
      _log.warning(
        'camera.failed',
        error: error,
        fields: {
          'stage': 'passkey.import.scan',
          'details': {'camera_error': key},
        },
      );
    }
    if (mounted) setState(() => _cameraError = error);
  }

  String _errorText(Object error) {
    if (error is CameraException &&
        (error.code == 'CameraAccessDenied' ||
            error.code == 'CameraAccessDeniedWithoutPrompt' ||
            error.code == 'CameraAccessRestricted')) {
      return '没有相机权限，请到系统设置里允许 NUIST++ 使用相机';
    }
    if (error is CameraException) {
      return '相机启动失败：${error.description ?? error.code}';
    }
    return '相机启动失败';
  }

  @override
  Widget build(BuildContext context) {
    final cameraError = _cameraError;
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
          if (cameraError == null)
            ReaderWidget(
              codeFormat: Format.qrCode,
              showFlashlight: false,
              showToggleCamera: false,
              showGallery: false,
              scanDelay: const Duration(milliseconds: 300),
              onScan: _onScan,
              onControllerCreated: _onControllerCreated,
            )
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _errorText(cameraError),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.5),
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
