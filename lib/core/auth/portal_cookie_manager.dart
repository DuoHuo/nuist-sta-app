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
  static const _refreshOwnerKey = 'portal.cookieRefreshOwner';

  Map<String, int>? _sessionRevisions(RequestOptions options) {
    final raw = options.extra[PortalCookieStore.hostRevisionsKey];
    return raw is Map ? Map<String, int>.from(raw) : null;
  }

  bool _snapshotMatches(RequestOptions options) {
    final snapshot = _sessionRevisions(options);
    return store == null ||
        snapshot == null ||
        snapshot.entries.every(
          (entry) => store!.hostRevision(entry.key) == entry.value,
        );
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      checkSession?.call();
      final store = this.store;
      if (store != null) {
        final scoped = store.requestHostRevisions;
        final snapshot =
            _sessionRevisions(options) ??
            (scoped?.containsKey(options.uri.host) == true ? scoped : null);
        final generation =
            options.extra[PortalCookieStore.accountGenerationKey] as int? ??
            store.requestAccountGeneration ??
            store.generation;
        if (snapshot != null) {
          options.extra[PortalCookieStore.hostRevisionsKey] =
              Map<String, int>.unmodifiable(snapshot);
          store.checkHostRevisions(snapshot);
        }
        options.extra[PortalCookieStore.accountGenerationKey] = generation;
        store.checkGeneration(generation);
        options.extra[_revisionKey] =
            snapshot?[options.uri.host] ?? store.hostRevision(options.uri.host);
        options.extra[_generationKey] = generation;
        options.extra[_refreshOwnerKey] = store.requestRefreshOwner;
      }
      final cookies = await loadCookies(options);
      checkSession?.call();
      if (store != null) {
        store.checkGeneration(options.extra[_generationKey] as int);
        final snapshot = _sessionRevisions(options);
        if (snapshot != null) store.checkHostRevisions(snapshot);
      }
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
    if (response.requestOptions.cancelToken?.isCancelled == true) {
      handler.next(response);
      return;
    }
    try {
      checkSession?.call();
      final expected = response.requestOptions.extra[_revisionKey];
      if (!_snapshotMatches(response.requestOptions) ||
          (store != null &&
              expected !=
                  store!.hostRevision(response.requestOptions.uri.host))) {
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

  /// 仅在 Cookie 边界逗号处拆分，Expires 日期中的逗号不构成边界。
  static final _setCookieSeparator = RegExp(r',(?=\s*[^=;,\s]+\s*=)');
  static final _sameSiteNone = RegExp(
    r';\s*samesite\s*=\s*none\b',
    caseSensitive: false,
  );
  static final _secureAttribute = RegExp(r';\s*secure\b', caseSensitive: false);

  /// 每条 Cookie 只在保护范围内解析一次，不让坏项中断其他合法项。
  static List<Cookie> _parseSetCookieHeaders(Iterable<String> headers) {
    final kept = <Cookie>[];
    var discarded = 0;
    for (final header in headers) {
      for (final raw in header.split(_setCookieSeparator)) {
        if (raw.trim().isEmpty) continue;
        final repaired =
            _sameSiteNone.hasMatch(raw) && !_secureAttribute.hasMatch(raw)
            ? raw.replaceAll(_sameSiteNone, '')
            : raw;
        try {
          kept.add(Cookie.fromSetCookieValue(repaired));
        } on FormatException {
          discarded++;
        } on HttpException {
          discarded++;
        }
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

  /// 只保存实际响应来源；取消或失效的响应不写回 Cookie。
  @override
  Future<void> saveCookies(Response response) async {
    final options = response.requestOptions;
    if (options.cancelToken?.isCancelled == true ||
        !_snapshotMatches(options)) {
      return;
    }
    checkSession?.call();
    final cookies = _parseSetCookieHeaders([
      for (final entry in response.headers.map.entries)
        if (entry.key.toLowerCase() == HttpHeaders.setCookieHeader)
          ...entry.value,
    ]);
    if (cookies.isEmpty || options.cancelToken?.isCancelled == true) return;
    final store = this.store;
    final expected = options.extra[_revisionKey];
    final generation = options.extra[_generationKey];
    if (store != null && expected is int && generation is int) {
      await store.saveForRevision(
        options.uri,
        cookies,
        generation: generation,
        hostRevision: expected,
        refreshOwner: options.extra[_refreshOwnerKey],
        sessionRevisions: _sessionRevisions(options),
        isCancelled: () => options.cancelToken?.isCancelled == true,
      );
      return;
    }
    await cookieJar.saveFromResponse(options.uri, cookies);
  }
}
