import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'aia_trust.dart';
import 'nuist_login.dart';
import 'passkey_bundle.dart';
import 'passkey_store.dart';
import 'portal_cookie_manager.dart';
import 'portal_cookie_store.dart';
import 'portal_exceptions.dart';
import 'portal_http.dart';

/// 门户与 VPN 共用的 CAS 认证协调器。
///
/// 认证串行执行，后来者复用前一次建立的 CAS 票根。这里只访问认证服务器，
/// 拿到业务跳转地址就释放队列；业务落地由调用方按自己的网络出口完成，
/// 避免「门户等 VPN 建连，VPN 又等门户认证」的循环。
class CasSession {
  CasSession({
    PortalCookieStore? cookies,
    Future<PasskeyBundle?> Function()? readCredential,
    this.createHttp,
  }) : cookies = cookies ?? PortalCookieStore.instance,
       _readCredential = readCredential ?? PasskeyStore.read;

  static final instance = CasSession();

  /// 与业务和 VPN 共用的 Cookie 存储。
  final PortalCookieStore cookies;
  final Future<PasskeyBundle?> Function() _readCredential;

  /// 测试用的引导客户端工厂；默认创建直连 CAS 的客户端。
  final PortalHttp Function(CookieJar jar)? createHttp;
  PortalHttp? _client;
  AiaTrust? _trust;
  int? _clientGeneration;
  Future<void> _queue = Future.value();

  /// 最近一次确定的凭据失效，供绑定状态界面监听。
  final credentialError = ValueNotifier<PortalCredentialError?>(null);

  PortalHttp _http(int generation) {
    if (_clientGeneration == generation && _client != null) return _client!;
    closeClient();
    _clientGeneration = generation;
    final jar = cookies.openJar();
    if (createHttp case final factory?) return _client = factory(jar);
    final trust = AiaTrust(
      resolveCacheDir: () async {
        final base = await getApplicationSupportDirectory();
        return Directory('${base.path}${Platform.pathSeparator}aia_certs');
      },
    );
    _trust = trust;
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
              checkSession: () => cookies.checkGeneration(generation),
            ),
          );
    return _client = PortalHttp(dio, trust: trust);
  }

  /// 复用 CAS 或执行一次 WebAuthn，返回带业务票据的跳转地址。
  Future<String> authenticate(
    String service, {
    void Function(String stage)? onStage,
  }) {
    final generation = cookies.generation;
    final result = _queue.then((_) async {
      cookies.checkGeneration(generation);
      if (credentialError.value case final error?) throw error;
      final http = _http(generation);
      await _trust?.preload();
      final bundle = await _readCredential();
      cookies.checkGeneration(generation);
      if (bundle == null) {
        throw const PortalCredentialError('尚未绑定统一门户，请先完成绑定');
      }
      try {
        final target = await NuistLogin(
          http: http,
          bundle: bundle,
          onStage: onStage,
        ).login(service, followServiceRedirects: false);
        cookies.checkGeneration(generation);
        credentialError.value = null;
        return target;
      } on PortalCredentialError catch (error) {
        cookies.checkGeneration(generation);
        credentialError.value = error;
        rethrow;
      }
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 关闭引导客户端；[resetQueue] 供清空账号时作废旧认证队列。
  void closeClient({bool resetQueue = false}) {
    _client?.dio.close(force: true);
    _client = null;
    _clientGeneration = null;
    _trust = null;
    if (resetQueue) _queue = Future.value();
  }
}
