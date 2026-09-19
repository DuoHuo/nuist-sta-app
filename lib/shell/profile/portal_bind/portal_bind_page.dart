import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/app_info.dart';
import '../../../core/auth/passkey_bundle.dart';
import '../../../core/auth/passkey_store.dart';
import '../../../core/colors.dart';

/// 「绑定统一门户」页：内嵌门户登录，登录后自动跳到「账户安全-通行密钥」，
/// 注入 assets/js/portal_passkey.js 完成软件 Passkey 注册，私钥包经
/// JavaScriptChannel 回传后存入安全存储。
class PortalBindPage extends StatefulWidget {
  const PortalBindPage({super.key});

  // 门户根地址会 302 到 http://…/authserver/login，Android WebView 禁止明文流量，
  // 所以直接从登录页进；后续任何 http 跳转也一律改写成 https（见 _rewriteToHttps）。
  // 登录后落到个人中心，脚本自己把 SPA 路由到 #/accountsecurity。
  static const portalHost = 'authserver.campus.invalid';
  static const portalUrl = 'https://$portalHost/authserver/login';

  @override
  State<PortalBindPage> createState() => _PortalBindPageState();
}

class _PortalBindPageState extends State<PortalBindPage> {
  static const _channelName = 'NuistPasskey';
  static const _scriptAsset = 'assets/js/portal_passkey.js';
  static const _vconsoleAsset = 'assets/js/vconsole.min.js';

  // 用桌面 UA 让门户走 PC 版页面，与参考脚本验证过的页面结构保持一致。
  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  late final WebViewController _controller;
  int _progress = 0;
  bool _finished = false;

  String _hint = '请登录统一门户';
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUserAgent)
      ..addJavaScriptChannel(
        _channelName,
        onMessageReceived: (m) => _onMessage(m.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
          onNavigationRequest: (request) {
            final https = _rewriteToHttps(request.url);
            if (https == null) return NavigationDecision.navigate;
            _controller.loadRequest(Uri.parse(https));
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            // 服务端 302 到 http 时 shouldOverrideUrlLoading 可能拦不到，兜底改写。
            final url = error.url;
            if (error.isForMainFrame == false || url == null) return;
            final https = _rewriteToHttps(url);
            if (https != null) _controller.loadRequest(Uri.parse(https));
          },
          // 登录后落到个人中心（URL 含 personCenter）就注入；跳到通行密钥页、
          // polyfill、等按钮都由脚本自己完成。URL 变化时也注入一次，尽量赶在
          // SPA 组件挂载前把 polyfill 装上；脚本自身幂等。
          onUrlChange: (change) => _injectIfPersonCenter(change.url),
          onPageFinished: (url) {
            // 先装 vConsole 再跑注册脚本：让我们的 XHR/fetch 钩子留在最外层，
            // 拦截不被 vConsole 的网络面板挡在里面。
            _injectVConsole();
            _injectIfPersonCenter(url);
          },
        ),
      );
    _start();
  }

  /// 指向门户的 http 地址返回对应的 https 地址，其余返回 null。
  static String? _rewriteToHttps(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'http') return null;
    if (uri.host != PortalBindPage.portalHost) return null;
    return uri.replace(scheme: 'https').toString();
  }

  Future<void> _start() async {
    // 清掉旧会话，保证绑定的是用户此刻登录的账号。
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {}
    await _controller.loadRequest(Uri.parse(PortalBindPage.portalUrl));
  }

  void _injectIfPersonCenter(String? url) {
    if (url == null || _finished) return;
    if (url.toLowerCase().contains('personcenter')) _inject();
  }

  /// debug 构建下往页面装一个 vConsole：手机右下角会出现绿色按钮，
  /// 能看页面自己的 console、网络请求、Element 和 Storage。release 不注入。
  ///
  /// runJavaScript 走 evaluateJavascript，不受页面 CSP 限制，所以直接把
  /// 整份源码丢进去执行，不用 <script src>。页面每次跳转都要重装，故放在
  /// onPageFinished；重复执行由 window.__vConsole 兜住。
  Future<void> _injectVConsole() async {
    if (!kDebugMode) return;
    try {
      final source = await rootBundle.loadString(_vconsoleAsset);
      if (!mounted) return;
      await _controller.runJavaScript(
        '$source\n'
        'window.__vConsole = window.__vConsole || new window.VConsole();',
      );
    } catch (e) {
      debugPrint('[vconsole] 注入失败：$e');
    }
  }

  static String get _deviceName {
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      final other => other.name,
    };
    return '$kAppName ($platform)';
  }

  Future<void> _inject() async {
    if (_finished) return;
    final script = (await rootBundle.loadString(_scriptAsset))
        .replaceFirst('__DEVICE_NAME__', jsonEncode(_deviceName));
    if (!mounted || _finished) return;
    await _controller.runJavaScript(script);
  }

  void _onMessage(String raw) {
    if (_finished) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'status':
        setState(() {
          _error = null;
          _hint = switch (msg['stage']) {
            'navigating' => '正在跳转到通行密钥页…',
            'waiting_page' => '等待页面加载…',
            'enabling_biometrics' => '正在开启生物识别登录…',
            'verifying' => '请在页面中完成身份验证（登录密码 + 验证码）',
            'registering' => '正在注册通行密钥…',
            _ => _hint,
          };
        });
      case 'error':
        setState(() => _error = msg['message'] as String? ?? '未知错误');
      case 'success':
        _onSuccess(msg['bundle']);
      case 'log':
        // 脚本只上报事件与接口返回码，不含凭据。
        if (kDebugMode) debugPrint('[portal_passkey] ${msg['message']}');
    }
  }

  Future<void> _onSuccess(Object? raw) async {
    if (raw is! Map) {
      setState(() => _error = '注册结果格式异常');
      return;
    }
    _finished = true;
    final bundle = PasskeyBundle.fromJson({
      ...raw.cast<String, dynamic>(),
      'deviceName': _deviceName,
      'createdAt': DateTime.now().toIso8601String(),
    });
    try {
      await PasskeyStore.save(bundle);
    } catch (e) {
      _finished = false;
      setState(() => _error = '凭据保存失败：$e');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('绑定成功'),
        content: Text('已注册通行密钥「${bundle.deviceName}」并保存到本机安全存储。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
    if (mounted) context.pop(true);
  }

  void _retry() {
    setState(() {
      _error = null;
      _hint = '正在重新加载…';
    });
    _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      appBar: AppBar(
        title: const Text('绑定统一门户'),
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
      body: Column(
        children: [
          Material(
            color: error == null
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Icon(
                    error == null ? Icons.info_outline : Icons.error_outline,
                    size: 18,
                    color: error == null
                        ? Theme.of(context).colorScheme.onPrimaryContainer
                        : Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error ?? _hint,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (error != null)
                    TextButton(onPressed: _retry, child: const Text('重试')),
                ],
              ),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
