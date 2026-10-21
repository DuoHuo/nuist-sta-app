import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/cas_session.dart';
import 'package:nuist_sta_app/core/auth/established_store.dart';
import 'package:nuist_sta_app/core/auth/nuist_login.dart';
import 'package:nuist_sta_app/core/auth/passkey_bundle.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_manager.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_store.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/auth/portal_session.dart';
import 'package:nuist_sta_app/core/network/vpn_auth.dart';
// 与现有 WebView 测试一致，仅使用已安装插件的平台接口模拟 Cookie 写入。
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _MemoryStorage implements Storage {
  final values = <String, String>{};

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll(List<String> keys) async {
    for (final key in keys) {
      values.remove(key);
    }
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) {}
}

class _CookieWebViewPlatform extends WebViewPlatform {
  final cookies = <WebViewCookie>[];
  Future<void> Function()? onWrite;

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => _CookieWebViewManager(params, this);
}

class _CookieWebViewManager extends PlatformWebViewCookieManager {
  _CookieWebViewManager(super.params, this.platform) : super.implementation();

  final _CookieWebViewPlatform platform;

  @override
  Future<void> setCookie(WebViewCookie cookie) async {
    await platform.onWrite?.call();
    platform.cookies.add(cookie);
  }

  @override
  Future<bool> clearCookies() async {
    final hadCookies = platform.cookies.isNotEmpty;
    platform.cookies.clear();
    return hadCookies;
  }
}

PortalHttp _http(
  CookieJar jar,
  FutureOr<ResponseBody> Function(RequestOptions) respond, {
  Future<void> Function()? prepare,
}) {
  final dio = Dio()
    ..httpClientAdapter = _Adapter(respond)
    ..interceptors.add(PortalCookieManager(jar, beforeRequest: prepare));
  addTearDown(() => dio.close(force: true));
  return PortalHttp(dio);
}

PasskeyBundle _bundle() {
  // 合成 P-256 标量，仅用于本地签名验证，不是任何账号的真实凭据。
  final scalar = List<int>.filled(32, 0)..[31] = 1;
  final der = [
    0x30,
    0x2e,
    0x02,
    0x01,
    0x00,
    0x30,
    0x00,
    0x04,
    0x27,
    0x30,
    0x25,
    0x02,
    0x01,
    0x01,
    0x04,
    0x20,
    ...scalar,
  ];
  return PasskeyBundle(
    rpId: Uri.parse(NuistLogin.authserverNormal).host,
    credentialId: 'synthetic-credential',
    privateKeyPkcs8Pem:
        '-----BEGIN PRIVATE KEY-----\n${base64Encode(der)}\n-----END PRIVATE KEY-----',
    userId: base64Url.encode(utf8.encode('202512340001')),
    anonbiometricsd: 'synthetic-device',
    deviceName: '测试设备',
    createdAt: DateTime(2026),
  );
}

ResponseBody _redirect(String target, {List<String>? cookies}) =>
    ResponseBody.fromString(
      '',
      302,
      headers: {
        HttpHeaders.locationHeader: [target],
        ?(cookies == null ? null : HttpHeaders.setCookieHeader): ?cookies,
      },
    );

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _Campus {
  _Campus(this.cookies) {
    cas = CasSession(
      cookies: cookies,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, auth),
    );
  }

  final PortalCookieStore cookies;
  late final CasSession cas;
  int assertions = 0;
  int authRequests = 0;
  final callbacks = <String, int>{};
  final counts = <String, int>{};
  final loggedIn = <String>{};
  final stored = <String, EstablishedEntry>{};
  bool vpnValid = false;
  int rulesRequests = 0;
  Future<void> Function()? callbackGate;

  Future<void> saveVpnSession() async {
    final info = base64Encode(
      utf8.encode(jsonEncode({'userId': 'a' * 32, 'username': '202512340001'})),
    );
    await cookies.openJar().saveFromResponse(Uri.parse(VpnAuth.controller), [
      Cookie('ENSSESSIONID', 'valid')
        ..path = '/'
        ..secure = true,
      Cookie('clientInfo', info)
        ..path = '/'
        ..secure = true,
    ]);
  }

  ResponseBody auth(RequestOptions options) {
    authRequests++;
    if (options.uri.path == NuistLogin.startAssertionPath) {
      assertions++;
      return _json({
        'result': {
          'request': {
            'requestId': 'synthetic-request',
            'publicKeyCredentialRequestOptions': {
              'challenge': base64Url.encode(List<int>.filled(32, 1)),
              'allowCredentials': [
                {'id': 'synthetic-credential', 'type': 'public-key'},
              ],
            },
          },
        },
      });
    }
    final service = options.uri.queryParameters['service']!;
    final cookie = '${options.headers[HttpHeaders.cookieHeader]}';
    if (options.method == 'POST' || cookie.contains('CASTGC=valid')) {
      final target = Uri.parse(service).replace(
        queryParameters: {
          ...Uri.parse(service).queryParameters,
          'ticket': 'synthetic-ticket',
        },
      );
      return _redirect(
        '$target',
        cookies: ['CASTGC=valid; Path=/authserver; HttpOnly; Secure'],
      );
    }
    return ResponseBody.fromString(
      '<form id="casLoginForm"><input name="execution" value="e1s1"></form>',
      200,
    );
  }

  Future<ResponseBody> business(RequestOptions options) async {
    final host = options.uri.host;
    if (options.uri.path == '/callback') {
      callbacks[host] = (callbacks[host] ?? 0) + 1;
      await callbackGate?.call();
      loggedIn.add(host);
      return _redirect(
        'https://$host/home',
        cookies: ['BUSINESS=valid; Path=/; Secure'],
      );
    }
    if (options.uri.path == '/home') return ResponseBody.fromString('已登录', 200);
    counts[host] = (counts[host] ?? 0) + 1;
    final cookie = '${options.headers[HttpHeaders.cookieHeader]}';
    if (!loggedIn.contains(host) || !cookie.contains('BUSINESS=valid')) {
      return _redirect(
        '${NuistLogin.authserverNormal}${NuistLogin.loginPath}?service=x',
      );
    }
    return _json({'ok': true});
  }

  Future<ResponseBody> controller(RequestOptions options) async {
    if (options.uri.path.contains('/callback/cas')) {
      vpnValid = true;
      final info = base64Encode(
        utf8.encode(
          jsonEncode({'userId': 'a' * 32, 'username': '202512340001'}),
        ),
      );
      return _redirect(
        '${VpnAuth.controller}/enlink/',
        cookies: [
          'ENSSESSIONID=valid; Path=/; Secure',
          'clientInfo=$info; Path=/; Secure',
        ],
      );
    }
    if (options.uri.path.contains('/terminal/rules/')) {
      rulesRequests++;
      final cookie = '${options.headers[HttpHeaders.cookieHeader]}';
      if (!vpnValid || !cookie.contains('ENSSESSIONID=valid')) {
        return _json({'code': 401}, 401);
      }
      return _json({
        'code': 200,
        'data': {'token': 'synthetic-token', 'server': 'gateway.test:443'},
      });
    }
    return ResponseBody.fromString('已登录', 200);
  }

  VpnAuth vpn() => VpnAuth(
    cas: cas,
    readCredential: () async => _bundle(),
    createHttp: (jar) => _http(jar, controller),
  );

  PortalSession portal({Future<void> Function()? prepare}) =>
      PortalSession.forTesting(
        cas: cas,
        prepareNetwork: prepare,
        createHttp: (jar) => _http(jar, business, prepare: prepare),
        readEstablished: () async => Map.of(stored),
        writeEstablished: (entries) async {
          stored
            ..clear()
            ..addAll(entries);
        },
      );

  Future<Response<dynamic>> query(PortalSession session, String host) =>
      session.request(
        'https://$host/callback',
        (http) => http.get(Uri.parse('https://$host/data')),
      );
}

void main() {
  test('冷启动恢复 VPN 和业务会话，CAS 过期也不触发认证', () async {
    final storage = _MemoryStorage();
    final first = _Campus(PortalCookieStore(storage: storage));
    final vpn = first.vpn();
    final portal = first.portal(
      prepare: () async {
        await vpn.obtain();
      },
    );
    await first.query(portal, 'jwxt.test');
    expect(first.assertions, 1);

    await first.cookies.clearHost(Uri.parse(NuistLogin.authserverNormal));
    final restarted = _Campus(PortalCookieStore(storage: storage))
      ..vpnValid = true
      ..loggedIn.add('jwxt.test')
      ..stored.addAll(first.stored);
    final restartedVpn = restarted.vpn();
    final resumed = restarted.portal(
      prepare: () async {
        await restartedVpn.obtain();
      },
    );
    expect((await restarted.query(resumed, 'jwxt.test')).statusCode, 200);
    expect(restarted.authRequests, 0);
    expect(restarted.assertions, 0);
    expect(restarted.rulesRequests, 1);
  });

  test('VPN 先认证，再恢复两个业务时只做一次 WebAuthn', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final vpn = campus.vpn();
    Future<void>? ready;
    Future<void> prepare() => ready ??= () async {
      await vpn.obtain();
    }();
    final portal = campus.portal(prepare: prepare);
    final results = await Future.wait([
      campus.query(portal, 'jwxt.test'),
      campus.query(portal, 'icard.test'),
    ]).timeout(const Duration(seconds: 5));
    expect(results.map((response) => response.statusCode), [200, 200]);
    expect(campus.assertions, 1);
    expect(campus.callbacks, {'jwxt.test': 1, 'icard.test': 1});
  });

  test('两个业务同时失效，共用 CAS 认证但分别完成业务登录', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final portal = campus.portal();
    await Future.wait([
      campus.query(portal, 'jwxt.test'),
      campus.query(portal, 'icard.test'),
    ]);
    expect(campus.assertions, 1);
    expect(campus.callbacks, {'jwxt.test': 1, 'icard.test': 1});
  });

  test('VPN 控制器过期但 CAS 有效，只做 SSO', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    await campus.saveVpnSession();
    await campus.cookies.openJar().saveFromResponse(
      Uri.parse('${NuistLogin.authserverNormal}/authserver/login'),
      [
        Cookie('CASTGC', 'valid')
          ..path = '/authserver'
          ..secure = true,
      ],
    );
    expect((await campus.vpn().obtain()).token, 'synthetic-token');
    expect(campus.assertions, 0);
    expect(campus.rulesRequests, 2);
  });

  test('VPN HTTP 200 加业务码 1000 的真实超时形态会恢复会话', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    await campus.saveVpnSession();
    var requests = 0;
    final vpn = VpnAuth(
      cas: campus.cas,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (options.uri.path.contains('/terminal/rules/')) {
          requests++;
          if (!campus.vpnValid) {
            return _json({'code': '1000', 'messages': '已超时，请重新登录!'});
          }
        }
        return campus.controller(options);
      }),
    );
    expect((await vpn.obtain()).token, 'synthetic-token');
    expect(requests, 2);
    expect(campus.assertions, 1);
  });

  test('普通维护页与权限错误不会触发 WebAuthn', () async {
    final cookies = PortalCookieStore(storage: _MemoryStorage());
    var requests = 0;
    final cas = CasSession(
      cookies: cookies,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (_) {
        requests++;
        return ResponseBody.fromString('<html>维护中</html>', 403);
      }),
    );
    await expectLater(
      cas.authenticate('https://jwxt.test/callback'),
      throwsA(isA<PortalLoginError>()),
    );
    expect(requests, 1);
    expect(cas.credentialError.value, isNull);
  });

  test('清空途中旧响应不能写回 Cookie、落地缓存或新账号', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final portal = campus.portal();
    final entered = Completer<void>();
    final release = Completer<void>();
    campus.callbackGate = () async {
      entered.complete();
      await release.future;
    };
    final old = portal.ensureLoggedIn('https://jwxt.test/callback');
    final rejected = expectLater(old, throwsA(isA<PortalException>()));
    await entered.future;
    await portal.clear();
    campus.callbackGate = null;
    await campus
        .query(portal, 'icard.test')
        .timeout(const Duration(seconds: 5));
    release.complete();
    await rejected;
    final jar = campus.cookies.openJar();
    expect(
      await jar.loadForRequest(Uri.parse('https://jwxt.test/home')),
      isEmpty,
    );
    expect(
      await jar.loadForRequest(
        Uri.parse('${NuistLogin.authserverNormal}/authserver/login'),
      ),
      hasLength(1),
    );
    expect(campus.stored.keys, ['https://icard.test/callback']);
    expect(campus.assertions, 2);
  });

  test('VPN 清理保留 CAS 和父域共享的业务 Cookie', () async {
    final storage = _MemoryStorage();
    final campus = _Campus(PortalCookieStore(storage: storage));
    final controller = Uri.parse(VpnAuth.controller);
    final parent = controller.host.split('.').skip(2).join('.');
    final jar = campus.cookies.openJar();
    await jar.saveFromResponse(controller, [
      Cookie('ENSSESSIONID', 'synthetic')
        ..domain = parent
        ..path = '/',
      Cookie('sharedBusiness', 'synthetic')
        ..domain = parent
        ..path = '/',
    ]);
    final auth = Uri.parse('${NuistLogin.authserverNormal}/authserver/login');
    await jar.saveFromResponse(auth, [
      Cookie('CASTGC', 'valid')..path = '/authserver',
    ]);
    await campus.vpn().clear();
    final restored = PortalCookieStore(storage: storage).openJar();
    expect(
      (await restored.loadForRequest(controller)).map((cookie) => cookie.name),
      ['sharedBusiness'],
    );
    expect(
      (await restored.loadForRequest(auth)).map((cookie) => cookie.name),
      containsAll(['CASTGC', 'sharedBusiness']),
    );
  });

  test('持久化会话 Cookie，删除和过期的 Secure Cookie 不再发送', () async {
    final storage = _MemoryStorage();
    final cookies = PortalCookieStore(storage: storage);
    final uri = Uri.parse('https://auth.test/authserver/login');
    var jar = cookies.openJar();
    await jar.saveFromResponse(uri, [
      Cookie('CASTGC', 'valid')..path = '/authserver',
    ]);
    jar = PortalCookieStore(storage: storage).openJar();
    expect((await jar.loadForRequest(uri)).single.name, 'CASTGC');
    await jar.saveFromResponse(uri, [
      Cookie('CASTGC', 'deleted')
        ..path = '/authserver'
        ..secure = true
        ..maxAge = 0,
      Cookie('expired', 'synthetic')
        ..path = '/'
        ..secure = true
        ..expires = DateTime.utc(2000),
    ]);
    expect(await jar.loadForRequest(uri), isEmpty);
  });

  test('准备 VPN 后才装入 Cookie，首次请求使用更新后的 CAS 状态', () async {
    final cookies = PortalCookieStore(storage: _MemoryStorage());
    final jar = cookies.openJar();
    final uri = Uri.parse('https://auth.test/authserver/login');
    await jar.saveFromResponse(uri, [
      Cookie('CASTGC', 'old')..path = '/authserver',
    ]);
    final http = _http(
      jar,
      (options) {
        expect(options.headers[HttpHeaders.cookieHeader], 'CASTGC=new');
        return ResponseBody.fromString('完成', 200);
      },
      prepare: () => jar.saveFromResponse(uri, [
        Cookie('CASTGC', 'new')..path = '/authserver',
      ]),
    );
    expect((await http.get(uri)).data, '完成');
  });

  test('控制器已有会话但返回维护页，不清 Cookie 或转去认证', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    await campus.saveVpnSession();
    var requests = 0;
    final vpn = VpnAuth(
      cas: campus.cas,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (_) {
        requests++;
        return ResponseBody.fromString('<html>维护中</html>', 200);
      }),
    );
    await expectLater(vpn.obtain(), throwsA(isA<PortalLoginError>()));
    expect(requests, 1);
    expect(campus.authRequests, 0);
    expect(
      (await campus.cookies.openJar().loadForRequest(
        Uri.parse(VpnAuth.controller),
      )).map((cookie) => cookie.name),
      containsAll(['ENSSESSIONID', 'clientInfo']),
    );
  });

  test('CAS 普通提交失败不标记凭据失效，队列失败后仍可重试', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    var failSubmit = true;
    final cas = CasSession(
      cookies: campus.cookies,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (failSubmit &&
            options.uri.path == NuistLogin.loginPath &&
            options.method == 'POST') {
          return ResponseBody.fromString('<html>维护中</html>', 200);
        }
        return campus.auth(options);
      }),
    );
    await expectLater(
      cas.authenticate('https://jwxt.test/callback'),
      throwsA(isA<PortalLoginError>()),
    );
    expect(cas.credentialError.value, isNull);
    failSubmit = false;
    expect(
      await cas.authenticate('https://jwxt.test/callback'),
      contains('synthetic-ticket'),
    );
    expect(campus.assertions, 2);
  });

  test('CAS 普通 JSON 错误不标记密钥失效，恢复服务后可继续认证', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    Map<String, Object?>? failure;
    final cas = CasSession(
      cookies: campus.cookies,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (failure != null &&
            options.uri.path == NuistLogin.startAssertionPath) {
          return _json(failure);
        }
        return campus.auth(options);
      }),
    );
    for (final error in [
      {'message': '系统维护中'},
      {'success': false, 'message': '系统繁忙，请稍后再试'},
    ]) {
      failure = error;
      await expectLater(
        cas.authenticate('https://jwxt.test/callback'),
        throwsA(isA<PortalLoginError>()),
      );
      expect(cas.credentialError.value, isNull);
    }
    failure = null;
    expect(
      await cas.authenticate('https://jwxt.test/callback'),
      contains('synthetic-ticket'),
    );
    expect(campus.assertions, 1);
  });

  test('解绑等待 WebView 写入完成后再清空，不留下晚到的旧 Cookie', () async {
    final previous = WebViewPlatform.instance;
    final platform = _CookieWebViewPlatform();
    WebViewPlatform.instance = platform;
    addTearDown(() {
      if (previous != null) WebViewPlatform.instance = previous;
    });
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final portal = campus.portal();
    await campus.cookies.openJar().saveFromResponse(
      Uri.parse('${NuistLogin.authserverNormal}/authserver/login'),
      [Cookie('CASTGC', 'synthetic')..path = '/authserver'],
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    platform.onWrite = () async {
      entered.complete();
      await release.future;
    };
    final syncing = portal.syncToWebView(['https://jwxt.test/home']);
    final rejected = expectLater(syncing, throwsA(isA<PortalException>()));
    await entered.future;
    final clearing = portal.clear(includeWebView: true);
    release.complete();
    await clearing;
    await rejected;
    expect(platform.cookies, isEmpty);
  });

  test('损坏的 Cookie 落盘按没有会话处理', () async {
    final storage = _MemoryStorage();
    final uri = Uri.parse('https://auth.test/authserver/login');
    await PortalCookieStore(storage: storage).openJar().saveFromResponse(uri, [
      Cookie('CASTGC', 'synthetic')..path = '/authserver',
    ]);
    storage.values[uri.host] = '{broken';
    final jar = PortalCookieStore(storage: storage).openJar();
    expect(await jar.loadForRequest(uri), isEmpty);
    await jar.saveFromResponse(uri, [
      Cookie('CASTGC', 'new')..path = '/authserver',
    ]);
    expect((await jar.loadForRequest(uri)).single.value, 'new');
  });

  test('冷启动 CASTGC 有效而 VPN 控制器过期时只走 SSO', () async {
    final storage = _MemoryStorage();
    final first = _Campus(PortalCookieStore(storage: storage));
    await first.vpn().obtain();
    final restarted = _Campus(PortalCookieStore(storage: storage));
    expect((await restarted.vpn().obtain()).token, 'synthetic-token');
    expect(restarted.assertions, 0);
    expect(restarted.authRequests, 1);
  });

  test('业务缓存超过原有 TTL 时确认会话，仍复用 CASTGC', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final portal = campus.portal();
    await portal.ensureLoggedIn('https://jwxt.test/callback');
    final restarted = _Campus(campus.cookies)..stored.addAll(campus.stored);
    restarted.stored['https://jwxt.test/callback'] = EstablishedEntry(
      landing: 'https://jwxt.test/home',
      at: DateTime(2020),
      restored: true,
    );
    await restarted.portal().ensureLoggedIn('https://jwxt.test/callback');
    expect(restarted.callbacks['jwxt.test'], 1);
    expect(restarted.assertions, 0);
  });

  test('测试登录清空共享 CAS 会话，每次均重新验证密钥', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final portal = campus.portal();
    await portal.verifyCredential(service: 'https://jwxt.test/callback');
    await portal.verifyCredential(service: 'https://jwxt.test/callback');
    expect(campus.assertions, 2);
  });

  test('晚到的旧响应覆盖新业务 Cookie 时仍重新恢复并重试', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final entered = Completer<void>();
    final release = Completer<void>();
    var slowCalls = 0;
    final portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, (options) async {
        if (options.uri.path == '/slow' && slowCalls++ == 0) {
          entered.complete();
          await release.future;
          return _redirect(
            '${NuistLogin.authserverNormal}${NuistLogin.loginPath}?service=x',
            cookies: ['BUSINESS=expired; Path=/; Secure'],
          );
        }
        if (options.uri.host == Uri.parse(NuistLogin.authserverNormal).host) {
          return ResponseBody.fromString(
            '<form id="casLoginForm"><input name="execution" value="e1s1"></form>',
            200,
          );
        }
        return campus.business(options);
      }),
    );
    await campus.query(portal, 'jwxt.test');
    final slow = portal.request(
      'https://jwxt.test/callback',
      (http) => http.get(Uri.parse('https://jwxt.test/slow')),
    );
    await entered.future;
    await portal.ensureLoggedIn('https://jwxt.test/callback', force: true);
    release.complete();
    expect((await slow).statusCode, 200);
    expect(campus.callbacks['jwxt.test'], 3);
    expect(campus.assertions, 1);
  });
}
