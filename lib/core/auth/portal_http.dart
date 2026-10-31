import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../network/vpn_http_adapter.dart';
import '../network/vpn_log.dart';
import 'aia_trust.dart';
import 'portal_exceptions.dart';
import 'safe_message.dart';

/// 门户登录相关的兼容日志出口，由 [PortalSession] 接到统一日志入口。
///
/// 做成可注入而不是直接 import flutter：让 nuist_login / portal_http 保持纯
/// Dart，能在桌面用 `dart run` 直接对着真实门户跑验证脚本，不用起模拟器。
/// 新代码应优先记录结构化事件；该出口仅用于仍需保持纯 Dart 的登录实现。
void Function(String message)? portalLogger;

/// 结构化门户日志出口，应用启动时接到统一日志层。
void Function(String event, Map<String, Object?>? fields)? portalEventLogger;

/// 记录稳定事件；纯 Dart 验证环境的旧出口仅接收事件名。
void portalLog(String event, {Map<String, Object?>? fields}) {
  portalEventLogger?.call(event, fields);
  portalLogger?.call('[portal] $event');
}

/// 门户请求的公共 HTTP 行为：超时、状态码放行、异常归类、手动跟随重定向。
///
/// 登录流程和登录之后的业务请求都要用它，核心原因是重定向必须由我们自己跟
/// 随（见 [followRedirects]）。
class PortalHttp {
  const PortalHttp(this.dio, {this.trust});

  final Dio dio;

  /// 有它时，握手因证书链不完整失败会自动补链重试一次（见 [AiaTrust]）。
  final AiaTrust? trust;

  static const timeout = Duration(seconds: 30);
  static const maxRedirects = 10;

  static const redirectCodes = [301, 302, 303, 307, 308];

  static bool isRedirect(int? status) =>
      status != null && redirectCodes.contains(status);

  /// 明确的 CAS 登录跳转或表单；用于识别 VPN 控制器会话失效。
  static bool isLoginResponse(Response<dynamic> response) {
    if (response.statusCode == 401) return true;
    if ((response.statusCode ?? 0) >= 400) return false;
    bool isLoginUri(Uri uri) => uri.path
        .toLowerCase()
        .replaceFirst(RegExp(r'/+$'), '')
        .endsWith('/authserver/login');
    if (isLoginUri(response.realUri)) return true;
    final location = response.headers.value('location');
    if (isRedirect(response.statusCode) &&
        location != null &&
        isLoginUri(response.realUri.resolve(location))) {
      return true;
    }
    final body = response.data;
    return body is String &&
        (RegExp(
              r'''<form\b[^>]*\bid\s*=\s*["']casLoginForm["']''',
              caseSensitive: false,
            ).hasMatch(body) ||
            (body.toLowerCase().contains('authserver/login') &&
                RegExp(
                  r'''\bname\s*=\s*["']execution["']''',
                  caseSensitive: false,
                ).hasMatch(body)));
  }

  static Options options({
    Map<String, String>? headers,
    String? contentType,
    ResponseType responseType = ResponseType.plain,
  }) => Options(
    headers: headers,
    contentType: contentType,
    responseType: responseType,
    // 自动重定向必须关掉，理由见 followRedirects。
    followRedirects: false,
    // 3xx 要自己处理，4xx 要能读出响应体判断失败原因，所以放行到 500。
    validateStatus: (status) => status != null && status < 500,
    sendTimeout: timeout,
    receiveTimeout: timeout,
  );

  Future<Response<dynamic>> get(
    Uri uri, {
    Map<String, String>? headers,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
  }) => send(
    () => dio.getUri<dynamic>(
      uri,
      options: options(headers: headers, responseType: responseType),
      cancelToken: cancelToken,
    ),
  );

  Future<Response<dynamic>> post(
    Uri uri, {
    required Object data,
    Map<String, String>? headers,
    String? contentType,
    ResponseType responseType = ResponseType.plain,
  }) => send(
    () => dio.postUri<dynamic>(
      uri,
      data: data,
      options: options(
        headers: headers,
        contentType: contentType,
        responseType: responseType,
      ),
    ),
  );

  /// 把 dio 的传输异常归类成 [PortalNetworkError]，其余归到 [PortalLoginError]。
  ///
  /// 这个区分是「Passkey 吊销要显式提醒」的前提：连不上服务器不能拿来推断
  /// 凭据失效，否则用户在地铁里打开 APP 就会被告知需要重新绑定。
  Future<Response<dynamic>> send(
    Future<Response<dynamic>> Function() request,
  ) async {
    try {
      final response = await request();
      final location = response.headers.value('location');
      if (VpnRequestLog.of(response.requestOptions) == null) {
        portalLog(
          'http.completed',
          fields: {
            'method': response.requestOptions.method,
            'host': response.realUri.host,
            'status_code': response.statusCode,
            if (location != null)
              'redirect_host': response.realUri.resolve(location).host,
          },
        );
      }
      return response;
    } on DioException catch (e) {
      if (e.error case final PortalException error) throw error;
      if (VpnRequestLog.of(e.requestOptions) == null) {
        portalLog(
          'http.failed',
          fields: {
            'method': e.requestOptions.method,
            'host': e.requestOptions.uri.host,
            'dio_type': e.type.name,
            'error_kind': vpnErrorKind(e),
            'status_code': e.response?.statusCode,
          },
        );
      }
      if (await _repairedChain(e)) return send(request);
      // 自定义连接工厂的 TLS 异常可能被 Dio 归为 unknown，仍属于网络错误。
      if (e.error is HandshakeException) {
        throw const PortalNetworkError('门户证书或 TLS 握手失败，请检查网络环境');
      }
      if (e.error is SocketException) {
        throw const PortalNetworkError('无法连接校园网络，请检查网络后重试');
      }
      throw switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => const PortalNetworkError(
          '连接门户超时，请检查网络后重试',
        ),
        DioExceptionType.connectionError => PortalNetworkError(
          '无法连接门户，请检查网络后重试',
        ),
        DioExceptionType.badCertificate => const PortalNetworkError(
          '门户证书校验失败，请检查网络环境',
        ),
        _ => const PortalLoginError(kLoginFailedText),
      };
    }
  }

  /// 握手失败且补链成功时返回 true。[AiaTrust] 对同一主机只补一次，所以
  /// [send] 里的递归重试不会打转。
  Future<bool> _repairedChain(DioException e) async {
    final trust = this.trust;
    if (trust == null || !AiaTrust.isHandshakeFailure(e.error)) return false;
    final host = e.requestOptions.uri.host;
    final adapter = dio.httpClientAdapter;
    if (!await trust.tryRepair(
      host,
      createFetchClient: adapter is VpnHttpClientAdapter
          ? () => adapter.createRoutedClient(
              useVpn: e.requestOptions.extra['vpnDio.usedVpn'] == true,
            )
          : null,
    )) {
      return false;
    }
    // SecurityContext 变了，旧 HttpClient 的连接池还带着旧上下文，必须换新。
    if (adapter is VpnHttpClientAdapter) {
      adapter.resetClients();
    } else {
      adapter.close(force: true);
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: trust.createHttpClient,
      );
    }
    portalLog('certificate.repaired_retry', fields: {'host': host});
    return true;
  }

  /// 手动跟随重定向，**刻意不用 dio 的自动重定向**。
  ///
  /// dio 的 CookieManager 是拦截器，只看得到它自己发出的请求；自动重定向发生
  /// 在底层 HttpClient 内部，中间几跳的 Set-Cookie 不会进 CookieJar。CAS 流程
  /// 恰恰靠中间跳转下发会话 Cookie，丢了就登不进去。Python 版没这个问题，是
  /// 因为 requests 自己实现跟随、每跳都过 jar。
  Future<Response<dynamic>> followRedirects(
    Response<dynamic> response, {
    CancelToken? cancelToken,
  }) async {
    var current = response;
    for (var hop = 0; hop < maxRedirects; hop++) {
      if (!isRedirect(current.statusCode)) return current;
      final location = current.headers.value('location');
      if (location == null || location.isEmpty) {
        throw PortalLoginError('HTTP ${current.statusCode} 重定向缺少 Location');
      }
      current = await get(
        current.realUri.resolve(location),
        cancelToken: cancelToken,
      );
    }
    throw const PortalLoginError('重定向次数过多，疑似陷入跳转循环');
  }
}
