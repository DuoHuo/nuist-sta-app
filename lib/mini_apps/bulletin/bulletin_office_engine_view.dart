import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 在独立的 Android 阅读视图中显示离线引擎生成的内容。
class BulletinOfficeEngineView extends StatefulWidget {
  /// 打开已下载的附件，文件直接由原生视图读取。
  const BulletinOfficeEngineView({
    super.key,
    required this.file,
    required this.onReady,
    required this.onFailure,
  });

  final File file;
  final ValueChanged<String?> onReady;
  final VoidCallback onFailure;

  @override
  State<BulletinOfficeEngineView> createState() =>
      _BulletinOfficeEngineViewState();
}

class _BulletinOfficeEngineViewState extends State<BulletinOfficeEngineView> {
  static const _viewType = 'nuist/bulletin_office_view';

  MethodChannel? _channel;
  Timer? _timeout;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(const Duration(seconds: 15), _fail);
  }

  Future<void> _start(int id) async {
    if (!mounted || _failed) return;
    final channel = MethodChannel('$_viewType/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted || _failed) return;
      switch (call.method) {
        case 'ready':
          _timeout?.cancel();
          final mime = call.arguments as String?;
          widget.onReady(mime?.isNotEmpty == true ? mime : null);
        case 'failed':
          _fail();
      }
    });
    try {
      await channel.invokeMethod<void>('load', {
        'path': widget.file.path,
        'dark': Theme.of(context).brightness == Brightness.dark,
      });
    } on PlatformException {
      _fail();
    } on MissingPluginException {
      _fail();
    }
  }

  void _fail() {
    if (!mounted || _failed) return;
    _failed = true;
    _timeout?.cancel();
    widget.onFailure();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AndroidView(viewType: _viewType, onPlatformViewCreated: _start);
}
