import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../config/campus_config.dart';
import '../logging/http_diagnostics.dart';
import '../logging/diagnostic_error.dart';
import '../network/vpn_dio.dart';
import '../network/vpn_http_adapter.dart';
import '../network/vpn_log.dart';
import 'aia_trust.dart';
import 'cas_session.dart';
import 'portal_cookie_manager.dart';
import 'portal_cookie_store.dart';
import 'portal_exceptions.dart';

/// Cookie 装载前准备校园传输，不承担任何子系统鉴权职责。
class VpnPreparationInterceptor extends Interceptor {
  VpnPreparationInterceptor(
    this.dio, {
    this.beforeRequest,
    this.timeout = const Duration(seconds: 70),
  });
  final Dio dio;
  final Future<void> Function()? beforeRequest;
  final Duration timeout;
  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final log = VpnRequestLog.start(options, managedByInterceptor: true)!;
    try {
      await log.run(() async {
        final preparing = () async {
          if (beforeRequest != null) {
            await beforeRequest!();
            return;
          }
          final adapter = unwrapHttpDiagnostics(dio.httpClientAdapter);
          if (adapter is! VpnHttpClientAdapter) return;
          final forced =
              options.extra[forceVpnKey] as bool? ?? adapter.forceVpn;
          final useVpn =
              forced ||
              await adapter.detectCampusNetwork?.call() !=
                  CampusNetworkState.onCampus;
          if (useVpn && adapter.connector is VpnPreparedConnector) {
            await (adapter.connector as VpnPreparedConnector).prepare();
          }
        }().timeout(timeout);
        final cancelled = options.cancelToken?.whenCancel.then<void>(
          (error) => throw error,
        );
        await (cancelled == null
            ? preparing
            : Future.any([preparing, cancelled]));
      });
      if (options.cancelToken?.isCancelled == true) {
        throw options.cancelToken!.cancelError!;
      }
      log.preparationMs = log.watch.elapsedMilliseconds;
      handler.next(options);
    } catch (error, stack) {
      final failure = error is TimeoutException
          ? PortalNetworkError(
              '校园网络准备超时，请检查网络后重试',
              code: 'request_preparation_timeout',
              stage: 'request.prepare',
              cause: error,
              causeStackTrace: stack,
              context: {'timeout_ms': timeout.inMilliseconds},
            )
          : error;
      log.fail(failure);
      handler.reject(
        error is DioException
            ? error
            : DioException(
                requestOptions: options,
                error: failure,
                stackTrace: stack,
              ),
        true,
      );
    }
  }
}

/// 校园证书预补链及握手缺链修复，与 Cookie 和业务会话相互独立。
class AiaTrustInterceptor extends Interceptor {
  AiaTrustInterceptor(this.dio, this.trust, {Set<String>? prepareHosts})
    : prepareHosts = prepareHosts ?? {CampusHosts.icard};
  final Dio dio;
  final AiaTrust trust;
  final Set<String> prepareHosts;
  void _reset() {
    final adapter = unwrapHttpDiagnostics(dio.httpClientAdapter);
    if (adapter is VpnHttpClientAdapter) {
      adapter.resetClients();
    } else if (adapter is IOHttpClientAdapter) {
      adapter.close(force: true);
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: trust.createHttpClient,
      );
      installHttpDiagnostics(dio);
    }
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final adapter = unwrapHttpDiagnostics(dio.httpClientAdapter);
      if (adapter is IOHttpClientAdapter || adapter is VpnHttpClientAdapter) {
        final previous = trust.context;
        await trust.preload();
        var repaired = false;
        if (prepareHosts.contains(options.uri.host)) {
          repaired = await trust.prepareHost(
            options.uri,
            createProbeClient: adapter is VpnHttpClientAdapter
                ? adapter.createPreparationClient
                : null,
            createFetchClient: adapter is VpnHttpClientAdapter
                ? adapter.createPreparationClient
                : null,
          );
        }
        if (repaired || !identical(previous, trust.context)) _reset();
      }
      handler.next(options);
    } catch (error, stack) {
      handler.reject(
        DioException(requestOptions: options, error: error, stackTrace: stack),
        true,
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.requestOptions.extra['_aiaRepaired'] == true ||
        !AiaTrust.isHandshakeFailure(err.error) ||
        err.requestOptions.data is Stream ||
        err.requestOptions.cancelToken?.isCancelled == true) {
      handler.next(err);
      return;
    }
    try {
      final adapter = unwrapHttpDiagnostics(dio.httpClientAdapter);
      final repaired = await trust.tryRepair(
        err.requestOptions.uri.host,
        createFetchClient: adapter is VpnHttpClientAdapter
            ? () => adapter.createRoutedClient(
                useVpn: err.requestOptions.extra['vpnDio.usedVpn'] == true,
              )
            : null,
      );
      if (!repaired) {
        handler.next(err);
        return;
      }
      _reset();
      err.requestOptions.extra['_aiaRepaired'] = true;
      if (err.requestOptions.data is FormData) {
        err.requestOptions.data = (err.requestOptions.data as FormData).clone();
      }
      handler.resolve(await dio.fetch<dynamic>(err.requestOptions));
    } catch (failure, stack) {
      handler.next(
        failure is DioException
            ? failure
            : DioException(
                requestOptions: err.requestOptions,
                error: failure,
                stackTrace: stack,
              ),
      );
    }
  }
}

/// 每跳都经过 Cookie 与诊断拦截器，并按协议保留或转换请求方法。
class ManualRedirectInterceptor extends Interceptor {
  ManualRedirectInterceptor(this.transport);
  final CampusTransport transport;
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final validate = options.validateStatus;
    options.extra.putIfAbsent('_redirectValidateStatus', () => validate);
    options.validateStatus = (status) =>
        CampusTransport.isRedirect(status) || validate(status);
    options.followRedirects = false;
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    VpnRequestLog.of(response.requestOptions)?.complete(
      response.statusCode,
      response.realUri,
      response.headers.value('location'),
    );
    if (response.requestOptions.extra['followRedirects'] == false ||
        !CampusTransport.isRedirect(response.statusCode)) {
      handler.next(response);
      return;
    }
    try {
      handler.resolve(await transport.followRedirects(response));
    } catch (error, stack) {
      handler.reject(
        error is DioException
            ? error
            : DioException(
                requestOptions: response.requestOptions,
                error: error,
                stackTrace: stack,
              ),
        true,
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    VpnRequestLog.of(err.requestOptions)
        ?.fail(err, status: err.response?.statusCode);
    handler.next(err);
  }
}

/// 校园纯传输入口；认证模式只比无状态模式多一个 Cookie 拦截器。
class CampusTransport {
  CampusTransport.authenticated({
    Dio? dio,
    BaseOptions? options,
    PortalCookieStore? cookieStore,
    bool forceVpn = false,
    AiaTrust? trust,
    Future<void> Function()? beforeRequest,
    void Function()? checkSession,
  }) : this._(
         dio: dio,
         options: options,
         cookieStore: cookieStore ?? CasSession.instance.cookies,
         forceVpn: forceVpn,
         trust: trust,
         beforeRequest: beforeRequest,
         checkSession: checkSession,
       );
  CampusTransport.stateless({
    Dio? dio,
    BaseOptions? options,
    bool forceVpn = false,
    AiaTrust? trust,
  }) : this._(
         dio: dio,
         options: options,
         forceVpn: forceVpn,
         trust: trust,
         stateless: true,
       );

  /// 供 CAS 和既有 PortalHttp 包装已配置的直连客户端，不重复装载 Cookie。
  CampusTransport.fromDio(
    Dio dio, {
    AiaTrust? trust,
    PortalCookieStore? cookieStore,
    bool installInterceptors = true,
  }) : this._(
         dio: dio,
         trust: trust,
         cookieStore: cookieStore,
         installInterceptors: installInterceptors,
       );
  CampusTransport._({
    Dio? dio,
    BaseOptions? options,
    this.cookieStore,
    bool forceVpn = false,
    AiaTrust? trust,
    bool installInterceptors = true,
    Future<void> Function()? beforeRequest,
    void Function()? checkSession,
    bool stateless = false,
  }) : trust = trust ?? AiaTrust.shared {
    if (stateless &&
        dio != null &&
        dio.interceptors.any((i) => i is PortalCookieManager)) {
      throw ArgumentError('无状态校园传输不能复用带门户 Cookie 的客户端');
    }
    this.dio =
        dio ??
        vpnDio(
          options:
              options ??
              BaseOptions(
                headers: {
                  'User-Agent': 'Mozilla/5.0',
                  'Accept-Language': 'zh-CN,en;q=0.9,en-US;q=0.8',
                },
              ),
          forceVpn: forceVpn,
          securityContextProvider: () => this.trust.context,
          onBadCertificate: this.trust.onBadCertificate,
        );
    if (installInterceptors) {
      final retry = this.dio.interceptors
          .whereType<VpnIdempotentRetryInterceptor>()
          .firstOrNull;
      if (retry != null) this.dio.interceptors.remove(retry);
      if (!this.dio.interceptors.any((i) => i is VpnPreparationInterceptor)) {
        this.dio.interceptors.add(
          VpnPreparationInterceptor(this.dio, beforeRequest: beforeRequest),
        );
      }
      if (!this.dio.interceptors.any((i) => i is AiaTrustInterceptor)) {
        this.dio.interceptors.add(AiaTrustInterceptor(this.dio, this.trust));
      }
      if (cookieStore != null &&
          !this.dio.interceptors.any((i) => i is PortalCookieManager)) {
        this.dio.interceptors.add(
          PortalCookieManager(
            cookieStore!.openJar(),
            store: cookieStore,
            checkSession: checkSession,
          ),
        );
      }
      if (!this.dio.interceptors.any((i) => i is ManualRedirectInterceptor)) {
        this.dio.interceptors.add(ManualRedirectInterceptor(this));
      }
      if (retry != null) this.dio.interceptors.add(retry);
    }
    installHttpDiagnostics(this.dio);
  }
  late final Dio dio;
  final AiaTrust trust;
  final PortalCookieStore? cookieStore;
  static const timeout = Duration(seconds: 30);
  static bool isRedirect(int? status) =>
      const {301, 302, 303, 307, 308}.contains(status);

  /// 全局失效只识别非 5xx 的拒绝状态及明确的 CAS 登录特征。
  static bool isGlobalAuthExpired(
    Response<dynamic> response, {
    bool treat403 = true,
  }) {
    final status = response.statusCode ?? 0;
    if (status >= 500) return false;
    if (status == 401 || treat403 && status == 403) return true;
    bool login(Uri uri) => uri.path.toLowerCase().contains('/authserver/login');
    if (login(response.realUri)) return true;
    for (final hop in response.redirects) {
      if (login(hop.location)) return true;
    }
    final location = response.headers.value('location');
    if (location != null && login(response.realUri.resolve(location))) {
      return true;
    }
    final body = response.data;
    return body is String &&
        (body.toLowerCase().contains('casloginform') ||
            body.toLowerCase().contains('authserver') &&
                (body.toLowerCase().contains('<html') ||
                    body.toLowerCase().contains('<form')));
  }

  static Options options({
    Map<String, dynamic>? headers,
    String? contentType,
    ResponseType responseType = ResponseType.plain,
    bool followRedirects = true,
    bool idempotent = false,
    Map<String, dynamic>? extra,
  }) => Options(
    headers: headers,
    contentType: contentType,
    responseType: responseType,
    followRedirects: false,
    validateStatus: (status) => status != null && status < 500,
    receiveTimeout: timeout,
    sendTimeout: timeout,
    extra: {
      'followRedirects': followRedirects,
      'idempotent': idempotent,
      ...?extra,
    },
  );
  Future<Response<dynamic>> get(
    Uri uri, {
    Map<String, dynamic>? headers,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
    bool followRedirects = true,
  }) => sendCallback(
    () => dio.getUri<dynamic>(
      uri,
      options: options(
        headers: headers,
        responseType: responseType,
        followRedirects: followRedirects,
      ),
      cancelToken: cancelToken,
    ),
  );
  Future<Response<dynamic>> post(
    Uri uri, {
    required Object? data,
    Map<String, dynamic>? headers,
    String? contentType,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
    bool idempotent = false,
    bool followRedirects = true,
  }) => sendCallback(
    () => dio.postUri<dynamic>(
      uri,
      data: data,
      options: options(
        headers: headers,
        contentType: contentType,
        responseType: responseType,
        idempotent: idempotent,
        followRedirects: followRedirects,
      ),
      cancelToken: cancelToken,
    ),
  );

  /// 每次发送重新编码请求体，保证查询型 POST 的唯一一次重放可用。
  Future<Response<dynamic>> send(RequestOptions options) {
    options.followRedirects = false;
    options.validateStatus = (status) => status != null && status < 600;
    return sendCallback(() => dio.fetch<dynamic>(options));
  }

  /// 兼容旧 PortalHttp 回调，异常包装保留原始原因与堆栈。
  Future<Response<dynamic>> sendCallback(
    Future<Response<dynamic>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (error, stack) {
      if (error.error case final PortalException failure) {
        Error.throwWithStackTrace(failure, error.stackTrace);
      }
      final network =
          error.error is SocketException ||
          error.error is HandshakeException ||
          error.error is HttpException ||
          const {
            DioExceptionType.connectionTimeout,
            DioExceptionType.sendTimeout,
            DioExceptionType.receiveTimeout,
            DioExceptionType.connectionError,
            DioExceptionType.badCertificate,
          }.contains(error.type);
      final context = <String, Object?>{
        'method': error.requestOptions.method,
        'host': error.requestOptions.uri.host,
        'dio_type': error.type.name,
        'status_code': ?error.response?.statusCode,
      };
      final code = error.error is HandshakeException
          ? 'tls_handshake_failed'
          : error.error is SocketException
          ? 'socket_connection_failed'
          : switch (error.type) {
              DioExceptionType.badResponse => 'http_status_rejected',
              DioExceptionType.connectionError => 'http_connection_failed',
              DioExceptionType.badCertificate => 'certificate_rejected',
              DioExceptionType.cancel => 'request_cancelled',
              DioExceptionType.unknown => 'http_unexpected_failure',
              _ => 'http_${error.type.name}',
            };
      final Object failure = network
          ? PortalNetworkError(
              '无法连接校园网络，请检查网络后重试',
              code: code,
              stage: 'http.request',
              cause: error,
              causeStackTrace: stack,
              context: context,
            )
          : DiagnosticException(
              '服务暂时不可用，请稍后重试',
              code: code,
              stage: 'http.request',
              cause: error,
              causeStackTrace: stack,
              context: context,
            );
      Error.throwWithStackTrace(failure, stack);
    }
  }

  /// 手动重定向时不丢失每跳 Cookie；307/308 保留原方法、数据和请求头。
  Future<Response<dynamic>> followRedirects(
    Response<dynamic> response, {
    CancelToken? cancelToken,
  }) async {
    var current = response;
    final redirects = <RedirectRecord>[...response.redirects];
    final original = response.requestOptions;
    final origin = original.uri;
    final max = original.extra['maxRedirects'] as int? ?? 10;
    final sameHost = original.extra['sameHostOnly'] == true;
    var hop = 0;
    while (isRedirect(current.statusCode)) {
      if (hop++ >= max) {
        throw PortalLoginError(
          '重定向次数过多',
          code: 'redirect_limit_exceeded',
          stage: 'http.redirect',
          context: {
            'details': {'max_hops': max},
          },
        );
      }
      final location = current.headers.value('location');
      if (location == null || location.isEmpty) {
        throw PortalLoginError(
          '重定向缺少 Location',
          code: 'redirect_location_missing',
          stage: 'http.redirect',
          context: {'status_code': current.statusCode},
        );
      }
      final Uri target;
      try {
        target = current.realUri.resolve(location);
      } on FormatException catch (error, stack) {
        Error.throwWithStackTrace(
          PortalLoginError(
            '重定向 Location 格式无效',
            code: 'redirect_location_invalid',
            stage: 'http.redirect',
            cause: error,
            causeStackTrace: stack,
            context: {
              'status_code': current.statusCode,
              'details': {'hop': hop},
            },
          ),
          stack,
        );
      }
      if (sameHost &&
          (target.scheme != origin.scheme ||
              target.host != origin.host ||
              target.port != origin.port ||
              target.userInfo.isNotEmpty)) {
        throw const PortalLoginError(
          '重定向离开允许的来源',
          code: 'redirect_host_rejected',
          stage: 'http.redirect',
        );
      }
      final old = current.requestOptions;
      final method = old.method.toUpperCase();
      final toGet = current.statusCode == 303
          ? method != 'HEAD'
          : const {301, 302}.contains(current.statusCode) && method == 'POST';
      redirects.add(RedirectRecord(current.statusCode!, old.method, target));
      final headers = Map<String, dynamic>.from(
        old.headers,
      )..removeWhere((key, _) => key.toLowerCase() == HttpHeaders.cookieHeader);
      if (toGet) {
        headers.removeWhere(
          (key, _) => const {
            'content-length',
            'content-type',
            'transfer-encoding',
          }.contains(key.toLowerCase()),
        );
      }
      final changedOrigin =
          target.scheme != old.uri.scheme ||
          target.host != old.uri.host ||
          target.port != old.uri.port;
      if (changedOrigin) {
        headers.removeWhere(
          (key, _) => const {
            'authorization',
            'proxy-authorization',
            'synjones-auth',
            'x-csrf-token',
          }.contains(key.toLowerCase()),
        );
      }
      final nextExtra = Map<String, dynamic>.from(old.extra)
        ..remove('_vpnReplayed')
        ..remove('_aiaRepaired')
        ..remove('_redirectValidateStatus')
        ..remove('vpnDio.engineId');
      nextExtra['followRedirects'] = false;
      final next = old.copyWith(
        path: target.toString(),
        baseUrl: '',
        queryParameters: {},
        method: toGet ? 'GET' : old.method,
        data: toGet ? null : old.data,
        headers: headers,
        cancelToken: cancelToken ?? old.cancelToken,
        extra: nextExtra,
      );
      if (toGet) {
        next.data = null;
        next.contentType = null;
      } else if (next.data is FormData) {
        next.data = (next.data as FormData).clone();
      }
      next.validateStatus = (status) => status != null && status < 600;
      current = await dio.fetch<dynamic>(next);
    }
    current.redirects = redirects;
    final validate = original.extra['_redirectValidateStatus'];
    if (validate is bool Function(int?) && !validate(current.statusCode)) {
      throw DioException.badResponse(
        statusCode: current.statusCode!,
        requestOptions: current.requestOptions,
        response: current,
      );
    }
    return current;
  }

  /// 仅关闭本传输持有的客户端。
  void close({bool force = false}) => dio.close(force: force);
}
