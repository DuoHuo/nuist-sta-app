import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../config/campus_config.dart';
import '../network/vpn_log.dart';
import 'aia_trust.dart';
import 'nuist_login.dart';
import 'passkey_bundle.dart';
import 'passkey_store.dart';
import 'portal_cookie_manager.dart';
import 'portal_cookie_store.dart';
import 'portal_exceptions.dart';
import 'portal_http.dart';

/// CAS 返回的业务票据地址，以及是否复用了旧 CASTGC。
class CasAuthenticationResult {
  const CasAuthenticationResult({
    required this.landingUri,
    this.ssoReused = false,
  });
  final Uri landingUri;
  final bool ssoReused;
}

/// 串行访问认证服务器，取得 ST 后释放锁，业务落地由调用方完成。
class CasSession {
  CasSession({
    PortalCookieStore? cookies,
    Future<PasskeyBundle?> Function()? readCredential,
    this.createHttp,
    this.authenticationTimeout = const Duration(seconds: 40),
  }) : cookies = cookies ?? PortalCookieStore.instance,
       _readCredential = readCredential ?? PasskeyStore.read;

  static final instance = CasSession();
  final PortalCookieStore cookies;
  final Future<PasskeyBundle?> Function() _readCredential;
  final Duration authenticationTimeout;
  final PortalHttp Function(CookieJar jar)? createHttp;
  final credentialError = ValueNotifier<PortalCredentialError?>(null);
  final Set<CancelToken> _active = {};
  int _accountGeneration = 0;
  PortalHttp? _client;
  int? _clientGeneration;
  Future<void> _queue = Future.value();

  PortalHttp _http(int generation) {
    if (_clientGeneration == generation && _client != null) return _client!;
    closeClient();
    _clientGeneration = generation;
    final jar = cookies.openJar();
    if (createHttp case final factory?) {
      final http = factory(jar);
      final index = http.dio.interceptors.indexWhere(
        (interceptor) => interceptor is PortalCookieManager,
      );
      if (index >= 0) {
        http.dio.interceptors[index] = PortalCookieManager(
          jar,
          store: cookies,
          checkSession: () => cookies.checkGeneration(generation),
        );
      }
      return _client = http;
    }
    final trust = AiaTrust.shared;
    final dio =
        Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              headers: {
                'User-Agent': NuistLogin.userAgent,
                'Accept-Language': 'zh-CN,en;q=0.9,en-US;q=0.8',
              },
            ),
          )
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: trust.createHttpClient,
          )
          ..interceptors.add(
            PortalCookieManager(
              jar,
              store: cookies,
              checkSession: () => cookies.checkGeneration(generation),
            ),
          );
    return _client = PortalHttp(dio, trust: trust);
  }

  /// 兼容入口：返回业务票据 URL。
  Future<String> authenticate(
    String service, {
    void Function(String stage)? onStage,
    bool forceFreshWebAuthn = false,
  }) async => (await authenticateResult(
    service,
    onStage: onStage,
    forceFreshWebAuthn: forceFreshWebAuthn,
  )).landingUri.toString();

  /// 坏 CASTGC 落地失败后，可强制清认证域并重新签名 WebAuthn 断言。
  Future<CasAuthenticationResult> authenticateResult(
    String service, {
    void Function(String stage)? onStage,
    bool forceFreshWebAuthn = false,
  }) {
    final generation = cookies.generation;
    final epoch = _accountGeneration;
    final queued = Stopwatch()..start();
    final cancel = CancelToken();
    Future<void> timeoutCleanup = Future.value();
    var stage = 'cas.queue';
    void check() {
      cookies.checkGeneration(generation);
      if (epoch != _accountGeneration || cancel.isCancelled) {
        throw PortalNetworkError(
          '门户认证已取消，请重试',
          code: 'authentication_superseded',
          stage: stage,
        );
      }
    }

    portalLog('authentication.queued', fields: {'stage': stage});
    final result = _queue.then((_) {
      check();
      _active.add(cancel);
      final work = () async {
        portalLog(
          'authentication.dequeued',
          fields: {'queued_ms': queued.elapsedMilliseconds},
        );
        if (!forceFreshWebAuthn) {
          if (credentialError.value case final error?) {
            throw error;
          }
        }
        if (forceFreshWebAuthn) {
          await cookies.clearHost(
            Uri(scheme: 'https', host: CampusHosts.authserver),
            names: {'CASTGC'},
          );
          check();
        }
        final http = _http(generation);
        stage = 'cas.preload';
        if (createHttp == null) await AiaTrust.shared.preload();
        check();
        stage = 'cas.credential';
        final bundle = await _readCredential();
        check();
        if (bundle == null) {
          throw const PortalCredentialError(
            '尚未绑定统一门户，请先完成绑定',
            code: 'credential_unavailable',
            stage: 'cas.credential',
          );
        }
        var ssoReused = false;
        try {
          stage = 'cas.login';
          final target = await NuistLogin(
            http: http,
            bundle: bundle,
            cancelToken: cancel,
            onStage: (value) {
              stage = 'cas.$value';
              ssoReused |= value == 'sso_reused';
              onStage?.call(value);
            },
          ).login(service, followServiceRedirects: false);
          check();
          credentialError.value = null;
          return CasAuthenticationResult(
            landingUri: Uri.parse(target),
            ssoReused: ssoReused,
          );
        } on PortalCredentialError catch (error) {
          check();
          credentialError.value = error;
          rethrow;
        }
      }();
      // 超时只影响已经出队的认证；排队者各自从出队时开始计时。
      return work
          .timeout(
            authenticationTimeout,
            onTimeout: () {
              cancel.cancel('本次 CAS 认证超时');
              cookies.invalidateHostRevision(CampusHosts.authserver);
              timeoutCleanup = cookies.clearHost(
                Uri(scheme: 'https', host: CampusHosts.authserver),
                names: {'CASTGC'},
              );
              vpnLog(
                'cas.authentication_timeout',
                fields: {'timeout_ms': authenticationTimeout.inMilliseconds},
              );
              throw PortalNetworkError(
                '门户认证超时，请检查网络后重试',
                code: 'authentication_timeout',
                stage: stage,
                context: {'timeout_ms': authenticationTimeout.inMilliseconds},
              );
            },
          )
          .whenComplete(() => _active.remove(cancel));
    });
    // 已开始的 Cookie 存储先排空并清理，迟到网络响应则被 CancelToken 阻断写回。
    // 不等待可能无法取消的凭据平台读取，避免阻塞排在后面的正常认证。
    _queue = result.then<void>(
      (_) => timeoutCleanup.then<void>((_) {}, onError: (_) {}),
      onError: (_) => timeoutCleanup.then<void>((_) {}, onError: (_) {}),
    );
    return result;
  }

  /// 账号解绑或切换时才取消全队列；单次认证超时绝不调用此路径。
  void closeClient({bool resetQueue = false}) {
    _client?.dio.close(force: true);
    _client = null;
    _clientGeneration = null;
    if (resetQueue) {
      _accountGeneration++;
      for (final cancel in _active) {
        cancel.cancel('账号会话已清除');
      }
      _active.clear();
      _queue = Future.value();
    }
  }
}

/// 声明式会话层使用的认证器名称；保留旧名称供绑定和 VPN 兼容。
typedef CasAuthenticator = CasSession;
