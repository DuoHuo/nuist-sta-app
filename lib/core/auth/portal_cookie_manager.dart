import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../network/vpn_log.dart';
import 'portal_exceptions.dart';

/// 门户与 VPN 共用的 Cookie 拦截器，只按响应来源保存 Cookie。
///
/// dio_cookie_manager 会把重定向响应的 Cookie 另存到 Location 目标，导致
/// host-only Cookie 跨域混用，或无 Path 的 Cookie 被复制到另一条路径。
/// 手动跟随重定向时，每一跳只保存自己的 Cookie，下一跳按作用域取用。
///
/// 顺带兼容学校个别平台下发的非法 Cookie：劳动教育平台等站点会在 HTTPS
/// 响应里下发 `SameSite=None` 却不带 `Secure`，dart:io 按 RFC 6265bis 直接
/// 抛 HttpException，父类会把**整条响应**判为保存失败（同一响应里合法的
/// Cookie 也一起丢掉），CAS 登录因此中断。原生客户端本来就不实现 SameSite
/// 语义，这里去掉该属性；实在无法解析的 Cookie 单独丢弃，不再拖垮整次请求。
class PortalCookieManager extends CookieManager {
  PortalCookieManager(
    super.cookieJar, {
    this.beforeRequest,
    this.checkSession,
    this.preparationTimeout = const Duration(seconds: 70),
  }) {
    // 兜住加载路径（请求头里的 Cookie）以及保存时漏网的 HttpException；
    // FormatException 不会在这里被忽略，所以在 [_normalizeSetCookie] 里提前过滤。
    ignoreInvalidCookies = true;
  }

  /// 装入 Cookie 前准备网络和证书，确保使用 VPN 登录后更新的会话。
  final Future<void> Function()? beforeRequest;

  /// 解绑后拒绝旧请求和旧响应，包含没有 Set-Cookie 的响应。
  final void Function()? checkSession;

  /// 请求准备阶段包含 VPN 启动和 Cookie 读取，不受 Dio 传输超时保护。
  final Duration preparationTimeout;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final log = VpnRequestLog.start(options, managedByInterceptor: true);
    try {
      final preparation = vpnStage(
        '${log?.label ?? options.uri.host} 准备',
        () async {
          checkSession?.call();
          await beforeRequest?.call();
          checkSession?.call();
          return loadCookies(options);
        },
        timeout: preparationTimeout,
      );
      final cancelled = options.cancelToken?.whenCancel.then<String>((error) {
        throw error;
      });
      final cookies = await (cancelled == null
          ? preparation
          : Future.any([preparation, cancelled]));
      checkSession?.call();
      if (options.cancelToken?.isCancelled == true) {
        throw options.cancelToken!.cancelError!;
      }
      log?.preparationMs = log.watch.elapsedMilliseconds;
      log?.route = '直连';
      options.headers[HttpHeaders.cookieHeader] = cookies.isNotEmpty
          ? cookies
          : null;
      handler.next(options);
    } catch (error) {
      log?.fail(error);
      handler.reject(
        error is DioException
            ? error
            : DioException(
                requestOptions: options,
                error: error is TimeoutException
                    ? const PortalNetworkError('校园网络准备超时，请检查网络后重试')
                    : error,
              ),
        true,
      );
      return;
    }
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    try {
      checkSession?.call();
    } catch (error) {
      VpnRequestLog.of(response.requestOptions)?.fail(error);
      handler.reject(
        DioException(requestOptions: response.requestOptions, error: error),
        true,
      );
      return;
    }
    await super.onResponse(response, handler);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    VpnRequestLog.of(err.requestOptions)
        ?.fail(err, status: err.response?.statusCode);
    await super.onError(err, handler);
  }

  /// 匹配属性位置的 `; SameSite=None`（大小写不敏感，允许等号两侧空格）。
  static final _sameSiteNone = RegExp(
    r';\s*samesite\s*=\s*none\b',
    caseSensitive: false,
  );

  /// 匹配属性位置的 `; Secure`，不能误伤 Cookie 值里的相同字样。
  static final _secureAttribute = RegExp(r';\s*secure\b', caseSensitive: false);

  /// 与 dio_cookie_manager 内部拆分合并 Set-Cookie 的规则一致，避免一条
  /// header 里放多个 Cookie 时被我们误判成一条非法 Cookie。
  static final _setCookieSeparator = RegExp(r'(?<=)(,)(?=[^;]+?=)');

  /// 去掉不合法的 `SameSite=None`，其余属性与 Cookie 值保持不变。
  static String _repairSetCookie(String value) {
    if (!_sameSiteNone.hasMatch(value) || _secureAttribute.hasMatch(value)) {
      return value;
    }
    return value.replaceAll(_sameSiteNone, '');
  }

  /// 修正并校验单条 Set-Cookie；无法解析时返回 null（丢弃）。
  static String? _normalizeSetCookie(String value) {
    final repaired = _repairSetCookie(value);
    try {
      Cookie.fromSetCookieValue(repaired);
      return repaired;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  /// 返回这条 Set-Cookie header 里所有能保存的 Cookie。
  ///
  /// 正常是一条 header 一个 Cookie，走一次解析的快路径；解析失败时才按
  /// 上游规则拆开逐个处理，尽量保留同一条 header 里的合法 Cookie。
  static List<String> _normalizeSetCookieHeader(String header) {
    final whole = _normalizeSetCookie(header);
    if (whole != null) return [whole];
    return [
      for (final part in header.split(_setCookieSeparator))
        if (part.isNotEmpty) ?_normalizeSetCookie(part),
    ];
  }

  /// 使用不含 Location 的响应视图保存 Cookie，原响应仍供调用方跟随跳转。
  @override
  Future<void> saveCookies(Response response) async {
    checkSession?.call();
    final headers = <String, List<String>>{
      for (final entry in response.headers.map.entries)
        if (entry.key.toLowerCase() != HttpHeaders.locationHeader)
          entry.key: entry.key.toLowerCase() == HttpHeaders.setCookieHeader
              ? [
                  for (final value in entry.value)
                    ..._normalizeSetCookieHeader(value),
                ]
              : entry.value,
    };
    await super.saveCookies(
      Response<dynamic>(
        requestOptions: response.requestOptions,
        statusCode: response.statusCode,
        redirects: response.redirects,
        headers: Headers.fromMap(
          headers,
          preserveHeaderCase: response.headers.preserveHeaderCase,
        ),
      ),
    );
    VpnRequestLog.of(response.requestOptions)?.complete(
      response.statusCode,
      response.realUri,
      response.headers.value(HttpHeaders.locationHeader),
    );
  }
}
