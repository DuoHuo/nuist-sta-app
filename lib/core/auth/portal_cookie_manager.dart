import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../logging/app_log.dart';
import 'portal_cookie_store.dart';

/// 只负责 Cookie 读写和学校响应中畸形 Set-Cookie 的规范化。
class PortalCookieManager extends CookieManager {
  static final _log = AppLog.logger('core.auth.cookie_manager');
  PortalCookieManager(super.cookieJar, {this.store, this.checkSession}) {
    ignoreInvalidCookies = true;
  }

  /// Cookie 的账号和域代次来源，防止旧响应覆盖重登后的 Cookie。
  final PortalCookieStore? store;
  final void Function()? checkSession;
  static const _revisionKey = 'portal.cookieHostRevision';
  static const _generationKey = 'portal.cookieAccountGeneration';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      checkSession?.call();
      options.extra[_revisionKey] = store?.hostRevision(options.uri.host);
      options.extra[_generationKey] = store?.generation;
      final cookies = await loadCookies(options);
      checkSession?.call();
      if (options.cancelToken?.isCancelled == true) {
        throw options.cancelToken!.cancelError!;
      }
      options.headers[HttpHeaders.cookieHeader] = cookies.isNotEmpty
          ? cookies
          : null;
      handler.next(options);
    } catch (error, stackTrace) {
      handler.reject(
        error is DioException
            ? error
            : DioException(
                requestOptions: options,
                error: error,
                stackTrace: stackTrace,
              ),
        true,
      );
    }
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    try {
      checkSession?.call();
      final expected = response.requestOptions.extra[_revisionKey];
      if (store != null &&
          expected != store!.hostRevision(response.requestOptions.uri.host)) {
        // 业务层仍可查看失效响应，用 revision 合并恢复；旧 Cookie 不再写回。
        handler.next(response);
        return;
      }
    } catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          error: error,
          stackTrace: stackTrace,
        ),
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
    final kept = <String>[];
    var discarded = 0;
    for (final part in header.split(_setCookieSeparator)) {
      if (part.isEmpty) continue;
      final normalized = _normalizeSetCookie(part);
      if (normalized == null) {
        discarded++;
      } else {
        kept.add(normalized);
      }
    }
    if (discarded > 0) {
      _log.warning(
        'cookie.invalid_discarded',
        fields: {
          'skipped_count': discarded,
          'reason_code': 'response_cookie_invalid',
          'stage': 'session.cookie.parse',
        },
      );
    }
    return kept;
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
    if (store case final store?) {
      final expected = response.requestOptions.extra[_revisionKey];
      final generation = response.requestOptions.extra[_generationKey];
      if (expected is int && generation is int) {
        final cookies = <Cookie>[
          for (final entry in headers.entries)
            if (entry.key.toLowerCase() == HttpHeaders.setCookieHeader)
              for (final value in entry.value)
                for (final part in value.split(_setCookieSeparator))
                  if (part.trim().isNotEmpty) Cookie.fromSetCookieValue(part),
        ];
        await store.saveForRevision(
          response.requestOptions.uri,
          cookies,
          generation: generation,
          hostRevision: expected,
        );
        return;
      }
    }
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
  }
}
