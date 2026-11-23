import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../logging/app_log.dart';
import 'campus_transport.dart';
import 'cas_session.dart';
import 'portal_cookie_store.dart';
import 'portal_exceptions.dart';
import 'service_auth_spec.dart';

/// 一个子系统的会话及其业务修订号、账号代次和 Cookie 域代次。
class SessionEntry<TSession> {
  const SessionEntry({
    required this.session,
    required this.revision,
    required this.cookieGeneration,
    required this.establishedAt,
    required this.hostRevisions,
  });
  final TSession session;
  final int revision;
  final int cookieGeneration;
  final DateTime establishedAt;
  final Map<String, int> hostRevisions;
}

/// 请求构造只描述网络请求，执行器可能调用两次，不能包含业务副作用。
typedef RequestBuilder = RequestOptions Function();
typedef ServiceAuthenticator = Future<CasAuthenticationResult> Function(
  String service, {
  bool forceFreshWebAuthn,
});

/// 按声明式服务合流登录，携带旧修订号的错峰失效响应复用已刷新的会话。
class SessionExecutor {
  SessionExecutor({
    required this.transport,
    CasSession? authenticator,
    PortalCookieStore? cookieStore,
    ServiceAuthenticator? authenticate,
  }) : cookieStore =
           cookieStore ?? transport.cookieStore ?? PortalCookieStore.instance,
       _authenticator = authenticate == null
           ? (authenticator ?? CasSession.instance)
           : null,
       _authenticate =
           authenticate ??
           (authenticator ?? CasSession.instance).authenticateResult;

  static final _log = AppLog.logger('core.auth.session_executor');
  final CampusTransport transport;
  final PortalCookieStore cookieStore;
  final ServiceAuthenticator _authenticate;
  final CasSession? _authenticator;

  Future<CasAuthenticationResult> _authenticateService(
    String service, {
    required bool forceFreshWebAuthn,
    void Function(String stage)? onStage,
  }) => onStage != null && _authenticator != null
      ? _authenticator.authenticateResult(
          service,
          forceFreshWebAuthn: forceFreshWebAuthn,
          onStage: onStage,
        )
      : _authenticate(service, forceFreshWebAuthn: forceFreshWebAuthn);
  final Map<String, SessionEntry<dynamic>> _entries = {};
  final Map<String, int> _revisions = {};
  final Map<String, Future<SessionEntry<dynamic>>> _inflightRefresh = {};
  final Map<String, bool> _inflightFreshWebAuthn = {};
  final Map<String, Future<void>> _hostQueues = {};
  final Set<CancelToken> _requests = {};
  int _epoch = 0;

  /// 仅供清理顺序回归检查，不暴露会话或凭据内容。
  @visibleForTesting
  int get debugSessionCount => _entries.length;

  Future<T> _coordinateHost<T>(String host, Future<T> Function() action) {
    final work = (_hostQueues[host] ?? Future<void>.value()).then(
      (_) => action(),
    );
    late final Future<void> tail;
    tail = work.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_hostQueues[host], tail)) _hostQueues.remove(host);
    });
    _hostQueues[host] = tail;
    return work;
  }

  Future<T> _coordinateHosts<T>(
    Iterable<String> hosts,
    Future<T> Function() action,
  ) {
    final sorted = hosts.toSet().toList()..sort();
    Future<T> acquire(int index) => index == sorted.length
        ? cookieStore.runRefreshing(sorted, action)
        : _coordinateHost(sorted[index], () => acquire(index + 1));
    return acquire(0);
  }

  /// 兼容 H5 门面恢复已验证的落地标记，子系统非 Cookie 凭据仍由 Spec 建立。
  void restoreSession<S>(ServiceAuthSpec<S> spec, S session) {
    if (_inflightRefresh.containsKey(spec.id)) return;
    final current = _entries[spec.id];
    if (current != null && _valid(current)) return;
    final revision = (_revisions[spec.id] ?? 0) + 1;
    _revisions[spec.id] = revision;
    _entries[spec.id] = SessionEntry<S>(
      session: session,
      revision: revision,
      cookieGeneration: cookieStore.generation,
      establishedAt: DateTime.now(),
      hostRevisions: {
        for (final host in spec.cookieHosts)
          host: cookieStore.hostRevision(host),
      },
    );
  }

  bool _valid(SessionEntry<dynamic> entry) =>
      entry.cookieGeneration == cookieStore.generation &&
      entry.hostRevisions.entries.every(
        (pair) => cookieStore.hostRevision(pair.key) == pair.value,
      );

  /// 返回有效会话；没有会话时单飞建立，不清除仍可能有效的其他服务 Cookie。
  Future<SessionEntry<S>> ensureSession<S>(
    ServiceAuthSpec<S> spec, {
    bool force = false,
    bool forceFreshWebAuthn = false,
    void Function(String stage)? onStage,
  }) async {
    final pending = _inflightRefresh[spec.id];
    if (pending != null) {
      final requiresFresh =
          forceFreshWebAuthn && _inflightFreshWebAuthn[spec.id] != true;
      if (requiresFresh) {
        final generation = cookieStore.generation;
        try {
          await pending;
        } catch (_) {
          // 旧普通登录的失败不能取消用户明确发起的完整 WebAuthn。
        }
        cookieStore.checkGeneration(generation);
        return ensureSession(
          spec,
          force: true,
          forceFreshWebAuthn: true,
          onStage: onStage,
        );
      }
      final entry = (await pending) as SessionEntry<S>;
      cookieStore.checkGeneration(entry.cookieGeneration);
      return entry;
    }
    final current = _entries[spec.id];
    if (!force && !forceFreshWebAuthn && current != null && _valid(current)) {
      return current as SessionEntry<S>;
    }
    return _refresh(
      spec,
      clearCookies: force || forceFreshWebAuthn,
      forceFreshWebAuthn: forceFreshWebAuthn,
      onStage: onStage,
    );
  }

  /// 只有失败请求使用的修订号仍为最新时才重登。
  Future<SessionEntry<S>> refreshIfNeeded<S>(
    ServiceAuthSpec<S> spec, {
    required int failedRevision,
  }) async {
    final pending = _inflightRefresh[spec.id];
    if (pending != null) return (await pending) as SessionEntry<S>;
    final current = _entries[spec.id];
    if (current != null &&
        current.revision > failedRevision &&
        _valid(current)) {
      return current as SessionEntry<S>;
    }
    // 其他同域应用已经清理并刷新 Cookie：重新进入本应用，不再清新 Cookie。
    final domainChanged =
        current != null &&
        !current.hostRevisions.entries.every(
          (pair) => cookieStore.hostRevision(pair.key) == pair.value,
        );
    return _refresh(spec, clearCookies: !domainChanged);
  }

  Future<SessionEntry<S>> _refresh<S>(
    ServiceAuthSpec<S> spec, {
    required bool clearCookies,
    bool forceFreshWebAuthn = false,
    void Function(String stage)? onStage,
  }) {
    final epoch = _epoch;
    final generation = cookieStore.generation;
    void check() {
      cookieStore.checkGeneration(generation);
      if (_epoch != epoch) {
        throw const PortalLoginError(
          '会话已清除，请重新发起请求',
          code: 'session_generation_changed',
          stage: 'service.establish',
        );
      }
    }

    late final Future<SessionEntry<S>> work;
    work = _log
        .operation(
          'service.refresh',
          () => _coordinateHosts(spec.cookieHosts, () async {
            check();
            final previous = _entries[spec.id];
            final hostChanged =
                previous != null &&
                !previous.hostRevisions.entries.every(
                  (pair) => cookieStore.hostRevision(pair.key) == pair.value,
                );
            if (clearCookies && (forceFreshWebAuthn || !hostChanged)) {
              await cookieStore.clearHosts(spec.cookieHosts);
            }
            check();
            var result = await _authenticateService(
              spec.casServiceUrl,
              forceFreshWebAuthn: forceFreshWebAuthn,
              onStage: onStage,
            );
            check();
            late Map<String, int> establishedRevisions;
            Future<S> establish(CasAuthenticationResult authentication) async {
              check();
              final revisions = <String, int>{
                for (final host in spec.cookieHosts)
                  host: cookieStore.hostRevision(host),
              };
              cookieStore.checkHostRevisions(revisions);
              final session = await spec.establish(
                transport,
                authentication.landingUri,
              );
              check();
              cookieStore.checkHostRevisions(revisions);
              establishedRevisions = Map.unmodifiable(revisions);
              return session;
            }

            late S session;
            try {
              session = await establish(result);
            } on PortalLoginError catch (error) {
              final status = error.context['status_code'];
              final missingIcardToken = error.code == 'icard_token_missing';
              final expiredLanding =
                  error.code == 'service_returned_to_login' ||
                  status == 401 ||
                  status == 403 ||
                  missingIcardToken;
              if ((status is int && status >= 500) ||
                  !expiredLanding ||
                  (!result.ssoReused && !missingIcardToken)) {
                rethrow;
              }
              final forceFreshWebAuthn = result.ssoReused;
              _log.info(
                forceFreshWebAuthn
                    ? 'service.fresh_webauthn_required'
                    : 'service.token_missing_retry',
                fields: {'service': spec.id, 'reason_code': error.code},
              );
              await cookieStore.clearHosts(spec.cookieHosts);
              check();
              result = await _authenticateService(
                spec.casServiceUrl,
                forceFreshWebAuthn: forceFreshWebAuthn,
                onStage: onStage,
              );
              check();
              session = await establish(result);
            }
            check();
            final revision = (_revisions[spec.id] ?? 0) + 1;
            _revisions[spec.id] = revision;
            final entry = SessionEntry<S>(
              session: session,
              revision: revision,
              cookieGeneration: generation,
              establishedAt: DateTime.now(),
              hostRevisions: establishedRevisions,
            );
            _entries[spec.id] = entry;
            return entry;
          }),
          fields: {'service': spec.id, 'force': clearCookies},
          successLevel: AppLogLevel.debug,
        )
        .whenComplete(() {
          if (identical(_inflightRefresh[spec.id], work)) {
            _inflightRefresh.remove(spec.id);
            _inflightFreshWebAuthn.remove(spec.id);
          }
        });
    _inflightRefresh[spec.id] = work;
    _inflightFreshWebAuthn[spec.id] = forceFreshWebAuthn;
    return work;
  }

  /// 发送一个查询；鉴权失效最多重放一次，5xx 不触发重登。
  Future<Response<dynamic>> execute<S>(
    ServiceAuthSpec<S> spec,
    RequestBuilder buildRequest, {
    bool idempotent = true,
  }) => _execute(spec, (entry) async {
    final options = buildRequest();
    options.extra[PortalCookieStore.hostRevisionsKey] =
        Map<String, int>.unmodifiable(entry.hostRevisions);
    options.extra[PortalCookieStore.accountGenerationKey] =
        entry.cookieGeneration;
    options.extra['idempotent'] = idempotent;
    options.validateStatus = (status) =>
        status != null && status >= 100 && status < 600;
    final cancel = options.cancelToken ?? CancelToken();
    options.cancelToken = cancel;
    _requests.add(cancel);
    try {
      await spec.applyAuth(options, entry.session);
      cookieStore.checkGeneration(entry.cookieGeneration);
      return await cookieStore.runWithSession(
        entry.hostRevisions,
        entry.cookieGeneration,
        () => transport.send(options),
      );
    } finally {
      _requests.remove(cancel);
    }
  }, idempotent: idempotent);

  /// 旧 PortalSession.request 门面也使用同一修订号和单飞机制。
  Future<Response<dynamic>> executeCallback<S>(
    ServiceAuthSpec<S> spec,
    Future<Response<dynamic>> Function() request,
  ) => _execute(
    spec,
    (entry) => cookieStore.runWithSession(
      entry.hostRevisions,
      entry.cookieGeneration,
      request,
    ),
    idempotent: true,
  );

  Future<Response<dynamic>> _execute<S>(
    ServiceAuthSpec<S> spec,
    Future<Response<dynamic>> Function(SessionEntry<S>) request, {
    required bool idempotent,
  }) async {
    var entry = await ensureSession(spec);
    final epoch = _epoch;
    for (var attempt = 0; attempt < 2; attempt++) {
      cookieStore.checkGeneration(entry.cookieGeneration);
      if (epoch != _epoch) {
        throw const PortalLoginError(
          '会话已清除，请重新发起请求',
          code: 'session_generation_changed',
          stage: 'service.request',
        );
      }
      late final Response<dynamic> response;
      try {
        cookieStore.checkHostRevisions(entry.hostRevisions);
        response = await request(entry);
      } on PortalLoginError catch (error, stackTrace) {
        if (error.code != 'service_cookie_revision_changed') rethrow;
        if (!idempotent) {
          if (_entries[spec.id]?.revision == entry.revision) {
            _entries.remove(spec.id);
          }
          throw PortalLoginError(
            '会话已更新，写入请求未重放，请重新确认后提交',
            code: 'session_expired_non_idempotent',
            stage: 'service.request',
            cause: error,
            causeStackTrace: stackTrace,
            context: {'service': spec.id},
          );
        }
        if (attempt == 1) rethrow;
        entry = await refreshIfNeeded(spec, failedRevision: entry.revision);
        continue;
      }
      cookieStore.checkGeneration(entry.cookieGeneration);
      final expired =
          (response.statusCode ?? 0) < 500 &&
          (isGlobalAuthExpired(response, treat403: spec.treat403AsExpired) ||
              spec.isSubsystemExpired(response));
      if (!expired) return response;
      if (!idempotent) {
        if (_entries[spec.id]?.revision == entry.revision) {
          _entries.remove(spec.id);
        }
        throw PortalLoginError(
          '会话已失效，写入请求未重放，请重新确认后提交',
          code: 'session_expired_non_idempotent',
          stage: 'service.request',
          context: {
            'service': spec.id,
            'status_code': response.statusCode,
            'attempt': 1,
          },
        );
      }
      if (attempt == 1) {
        throw PortalLoginError(
          '重新登录后服务仍拒绝访问，请稍后再试',
          code: 'reauthentication_exhausted',
          stage: 'service.request',
          context: {
            'service': spec.id,
            'status_code': response.statusCode,
            'attempt': attempt + 1,
          },
        );
      }
      entry = await refreshIfNeeded(spec, failedRevision: entry.revision);
    }
    throw StateError('unreachable');
  }

  /// 先取消在途业务和建立结果，留存条目直到隧道停止后统一清理。
  void cancelPending() {
    _epoch++;
    for (final request in _requests) {
      request.cancel('账号会话已清除');
    }
    _requests.clear();
  }

  /// 隧道停止后清理会话内存，旧异步任务仍受代次校验保护。
  void clear() {
    cancelPending();
    _entries.clear();
    _revisions.clear();
    _inflightRefresh.clear();
    _inflightFreshWebAuthn.clear();
    _hostQueues.clear();
  }
}
