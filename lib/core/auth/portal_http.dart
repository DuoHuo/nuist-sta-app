import 'package:dio/dio.dart';

import 'aia_trust.dart';
import 'campus_transport.dart';
import 'service_auth_spec.dart';

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

/// CAS 和旧 UI 调用的兼容门面，HTTP 行为统一委托给 CampusTransport。
class PortalHttp {
  PortalHttp(this.dio, {this.trust})
    : _transport = CampusTransport.fromDio(dio, trust: trust);
  final Dio dio;
  final AiaTrust? trust;
  final CampusTransport _transport;
  static const timeout = Duration(seconds: 30);
  static const maxRedirects = 10;
  static const redirectCodes = [301, 302, 303, 307, 308];
  static bool isRedirect(int? status) =>
      status != null && redirectCodes.contains(status);
  static bool isLoginResponse(Response<dynamic> response) =>
      isGlobalAuthExpired(response);

  static Options options({
    Map<String, String>? headers,
    String? contentType,
    ResponseType responseType = ResponseType.plain,
  }) => Options(
    headers: headers,
    contentType: contentType,
    responseType: responseType,
    followRedirects: false,
    validateStatus: (status) => status != null && status < 500,
    sendTimeout: timeout,
    receiveTimeout: timeout,
  );

  Future<Response<dynamic>> get(
    Uri uri, {
    Map<String, String>? headers,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
  }) => _transport.get(
    uri,
    headers: headers,
    responseType: responseType,
    cancelToken: cancelToken,
    followRedirects: false,
  );

  Future<Response<dynamic>> post(
    Uri uri, {
    required Object data,
    Map<String, String>? headers,
    String? contentType,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
  }) => _transport.post(
    uri,
    data: data,
    headers: headers,
    contentType: contentType,
    responseType: responseType,
    cancelToken: cancelToken,
    followRedirects: false,
    idempotent: false,
  );

  Future<Response<dynamic>> send(
    Future<Response<dynamic>> Function() request,
  ) => _transport.sendCallback(request);

  Future<Response<dynamic>> followRedirects(
    Response<dynamic> response, {
    CancelToken? cancelToken,
  }) => _transport.sendCallback(
    () => _transport.followRedirects(response, cancelToken: cancelToken),
  );
}
