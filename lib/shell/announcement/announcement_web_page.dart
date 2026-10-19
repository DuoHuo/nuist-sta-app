import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/colors.dart';
import 'announcement_models.dart';

/// 构造公告外链页面的工厂；测试环境没有 WebView 平台实现，可替换为伪页面。
typedef AnnouncementWebPageBuilder = Widget Function(AnnouncementLink link);

/// 公告「查看详情」使用的页面工厂，默认为 [AnnouncementWebPage]。
///
/// 仅测试应覆盖此值，用完需恢复。
AnnouncementWebPageBuilder announcementWebPageBuilder = (link) =>
    AnnouncementWebPage(link: link);

/// 公告外链的应用内浏览器：只允许 https 导航，不注入任何门户会话或调试脚本。
class AnnouncementWebPage extends StatefulWidget {
  const AnnouncementWebPage({super.key, required this.link});

  /// 要打开的链接，由 [AnnouncementLink.tryParse] 保证为 https。
  final AnnouncementLink link;

  @override
  State<AnnouncementWebPage> createState() => _AnnouncementWebPageState();
}

class _AnnouncementWebPageState extends State<AnnouncementWebPage> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;
  String? _pageTitle;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final uri = Uri.tryParse(req.url);
            return uri != null && uri.scheme == 'https'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _error = null);
          },
          onPageFinished: (_) async {
            final title = await _controller.getTitle();
            if (mounted && title != null && title.isNotEmpty) {
              setState(() => _pageTitle = title);
            }
          },
          onWebResourceError: (e) {
            // 只处理主框架错误，子资源失败不影响页面展示。
            if (e.isForMainFrame == false) return;
            if (mounted) setState(() => _error = '页面加载失败');
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.link.url));
  }

  void _copyLink() {
    Clipboard.setData(ClipboardData(text: widget.link.url)).catchError((_) {});
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('链接已复制')));
  }

  Future<void> _onBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final loading = _progress > 0 && _progress < 100;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            _pageTitle ?? widget.link.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '复制链接',
              icon: const Icon(Icons.copy),
              onPressed: _copyLink,
            ),
          ],
          bottom: loading
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    value: _progress / 100,
                    minHeight: 2,
                    color: palette.accent,
                  ),
                )
              : null,
        ),
        // 网页内容是学校自己的页面，不做任何注入或反色，只适配容器层。
        body: _error != null
            ? Center(
                child: Text(_error!, style: TextStyle(color: palette.hint)),
              )
            : WebViewWidget(controller: _controller),
      ),
    );
  }
}
