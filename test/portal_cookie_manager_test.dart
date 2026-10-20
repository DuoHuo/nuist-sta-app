import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/auth/portal_cookie_manager.dart';
import 'package:nuist_sta_app/core/auth/portal_http.dart';

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

  for (final status in PortalHttp.redirectCodes) {
    test('HTTP $status 跨域跳转不覆盖另一域的同名会话 Cookie', () async {
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
    });
  }

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
}
