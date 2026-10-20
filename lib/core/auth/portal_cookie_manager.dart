import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

/// 门户与 VPN 共用的 Cookie 拦截器，只按响应来源保存 Cookie。
///
/// dio_cookie_manager 会把重定向响应的 Cookie 另存到 Location 目标，导致
/// host-only Cookie 跨域混用，或无 Path 的 Cookie 被复制到另一条路径。
/// 手动跟随重定向时，每一跳只保存自己的 Cookie，下一跳按作用域取用。
class PortalCookieManager extends CookieManager {
  /// 保留依赖库的请求头注入、Cookie 解析与存储异常处理。
  PortalCookieManager(super.cookieJar);

  /// 使用不含 Location 的响应视图保存 Cookie，原响应仍供调用方跟随跳转。
  @override
  Future<void> saveCookies(Response response) => super.saveCookies(
    Response<dynamic>(
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      redirects: response.redirects,
      headers: Headers.fromMap({
        for (final entry in response.headers.map.entries)
          if (entry.key.toLowerCase() != HttpHeaders.locationHeader)
            entry.key: entry.value,
      }, preserveHeaderCase: response.headers.preserveHeaderCase),
    ),
  );
}
