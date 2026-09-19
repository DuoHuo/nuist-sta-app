import 'package:dio/dio.dart';

import 'portal_exceptions.dart';

/// 门户登录相关的日志出口，由 [PortalSession] 在 debug 构建下接到 debugPrint。
///
/// 做成可注入而不是直接 import flutter：让 nuist_login / portal_http 保持纯
/// Dart，能在桌面用 `dart run` 直接对着真实门户跑验证脚本，不用起模拟器。
/// 调用方负责不把凭据、Cookie 值、私钥传进来；这里不做脱敏。
void Function(String message)? portalLogger;

void portalLog(String message) => portalLogger?.call('[portal] $message');

/// 门户请求的公共 HTTP 行为：超时、状态码放行、异常归类、手动跟随重定向。
///
/// 登录流程和登录之后的业务请求都要用它，核心原因是重定向必须由我们自己跟
/// 随（见 [followRedirects]）。
class PortalHttp {
  const PortalHttp(this.dio);

  final Dio dio;

  static const timeout = Duration(seconds: 30);
  static const maxRedirects = 10;

  static const redirectCodes = [301, 302, 303, 307, 308];

  static bool isRedirect(int? status) =>
      status != null && redirectCodes.contains(status);

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
  }) => send(
    () => dio.getUri<dynamic>(
      uri,
      options: options(headers: headers, responseType: responseType),
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
      portalLog(
        '${response.requestOptions.method} ${_short(response.realUri)} '
        '→ HTTP ${response.statusCode}'
        '${location == null ? '' : ' → ${_short(Uri.parse(location))}'}',
      );
      return response;
    } on DioException catch (e) {
      portalLog(
        '${e.requestOptions.method} ${_short(e.requestOptions.uri)} '
        '✗ ${e.type.name}: ${e.message}',
      );
      throw switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => const PortalNetworkError(
          '连接门户超时，请检查网络后重试',
        ),
        DioExceptionType.connectionError => PortalNetworkError(
          '无法连接门户：${e.message ?? '网络不可用'}',
        ),
        DioExceptionType.badCertificate => const PortalNetworkError(
          '门户证书校验失败，请检查网络环境',
        ),
        _ => PortalLoginError('请求失败：${e.message ?? e.type.name}'),
      };
    }
  }

  /// 手动跟随重定向，**刻意不用 dio 的自动重定向**。
  ///
  /// dio 的 CookieManager 是拦截器，只看得到它自己发出的请求；自动重定向发生
  /// 在底层 HttpClient 内部，中间几跳的 Set-Cookie 不会进 CookieJar。CAS 流程
  /// 恰恰靠中间跳转下发会话 Cookie，丢了就登不进去。Python 版没这个问题，是
  /// 因为 requests 自己实现跟随、每跳都过 jar。
  Future<Response<dynamic>> followRedirects(Response<dynamic> response) async {
    var current = response;
    for (var hop = 0; hop < maxRedirects; hop++) {
      if (!isRedirect(current.statusCode)) return current;
      final location = current.headers.value('location');
      if (location == null || location.isEmpty) {
        throw PortalLoginError('HTTP ${current.statusCode} 重定向缺少 Location');
      }
      current = await get(current.realUri.resolve(location));
    }
    throw const PortalLoginError('重定向次数过多，疑似陷入跳转循环');
  }

  /// 日志里的 URL：去掉 query，CAS 的 ticket 和 service 参数又长又没信息量。
  static String _short(Uri uri) =>
      uri.replace(query: '').toString().replaceAll(RegExp(r'\?$'), '') +
      (uri.hasQuery ? '?…' : '');
}
