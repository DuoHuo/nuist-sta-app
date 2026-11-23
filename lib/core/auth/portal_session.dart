import 'dart:async';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:webview_flutter/webview_flutter.dart';

import '../config/campus_config.dart';
import '../logging/app_log.dart';
import '../logging/diagnostic_redactor.dart';
import '../logging/http_diagnostics.dart';
import '../network/vpn_gateway.dart';
import '../network/vpn_log.dart';
import 'campus_transport.dart';
import 'cas_session.dart';
import 'established_store.dart';
import 'nuist_login.dart';
import 'portal_cookie_manager.dart';
import 'portal_exceptions.dart';
import 'portal_http.dart';
import 'service_auth_spec.dart';
import 'session_executor.dart';

/// 常用服务的 service 参数。
///
/// CAS 拿它做字符串精确匹配来校验 ticket，**不要随手改写大小写或尾斜杠**。
abstract final class PortalServices {
  static final jwxt =
      'https://${CampusHosts.jwxt}/jwapp/sys/emaphome/portal/index.do';

  /// 校园一卡通（电费）。登录落地 URL 的 query 里带 `synjones-auth`，这才是
  /// icard 接口真正认的凭据，Cookie 在那边没用。
  ///
  /// service 是回调地址 `/berserker-auth/cas/callback/wisedu`，`redirectUrl`
  /// 的值在 service 内部已是一次编码的形式（`%3A`、`%2F`、`%3F`、`%3D`），
  /// 对应浏览器 CAS 登录 URL 里的二次编码，保持原样。
  static final icard =
      'https://${CampusHosts.icard}/berserker-auth/cas/callback/wisedu'
      '?redirectUrl=https%3A%2F%2F${CampusHosts.icard}'
      '%2Fplat-pc%2F%3Fname%3DloginTransit';

  /// 信息门户（学业数据等 cus 接口）。实测未登录访问会被 302 到
  /// `authserver/login?service=https://i.<校园根域>/login`。
  static final iportal = 'https://${CampusHosts.iportal}/login';

  /// 图书馆首页公开的 CAS 回调，service 中包含显式的 443 端口。
  static final library =
      'https://${CampusHosts.library}:443/meta-local/opac/cas/rosetta';

  /// 创新创业实践教育平台 cxcyjy（双创学分的上级平台）。不是裸域名：平台
  /// 首页登录按钮直指这个回调，探测自 `/pt` 页面。CAS 落地后平台还要再由页面
  /// JS 补一次 POST 才算登录完成，见 InnovationCreditApi。
  static final cxcyjy =
      'https://${CampusHosts.cxcyjy}/pt/HomePage/UnifiedAuthenticationLogin';

  /// 劳动教育平台。未登录访问业务页会被 302 到站内 `/AuthServer/Login`，
  /// 该页「统一认证」按钮经 `/UnifiedAuth/CASLogin` 再 302 到 CAS，service 即此。
  /// 主机名统一小写后已实测 CAS 校验通过。
  static final labor = 'https://${CampusHosts.labor}/UnifiedAuth/CASLogin';
}

/// 本次取得的真实落地地址及其诊断依据；诊断副本已脱敏，业务地址保持原样。
class PortalLoginResult {
  const PortalLoginResult({
    required this.landing,
    required this.diagnosticContext,
  });

  final String landing;
  final Map<String, Object?> diagnosticContext;
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
///   (http) => http.get(Uri.parse('https://jwxt.<校园根域>/...')),
/// );
/// ```
class PortalSession {
  static final _log = AppLog.logger('core.auth.portal_session');
  PortalSession._({
    CasSession? cas,
    Future<void> Function()? prepareNetwork,
    Future<void> Function()? resetNetwork,
    this._createHttp,
    Future<Map<String, EstablishedEntry>> Function()? readEstablished,
    Future<void> Function(Map<String, EstablishedEntry>)? writeEstablished,
  }) : _cas = cas ?? CasSession.instance,
       _prepareNetwork = prepareNetwork ?? VpnGateway.instance.prepare,
       _resetNetwork = resetNetwork ?? VpnGateway.instance.reset,
       _readEstablished = readEstablished ?? EstablishedStore.read,
       _writeEstablished = writeEstablished ?? EstablishedStore.write;

  /// 在测试中注入合成认证服务器与本地存储，不连接学校或加载 VPN 原生库。
  @visibleForTesting
  factory PortalSession.forTesting({
    required CasSession cas,
    required PortalHttp Function(CookieJar jar) createHttp,
    Future<void> Function()? prepareNetwork,
    Future<void> Function()? resetNetwork,
    Future<Map<String, EstablishedEntry>> Function()? readEstablished,
    Future<void> Function(Map<String, EstablishedEntry>)? writeEstablished,
  }) => PortalSession._(
    cas: cas,
    createHttp: createHttp,
    prepareNetwork: prepareNetwork ?? () async {},
    resetNetwork: resetNetwork ?? () async {},
    readEstablished: readEstablished ?? () async => {},
    writeEstablished: writeEstablished ?? (_) async {},
  );

  static final PortalSession instance = PortalSession._();

  /// 仅供清理顺序回归检查，不暴露落地地址或凭据。
  @visibleForTesting
  int get debugEstablishedCount => _established.length;

  /// 业务落地缓存保留原来的 12 小时信任期。
  static const establishedTtl = Duration(hours: 12);
  static const _loginTimeout = Duration(seconds: 90);

  final CasSession _cas;
  final Future<void> Function() _prepareNetwork;
  final Future<void> Function() _resetNetwork;
  final PortalHttp Function(CookieJar jar)? _createHttp;
  final Future<Map<String, EstablishedEntry>> Function() _readEstablished;
  final Future<void> Function(Map<String, EstablishedEntry>) _writeEstablished;

  /// 最近一次因凭据问题导致的失败；绑定状态页监听它来显示「已失效」。
  ///
  /// 只有确定不是网络问题时才会被置位（见 [PortalHttp.send] 的异常归类）。
  ValueNotifier<PortalCredentialError?> get credentialError =>
      _cas.credentialError;

  late CookieJar _jar;
  late PortalHttp _http;
  late CampusTransport _transport;
  SessionExecutor? _executor;

  /// 门户小程序的声明式鉴权与请求执行入口。
  SessionExecutor get executor {
    _ensureReady();
    return _executor!;
  }

  int? _clientGeneration;
  bool _ready = false;
  Future<void>? _clearing;
  bool _clearWebView = false;
  Future<void> _saving = Future.value();
  Future<void> _webViewQueue = Future.value();

  /// 已建立会话的 service → 落地 URL，冷启动时从磁盘恢复。
  final Map<String, EstablishedEntry> _established = {};

  /// 磁盘上的 [_established] 读回来了没有；取缓存前必须等它。
  late final Future<void> _restored;

  /// 同一个 service 的并发请求合并成一次登录。
  final Map<String, Future<PortalLoginResult>> _pending = {};
  final Map<String, bool> _pendingFreshWebAuthn = {};
  final Map<String, int> _pendingIds = {};
  static int _loginSequence = 0;

  // ==================== 对外接口 ====================

  /// 确保 [service] 已登录，返回落地 URL。
  ///
  /// [force] 为 true 时无视缓存重新登录，用于会话过期后的重试；若此刻恰好有
  /// 同一个 service 的登录在飞，直接等它——它产出的必然是新会话，再排一次
  /// 纯属浪费。
  ///
  /// [trustRestored] 为 false 时不采信从磁盘恢复、本进程尚未验证过的缓存。
  /// 给无法在页面内恢复会话的 WebView 使用，其他业务仍按原有流程重试。
  Future<String> ensureLoggedIn(
    String service, {
    bool force = false,
    bool trustRestored = true,
    void Function(String stage)? onStage,
  }) async => (await _ensureLoggedIn(
    service,
    force: force,
    trustRestored: trustRestored,
    onStage: onStage,
    loadCachedResponse: false,
  )).landing;

  /// 取得落地地址，并为当前操作补入其来源和原登录响应；旧缓存缺证据时明确说明。
  Future<PortalLoginResult> ensureLoggedInWithEvidence(
    String service, {
    bool force = false,
    bool trustRestored = true,
    void Function(String stage)? onStage,
  }) => _ensureLoggedIn(
    service,
    force: force,
    trustRestored: trustRestored,
    onStage: onStage,
    loadCachedResponse: true,
  );

  Future<PortalLoginResult> _ensureLoggedIn(
    String service, {
    required bool force,
    required bool trustRestored,
    required bool loadCachedResponse,
    bool forceFreshWebAuthn = false,
    void Function(String stage)? onStage,
  }) async {
    _ensureReady();
    if (_clearing case final clearing?) await clearing;
    final generation = _cas.cookies.generation;
    _ensureReady();
    await _restored;
    _cas.cookies.checkGeneration(generation);
    final pending = _pending[service];
    if (pending != null) {
      if (forceFreshWebAuthn && _pendingFreshWebAuthn[service] != true) {
        try {
          await pending;
        } catch (_) {
          // 显式验证仍须开始新的完整认证，旧普通登录的失败不能替代它。
        }
        _cas.cookies.checkGeneration(generation);
        return _ensureLoggedIn(
          service,
          force: true,
          trustRestored: trustRestored,
          loadCachedResponse: loadCachedResponse,
          forceFreshWebAuthn: true,
          onStage: onStage,
        );
      }
      _log.debug(
        'service.login_joined',
        fields: {
          'service': AppLog.serviceForHost(Uri.parse(service).host),
          'shared_login_id': _pendingIds[service],
        },
      );
      final shared = await pending;
      _cas.cookies.checkGeneration(generation);
      final details = Map<String, Object?>.from(shared.diagnosticContext)
        ..['shared_login'] = true
        ..['http_performed_for_this_lookup'] = false
        ..['lookup_note'] = '本次复用正在进行的登录，响应来自同一个共享登录任务';
      AppLog.addEvidence('portal.landing', details);
      return PortalLoginResult(
        landing: shared.landing,
        diagnosticContext: Map.unmodifiable(details),
      );
    }
    if (!force) {
      final cached = _lookup(service, trustRestored: trustRestored);
      if (cached != null) {
        final result = await _landingResult(
          service,
          cached,
          source: cached.restored ? 'restored' : 'memory',
          loadCachedResponse: loadCachedResponse,
        );
        // 读取诊断文件期间可能解绑；新增的 await 不能让旧凭据继续出网。
        _cas.cookies.checkGeneration(generation);
        if (!cached.restored) {
          executor.restoreSession(
            _PortalLandingSpec(service),
            Response<dynamic>(
              requestOptions: RequestOptions(path: cached.landing),
              statusCode: 200,
            ),
          );
        }
        return result;
      }
    }
    // 下面到登记 _pending 之间不能有 await，否则并发调用会漏过合流各登一次。
    if (force && _established.remove(service) != null) {
      unawaited(_persist());
    }
    late final Future<PortalLoginResult> future;
    final cancelToken = CancelToken();
    final loginId = ++_loginSequence;
    final queued = Stopwatch()..start();
    var phase = 'service.queue';
    final fields = <String, Object?>{
      'service': AppLog.serviceForHost(Uri.parse(service).host),
      'force': force,
      'login_id': loginId,
    };
    future = _log
        .operation(
          'service.login',
          () => _withLoginTimeout(
            () {
              phase = 'service.login';
              _log.debug(
                'service.login_dequeued',
                fields: {...fields, 'queued_ms': queued.elapsedMilliseconds},
              );
              return _performLogin(
                service,
                generation,
                onStage,
                cancelToken,
                forceFreshWebAuthn: forceFreshWebAuthn,
              );
            },
            onTimeout: () => cancelToken.cancel('业务登录整体超时'),
            stage: () => phase,
            context: fields,
          ),
          fields: fields,
          successLevel: AppLogLevel.debug,
          failureLevel: AppLogLevel.warning,
        )
        .whenComplete(() {
          if (identical(_pending[service], future)) {
            _pending.remove(service);
            _pendingFreshWebAuthn.remove(service);
            _pendingIds.remove(service);
          }
        });
    _pendingIds[service] = loginId;
    _pending[service] = future;
    _pendingFreshWebAuthn[service] = forceFreshWebAuthn;
    final result = await future;
    AppLog.addEvidence('portal.landing', result.diagnosticContext);
    return result;
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
  /// 用于双创、劳动教育等自行判断业务会话是否失效的查询。
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
  ) => _log.operation(
    'service.request',
    () async {
      _ensureReady();
      if (_clearing case final clearing?) await clearing;
      await ensureLoggedIn(service);
      return executor.executeCallback(
        _PortalLandingSpec(service),
        () async => _http.followRedirects(await send(_http)),
      );
    },
    fields: {
      'service': AppLog.serviceForHost(Uri.tryParse(service)?.host ?? ''),
    },
    resultFields: (response) => {'status_code': response.statusCode},
    successLevel: AppLogLevel.debug,
    failureLevel: AppLogLevel.warning,
  );

  /// 把 [urls] 各自所需的会话 Cookie 灌进 WebView，让 H5 页面打开即登录态。
  ///
  /// WebViewCookie 只支持 name/value/domain/path，设不了 secure/httpOnly，
  /// 对 JSESSIONID 这类会话 Cookie 够用。Android 的 WebView Cookie 是进程级
  /// 共享的，灌一次全局生效。
  Future<void> syncToWebView(Iterable<String> urls) async {
    _ensureReady();
    await _restored;
    if (_clearing case final clearing?) await clearing;
    _ensureReady();
    final generation = _cas.cookies.generation;
    final jar = _jar;
    return _serializeWebView(() async {
      final manager = WebViewCookieManager();
      // 顺带同步 authserver，WebView 里再点门户链接也不用重新登。
      final targets = {
        '${NuistLogin.authserverNormal}/authserver/login',
        ...urls,
      };
      for (final url in targets) {
        final uri = Uri.tryParse(url);
        if (uri == null || !uri.hasAuthority) continue;
        for (final cookie in await jar.loadForRequest(uri)) {
          _cas.cookies.checkGeneration(generation);
          await manager.setCookie(
            WebViewCookie(
              name: cookie.name,
              value: cookie.value,
              domain: cookie.domain ?? uri.host,
              path: cookie.path ?? '/',
            ),
          );
          _cas.cookies.checkGeneration(generation);
        }
        _cas.cookies.checkGeneration(generation);
      }
    });
  }

  /// 清空会话。解绑时应连带清掉 WebView，重新绑定时则要保留（留着门户的登录
  /// 态，用户就不必再输一遍密码）。
  Future<void> clear({bool includeWebView = false}) {
    _clearWebView |= includeWebView;
    if (_clearing case final clearing?) return clearing;
    _ensureReady();
    _cas.cookies.invalidateAccount();
    _cas.closeClient(resetQueue: true);
    _executor?.cancelPending();
    _http.dio.close(force: true);
    late final Future<void> clearing;
    clearing =
        () async {
          try {
            await _resetNetwork();
          } finally {
            await _restored;
            await _cas.cookies.deleteAll();
            _established.clear();
            _executor?.clear();
            _clientGeneration = null;
            _pending.clear();
            _pendingFreshWebAuthn.clear();
            _pendingIds.clear();
            credentialError.value = null;
            await _persist();
            if (_clearWebView) {
              try {
                await _serializeWebView(() async {
                  await WebViewCookieManager().clearCookies();
                });
              } catch (error, stackTrace) {
                _log.warning(
                  'webview.clear_failed',
                  error: error,
                  stackTrace: stackTrace,
                  fields: {
                    'stage': 'session.clear_webview',
                    'reason_code': 'webview_cookie_clear_failed',
                  },
                );
              }
            }
          }
        }().whenComplete(() {
          if (identical(_clearing, clearing)) _clearing = null;
          _clearWebView = false;
        });
    return _clearing = clearing;
  }

  /// 强制完整 WebAuthn 并重新落地目标服务，验证本机凭据是否仍被门户承认。
  ///
  /// 普通的 [ensureLoggedIn] 在 CAS 票根还有效时会走 SSO 快路径、压根不碰
  /// Passkey，那样验不出凭据有没有被吊销。这里只清认证域和目标服务的 Cookie，
  /// 保留账号代次、其他服务请求和现有 VPN 隧道。
  Future<String> verifyCredential({
    String? service,
    void Function(String stage)? onStage,
  }) async {
    final target = service ?? PortalServices.jwxt;
    return (await _ensureLoggedIn(
      target,
      force: true,
      trustRestored: false,
      loadCachedResponse: false,
      forceFreshWebAuthn: true,
      onStage: onStage,
    )).landing;
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
    portalEventLogger ??= (event, fields) =>
        AppLog.logger('core.auth.portal').debug(event, fields: fields);
    final generation = _cas.cookies.generation;
    if (!_ready) {
      _restored = _readEstablished()
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              vpnLog(
                'session.cache_timeout',
                fields: {'outcome': 'cache_fallback'},
              );
              return {};
            },
          )
          .then((entries) {
            if (generation != _cas.cookies.generation) return;
            for (final MapEntry(:key, :value) in entries.entries) {
              _established.putIfAbsent(key, () => value);
            }
          });
      _ready = true;
    }
    if (_clientGeneration == generation) return;
    if (_clientGeneration != null) _http.dio.close(force: true);
    _clientGeneration = generation;
    _jar = _cas.cookies.openJar();
    if (_createHttp case final factory?) {
      _http = factory(_jar);
      final index = _http.dio.interceptors.indexWhere(
        (item) => item is PortalCookieManager,
      );
      if (index >= 0) {
        _http.dio.interceptors[index] = PortalCookieManager(
          _jar,
          store: _cas.cookies,
          checkSession: () => _cas.cookies.checkGeneration(generation),
        );
      }
      _transport = CampusTransport.fromDio(
        _http.dio,
        cookieStore: _cas.cookies,
      );
      _executor = SessionExecutor(
        transport: _transport,
        authenticator: _cas,
        cookieStore: _cas.cookies,
      );
      return;
    }
    _transport = CampusTransport.authenticated(
      cookieStore: _cas.cookies,
      options: BaseOptions(
        headers: {
          'User-Agent': NuistLogin.userAgent,
          'Accept-Language': 'zh-CN,en;q=0.9,en-US;q=0.8',
        },
      ),
      beforeRequest: () async {
        if (_clearing case final clearing?) await clearing;
        _cas.cookies.checkGeneration(generation);
        await _prepareNetwork();
        _cas.cookies.checkGeneration(generation);
      },
      checkSession: () => _cas.cookies.checkGeneration(generation),
    );
    _http = PortalHttp(_transport.dio, trust: _transport.trust);
    _executor = SessionExecutor(
      transport: _transport,
      authenticator: _cas,
      cookieStore: _cas.cookies,
    );
  }

  /// 取 [service] 的缓存落地 URL；过期或不采信时返回 null。
  EstablishedEntry? _lookup(String service, {required bool trustRestored}) {
    final entry = _established[service];
    if (entry == null) {
      portalLog(
        'session.cache_miss',
        fields: {'host': Uri.parse(service).host},
      );
      return null;
    }
    if (entry.isExpired(establishedTtl)) {
      portalLog(
        'session.cache_expired',
        fields: {
          'host': Uri.parse(service).host,
          'details': {
            'age_ms': DateTime.now().difference(entry.at).inMilliseconds,
            'ttl_ms': establishedTtl.inMilliseconds,
            'restored': entry.restored,
          },
        },
      );
      _established.remove(service);
      return null;
    }
    if (entry.restored && !trustRestored) {
      portalLog(
        'session.cache_not_trusted',
        fields: {'host': Uri.parse(service).host},
      );
      return null;
    }
    portalLog(
      'session.cache_hit',
      fields: {
        'host': Uri.parse(service).host,
        'cache_source': entry.restored ? 'restored' : 'memory',
      },
    );
    return entry;
  }

  Future<PortalLoginResult> _landingResult(
    String service,
    EstablishedEntry entry, {
    required String source,
    bool loadCachedResponse = true,
    bool publishEvidence = true,
    Map<String, Object?>? currentEvidence,
  }) async {
    Map<String, Object?>? responseEvidence = currentEvidence;
    String? unavailableReason;
    final reference = entry.diagnosticRecord;
    if (responseEvidence == null) {
      if (reference == null) {
        unavailableReason = entry.restored
            ? 'restored_landing_only'
            : 'landing_response_not_recorded';
      } else if (!loadCachedResponse) {
        unavailableReason = 'not_loaded_for_plain_lookup';
      } else {
        try {
          final record = await AppLog.readRecord(reference);
          final attrs = record?['attrs'];
          final exchange = attrs is Map ? attrs['details'] : null;
          final event = record?['event'];
          final response = exchange is Map ? exchange['response'] : null;
          final status = response is Map
              ? response['status'] ?? response['status_code']
              : null;
          if (const {'http.exchange', 'http.exchange_failed'}.contains(event) &&
              response is Map &&
              status is int &&
              status >= 100 &&
              status <= 599 &&
              (response.containsKey('body') ||
                  response.containsKey('body_base64'))) {
            responseEvidence = {
              'record_ref': reference,
              'exchange': Map<String, Object?>.from(exchange as Map),
            };
          } else {
            final missing = exchange is Map
                ? exchange['incomplete_reason']
                : null;
            final responseMissing = response is Map
                ? response['incomplete_reason']
                : null;
            unavailableReason = record == null
                ? 'diagnostic_record_expired_removed_or_unavailable'
                : !const {
                    'http.exchange',
                    'http.exchange_failed',
                  }.contains(event)
                ? 'diagnostic_record_not_http_exchange'
                : missing is String
                ? missing
                : responseMissing is String
                ? responseMissing
                : 'diagnostic_response_body_unavailable';
          }
        } catch (error, stackTrace) {
          unavailableReason = 'diagnostic_record_read_failed';
          _log.warning(
            'diagnostics.record_read_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }
    final uri = Uri.tryParse(entry.landing);
    final queryNames = <String>[];
    var authorizationParameterPresent = false;
    var authorizationPresent = false;
    var queryDecoded = uri != null;
    if (uri != null) {
      try {
        queryNames.addAll(uri.queryParametersAll.keys);
        authorizationParameterPresent = queryNames.contains('synjones-auth');
        authorizationPresent =
            uri.queryParameters['synjones-auth']?.isNotEmpty == true;
      } on FormatException {
        queryDecoded = false;
      }
    }
    final details = Map<String, Object?>.from(
      DiagnosticRedactor.value({
        'service': AppLog.serviceForHost(Uri.parse(service).host),
        'landing_url': entry.landing,
        'source': source,
        'shared_login': false,
        'http_performed_for_this_lookup': source == 'fresh',
        'lookup_note': source == 'fresh'
            ? '落地地址来自本次登录的实际HTTP响应'
            : '本次直接使用会话缓存，没有发起HTTP请求',
        'cached_at': entry.at.toUtc().toIso8601String(),
        'cache_age_ms': DateTime.now().difference(entry.at).inMilliseconds,
        'query_parameter_names': queryNames,
        'query_decoded': queryDecoded,
        'authorization_parameter_present': authorizationParameterPresent,
        'authorization_present': authorizationPresent,
        'fragment_present': uri?.hasFragment ?? false,
        'original_response_available': responseEvidence != null,
        'original_response_unavailable_reason': ?unavailableReason,
        'record_ref': ?reference,
        'landing_response': ?responseEvidence,
      }) as Map,
    );
    if (publishEvidence) {
      AppLog.addEvidence(
        loadCachedResponse ? 'portal.landing' : 'portal.landing_reference',
        details,
      );
    }
    return PortalLoginResult(
      landing: entry.landing,
      diagnosticContext: Map.unmodifiable(details),
    );
  }

  Future<PortalLoginResult> _performLogin(
    String service,
    int generation,
    void Function(String stage)? onStage,
    CancelToken cancelToken, {
    required bool forceFreshWebAuthn,
  }) async {
    void check() {
      _cas.cookies.checkGeneration(generation);
      if (cancelToken.isCancelled) {
        throw const PortalNetworkError(
          '业务登录已超时，请重试',
          code: 'service_login_cancelled',
          stage: 'service.login',
        );
      }
    }

    check();
    _ensureReady();
    final host = Uri.parse(service).host;
    try {
      await _prepareNetwork();
      check();
      portalLog('session.restore_started', fields: {'host': host});
      final sessionEntry = await executor.ensureSession(
        _PortalLandingSpec(service, cancelToken: cancelToken),
        force: true,
        forceFreshWebAuthn: forceFreshWebAuthn,
        onStage: onStage,
      );
      final response = sessionEntry.session;
      check();
      final responseEvidence =
          httpDiagnosticEvidence(response.requestOptions) ??
          {
            'exchange': DiagnosticRedactor.value({
              'capture_source': 'portal_response_object',
              'request': {
                'url': response.requestOptions.uri.toString(),
                'headers': response.requestOptions.headers,
              },
              'response': {
                'url': response.realUri.toString(),
                'status': response.statusCode,
                'headers': response.headers.map,
                'body': response.data,
              },
            }),
          };
      if (_looksLikeLoginPage(response) || (response.statusCode ?? 0) >= 400) {
        AppLog.addEvidence('portal.landing_response', responseEvidence);
        throw PortalLoginError(
          '业务登录未完成，请稍后再试',
          code: _looksLikeLoginPage(response)
              ? 'service_returned_to_login'
              : 'service_status_rejected',
          stage: 'service.landing',
          context: {
            'service': AppLog.serviceForHost(host),
            'status_code': response.statusCode,
          },
        );
      }
      final landing = response.realUri.toString();
      check();
      portalLog('session.restored', fields: {'host': host});
      final responseReference = responseEvidence['record_ref'];
      final entry = EstablishedEntry(
        landing: landing,
        at: DateTime.now(),
        diagnosticRecord: responseReference is Map
            ? Map<String, Object?>.from(responseReference)
            : null,
      );
      _established[service] = entry;
      await _persist();
      check();
      return await _landingResult(
        service,
        entry,
        source: 'fresh',
        currentEvidence: responseEvidence,
        publishEvidence: false,
      );
    } on PortalCredentialError catch (e) {
      // 凭据被服务端拒绝，记下来让绑定状态页显示「已失效」。
      check();
      credentialError.value = e;
      rethrow;
    } on SocketException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        PortalNetworkError(
          '无法建立校园网络连接，请检查网络后重试',
          code: 'service_socket_failed',
          stage: 'service.login',
          cause: error,
          causeStackTrace: stackTrace,
        ),
        stackTrace,
      );
    } on TimeoutException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        PortalNetworkError(
          '校园网络准备超时，请检查网络后重试',
          code: 'service_prepare_timeout',
          stage: 'service.login',
          cause: error,
          causeStackTrace: stackTrace,
        ),
        stackTrace,
      );
    } catch (_) {
      // 清会话会关闭旧客户端；由代次判断区分取消与真实业务故障。
      check();
      rethrow;
    }
  }

  Future<void> _persist() {
    final snapshot = Map<String, EstablishedEntry>.of(_established);
    final result = _saving.then((_) => _writeEstablished(snapshot));
    _saving = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _serializeWebView(Future<void> Function() task) {
    final result = _webViewQueue.then((_) => task());
    _webViewQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 仅限制本次兼容门面的等待时间；登录合流和域协调由执行器负责。
  Future<T> _withLoginTimeout<T>(
    Future<T> Function() task, {
    void Function()? onTimeout,
    String Function()? stage,
    Map<String, Object?> context = const {},
  }) {
    return Future<T>.sync(task).timeout(
      _loginTimeout,
      onTimeout: () {
        onTimeout?.call();
        vpnLog('session.login_timeout');
        throw PortalNetworkError(
          '业务登录超时，请检查网络后重试',
          code: 'service_login_timeout',
          stage: stage?.call() ?? 'service.login',
          context: {...context, 'timeout_ms': _loginTimeout.inMilliseconds},
        );
      },
    );
  }

  /// 响应是不是被门户弹回了登录页。
  static bool _looksLikeLoginPage(Response<dynamic> response) {
    return isGlobalAuthExpired(response);
  }
}

/// 仅保留给 H5 与绑定界面的通用 CAS 落地兼容契约。
class _PortalLandingSpec extends ServiceAuthSpec<Response<dynamic>> {
  const _PortalLandingSpec(this.casServiceUrl, {this.cancelToken});
  final CancelToken? cancelToken;
  @override
  final String casServiceUrl;
  @override
  String get id => 'landing.$casServiceUrl';
  @override
  List<String> get cookieHosts => [Uri.parse(casServiceUrl).host];
  @override
  Future<Response<dynamic>> establish(
    CampusTransport transport,
    Uri casLandingUri,
  ) async {
    final response = await transport.get(
      casLandingUri,
      cancelToken: cancelToken,
    );
    if (isGlobalAuthExpired(response) || (response.statusCode ?? 0) >= 400) {
      throw PortalLoginError(
        '业务登录未完成，请稍后再试',
        code: isGlobalAuthExpired(response)
            ? 'service_returned_to_login'
            : 'service_status_rejected',
        stage: 'service.landing',
        context: {'status_code': response.statusCode},
      );
    }
    return response;
  }
}
