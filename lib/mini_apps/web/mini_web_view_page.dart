import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_manifest.dart';
import '../../core/colors.dart';

/// H5 小程序的通用承载页：顶栏显示小程序名，正文加载 [manifest.url]。
///
/// 壳不感知具体网页；H5 小程序只需在注册表登记一条带 url 的
/// [AppManifest]，点击宫格即进入本页。
class MiniWebViewPage extends StatefulWidget {
  const MiniWebViewPage({super.key, required this.manifest});

  final AppManifest manifest;

  @override
  State<MiniWebViewPage> createState() => _MiniWebViewPageState();
}

class _MiniWebViewPageState extends State<MiniWebViewPage> {
  late final WebViewController _controller;

  // 页面加载进度，>0 且 <1 时在顶栏下方显示细进度条。
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onProgress: (p) => setState(() => _progress = p),
            ),
          )
          ..loadRequest(Uri.parse(widget.manifest.url!));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.manifest.label),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: LinearProgressIndicator(
            minHeight: 2,
            value: _progress > 0 && _progress < 100 ? _progress / 100 : null,
            color: Theme.of(context).colorScheme.primary,
            backgroundColor: AppColors.rowDivider,
          ),
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
