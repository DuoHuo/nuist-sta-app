import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_manifest.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_session.dart';
import '../../core/colors.dart';

/// H5 小程序的通用承载页：顶栏显示小程序名，正文加载 [manifest.url]。
///
/// 壳不感知具体网页；H5 小程序只需在注册表登记一条带 url 的
/// [AppManifest]，点击宫格即进入本页。声明了
/// [AppManifest.requiresPortal] 的小程序，会在加载前先把门户会话准备好。
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

  /// 准备门户会话时的失败；非 null 时用错误页顶替 WebView。
  PortalException? _error;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(onProgress: (p) => setState(() => _progress = p)),
      );
    _start();
  }

  Future<void> _start() async {
    final url = widget.manifest.url!;
    if (widget.manifest.requiresPortal) {
      setState(() {
        _preparing = true;
        _error = null;
      });
      try {
        // 先确保有会话，再灌进 WebView —— 顺序反了就只会同步到一份空 Cookie。
        await PortalSession.instance.ensureLoggedIn(url);
        await PortalSession.instance.syncToWebView([url]);
      } on PortalException catch (e) {
        if (mounted) {
          setState(() {
            _error = e;
            _preparing = false;
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() => _preparing = false);
    }
    if (!mounted) return;
    await _controller.loadRequest(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.manifest.label),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          // 加载完成后隐藏；value 传 null 会变成无限循环的不确定进度动画。
          child: _progress < 100
              ? LinearProgressIndicator(
                  minHeight: 2,
                  value: _progress / 100,
                  color: Theme.of(context).colorScheme.primary,
                  backgroundColor: AppColors.rowDivider,
                )
              : const SizedBox(height: 2),
        ),
      ),
      body: switch ((_error, _preparing)) {
        (final PortalException error, _) => _PortalErrorView(
          error: error,
          onRetry: _start,
        ),
        (_, true) => const Center(child: CircularProgressIndicator()),
        _ => WebViewWidget(controller: _controller),
      },
    );
  }
}

/// 门户会话准备失败时的占位页：网络问题给「重试」，凭据问题引到绑定页。
class _PortalErrorView extends StatelessWidget {
  const _PortalErrorView({required this.error, required this.onRetry});

  final PortalException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final needsBinding = error is PortalCredentialError;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              needsBinding ? Icons.gpp_maybe_outlined : Icons.wifi_off,
              size: 40,
              color: AppColors.hint,
            ),
            const SizedBox(height: 12),
            Text(
              needsBinding ? '需要统一门户身份' : '网络不可用',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.titleText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.hint,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            if (needsBinding)
              FilledButton(
                onPressed: () => context.push('/portal-bind'),
                child: const Text('去绑定'),
              )
            else
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
