import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/nuist_login.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_manager.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_store.dart';
import 'package:nuist_sta_app/core/auth/portal_exceptions.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';
import 'package:nuist_sta_app/core/auth/safe_message.dart';
import 'package:nuist_sta_app/core/auth/student_id_mask.dart';
import 'package:nuist_sta_app/core/logging/diagnostic_error.dart';

class _CookieAdapter implements HttpClientAdapter {
  _CookieAdapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) {}
}

class _MemoryCookieStorage implements Storage {
  final values = <String, String>{};
  int writes = 0;
  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> deleteAll(List<String> keys) async {
    for (final key in keys) {
      values.remove(key);
    }
  }
}

Dio _client(
  CookieJar jar,
  ResponseBody Function(RequestOptions options) respond,
) {
  final client = Dio()
    ..httpClientAdapter = _CookieAdapter(respond)
    ..interceptors.add(PortalCookieManager(jar));
  addTearDown(() => client.close(force: true));
  return client;
}

Future<Map<String, String>> _cookies(CookieJar jar, Uri uri) async => {
  for (final cookie in await jar.loadForRequest(uri)) cookie.name: cookie.value,
};

void main() {
  final auth = Uri.parse('https://auth.campus.test/auth/login');
  final business = Uri.parse('https://business.campus.test/app/index');

  test('各重定向状态码跨域跳转均不覆盖另一域的同名会话 Cookie', () async {
    for (final status in PortalHttp.redirectCodes) {
      for (final (source, target) in [(auth, business), (business, auth)]) {
        final jar = CookieJar();
        await jar.saveFromResponse(target, [
          Cookie('JSESSIONID', 'target-session')..path = '/',
        ]);
        final client = _client(
          jar,
          (_) => ResponseBody.fromString(
            '',
            status,
            headers: {
              HttpHeaders.locationHeader: [target.toString()],
              HttpHeaders.setCookieHeader: [
                'JSESSIONID=source-session; Path=/',
              ],
            },
          ),
        );

        final response = await client.getUri<dynamic>(
          source,
          options: PortalHttp.options(),
        );

        expect(await _cookies(jar, source), {'JSESSIONID': 'source-session'});
        expect(await _cookies(jar, target), {'JSESSIONID': 'target-session'});
        expect(response.statusCode, status);
        expect(response.headers.value(HttpHeaders.locationHeader), '$target');
        expect(response.headers[HttpHeaders.setCookieHeader], [
          'JSESSIONID=source-session; Path=/',
        ]);
      }
    }
  });

  test('同域跳转不把默认 Path 的 Cookie 复制到目标路径', () async {
    final jar = CookieJar();
    final target = auth.replace(path: '/app/index');
    final client = _client(
      jar,
      (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          HttpHeaders.locationHeader: [target.path],
          HttpHeaders.setCookieHeader: ['JSESSIONID=auth-session'],
        },
      ),
    );

    await client.getUri<dynamic>(auth, options: PortalHttp.options());

    expect(await _cookies(jar, auth), {'JSESSIONID': 'auth-session'});
    expect(await _cookies(jar, target), isEmpty);
  });

  test('显式 Domain 仍按作用域共享，保留多条 Cookie 和 Expires 解析', () async {
    final jar = CookieJar();
    final client = _client(
      jar,
      (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          HttpHeaders.locationHeader: ['$business'],
          HttpHeaders.setCookieHeader: [
            'shared=domain-session; Domain=campus.test; Path=/; '
                'Expires=Wed, 09 Jun 2038 10:18:14 GMT; HttpOnly; Secure',
            'JSESSIONID=auth-session; Path=/; HttpOnly',
          ],
        },
      ),
    );

    await client.getUri<dynamic>(auth, options: PortalHttp.options());

    expect(await _cookies(jar, auth), {
      'shared': 'domain-session',
      'JSESSIONID': 'auth-session',
    });
    expect(await _cookies(jar, business), {'shared': 'domain-session'});
    expect(await _cookies(jar, Uri.parse('https://unrelated.test/')), isEmpty);
    final shared = (await jar.loadForRequest(business)).single;
    expect(shared.secure, isTrue);
    expect(shared.httpOnly, isTrue);
    expect(shared.expires, DateTime.utc(2038, 6, 9, 10, 18, 14));
  });

  test('进入 Dio 错误分支的重定向也只保存响应来源的 Cookie', () async {
    final jar = CookieJar();
    final client = _client(
      jar,
      (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          HttpHeaders.locationHeader: ['$business'],
          HttpHeaders.setCookieHeader: ['JSESSIONID=auth-session; Path=/'],
        },
      ),
    );

    await expectLater(
      client.getUri<dynamic>(
        auth,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status == 200,
        ),
      ),
      throwsA(isA<DioException>()),
    );

    expect(await _cookies(jar, auth), {'JSESSIONID': 'auth-session'});
    expect(await _cookies(jar, business), isEmpty);
  });

  test('多跳登录每一跳及时保存 Cookie，下一跳只带匹配的会话', () async {
    final jar = CookieJar();
    final callback = business.replace(path: '/callback');
    final visited = <Uri>[];
    final client = _client(jar, (options) {
      visited.add(options.uri);
      if (options.uri == auth) {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            HttpHeaders.locationHeader: ['$callback'],
            HttpHeaders.setCookieHeader: [
              'JSESSIONID=auth-session; Path=/',
              'CASTGC=synthetic-ticket; Path=/',
            ],
          },
        );
      }
      if (options.uri == callback) {
        expect(options.headers[HttpHeaders.cookieHeader], isNull);
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            HttpHeaders.locationHeader: [business.path],
            HttpHeaders.setCookieHeader: [
              'JSESSIONID=business-session; Path=/',
            ],
          },
        );
      }
      expect(options.uri, business);
      expect(
        options.headers[HttpHeaders.cookieHeader],
        'JSESSIONID=business-session',
      );
      return ResponseBody.fromString('已登录', 200);
    });
    final http = PortalHttp(client);

    final response = await http.followRedirects(await http.get(auth));

    expect(visited, [auth, callback, business]);
    expect(response.data, '已登录');
    expect(response.realUri, business);
    expect(await _cookies(jar, auth), {
      'JSESSIONID': 'auth-session',
      'CASTGC': 'synthetic-ticket',
    });
    expect(await _cookies(jar, business), {'JSESSIONID': 'business-session'});
  });

  for (final status in [200, 302]) {
    test('HTTP $status 响应里 SameSite=None 缺 Secure 的 Cookie 被修正后仍入库', () async {
      final jar = CookieJar();
      final client = _client(
        jar,
        (_) => ResponseBody.fromString(
          '',
          status,
          headers: {
            HttpHeaders.locationHeader: ['$business'],
            HttpHeaders.setCookieHeader: [
              'JSESSIONID=auth-session; Path=/; HttpOnly',
              'legacy=1; Path=/; HttpOnly; SameSite=None',
            ],
          },
        ),
      );

      final response = await client.getUri<dynamic>(
        auth,
        options: PortalHttp.options(),
      );

      expect(response.statusCode, status);
      final cookies = await jar.loadForRequest(auth);
      expect(
        {for (final cookie in cookies) cookie.name: cookie.value},
        {'JSESSIONID': 'auth-session', 'legacy': '1'},
      );
      // 去掉非法属性后按普通 Cookie 保存，原生客户端不区分 SameSite。
      expect(cookies.firstWhere((c) => c.name == 'legacy').sameSite, isNull);
    });
  }

  test('带 Secure 的 SameSite=None 原样保留', () async {
    final jar = CookieJar();
    final client = _client(
      jar,
      (_) => ResponseBody.fromString(
        '',
        200,
        headers: {
          HttpHeaders.setCookieHeader: [
            'strict=1; Path=/; HttpOnly; SameSite=None; Secure',
          ],
        },
      ),
    );

    await client.getUri<dynamic>(auth, options: PortalHttp.options());

    final cookie = (await jar.loadForRequest(auth)).single;
    expect(cookie.sameSite, SameSite.none);
    expect(cookie.secure, isTrue);
  });

  test('无法解析的 Cookie 单条跳过，同响应其它 Cookie 不受影响', () async {
    final jar = CookieJar();
    final client = _client(
      jar,
      (_) => ResponseBody.fromString(
        '',
        200,
        headers: {
          HttpHeaders.setCookieHeader: [
            'good=1; Path=/; HttpOnly',
            'bad-without-equals; Path=/',
          ],
        },
      ),
    );

    final response = await client.getUri<dynamic>(
      auth,
      options: PortalHttp.options(),
    );

    expect(response.statusCode, 200);
    expect(await _cookies(jar, auth), {'good': '1'});
  });

  test('一条 header 合并多个 Cookie 时，只修正非法的那条', () async {
    final jar = CookieJar();
    final client = _client(
      jar,
      (_) => ResponseBody.fromString(
        '',
        200,
        headers: {
          HttpHeaders.setCookieHeader: [
            'good=1; Path=/, bad=2; Path=/; SameSite=None',
          ],
        },
      ),
    );

    await client.getUri<dynamic>(auth, options: PortalHttp.options());

    final cookies = await jar.loadForRequest(auth);
    expect(
      {for (final cookie in cookies) cookie.name: cookie.value},
      {'good': '1', 'bad': '2'},
    );
    expect(cookies.firstWhere((c) => c.name == 'bad').sameSite, isNull);
  });

  test('已取消响应的onResponse与saveCookies都不能写回CAS Cookie', () async {
    final jar = CookieJar();
    final manager = PortalCookieManager(jar);
    final cancel = CancelToken()..cancel('认证已超时');
    final response = Response<dynamic>(
      requestOptions: RequestOptions(
        path: 'https://auth.test/authserver/login',
        cancelToken: cancel,
      ),
      statusCode: 200,
      headers: Headers.fromMap({
        HttpHeaders.setCookieHeader: ['CASTGC=stale; Path=/authserver'],
      }),
    );
    await manager.onResponse(response, ResponseInterceptorHandler());
    await manager.saveCookies(response);
    expect(
      await jar.loadForRequest(Uri.https('auth.test', '/authserver/login')),
      isEmpty,
    );
  });

  test('store模式合并Cookie只受保护解析一次，Expires逗号与坏项均不影响合法Cookie', () async {
    final storage = _MemoryCookieStorage();
    final store = PortalCookieStore(storage: storage);
    final jar = store.openJar();
    final client = _client(
      jar,
      (_) => ResponseBody.fromString(
        '',
        200,
        headers: {
          HttpHeaders.setCookieHeader: [
            'a=1; Expires=Wed, 09 Jun 2038 10:18:14 GMT, b=2; Path=/, =invalid; Path=/',
          ],
        },
      ),
    );
    final managerIndex = client.interceptors.indexWhere(
      (interceptor) => interceptor is PortalCookieManager,
    );
    client.interceptors[managerIndex] = PortalCookieManager(jar, store: store);
    await client.getUri<dynamic>(auth, options: PortalHttp.options());
    final cookies = await jar.loadForRequest(auth);
    expect(
      {for (final cookie in cookies) cookie.name: cookie.value},
      {'a': '1', 'b': '2'},
    );
    expect(
      cookies.singleWhere((cookie) => cookie.name == 'a').expires,
      DateTime.utc(2038, 6, 9, 10, 18, 14),
    );
  });

  test('没有合法SetCookie时store模式直接返回，不调用持久化写入', () async {
    final storage = _MemoryCookieStorage();
    final store = PortalCookieStore(storage: storage);
    final manager = PortalCookieManager(store.openJar(), store: store);
    await manager.saveCookies(
      Response<dynamic>(
        requestOptions: RequestOptions(path: 'https://empty.test/'),
        statusCode: 200,
        headers: Headers.fromMap({
          HttpHeaders.setCookieHeader: ['=invalid; Path=/'],
        }),
      ),
    );
    expect(storage.writes, 0);
    expect(storage.values, isEmpty);
  });

  test('PortalHttp手动重定向终点503保留诊断原因，不泄漏裸DioException', () async {
    final jar = CookieJar();
    final http = PortalHttp(
      _client(
        jar,
        (options) => options.uri.path == '/start'
            ? ResponseBody.fromString(
                '',
                302,
                headers: {
                  HttpHeaders.locationHeader: ['/failed'],
                },
              )
            : ResponseBody.fromString('维护中', 503),
      ),
    );
    final response = await http.get(Uri.https('redirect.test', '/start'));
    await expectLater(
      http.followRedirects(response),
      throwsA(
        isA<DiagnosticException>()
            .having((error) => error.context['status_code'], 'status', 503)
            .having((error) => error.cause, 'cause', isA<DioException>())
            .having((error) => error.causeStackTrace, 'stack', isNotNull),
      ),
    );
  });

  test('学号脱敏 maskStudentId 覆盖 12 位、10 位、短串与空串', () {
    expect(maskStudentId('202512340001'), '2025******01');
    expect(maskStudentId('2023123401'), '2023****01');
    expect(maskStudentId('123456'), '1*****');
    expect(maskStudentId('1'), '1');
    expect(maskStudentId(''), '');
  });

  group('认证诊断与安全错误文案', () {
    const forbidden = [
      '{',
      '<html',
      '<!DOCTYPE',
      'JSESSIONID',
      'CASTGC',
      'Set-Cookie',
    ];

    void expectSafe(Object? data) {
      try {
        NuistLogin.parseStartAssertion(data, statusCode: 502);
        fail('should throw');
      } on PortalException catch (e) {
        final msg = e.message;
        for (final f in forbidden) {
          expect(
            msg.toLowerCase().contains(f.toLowerCase()),
            isFalse,
            reason: 'leaked "$f": $msg',
          );
        }
        expect(msg.length, lessThanOrEqualTo(100));
      }
    }

    test('响应外壳错误与缺少 request 有不同原因码', () {
      expect(
        () => NuistLogin.parseStartAssertion([], statusCode: 200),
        throwsA(
          isA<PortalLoginError>()
              .having((e) => e.code, 'code', 'assertion_response_not_object')
              .having((e) => e.stage, 'stage', 'cas.asserting'),
        ),
      );
      expect(
        () =>
            NuistLogin.parseStartAssertion({'success': true}, statusCode: 200),
        throwsA(
          isA<PortalLoginError>()
              .having((e) => e.code, 'code', 'assertion_request_missing')
              .having((e) => e.context['status_code'], 'status', 200),
        ),
      );
    });

    test('HTTP错误保留状态、Dio原因与原始栈，不误报门户登录失败', () async {
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      final options = RequestOptions(path: 'https://campus.test/service');
      final originalStack = StackTrace.fromString(
        '#0 syntheticTransport (transport.dart:4:2)',
      );
      final original = DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(requestOptions: options, statusCode: 503),
        stackTrace: originalStack,
      );
      try {
        await PortalHttp(dio).send(() => Future.error(original, originalStack));
        fail('应抛出服务响应错误');
      } catch (error, stackTrace) {
        expect(error, isA<DiagnosticException>());
        final diagnostic = error as DiagnosticException;
        expect(diagnostic.code, 'http_status_rejected');
        expect(diagnostic.context['status_code'], 503);
        expect(diagnostic.cause, same(original));
        expect(diagnostic.causeStackTrace, same(originalStack));
        expect(stackTrace.toString(), originalStack.toString());
      }
    });

    test('Dio包裹的门户异常使用原始栈重新抛出', () async {
      final dio = Dio();
      addTearDown(() => dio.close(force: true));
      const original = PortalCredentialError(
        '合成凭据已失效',
        code: 'credential_not_allowed',
        stage: 'cas.signing',
      );
      final originalStack = StackTrace.fromString(
        '#0 syntheticSign (signer.dart:8:2)',
      );
      final wrapped = DioException(
        requestOptions: RequestOptions(path: 'https://campus.test/service'),
        error: original,
        stackTrace: originalStack,
      );
      try {
        await PortalHttp(dio).send(() => Future.error(wrapped));
        fail('应保留凭据错误');
      } catch (error, stackTrace) {
        expect(error, same(original));
        expect(stackTrace.toString(), originalStack.toString());
      }
    });

    test('startAssertion 异常 HTML/JSON/敏感文案响应均不泄漏原始响应', () {
      for (final fixture in [
        'test/fixtures/timetable/gateway_502.html',
        'test/fixtures/timetable/login_redirect_mock.html',
      ]) {
        expectSafe(File(fixture).readAsStringSync());
      }
      const html = '<!DOCTYPE html><html><body>502 Bad Gateway</body></html>';
      for (final payload in [
        {
          'code': 1,
          'datas': {'x': 'JSESSIONID=abc'},
        },
        {
          'success': false,
          'data': {'CASTGC': 'TGT-1'},
        },
        '{"foo":"bar","Set-Cookie":"JSESSIONID=1"}',
        {'success': false, 'message': html},
        {'message': html},
        {'success': false, 'message': 'Set-Cookie: CASTGC=TGT-x'},
        {'message': '错' * 150},
        {
          'success': false,
          'message': {'nested': 1},
        },
      ]) {
        expectSafe(payload);
      }
    });

    test('startAssertion 保留纯文本短提示，safeServerMessage 过滤非纯文本与敏感串', () {
      expect(
        () => NuistLogin.parseStartAssertion({'message': '未查询到设备信息'}),
        throwsA(
          isA<PortalCredentialError>().having(
            (e) => e.message,
            'message',
            startsWith('未查询到设备信息'),
          ),
        ),
      );
      expect(
        () => NuistLogin.parseStartAssertion({
          'success': false,
          'message': '<b>x</b>',
        }),
        throwsA(
          isA<PortalLoginError>().having(
            (e) => e.message,
            'message',
            kLoginFailedText,
          ),
        ),
      );
      expect(safeServerMessage('设备不存在'), '设备不存在');
      expect(safeServerMessage(42), kLoginFailedText);
      expect(safeServerMessage('{"a":1}'), kLoginFailedText);
      expect(safeServerMessage('JSESSIONID=1'), kLoginFailedText);
      expect(prefixedServerMessage('前缀：', '<html>'), kLoginFailedText);
    });
  });
}
