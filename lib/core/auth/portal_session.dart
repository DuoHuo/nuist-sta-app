import 'dart:async';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../network/vpn_dio.dart';
import '../network/vpn_gateway.dart';
import 'aia_trust.dart';
import 'established_store.dart';
import 'nuist_login.dart';
import 'passkey_bundle.dart';
import 'passkey_store.dart';
import 'portal_exceptions.dart';
import 'portal_http.dart';
import 'secure_cookie_storage.dart';

/// 常用服务的 service 参数。
///
/// CAS 拿它做字符串精确匹配来校验 ticket，**不要随手改写大小写或尾斜杠**。
abstract final class PortalServices {
  static const jwxt =
      'https://jwxt.nuist.edu.cn/jwapp/sys/emaphome/portal/index.do';

  /// 校园一卡通（电费）。登录落地 URL 的 query 里带 `synjones-auth`，这才是
  /// icard 接口真正认的凭据，Cookie 在那边没用。
  static const icard =
      'https://icard.nuist.edu.cn/berserker-auth/cas/login/wisedu'
      '?targetUrl=https://icard.nuist.edu.cn/plat-pc/?name=loginTransit';

  /// 信息门户 i.nuist.edu.cn（学业数据等 cus 接口）。实测未登录访问会被
  /// 302 到 `authserver/login?service=https://i.nuist.edu.cn/login`。
  static const iportal = 'https://i.nuist.edu.cn/login';

  /// 创新创业实践教育平台 cxcyjy（双创学分的上级平台）。不是裸域名：平台
  /// 首页登录按钮直指这个回调，探测自 `/pt` 页面。CAS 落地后平台还要再由页面
  /// JS 补一次 POST 才算登录完成，见 InnovationCreditApi。
  static const cxcyjy =
      'https://cxcyjy.nuist.edu.cn/pt/HomePage/UnifiedAuthenticationLogin';

  /// 劳动教育平台。未登录访问业务页会被 302 到站内 `/AuthServer/Login`，
  /// 该页「统一认证」按钮经 `/UnifiedAuth/CASLogin` 再 302 到 CAS，service 即此。
  /// host 里的大写 L 是服务端原样给的，CAS 精确匹配字符串，**不能改小写**。
  static const labor = 'https://Labor.nuist.edu.cn/UnifiedAuth/CASLogin';
}

/// 统一门户的全局会话，是壳和所有小程序取用登录态的唯一入口。
///
/// 职责：
/// - 持有全局 CookieJar（落盘到安全存储，重启 APP 后会话还能接着用）；
/// - 记住每个 service 的落地 URL 并同样落盘，冷启动命中就一个请求都不发；
/// - 按需登录，并让并发调用合流，不会因为三个小程序同时启动就登三次；
/// - 复用 CAS 票根：第一个 service 走完整 WebAuthn 断言，之后换 service 由
///   服务端直接放行，省掉一次签名和两个来回；
/// - 把凭据失效（[PortalCredentialError]）单独暴露给 UI，用于提示重新绑定。
///
/// 典型用法：
/// ```dart
/// final response = await PortalSession.instance.request(
///   PortalServices.jwxt,
///   (http) => http.get(Uri.parse('https://jwxt.nuist.edu.cn/...')),
/// );
/// ```
class PortalSession {
  PortalSession._();

  static final PortalSession instance = PortalSession._();

  /// 落地 URL 缓存的信任期。超过后不再直接采信，重新走一次 SSO 快路径确认
  /// （CAS 票根若还在，代价只是两个跳转）。
  static const establishedTtl = Duration(hours: 12);

  /// 最近一次因凭据问题导致的失败；绑定状态页监听它来显示「已失效」。
  ///
  /// 只有确定不是网络问题时才会被置位（见 [PortalHttp.send] 的异常归类）。
  final ValueNotifier<PortalCredentialError?> credentialError = ValueNotifier(
    null,
  );

  late final PersistCookieJar _jar;
  late final PortalHttp _http;
  late final AiaTrust _trust;
  bool _ready = false;

  /// 已建立会话的 service → 落地 URL，冷启动时从磁盘恢复。
  final Map<String, EstablishedEntry> _established = {};

  /// 磁盘上的 [_established] 读回来了没有；取缓存前必须等它。
  late final Future<void> _restored;

  /// 同一个 service 的并发请求合并成一次登录。
  final Map<String, Future<String>> _pending = {};

  /// 登录串行化队列：让后来者等前一个把票根建起来，从而走 SSO 快路径。
  Future<void> _queue = Future.value();

  // ==================== 对外接口 ====================

  /// 确保 [service] 已登录，返回落地 URL。
  ///
  /// [force] 为 true 时无视缓存重新登录，用于会话过期后的重试；若此刻恰好有
  /// 同一个 service 的登录在飞，直接等它——它产出的必然是新会话，再排一次
  /// 纯属浪费。
  ///
  /// [trustRestored] 为 false 时不采信从磁盘恢复、本进程尚未验证过的缓存。
  /// 给没有过期探测能力的调用方（如 WebView 承载页）用，其余接口都能从业务
  /// 响应里发现过期并 force 重试，直接吃缓存就好。
  Future<String> ensureLoggedIn(
    String service, {
    bool force = false,
    bool trustRestored = true,
    void Function(String stage)? onStage,
  }) async {
    _ensureReady();
    await _restored;
    if (!force) {
      final cached = _lookup(service, trustRestored: trustRestored);
      if (cached != null) return cached;
    }
    final pending = _pending[service];
    if (pending != null) return pending;
    // 下面到登记 _pending 之间不能有 await，否则并发调用会漏过合流各登一次。
    if (force && _established.remove(service) != null) {
      unawaited(EstablishedStore.write(_established));
    }
    late final Future<String> future;
    future = _serialize(() => _performLogin(service, onStage)).whenComplete(() {
      if (identical(_pending[service], future)) _pending.remove(service);
    });
    _pending[service] = future;
    return future;
  }

  /// 拿到一个已登录 [service] 的 [PortalHttp]，其 dio 已带好会话 Cookie。
  ///
  /// 需要精细控制请求时用它；一般情况用 [request] 更省事。
  Future<PortalHttp> clientFor(String service, {bool force = false}) async {
    await ensureLoggedIn(service, force: force);
    return _http;
  }

  /// 共享全局 Cookie 的裸客户端，**不保证任何登录态**。
  ///
  /// 给「先拿落盘的会话直接请求业务页，被拦回登录页再走 [clientFor] 强制重登」
  /// 的子系统用（双创、劳动教育）：它们的会话独立于 CAS 票根，先登一遍 CAS
  /// 再发现子系统会话其实还活着，等于白跑。常规接口请走 [request] / [clientFor]。
  PortalHttp get http {
    _ensureReady();
    return _http;
  }

  /// 发一个带门户会话的请求，会话过期时自动重登一次并重放。
  ///
  /// [send] 可能被调用两次，所以别在里面放有副作用的逻辑。
  Future<Response<dynamic>> request(
    String service,
    Future<Response<dynamic>> Function(PortalHttp http) send,
  ) async {
    var http = await clientFor(service);
    var response = await http.followRedirects(await send(http));
    if (!_looksLikeLoginPage(response)) return response;

    // 被门户弹回了登录页，说明落盘的会话已经过期，重登一次再放行。
    portalLog('会话已过期，重新登录 $service');
    http = await clientFor(service, force: true);
    response = await http.followRedirects(await send(http));
    if (_looksLikeLoginPage(response)) {
      throw const PortalLoginError('重新登录后仍被门户拦回登录页，请稍后再试');
    }
    return response;
  }

  /// 把 [urls] 各自所需的会话 Cookie 灌进 WebView，让 H5 页面打开即登录态。
  ///
  /// WebViewCookie 只支持 name/value/domain/path，设不了 secure/httpOnly，
  /// 对 JSESSIONID 这类会话 Cookie 够用。Android 的 WebView Cookie 是进程级
  /// 共享的，灌一次全局生效。
  Future<void> syncToWebView(Iterable<String> urls) async {
    _ensureReady();
    final manager = WebViewCookieManager();
    // 顺带同步 authserver，WebView 里再点门户链接也不用重新登。
    final targets = {'${NuistLogin.authserverNormal}/', ...urls};
    for (final url in targets) {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasAuthority) continue;
      for (final cookie in await _jar.loadForRequest(uri)) {
        await manager.setCookie(
          WebViewCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain ?? uri.host,
            path: cookie.path ?? '/',
          ),
        );
      }
    }
  }

  /// 清空会话。解绑时应连带清掉 WebView，重新绑定时则要保留（留着门户的登录
  /// 态，用户就不必再输一遍密码）。
  Future<void> clear({bool includeWebView = false}) async {
    _ensureReady();
    await _restored;
    _established.clear();
    credentialError.value = null;
    await EstablishedStore.write(_established);
    await _jar.deleteAll();
    await VpnGateway.instance.reset();
    if (includeWebView) {
      try {
        await WebViewCookieManager().clearCookies();
      } catch (_) {}
    }
  }

  /// 作废当前会话后完整登录一次，用来验证本机凭据是否还被门户承认。
  ///
  /// 普通的 [ensureLoggedIn] 在 CAS 票根还有效时会走 SSO 快路径、压根不碰
  /// Passkey，那样验不出凭据有没有被吊销，所以这里先把会话清掉，逼它走一遍
  /// 完整的 WebAuthn 断言。
  Future<String> verifyCredential({
    String service = PortalServices.jwxt,
    void Function(String stage)? onStage,
  }) async {
    // 先等在飞的登录跑完：force 会合流到它，而它是在 clear 之前开始的，
    // 验不出凭据。
    await _queue;
    await clear();
    return ensureLoggedIn(service, force: true, onStage: onStage);
  }

  /// 仅供调试界面使用：列出访问 [url] 时会带上的 Cookie 名称与域。
  ///
  /// **只返回名字和域，不返回值** —— Cookie 值等同于登录态，不该出现在任何
  /// 能被截图或复制走的地方。
  Future<List<String>> debugCookieNames(String url) async {
    _ensureReady();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return const [];
    final cookies = await _jar.loadForRequest(uri);
    return [
      for (final cookie in cookies)
        '${cookie.name}@${cookie.domain ?? uri.host}',
    ];
  }

  // ==================== 内部实现 ====================

  void _ensureReady() {
    if (_ready) return;
    if (kDebugMode) portalLogger ??= debugPrint;
    _jar = PersistCookieJar(
      // CASTGC 和 JSESSIONID 都是会话 Cookie 且无 expires，这两个开关不开
      // 等于什么都没存（Python 版落盘时同样强调了这点）。
      persistSession: true,
      ignoreExpires: true,
      storage: const SecureCookieStorage(),
    );
    final trust = AiaTrust(
      resolveCacheDir: () async {
        final base = await getApplicationSupportDirectory();
        return Directory('${base.path}${Platform.pathSeparator}aia_certs');
      },
    );
    _trust = trust;
    final dio = vpnDio(
      options: BaseOptions(
        headers: {
          'User-Agent': NuistLogin.userAgent,
          'Accept-Language': 'zh-CN,en;q=0.9,en-US;q=0.8',
        },
      ),
      securityContext: trust.context,
      onBadCertificate: trust.onBadCertificate,
    )..interceptors.add(CookieManager(_jar));
    _http = PortalHttp(dio, trust: trust);
    _restored = EstablishedStore.read().then((entries) {
      // 只补本进程还没登过的：恢复是异步的，别把已经新鲜的条目覆盖成旧的。
      for (final MapEntry(:key, :value) in entries.entries) {
        _established.putIfAbsent(key, () => value);
      }
    });
    _ready = true;
  }

  /// 取 [service] 的缓存落地 URL；过期或不采信时返回 null。
  String? _lookup(String service, {required bool trustRestored}) {
    final entry = _established[service];
    if (entry == null) return null;
    if (entry.isExpired(establishedTtl)) {
      portalLog('落地缓存超过信任期，重新确认 $service');
      _established.remove(service);
      return null;
    }
    if (entry.restored && !trustRestored) return null;
    return entry.landing;
  }

  Future<String> _performLogin(
    String service,
    void Function(String stage)? onStage,
  ) async {
    _ensureReady();
    // 先把缓存的中间证书灌进信任库，这样冷启动第一次握手就能直接成功。
    await _trust.preload();
    final PasskeyBundle? bundle = await PasskeyStore.read();
    if (bundle == null) {
      throw const PortalCredentialError('尚未绑定统一门户，请先完成绑定');
    }
    try {
      portalLog('开始登录 service=$service');
      final landing = await NuistLogin(
        http: _http,
        bundle: bundle,
        onStage: (stage) {
          portalLog('阶段: $stage');
          onStage?.call(stage);
        },
      ).login(service);
      portalLog('登录成功，落地 $landing');
      _established[service] = EstablishedEntry(
        landing: landing,
        at: DateTime.now(),
      );
      credentialError.value = null;
      await EstablishedStore.write(_established);
      return landing;
    } on PortalCredentialError catch (e) {
      // 凭据被服务端拒绝，记下来让绑定状态页显示「已失效」。
      portalLog('凭据失效: ${e.message}');
      credentialError.value = e;
      rethrow;
    } on PortalException catch (e) {
      portalLog('登录失败(${e.runtimeType}): ${e.message}');
      rethrow;
    }
  }

  /// 串行化登录，并保证一次失败不会把队列卡死。
  Future<T> _serialize<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 响应是不是被门户弹回了登录页。
  static bool _looksLikeLoginPage(Response<dynamic> response) {
    if (response.realUri.path.contains(NuistLogin.loginPath)) return true;
    final body = response.data;
    return body is String &&
        body.contains('authserver/login') &&
        body.contains('name="execution"');
  }
}
