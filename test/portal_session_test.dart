import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/cas_session.dart';
import 'package:nuist_sta_app/core/auth/campus_transport.dart';
import 'package:nuist_sta_app/core/auth/established_store.dart';
import 'package:nuist_sta_app/core/auth/nuist_login.dart';
import 'package:nuist_sta_app/core/auth/passkey_bundle.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_manager.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_store.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/auth/portal_session.dart';
import 'package:nuist_sta_app/core/auth/service_auth_spec.dart';
import 'package:nuist_sta_app/core/auth/session_executor.dart';
import 'package:nuist_sta_app/core/config/campus_config.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/network/vpn_auth.dart';
import 'package:nuist_sta_app/mini_apps/library/library_api.dart';
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

class _BlockingCookieStorage extends _MemoryStorage {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (key == CampusHosts.authserver &&
        value.contains('CASTGC=stale') &&
        !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.write(key, value);
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

class _AuthTestSpec extends ServiceAuthSpec<String> {
  const _AuthTestSpec({
    required this.id,
    required this.cookieHosts,
    this.buildSession,
  });
  @override
  final String id;
  @override
  final List<String> cookieHosts;
  final Future<String> Function(CampusTransport transport, Uri landing)?
  buildSession;
  @override
  String get casServiceUrl => 'https://${cookieHosts.first}/landing';
  @override
  Future<String> establish(CampusTransport transport, Uri casLandingUri) async {
    if (buildSession case final build?) return build(transport, casLandingUri);
    requireServiceSuccess(
      await transport.get(casLandingUri),
      endpoint: 'test.landing',
      service: id,
    );
    return id;
  }
}

class _LandingTestSpec extends ServiceAuthSpec<Response<dynamic>> {
  const _LandingTestSpec(this.casServiceUrl);
  @override
  final String casServiceUrl;
  @override
  String get id => 'landing.$casServiceUrl';
  @override
  List<String> get cookieHosts => [Uri.parse(casServiceUrl).host];
  @override
  Future<Response<dynamic>> establish(CampusTransport transport, Uri landing) =>
      transport.get(landing);
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
  final dio = Dio()..httpClientAdapter = _Adapter(respond);
  if (prepare != null) {
    dio.interceptors.add(
      VpnPreparationInterceptor(dio, beforeRequest: prepare),
    );
  }
  dio.interceptors.add(PortalCookieManager(jar));
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

  Future<void> saveVpnSession({String sessionId = 'valid'}) async {
    final info = base64Encode(
      utf8.encode(jsonEncode({'userId': 'a' * 32, 'username': '202512340001'})),
    );
    await cookies.openJar().saveFromResponse(Uri.parse(VpnAuth.controller), [
      Cookie('ENSSESSIONID', sessionId)
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test('图书馆请求遇到 401 时重新建立业务会话，且不记录借阅详情', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    final host = CampusHosts.library;
    const opac = '/meta-local/opac';
    final visited = <String>[];
    int loginCount = 0;
    final portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, (options) {
        final uri = options.uri;
        visited.add(uri.path);
        expect(uri.host, host);
        expect(options.method, 'GET');
        if (uri.path == '$opac/cas/rosetta') {
          expect(uri.queryParameters['ticket'], 'synthetic-ticket');
          loginCount++;
          return _redirect(
            'https://$host/mspace/',
            cookies: [
              'LIBRARY=valid; Path=/; Secure; HttpOnly',
              'CSRF-TOKEN=synthetic%2Btoken; Path=/; Secure',
            ],
          );
        }
        if (uri.path == '/mspace/') return ResponseBody.fromString('', 200);
        expect(uri.path, '$opac/users/loans');
        expect(uri.queryParameters, {'page': '2', 'pageSize': '20'});
        expect(
          options.headers[HttpHeaders.cookieHeader],
          contains('LIBRARY=valid'),
        );
        expect(options.headers['X-CSRF-TOKEN'], 'synthetic+token');
        if (loginCount == 1) return ResponseBody.fromString('', 401);
        return _json({
          'code': 0,
          'data': {
            'total': 21,
            'items': [
              {
                'bibId': 'synthetic-book',
                'bibAttrs': {'title': '私有测试借阅书名', 'author': '测试作者'},
                'loanDate': '2026-10-20 12:00:00',
                'dueDate': '2026-11-20',
                'loanStatus': 'soon',
              },
            ],
          },
        });
      }),
    );

    final loans = await LibraryApi(portal: portal).fetchLoans(2);
    expect(loginCount, 2);
    expect(visited, [
      '$opac/cas/rosetta',
      '/mspace/',
      '$opac/users/loans',
      '$opac/cas/rosetta',
      '/mspace/',
      '$opac/users/loans',
    ]);
    expect(loans.total, 21);
    expect(loans.items.single.borrowedOn, '2026-10-20');
    expect(loans.items.single.dueOn, '2026-11-20');
    expect(loans.items.single.status, '即将到期');
    expect(loans.items.single.title, '私有测试借阅书名');
    final diagnostics = jsonEncode(records);
    expect(diagnostics, contains('library_loans'));
    expect(diagnostics, isNot(contains('私有测试借阅书名')));
    expect(diagnostics, isNot(contains('synthetic+token')));
  });

  Future<Map<String, Object?>> landingEvidence(PortalSession portal) async {
    final result = await portal.ensureLoggedInWithEvidence(
      PortalServices.icard,
    );
    return Map<String, Object?>.from(result.diagnosticContext);
  }

  test('恢复落地缓存时展示实际地址和零HTTP事实', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    var requests = 0;
    final portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, (_) {
        requests++;
        return ResponseBody.fromString('不应发起请求', 200);
      }),
      readEstablished: () async => {
        PortalServices.icard: EstablishedEntry(
          landing: 'https://icard.test/landing?flow=old-cache&ticket=synthetic-secret',
          at: DateTime.now(),
          restored: true,
        ),
      },
    );
    final details = await landingEvidence(portal);
    expect(requests, 0);
    expect(campus.authRequests, 0);
    expect(details['source'], 'restored');
    expect(details['landing_url'], contains('/landing?flow=old-cache'));
    expect(
      details['landing_url'].toString().contains('synthetic-secret'),
      isFalse,
    );
    expect(details['query_parameter_names'], ['flow', 'ticket']);
    expect(details['authorization_present'], isFalse);
    expect(details['http_performed_for_this_lookup'], isFalse);
    expect(details['original_response_available'], isFalse);
    expect(
      details['original_response_unavailable_reason'],
      'restored_landing_only',
    );
  });

  test('落地证据保留新登录原响应，内存和序列化缓存仅按日志引用复用', () async {
    await AppLog.resetForTesting();
    final temp = await Directory.systemTemp.createTemp(
      'portal_landing_evidence_',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      await temp.delete(recursive: true);
    });
    await AppLog.initialize(directory: temp);
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final stored = <String, EstablishedEntry>{};
    var requests = 0;
    final portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, (_) {
        requests++;
        return ResponseBody.fromString(
          '<html>synthetic-landing-evidence<input name="token" value="synthetic-body-secret"></html>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
          },
        );
      }),
      writeEstablished: (entries) async {
        stored
          ..clear()
          ..addAll(entries);
      },
    );
    final fresh = await landingEvidence(portal);
    expect(fresh['source'], 'fresh');
    expect(fresh['http_performed_for_this_lookup'], isTrue);
    expect(fresh['original_response_available'], isTrue);
    expect(jsonEncode(fresh), contains('synthetic-landing-evidence'));
    expect(jsonEncode(fresh).contains('synthetic-body-secret'), isFalse);
    expect(requests, 1);
    final serialized = stored[PortalServices.icard]!.toJson();
    expect(serialized['diagnostic_record'], isA<Map>());
    expect(
      jsonEncode(serialized).contains('synthetic-landing-evidence'),
      isFalse,
    );
    expect(
      (serialized['diagnostic_record'] as Map).keys,
      unorderedEquals(['session_id', 'seq']),
    );

    final memory = await landingEvidence(portal);
    expect(memory['source'], 'memory');
    expect(memory['http_performed_for_this_lookup'], isFalse);
    expect(memory['original_response_available'], isTrue);
    expect(jsonEncode(memory), contains('synthetic-landing-evidence'));
    expect(requests, 1);

    final restored = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, (_) {
        requests++;
        return ResponseBody.fromString('不应发起请求', 200);
      }),
      readEstablished: () async => {
        PortalServices.icard: EstablishedEntry.fromJson(serialized)!,
      },
    );
    final restoredDetails = await landingEvidence(restored);
    expect(restoredDetails['source'], 'restored');
    expect(restoredDetails['original_response_available'], isTrue);
    expect(jsonEncode(restoredDetails), contains('synthetic-landing-evidence'));
    expect(requests, 1);
    await AppLog.clear();
    final removed = await landingEvidence(restored);
    expect(removed['original_response_available'], isFalse);
    expect(
      removed['original_response_unavailable_reason'],
      'diagnostic_record_expired_removed_or_unavailable',
    );
    expect(requests, 1);
  });

  for (final unavailable in ['attachment_missing', 'not_http']) {
    test('历史登录证据 $unavailable 时不宣称有原始响应', () async {
      await AppLog.resetForTesting();
      final temp = await Directory.systemTemp.createTemp(
        'portal_missing_evidence_',
      );
      addTearDown(() async {
        await AppLog.resetForTesting();
        await temp.delete(recursive: true);
      });
      await AppLog.initialize(directory: temp);
      Map<String, Object?> reference;
      if (unavailable == 'attachment_missing') {
        final evidence = AppLog.recordHttpExchange('test.portal_response', {
          'request': {'url': 'https://icard.test/landing'},
          'response': {'status': 200, 'body': 'x' * 70000, 'complete': true},
        })!;
        reference = Map<String, Object?>.from(evidence['record_ref'] as Map);
        await AppLog.snapshot();
        final attachments = Directory(
          '${temp.path}/nuist_sta_app/logs/records',
        );
        final attachment = await attachments
            .list()
            .where((entry) => entry is File)
            .cast<File>()
            .single;
        await attachment.delete();
      } else {
        Map<String, Object?>? unrelated;
        AppLog.recordListenerForTesting = (record) => unrelated = record;
        AppLog.logger('test.unrelated').info(
          'not_http',
          fields: {
            'details': {
              'response': {
                'status': 200,
                'body': 'unrelated-response-shaped-value',
              },
            },
          },
        );
        reference = {
          'session_id': unrelated!['session_id'],
          'seq': unrelated!['seq'],
        };
      }
      final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
      var requests = 0;
      final portal = PortalSession.forTesting(
        cas: campus.cas,
        createHttp: (jar) => _http(jar, (_) {
          requests++;
          return ResponseBody.fromString('不应请求', 200);
        }),
        readEstablished: () async => {
          PortalServices.icard: EstablishedEntry(
            landing: 'https://icard.test/landing?flow=cached',
            at: DateTime.now(),
            restored: true,
            diagnosticRecord: reference,
          ),
        },
      );
      final details = await landingEvidence(portal);
      expect(requests, 0);
      expect(details['original_response_available'], isFalse);
      expect(details.containsKey('landing_response'), isFalse);
      expect(details['record_ref'], reference);
      expect(
        details['original_response_unavailable_reason'],
        unavailable == 'attachment_missing'
            ? 'diagnostic_attachment_unavailable'
            : 'diagnostic_record_not_http_exchange',
      );
    });
  }

  test('并发登录记录共享任务编号与排队耗时', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final entered = Completer<void>();
    final release = Completer<void>();
    campus.callbackGate = () async {
      entered.complete();
      await release.future;
    };
    final portal = campus.portal();
    final first = portal.ensureLoggedIn('https://jwxt.test/callback');
    await entered.future;
    final second = portal.ensureLoggedIn('https://jwxt.test/callback');
    await pumpEventQueue();
    release.complete();
    expect(await second, await first);
    final joined = records.singleWhere(
      (r) => r['event'] == 'service.login_joined',
    );
    final dequeued = records.singleWhere(
      (r) => r['event'] == 'service.login_dequeued',
    );
    final completed = records.singleWhere(
      (r) => r['event'] == 'service.login.completed',
    );
    expect(
      (joined['attrs'] as Map)['shared_login_id'],
      (completed['attrs'] as Map)['login_id'],
    );
    expect((dequeued['attrs'] as Map)['queued_ms'], isNonNegative);
    expect(dequeued['trace_id'], completed['trace_id']);
    expect(campus.assertions, 1);
  });

  test('业务摘要匿名化，完整请求保留路径但隐藏凭据', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    await campus.query(campus.portal(), CampusHosts.jwxt);
    final login = records.singleWhere(
      (record) => record['event'] == 'service.login.completed',
    );
    final response = records.singleWhere(
      (record) => record['event'] == 'service.request.completed',
    );
    expect((login['attrs'] as Map)['service'], 'jwxt');
    expect((response['attrs'] as Map)['service'], 'jwxt');
    expect((response['attrs'] as Map)['status_code'], 200);
    expect(login['trace_id'], response['trace_id']);
    final summaries = records
        .map(
          (record) => {
            ...record,
            'attrs': Map<String, Object?>.from(record['attrs'] as Map)
              ..remove('details'),
          },
        )
        .toList();
    final text = jsonEncode(records);
    expect(
      jsonEncode(summaries).contains(CampusHosts.jwxt),
      isFalse,
      reason: '摘要中主机必须匿名化',
    );
    expect(text, contains('/data'));
    expect(text.contains('synthetic-ticket'), isFalse, reason: 'ticket必须脱敏');
    expect(text.contains('synthetic-credential'), isFalse, reason: '凭据ID必须脱敏');
  });

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

  test('VPN 控制器返回 1001 被踢下线时清理旧 Cookie 并经 CAS 重登恢复', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    final storage = _MemoryStorage();
    final campus = _Campus(PortalCookieStore(storage: storage));
    await campus.saveVpnSession(sessionId: 'kicked');
    var rulesRequests = 0;
    var callbacks = 0;
    String? callbackCookieHeader;
    final vpn = VpnAuth(
      cas: campus.cas,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (options.uri.path.contains('/callback/cas')) {
          callbacks++;
          callbackCookieHeader = options.headers[HttpHeaders.cookieHeader]
              ?.toString();
        }
        if (options.uri.path.contains('/terminal/rules/')) {
          rulesRequests++;
          final cookie = '${options.headers[HttpHeaders.cookieHeader]}';
          if (cookie.contains('ENSSESSIONID=kicked')) {
            return _json({
              'code': '1001',
              'messages': 'Account was kicked offline by the administrator, please log in again!',
              'data': null,
            });
          }
        }
        return campus.controller(options);
      }),
    );

    final credentials = await vpn.obtain();
    expect(credentials.token, 'synthetic-token');
    expect(rulesRequests, 2);
    expect(callbacks, 1);
    expect(campus.assertions, 1);
    expect(
      callbackCookieHeader ?? '',
      isNot(contains('ENSSESSIONID')),
      reason: 'CAS 回调前必须已清理失效的控制器会话 Cookie',
    );
    expect(callbackCookieHeader ?? '', isNot(contains('clientInfo')));

    final rejected = records
        .where((record) => record['event'] == 'authentication.session_rejected')
        .toList();
    expect(rejected, hasLength(1));
    final attrs = (rejected.single['attrs'] as Map).cast<String, Object?>();
    expect(attrs['reason_code'], 'controller_session_expired');
    expect(attrs['response_code'], 1001);
    expect(attrs['attempt'], 1);
    expect(attrs.containsKey('field_validation'), isFalse);
    expect(
      jsonEncode(rejected.single),
      isNot(contains('Account was kicked offline')),
      reason: '结构化会话失效事件不应把原始服务端文案直接写入摘要字段',
    );

    // 验证重启后磁盘已保存新会话，不再卡在被踢的旧 Cookie 上。
    final restarted = _Campus(PortalCookieStore(storage: storage))
      ..vpnValid = true;
    expect((await restarted.vpn().obtain()).token, 'synthetic-token');
    expect(restarted.authRequests, 0);
    expect(restarted.assertions, 0);
    expect(restarted.rulesRequests, 1);
  });

  test('VPN 控制器返回 1001 且 CASTGC 仍有效时清理控制器 Cookie 并仅走 SSO', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    await campus.saveVpnSession(sessionId: 'kicked');
    await campus.cookies.openJar().saveFromResponse(
      Uri.parse('${NuistLogin.authserverNormal}/authserver/login'),
      [
        Cookie('CASTGC', 'valid')
          ..path = '/authserver'
          ..secure = true,
      ],
    );
    var rulesRequests = 0;
    final vpn = VpnAuth(
      cas: campus.cas,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (options.uri.path.contains('/terminal/rules/')) {
          rulesRequests++;
          final cookie = '${options.headers[HttpHeaders.cookieHeader]}';
          if (cookie.contains('ENSSESSIONID=kicked')) {
            return _json({
              'code': '1001',
              'messages': 'Account was kicked offline by the administrator, please log in again!',
              'data': null,
            });
          }
        }
        return campus.controller(options);
      }),
    );

    expect((await vpn.obtain()).token, 'synthetic-token');
    expect(rulesRequests, 2);
    expect(campus.assertions, 0);
    expect(campus.authRequests, 1);
  });

  test('VPN HTTP 200 业务码 401、1001 整型及 1000 英文失效提示均可恢复会话', () async {
    final cases = <({Map<String, Object?> payload, int expectedCode})>[
      (
        payload: {'code': '401', 'messages': 'Unauthorized', 'data': null},
        expectedCode: 401,
      ),
      (
        payload: {
          'code': '1000',
          'messages': 'Session expired, Please Log In Again!',
          'data': null,
        },
        expectedCode: 1000,
      ),
      (
        payload: {
          'code': '1000',
          'messages': 'Account was Kicked Offline',
          'data': null,
        },
        expectedCode: 1000,
      ),
      (
        payload: {'code': 1001, 'messages': null, 'data': null},
        expectedCode: 1001,
      ),
    ];
    for (final testCase in cases) {
      final records = <Map<String, Object?>>[];
      AppLog.recordListenerForTesting = records.add;
      try {
        final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
        await campus.saveVpnSession(sessionId: 'stale');
        var rulesRequests = 0;
        final vpn = VpnAuth(
          cas: campus.cas,
          readCredential: () async => _bundle(),
          createHttp: (jar) => _http(jar, (options) {
            if (options.uri.path.contains('/terminal/rules/')) {
              rulesRequests++;
              if (!campus.vpnValid) return _json(testCase.payload);
            }
            return campus.controller(options);
          }),
        );
        expect((await vpn.obtain()).token, 'synthetic-token');
        expect(rulesRequests, 2);
        expect(campus.assertions, 1);
        final rejected = records.singleWhere(
          (record) => record['event'] == 'authentication.session_rejected',
        );
        final attrs = (rejected['attrs'] as Map).cast<String, Object?>();
        expect(attrs['reason_code'], 'controller_session_expired');
        expect(attrs['response_code'], testCase.expectedCode);
        expect(attrs.containsKey('field_validation'), isFalse);
      } finally {
        AppLog.recordListenerForTesting = null;
      }
    }
  });

  test('VPN 刚 CAS 重登后仍持续返回 1001 时抛 PortalLoginError 且不死循环', () async {
    final records = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = records.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    await campus.saveVpnSession(sessionId: 'kicked');
    var rulesRequests = 0;
    var callbacks = 0;
    final vpn = VpnAuth(
      cas: campus.cas,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (options.uri.path.contains('/callback/cas')) callbacks++;
        if (options.uri.path.contains('/terminal/rules/')) {
          rulesRequests++;
          return _json({
            'code': '1001',
            'messages': 'Account was kicked offline by the administrator, please log in again!',
            'data': null,
          });
        }
        return campus.controller(options);
      }),
    );

    await expectLater(
      vpn.obtain(),
      throwsA(
        isA<PortalLoginError>()
            .having((e) => e.code, 'code', 'vpn_controller_rules_rejected')
            .having((e) => e.stage, 'stage', 'vpn.rules.validate')
            .having((e) => e.context['response_code'], 'response_code', '1001')
            .having((e) => e.context['attempt'], 'attempt', 1)
            .having(
              (e) => (e.context['details'] as Map)['after_cas_relogin'],
              'after_cas_relogin',
              isTrue,
            )
            .having(
              (e) => (e.context['details'] as Map)['session_expired'],
              'session_expired',
              isTrue,
            ),
      ),
    );
    expect(rulesRequests, 2);
    expect(callbacks, 1);
    expect(campus.assertions, 1);
    final rejected = records
        .where((record) => record['event'] == 'authentication.session_rejected')
        .toList();
    expect(rejected, hasLength(2));
    for (final record in rejected) {
      final attrs = (record['attrs'] as Map).cast<String, Object?>();
      expect(attrs['reason_code'], 'controller_session_expired');
      expect(attrs['response_code'], 1001);
      expect(attrs.containsKey('field_validation'), isFalse);
    }
  });

  test('VPN 控制器返回未知错误码 500 或非重登 1000 错误时直接抛 PortalLoginError', () async {
    // 场景 1：复用旧会话遇到未知错误码 500 或非重登 1000 错误，不清 Cookie 也不触发 CAS。
    for (final failure in [
      {'code': '500', 'messages': 'Internal server error', 'data': null},
      {'code': '1000', 'messages': '系统繁忙，请稍后再试', 'data': null},
    ]) {
      final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
      await campus.saveVpnSession(sessionId: 'valid');
      var rulesRequests = 0;
      final vpn = VpnAuth(
        cas: campus.cas,
        readCredential: () async => _bundle(),
        createHttp: (jar) => _http(jar, (options) {
          if (options.uri.path.contains('/terminal/rules/')) {
            rulesRequests++;
            return _json(failure);
          }
          return campus.controller(options);
        }),
      );
      await expectLater(
        vpn.obtain(),
        throwsA(
          isA<PortalLoginError>()
              .having((e) => e.code, 'code', 'vpn_controller_rules_rejected')
              .having((e) => e.stage, 'stage', 'vpn.rules.validate')
              .having(
                (e) => e.context['response_code'],
                'response_code',
                failure['code'],
              )
              .having((e) => e.context['attempt'], 'attempt', 1),
        ),
      );
      expect(rulesRequests, 1);
      expect(campus.authRequests, 0);
      expect(
        (await campus.cookies.openJar().loadForRequest(
          Uri.parse(VpnAuth.controller),
        )).map((cookie) => cookie.name),
        containsAll(['ENSSESSIONID', 'clientInfo']),
      );
    }

    // 场景 2：旧会话 1001 触发 CAS 重登后，新会话遇到未知错误码 500 时抛异常且不重试。
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    await campus.saveVpnSession(sessionId: 'kicked');
    var rulesRequests = 0;
    final vpn = VpnAuth(
      cas: campus.cas,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (options.uri.path.contains('/terminal/rules/')) {
          rulesRequests++;
          if (!campus.vpnValid) {
            return _json({
              'code': '1001',
              'messages': 'Account was kicked offline by the administrator, please log in again!',
              'data': null,
            });
          }
          return _json({
            'code': '500',
            'messages': 'Internal server error',
            'data': null,
          });
        }
        return campus.controller(options);
      }),
    );
    await expectLater(
      vpn.obtain(),
      throwsA(
        isA<PortalLoginError>()
            .having((e) => e.code, 'code', 'vpn_controller_rules_rejected')
            .having((e) => e.stage, 'stage', 'vpn.rules.validate')
            .having((e) => e.context['response_code'], 'response_code', '500')
            .having((e) => e.context['attempt'], 'attempt', 1)
            .having(
              (e) => (e.context['details'] as Map)['after_cas_relogin'],
              'after_cas_relogin',
              isTrue,
            )
            .having(
              (e) => (e.context['details'] as Map)['session_expired'],
              'session_expired',
              isFalse,
            ),
      ),
    );
    expect(rulesRequests, 2);
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

  test('控制器旧会话返回维护页时清 Cookie 并重新认证', () async {
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
    expect(requests, 2);
    expect(campus.assertions, 1);
    expect(
      (await campus.cookies.openJar().loadForRequest(
        Uri.parse(VpnAuth.controller),
      )).map((cookie) => cookie.name),
      isEmpty,
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

  test('CAS 凭据读取卡住时有界失败并释放队列，迟到任务不发送认证请求', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final gate = Completer<void>();
    var firstRead = true;
    final cas = CasSession(
      cookies: campus.cookies,
      authenticationTimeout: const Duration(milliseconds: 100),
      readCredential: () async {
        if (firstRead) {
          firstRead = false;
          await gate.future;
        }
        return _bundle();
      },
      createHttp: (jar) => _http(jar, campus.auth),
    );
    await expectLater(
      cas.authenticate('https://jwxt.test/callback'),
      throwsA(isA<PortalNetworkError>()),
    );
    expect(cas.credentialError.value, isNull);
    expect(campus.authRequests, 0);
    expect(
      await cas.authenticate('https://jwxt.test/callback'),
      contains('synthetic-ticket'),
    );
    final requests = campus.authRequests;
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(campus.authRequests, requests);
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

  test('验证凭据每次完整签名，不改账号代次或取消其他服务请求', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final entered = Completer<void>();
    final release = Completer<void>();
    var networkResets = 0;
    final portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, (options) async {
        if (options.uri.host == 'icard.test' && options.uri.path == '/slow') {
          entered.complete();
          await release.future;
          return _json({'ok': true});
        }
        return campus.business(options);
      }),
      resetNetwork: () async {
        networkResets++;
      },
      readEstablished: () async => Map.of(campus.stored),
      writeEstablished: (entries) async {
        campus.stored
          ..clear()
          ..addAll(entries);
      },
    );
    await campus.query(portal, 'icard.test');
    final generation = campus.cookies.generation;
    final otherCookies = await campus.cookies.openJar().loadForRequest(
      Uri.https('icard.test', '/'),
    );
    final baselineAssertions = campus.assertions;
    final other = portal.request(
      'https://icard.test/callback',
      (http) => http.get(Uri.https('icard.test', '/slow')),
    );
    await entered.future;
    final stages = <String>[];
    campus.cas.credentialError.value = const PortalCredentialError('合成历史认证拒绝');
    await portal.verifyCredential(
      service: 'https://jwxt.test/callback',
      onStage: stages.add,
    );
    await portal.verifyCredential(
      service: 'https://jwxt.test/callback',
      onStage: stages.add,
    );
    expect(campus.assertions, baselineAssertions + 2);
    expect(campus.cookies.generation, generation);
    expect(networkResets, 0);
    expect(stages.where((stage) => stage == 'asserting').length, 2);
    expect(stages.where((stage) => stage == 'submitting').length, 2);
    expect(
      campus.stored.keys,
      containsAll([
        'https://icard.test/callback',
        'https://jwxt.test/callback',
      ]),
    );
    expect(
      campus.stored['https://jwxt.test/callback']!.diagnosticRecord,
      isNotNull,
    );
    expect(
      (await campus.cookies.openJar().loadForRequest(
        Uri.https('icard.test', '/'),
      )).map((cookie) => cookie.value),
      otherCookies.map((cookie) => cookie.value),
    );
    release.complete();
    expect((await other).statusCode, 200);
    expect(campus.callbacks['icard.test'], 1);
  });

  test('晚到旧响应不会覆盖新 Cookie，并复用刷新后的修订号', () async {
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
    expect(campus.callbacks['jwxt.test'], 2);
    expect(campus.assertions, 1);
  });

  for (final shape in ['1001', '403', 'html']) {
    test('VPN 旧控制器 Cookie 遇到 $shape 时清理并完整恢复', () async {
      final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
      await campus.saveVpnSession();
      var rejected = false;
      final vpn = VpnAuth(
        cas: campus.cas,
        readCredential: () async => _bundle(),
        createHttp: (jar) => _http(jar, (options) {
          if (!rejected && options.uri.path.contains('/terminal/rules/')) {
            rejected = true;
            return switch (shape) {
              '1001' => _json({'code': '1001', 'messages': '文案已变化'}),
              '403' => _json({'code': 'denied'}, 403),
              _ => ResponseBody.fromString('<html>会话页</html>', 200),
            };
          }
          return campus.controller(options);
        }),
      );
      expect((await vpn.obtain()).token, 'synthetic-token');
      expect(rejected, isTrue);
      expect(campus.assertions, 1);
      expect(campus.vpnValid, isTrue);
    });
  }

  test('全新控制器会话仅在业务码 200 但 token 未下发时短退避重试', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    var rules = 0;
    final vpn = VpnAuth(
      cas: campus.cas,
      readCredential: () async => _bundle(),
      createHttp: (jar) => _http(jar, (options) {
        if (options.uri.path.contains('/terminal/rules/')) {
          rules++;
          switch (rules) {
            case 1:
            case 2:
            case 3:
            case 4:
            case 5:
              return _json({
                'code': '200',
                'data': {'token': ''},
              });
          }
        }
        return campus.controller(options);
      }),
    );
    expect((await vpn.obtain()).token, 'synthetic-token');
    expect(rules, 6);
    expect(campus.assertions, 1);
  });

  test('CAS 队头超时只取消自身，已排队的第二个认证仍完成', () async {
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final blocked = Completer<void>();
    var reads = 0;
    final cas = CasSession(
      cookies: campus.cookies,
      authenticationTimeout: const Duration(milliseconds: 150),
      readCredential: () async {
        if (++reads == 1) await blocked.future;
        return _bundle();
      },
      createHttp: (jar) => _http(jar, campus.auth),
    );
    final first = cas.authenticate('https://first.test/callback');
    final rejection = expectLater(first, throwsA(isA<PortalNetworkError>()));
    final second = cas.authenticate('https://second.test/callback');
    await rejection;
    expect(await second, contains('second.test'));
    final performed = campus.authRequests;
    blocked.complete();
    await Future<void>.delayed(Duration.zero);
    expect(campus.authRequests, performed);
    expect(reads, 2);
  });

  test('五个错峰403只刷新一次，清旧Cookie并先进入index与角色设置再重放', () async {
    final store = PortalCookieStore(storage: _MemoryStorage());
    final gates = List.generate(5, (_) => Completer<void>());
    final allStarted = Completer<void>();
    final refreshed = Completer<void>();
    final calls = <String, int>{};
    final order = <String>[];
    var firstRequests = 0;
    var authCalls = 0;
    final dio = Dio()
      ..httpClientAdapter = _Adapter((options) async {
        final path = options.uri.path;
        order.add(path);
        if (path == '/landing') {
          return ResponseBody.fromString(
            '已落地',
            200,
            headers: {
              HttpHeaders.setCookieHeader: [
                'JWSESSION=session-$authCalls; Path=/; Secure',
              ],
            },
          );
        }
        if (path == '/index.do') {
          return ResponseBody.fromString('<html>应用首页</html>', 200);
        }
        if (path.endsWith('/setJwCommonAppRole.do')) {
          if (authCalls == 2 && !refreshed.isCompleted) refreshed.complete();
          return _json({'success': true});
        }
        expect(path, '/query.do');
        expect(options.extra['idempotent'], isTrue);
        final id = options.uri.queryParameters['request']!;
        calls[id] = (calls[id] ?? 0) + 1;
        if (calls[id] == 1) {
          firstRequests++;
          if (firstRequests == 5) allStarted.complete();
          await gates[int.parse(id)].future;
          return ResponseBody.fromString(
            '旧会话拒绝',
            403,
            headers: {
              HttpHeaders.setCookieHeader: ['JWSESSION=stale; Path=/; Secure'],
            },
          );
        }
        expect(
          options.headers['Referer'],
          'https://${CampusHosts.jwxt}/index.do',
        );
        expect(
          options.headers[HttpHeaders.cookieHeader],
          contains('JWSESSION=session-2'),
        );
        return _json({'ok': true});
      });
    addTearDown(() => dio.close(force: true));
    final executor = SessionExecutor(
      transport: CampusTransport.authenticated(dio: dio, cookieStore: store),
      cookieStore: store,
      authenticate: (service, {bool forceFreshWebAuthn = false}) async {
        authCalls++;
        if (authCalls == 2) {
          expect(
            await store.openJar().loadForRequest(
              Uri.https(CampusHosts.jwxt, '/'),
            ),
            isEmpty,
          );
        }
        return CasAuthenticationResult(
          landingUri: Uri.https(CampusHosts.jwxt, '/landing'),
        );
      },
    );
    final spec = JwxtAppSpec(
      appId: 'query',
      indexUrl: 'https://${CampusHosts.jwxt}/index.do',
      refererUrl: 'https://${CampusHosts.jwxt}/index.do',
      roleId: 'student',
    );
    final requests = List.generate(
      5,
      (id) => executor.execute(
        spec,
        () => RequestOptions(
          path: 'https://${CampusHosts.jwxt}/query.do?request=$id',
          method: 'POST',
          data: {'query': true},
        ),
      ),
    );
    await allStarted.future;
    gates.first.complete();
    await refreshed.future;
    for (final gate in gates.skip(1)) {
      gate.complete();
    }
    expect(
      (await Future.wait(requests))
          .every((response) => response.statusCode == 200),
      isTrue,
    );
    expect(authCalls, 2);
    expect(calls.values, everyElement(2));
    expect(order.where((path) => path == '/index.do').length, 2);
    final firstBusiness = order.indexOf('/query.do');
    expect(order.take(firstBusiness).last, endsWith('/setJwCommonAppRole.do'));
    expect(
      (await store.openJar().loadForRequest(Uri.https(CampusHosts.jwxt, '/')))
          .single
          .value,
      'session-2',
    );
  });

  test('坏CASTGC的SSO票据落地403后只追加一次完整WebAuthn', () async {
    final store = PortalCookieStore(storage: _MemoryStorage());
    final freshFlags = <bool>[];
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (options) => ResponseBody.fromString(
          'landing',
          freshFlags.length == 1 ? 403 : 200,
        ),
      );
    addTearDown(() => dio.close(force: true));
    final executor = SessionExecutor(
      transport: CampusTransport.authenticated(dio: dio, cookieStore: store),
      cookieStore: store,
      authenticate: (service, {bool forceFreshWebAuthn = false}) async {
        freshFlags.add(forceFreshWebAuthn);
        return CasAuthenticationResult(
          landingUri: Uri.https(CampusHosts.iportal, '/login'),
          ssoReused: !forceFreshWebAuthn,
        );
      },
    );
    expect(
      (await executor.execute(
        const IportalSpec(),
        () => RequestOptions(path: 'https://${CampusHosts.iportal}/data'),
      )).statusCode,
      200,
    );
    expect(freshFlags, [false, true]);
  });

  test('过期Secure Cookie清理持久化，损坏域删除，解绑停止隧道后不留domains', () async {
    final observed = <Map<String, Object?>>[];
    AppLog.recordListenerForTesting = observed.add;
    addTearDown(() => AppLog.recordListenerForTesting = null);
    final storage = _MemoryStorage();
    final uri = Uri.https('cookies.test', '/');
    final expired = SerializableCookie(
      Cookie('expired', 'synthetic')
        ..path = '/'
        ..secure = true
        ..expires = DateTime.utc(2000),
    );
    storage.values['.index'] = jsonEncode([uri.host]);
    storage.values[uri.host] = jsonEncode({
      '/': {'expired': expired.toJson()},
    });
    storage.values['.domains'] = jsonEncode({
      'cookies.test': {
        '/': {'expired': expired.toJson()},
      },
    });
    final store = PortalCookieStore(storage: storage);
    expect(await store.openJar().loadForRequest(uri), isEmpty);
    expect(
      observed.where(
        (record) => record['event'] == 'persisted_cookie.read_failed',
      ),
      isEmpty,
    );
    expect(storage.values[uri.host], isNot(contains('expired')));
    expect(storage.values['.domains'], isNot(contains('expired')));
    storage.values[uri.host] = '{broken';
    final freshStore = PortalCookieStore(storage: storage);
    expect(await freshStore.openJar().loadForRequest(uri), isEmpty);
    expect(storage.values.containsKey(uri.host), isFalse);
    final campus = _Campus(freshStore);
    final order = <String>[];
    var clearingPhase = false;
    late final PortalSession portal;
    late final SessionExecutor executor;
    portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, campus.business),
      readEstablished: () async => {},
      resetNetwork: () async {
        order.add('vpnStopped');
        expect(freshStore.generation, 1);
        expect(portal.debugEstablishedCount, 1);
        expect(executor.debugSessionCount, 1);
        expect(storage.values, isNotEmpty);
      },
      writeEstablished: (_) async {
        if (clearingPhase) order.add('cacheCleared');
      },
    );
    await portal.ensureLoggedIn('https://cookies.test/callback');
    executor = portal.executor;
    clearingPhase = true;
    await portal.clear();
    expect(order, ['vpnStopped', 'cacheCleared']);
    expect(storage.values, isEmpty);
    expect(portal.debugEstablishedCount, 0);
    expect(executor.debugSessionCount, 0);
  });

  for (final ssoReused in [false, true]) {
    test('一卡通落地缺token时清Cookie再认证一次，SSO=$ssoReused', () async {
      final store = PortalCookieStore(storage: _MemoryStorage());
      final flags = <bool>[];
      var businessCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = _Adapter((options) {
          if (options.uri.path == '/landing') {
            return ResponseBody.fromString(
              '一卡通落地',
              200,
              headers: {
                HttpHeaders.setCookieHeader: ['ICARD=dirty; Path=/; Secure'],
              },
            );
          }
          businessCalls++;
          expect(options.headers['synjones-auth'], 'bearer fresh-token');
          return _json({
            'code': 0,
            'data': {'ok': true},
          });
        });
      addTearDown(() => dio.close(force: true));
      final executor = SessionExecutor(
        transport: CampusTransport.authenticated(dio: dio, cookieStore: store),
        cookieStore: store,
        authenticate: (service, {bool forceFreshWebAuthn = false}) async {
          flags.add(forceFreshWebAuthn);
          if (flags.length == 2) {
            expect(
              await store.openJar().loadForRequest(
                Uri.https(CampusHosts.icard, '/'),
              ),
              isEmpty,
            );
          }
          return CasAuthenticationResult(
            landingUri: Uri.https(
              CampusHosts.icard,
              '/landing',
              flags.length == 1 ? null : {'synjones-auth': 'fresh-token'},
            ),
            ssoReused: flags.length == 1 && ssoReused,
          );
        },
      );
      expect(
        (await executor.execute(
          const IcardSpec(),
          () => RequestOptions(
            path: 'https://${CampusHosts.icard}/query',
            method: 'POST',
            data: const {},
          ),
        )).statusCode,
        200,
      );
      expect(flags, [false, ssoReused]);
      expect(businessCalls, 1);
    });
  }

  test('VPN复用坏CASTGC后控制器落地403或登录页时追加完整WebAuthn', () async {
    for (final shape in ['403', 'loginHtml']) {
      final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
      await campus.cookies.openJar().saveFromResponse(
        Uri.parse('${NuistLogin.authserverNormal}/authserver/login'),
        [
          Cookie('CASTGC', 'valid')
            ..path = '/authserver'
            ..secure = true,
        ],
      );
      var callbacks = 0;
      final vpn = VpnAuth(
        cas: campus.cas,
        readCredential: () async => _bundle(),
        createHttp: (jar) => _http(jar, (options) {
          if (options.uri.path.contains('/callback/cas')) {
            callbacks++;
            if (callbacks == 1) {
              return shape == '403'
                  ? ResponseBody.fromString('旧票据拒绝', 403)
                  : ResponseBody.fromString(
                      '<form id="casLoginForm"><input name="execution" value="e1s1"></form>',
                      200,
                    );
            }
          }
          return campus.controller(options);
        }),
      );
      expect((await vpn.obtain()).token, 'synthetic-token');
      expect(callbacks, 2);
      expect(campus.assertions, 1);
      expect(campus.authRequests, 4);
      expect(campus.cookies.generation, 0);
    }
  });

  for (final callbackMode in [false, true]) {
    test('刷新窗口拒绝旧entry晚进Cookie拦截器，callback=$callbackMode', () async {
      final store = PortalCookieStore(storage: _MemoryStorage());
      final entered = Completer<void>();
      final releaseOldRequest = Completer<void>();
      final refreshIndexEntered = Completer<void>();
      final releaseRefreshIndex = Completer<void>();
      var authCalls = 0;
      var examRequests = 0;
      var holdOldRequest = true;
      final host = CampusHosts.jwxt;
      final dio = Dio()
        ..httpClientAdapter = _Adapter((options) async {
          if (options.uri.path == '/landing') {
            return ResponseBody.fromString(
              '落地',
              200,
              headers: {
                HttpHeaders.setCookieHeader: [
                  'JSESSIONID=session-$authCalls; Path=/; Secure',
                ],
              },
            );
          }
          if (options.uri.path == '/wdkb/index' && authCalls == 3) {
            refreshIndexEntered.complete();
            await releaseRefreshIndex.future;
          }
          if (options.uri.path == '/exam/query') {
            examRequests++;
            expect(
              options.extra[PortalCookieStore.hostRevisionsKey],
              isA<Map>(),
            );
            return ResponseBody.fromString(
              '旧应用未登录',
              examRequests == 1 && authCalls == 3 ? 403 : 200,
              headers: {
                HttpHeaders.setCookieHeader: [
                  'JSESSIONID=${authCalls == 3 ? 'anonymous' : 'session-$authCalls'}; Path=/; Secure',
                ],
              },
            );
          }
          return _json({'ok': true});
        });
      addTearDown(() => dio.close(force: true));
      final transport = CampusTransport.authenticated(
        dio: dio,
        cookieStore: store,
      );
      final executor = SessionExecutor(
        transport: transport,
        cookieStore: store,
        authenticate: (service, {bool forceFreshWebAuthn = false}) async {
          authCalls++;
          return CasAuthenticationResult(
            landingUri: Uri.https(host, '/landing'),
          );
        },
      );
      final wdkb = JwxtAppSpec(
        appId: 'wdkb',
        indexUrl: 'https://$host/wdkb/index',
        refererUrl: 'https://$host/wdkb/index',
      );
      final exam = JwxtAppSpec(
        appId: 'exam',
        indexUrl: 'https://$host/exam/index',
        refererUrl: 'https://$host/exam/index',
      );
      final wdkbEntry = await executor.ensureSession(wdkb);
      await executor.ensureSession(exam);
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.uri.path == '/exam/query' && holdOldRequest) {
              holdOldRequest = false;
              entered.complete();
              await releaseOldRequest.future;
            }
            handler.next(options);
          },
        ),
      );
      final old = callbackMode
          ? executor.executeCallback(
              exam,
              () => transport.get(Uri.https(host, '/exam/query')),
            )
          : executor.execute(
              exam,
              () => RequestOptions(path: 'https://$host/exam/query'),
            );
      await entered.future;
      final refreshing = executor.refreshIfNeeded(
        wdkb,
        failedRevision: wdkbEntry.revision,
      );
      await refreshIndexEntered.future;
      releaseOldRequest.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(examRequests, 0);
      expect(
        (await store.openJar().loadForRequest(Uri.https(host, '/')))
            .single
            .value,
        'session-3',
      );
      releaseRefreshIndex.complete();
      await refreshing;
      expect((await old).statusCode, 200);
      expect(examRequests, 1);
      expect(store.hostRevision(host), 1);
      expect(
        (await store.openJar().loadForRequest(Uri.https(host, '/')))
            .single
            .value,
        isNot('anonymous'),
      );
    });
  }

  test('刷新期间不带业务快照的普通响应也不能覆盖建立中的Cookie', () async {
    final store = PortalCookieStore(storage: _MemoryStorage());
    final host = 'refresh.test';
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (options) => ResponseBody.fromString(
          '',
          200,
          headers: {
            HttpHeaders.setCookieHeader: [
              'S=${options.uri.path == '/establish' ? 'ready' : 'anonymous'}; Path=/',
            ],
          },
        ),
      );
    addTearDown(() => dio.close(force: true));
    final transport = CampusTransport.authenticated(
      dio: dio,
      cookieStore: store,
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final refreshing = store.runRefreshing([host], () async {
      await transport.get(Uri.https(host, '/establish'));
      entered.complete();
      await release.future;
    });
    await entered.future;
    await transport.get(Uri.https(host, '/business'));
    expect(
      (await store.openJar().loadForRequest(Uri.https(host, '/'))).single.value,
      'ready',
    );
    release.complete();
    await refreshing;
  });

  test('多域Spec锁住非首个共享域，建立过程中域变更结果不入缓存', () async {
    final store = PortalCookieStore(storage: _MemoryStorage());
    final dio = Dio()..httpClientAdapter = _Adapter((_) => _json({'ok': true}));
    addTearDown(() => dio.close(force: true));
    final executor = SessionExecutor(
      transport: CampusTransport.authenticated(dio: dio, cookieStore: store),
      cookieStore: store,
      authenticate: (service, {bool forceFreshWebAuthn = false}) async =>
          CasAuthenticationResult(landingUri: Uri.parse(service)),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    var secondStarted = false;
    final first = _AuthTestSpec(
      id: 'first',
      cookieHosts: const ['a.test', 'shared.test'],
      buildSession: (transport, landing) async {
        entered.complete();
        await release.future;
        return 'first';
      },
    );
    final second = _AuthTestSpec(
      id: 'second',
      cookieHosts: const ['z.test', 'shared.test'],
      buildSession: (transport, landing) async {
        secondStarted = true;
        return 'second';
      },
    );
    final firstWork = executor.ensureSession(first);
    await entered.future;
    final secondWork = executor.ensureSession(second);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, isFalse);
    release.complete();
    await Future.wait([firstWork, secondWork]);
    expect(secondStarted, isTrue);
    final changed = _AuthTestSpec(
      id: 'changed',
      cookieHosts: const ['main.test', 'secondary.test'],
      buildSession: (transport, landing) async {
        await store.clearHost(Uri.https('secondary.test', '/'));
        return 'invalid';
      },
    );
    await expectLater(
      executor.ensureSession(changed),
      throwsA(
        isA<PortalLoginError>().having(
          (error) => error.code,
          'code',
          'service_cookie_revision_changed',
        ),
      ),
    );
    expect(executor.debugSessionCount, 2);
  });

  test('非幂等首跳403清会话且不重放，下一次独立查询重新建立', () async {
    final store = PortalCookieStore(storage: _MemoryStorage());
    var authCalls = 0;
    var writes = 0;
    var rejected = true;
    final dio = Dio()
      ..httpClientAdapter = _Adapter((options) {
        if (options.uri.path == '/write') {
          writes++;
          return _json({'ok': true}, rejected ? 403 : 200);
        }
        return _json({'ok': true});
      });
    addTearDown(() => dio.close(force: true));
    final executor = SessionExecutor(
      transport: CampusTransport.authenticated(dio: dio, cookieStore: store),
      cookieStore: store,
      authenticate: (service, {bool forceFreshWebAuthn = false}) async {
        authCalls++;
        return CasAuthenticationResult(landingUri: Uri.parse(service));
      },
    );
    const spec = _AuthTestSpec(id: 'write', cookieHosts: ['write.test']);
    await expectLater(
      executor.execute(
        spec,
        () => RequestOptions(path: 'https://write.test/write', method: 'POST'),
        idempotent: false,
      ),
      throwsA(
        isA<PortalLoginError>()
            .having(
              (error) => error.code,
              'code',
              'session_expired_non_idempotent',
            )
            .having((error) => error.context['status_code'], 'status', 403),
      ),
    );
    expect(writes, 1);
    expect(authCalls, 1);
    expect(executor.debugSessionCount, 0);
    rejected = false;
    expect(
      (await executor.execute(
        spec,
        () => RequestOptions(path: 'https://write.test/write'),
      )).statusCode,
      200,
    );
    expect(authCalls, 2);
  });

  test('不信任恢复缓存与12小时过期均不能被执行器内存缓存截胡', () async {
    const service = 'https://jwxt.test/callback';
    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, campus.business),
      readEstablished: () async => {
        service: EstablishedEntry(
          landing: 'https://jwxt.test/home',
          at: DateTime.now(),
          restored: true,
        ),
      },
    );
    expect(await portal.ensureLoggedIn(service), 'https://jwxt.test/home');
    expect(portal.executor.debugSessionCount, 0);
    await portal.ensureLoggedIn(service, trustRestored: false);
    expect(campus.callbacks['jwxt.test'], 1);
    final expiredCampus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final expired = PortalSession.forTesting(
      cas: expiredCampus.cas,
      createHttp: (jar) => _http(jar, expiredCampus.business),
      readEstablished: () async => {
        service: EstablishedEntry(
          landing: 'https://jwxt.test/home',
          at: DateTime.utc(2000),
        ),
      },
    );
    expired.executor.restoreSession(
      const _LandingTestSpec(service),
      Response<dynamic>(
        requestOptions: RequestOptions(path: 'https://jwxt.test/home'),
        statusCode: 200,
      ),
    );
    await expired.ensureLoggedIn(service);
    expect(expiredCampus.callbacks['jwxt.test'], 1);
  });

  test('完整WebAuthn等待旧失败任务后仍独立认证，包含Portal门面与执行器', () async {
    final store = PortalCookieStore(storage: _MemoryStorage());
    final dio = Dio()..httpClientAdapter = _Adapter((_) => _json({'ok': true}));
    addTearDown(() => dio.close(force: true));
    final flags = <bool>[];
    final entered = Completer<void>();
    final release = Completer<void>();
    var builds = 0;
    final executor = SessionExecutor(
      transport: CampusTransport.authenticated(dio: dio, cookieStore: store),
      cookieStore: store,
      authenticate: (service, {bool forceFreshWebAuthn = false}) async {
        flags.add(forceFreshWebAuthn);
        return CasAuthenticationResult(landingUri: Uri.parse(service));
      },
    );
    final spec = _AuthTestSpec(
      id: 'fresh',
      cookieHosts: const ['fresh.test'],
      buildSession: (transport, landing) async {
        if (++builds == 1) {
          entered.complete();
          await release.future;
          throw const PortalLoginError('旧登录失败', code: 'old_failed');
        }
        return 'fresh';
      },
    );
    final old = executor.ensureSession(spec);
    final oldFailure = expectLater(old, throwsA(isA<PortalLoginError>()));
    await entered.future;
    final fresh = executor.ensureSession(spec, forceFreshWebAuthn: true);
    release.complete();
    await oldFailure;
    expect((await fresh).session, 'fresh');
    expect(flags, [false, true]);

    final campus = _Campus(PortalCookieStore(storage: _MemoryStorage()));
    final callbackEntered = Completer<void>();
    final callbackRelease = Completer<void>();
    var callbacks = 0;
    final portal = PortalSession.forTesting(
      cas: campus.cas,
      createHttp: (jar) => _http(jar, (options) async {
        if (options.uri.path == '/callback' && ++callbacks == 1) {
          callbackEntered.complete();
          await callbackRelease.future;
          return ResponseBody.fromString('失败', 403);
        }
        return campus.business(options);
      }),
    );
    final plain = portal.ensureLoggedIn('https://jwxt.test/callback');
    final plainFailure = expectLater(plain, throwsA(isA<PortalLoginError>()));
    await callbackEntered.future;
    final verifying = portal.verifyCredential(
      service: 'https://jwxt.test/callback',
    );
    callbackRelease.complete();
    await plainFailure;
    expect(await verifying, 'https://jwxt.test/home');
    expect(campus.assertions, 2);
  });

  test('CAS队头Cookie写入超时后先清理再放行第二个认证', () async {
    final storage = _BlockingCookieStorage();
    final campus = _Campus(PortalCookieStore(storage: storage));
    final cas = CasSession(
      cookies: campus.cookies,
      readCredential: () async => _bundle(),
      authenticationTimeout: const Duration(milliseconds: 200),
      createHttp: (jar) => _http(jar, (options) {
        final service = options.uri.queryParameters['service'];
        if (options.uri.path == NuistLogin.loginPath &&
            service == 'https://first.test/callback') {
          return _redirect(
            'https://first.test/callback?ticket=stale',
            cookies: ['CASTGC=stale; Path=/authserver; Secure'],
          );
        }
        if (service == 'https://second.test/callback' &&
            '${options.headers[HttpHeaders.cookieHeader]}'.contains(
              'CASTGC=stale',
            )) {
          return _redirect('https://second.test/callback?ticket=poisoned');
        }
        return campus.auth(options);
      }),
    );
    final first = cas.authenticate('https://first.test/callback');
    final failed = expectLater(first, throwsA(isA<PortalNetworkError>()));
    await storage.entered.future;
    final second = cas.authenticate('https://second.test/callback');
    await failed;
    storage.release.complete();
    expect(await second, contains('synthetic-ticket'));
    expect(
      (await campus.cookies.openJar().loadForRequest(
        Uri.parse('${NuistLogin.authserverNormal}/authserver/login'),
      )).singleWhere((cookie) => cookie.name == 'CASTGC').value,
      'valid',
    );
    expect(campus.assertions, 1);
  });
  test('损坏host恢复同时删除共享domains，不能再次读到内存域Cookie', () async {
    final storage = _MemoryStorage();
    final host = Uri.https('broken.test', '/');
    final seeded = PortalCookieStore(storage: storage);
    await seeded.openJar().saveFromResponse(host, [
      Cookie('host', 'ok')..path = '/',
      Cookie('shared', 'dirty')
        ..domain = '.broken.test'
        ..path = '/',
    ]);
    storage.values[host.host] = '{broken';
    final store = PortalCookieStore(storage: storage);
    expect(await store.openJar().loadForRequest(host), isEmpty);
    expect(storage.values.containsKey('.domains'), isFalse);
    expect(
      await store.openJar().loadForRequest(Uri.https('sub.broken.test', '/')),
      isEmpty,
    );
  });

  test('一卡通200与图书馆0明确成功码不因消息文本误判会话过期', () {
    Response<dynamic> response(Map<String, Object?> body) => Response<dynamic>(
      requestOptions: RequestOptions(path: 'https://success.test/data'),
      statusCode: 200,
      data: body,
    );
    expect(
      const IcardSpec().isSubsystemExpired(
        response({'code': '200', 'msg': 'token认证成功，登录正常'}),
      ),
      isFalse,
    );
    expect(
      const LibrarySpec().isSubsystemExpired(
        response({'code': 0, 'message': '已完成未登录用户筛选'}),
      ),
      isFalse,
    );
  });
}
