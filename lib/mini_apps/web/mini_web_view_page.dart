import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/navigation/app_navigation.dart';
import '../../core/app_manifest.dart';
import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_session.dart';
import '../../core/colors.dart';
import '../../core/logging/app_log.dart';
import '../../core/network/web_diagnostics.dart';

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
  static final _log = AppLog.logger('web_mini_app.page');

  late final WebViewController _controller;
  late final WebDiagnostics _diagnostics;

  // 页面加载进度，>0 且 <1 时在顶栏下方显示细进度条。
  int _progress = 0;

  /// 准备门户会话时的失败；非 null 时用错误页顶替 WebView。
  PortalException? _error;
  bool _preparing = false;
  bool _canGoBack = false;
  int _historyRevision = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _diagnostics = WebDiagnostics(_controller, scope: 'web_mini_app.page');
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (url) {
            _diagnostics.pageStarted(url);
            _syncBackHistory();
          },
          onUrlChange: (_) => _syncBackHistory(),
          onPageFinished: (url) async {
            await _diagnostics.pageFinished(url);
            await _syncBackHistory();
          },
          onWebResourceError: (error) {
            _diagnostics.resourceError(error);
            _syncBackHistory();
          },
          onHttpError: _diagnostics.httpError,
        ),
      );
    _start();
  }

  // 系统在手势开始前就需要知道能否退出，不能等返回回调里再异步查询。
  Future<void> _syncBackHistory() async {
    final revision = ++_historyRevision;
    final canGoBack = await _controller.canGoBack();
    if (!mounted || revision != _historyRevision || canGoBack == _canGoBack) {
      return;
    }
    setState(() => _canGoBack = canGoBack);
  }

  Future<void> _onBack() async {
    final canGoBack = await _controller.canGoBack();
    if (!mounted) return;
    if (canGoBack) {
      await _controller.goBack();
      await _syncBackHistory();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _start() async {
    try {
      await _diagnostics.attach();
    } catch (error, stackTrace) {
      _log.warning(
        'capture.attach_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final url = widget.manifest.url!;
    if (widget.manifest.requiresPortal) {
      setState(() {
        _preparing = true;
        _error = null;
      });
      try {
        await _log.operation(
          'portal_session.prepare',
          () async {
            // 先确保有会话，再灌进 WebView —— 顺序反了就只会同步到一份空 Cookie。
            // WebView 里没法探测过期再重试，所以磁盘恢复的缓存不采信，让它走一次
            // SSO 快路径确认。
            await PortalSession.instance.ensureLoggedIn(
              url,
              trustRestored: false,
            );
            await PortalSession.instance.syncToWebView([url]);
          },
          fields: {'app_id': widget.manifest.id},
          failureEvent: 'portal_session.prepare_failed',
        );
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
    try {
      await _controller.loadRequest(Uri.parse(url));
    } catch (error, stackTrace) {
      _log.warning(
        'page.load_failed',
        fields: {'app_id': widget.manifest.id},
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  void dispose() {
    _diagnostics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 只管容器层（顶栏、进度条、错误页）；网页内容是学校自己的页面，不做反色。
    return PopScope(
      canPop: _error != null || _preparing || !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
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
                    backgroundColor: AppPalette.of(context).rowDivider,
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
      ),
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
    final palette = AppPalette.of(context);
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
              color: palette.hint,
            ),
            const SizedBox(height: 12),
            Text(
              needsBinding ? '需要统一门户身份' : '网络不可用',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: palette.titleText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: palette.hint, height: 1.5),
            ),
            const SizedBox(height: 20),
            if (needsBinding)
              FilledButton(
                onPressed: () => AppNavigation.push(context, '/portal-bind'),
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
