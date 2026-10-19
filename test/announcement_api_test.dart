// 公告接口：条件头、304、响应头读取。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/api_endpoints.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(
  Object body, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
    ...headers,
  },
);

(AnnouncementApi, FakeAdapter) build(ResponseBody Function(RequestOptions) h) {
  final adapter = FakeAdapter(h);
  final dio = Dio()..httpClientAdapter = adapter;
  return (AnnouncementApi(dio: dio), adapter);
}

void main() {
  test('200 解析并读出 etag / last-modified，无参数时不带条件头', () async {
    final (api, adapter) = build(
      (_) => json(
        {
          'version': 1,
          'items': [
            {'id': '1', 'title': 't'},
          ],
        },
        headers: {
          'etag': ['"v1"'],
          'last-modified': ['Wed, 01 Jan 2026 00:00:00 GMT'],
        },
      ),
    );
    final r = await api.fetch();
    expect(r.notModified, isFalse);
    expect(r.items, hasLength(1));
    expect(r.etag, '"v1"');
    expect(r.lastModified, 'Wed, 01 Jan 2026 00:00:00 GMT');
    final req = adapter.requests.single;
    expect(req.uri.toString(), kAnnouncementEndpoint);
    expect(req.method, 'GET');
    final keys = req.headers.keys.map((k) => k.toLowerCase()).toSet();
    expect(keys.contains('if-none-match'), isFalse);
    expect(keys.contains('if-modified-since'), isFalse);
    expect(keys.contains('authorization'), isFalse);
    expect(keys.contains('cookie'), isFalse);
  });

  test('有校验值时发条件头；304 返回 notModified 且不抛', () async {
    final (api, adapter) = build((_) => ResponseBody.fromString('', 304));
    final r = await api.fetch(etag: '"v1"', lastModified: 'LM');
    expect(r.notModified, isTrue);
    expect(r.items, isNull);
    final req = adapter.requests.single;
    expect(req.headers['If-None-Match'], '"v1"');
    expect(req.headers['If-Modified-Since'], 'LM');
  });

  test('items 不是数组抛 FormatException', () async {
    final (api, _) = build((_) => json({'items': 'x'}));
    expect(api.fetch(), throwsFormatException);
  });

  test('5xx 抛出', () async {
    final (api, _) = build((_) => ResponseBody.fromString('', 500));
    expect(api.fetch(), throwsA(isA<DioException>()));
  });
}
