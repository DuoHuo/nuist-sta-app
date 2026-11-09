import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/config/api_endpoints.dart';
import 'package:nuist_sta_app/core/logging/app_log.dart';
import 'package:nuist_sta_app/core/network/client_metadata.dart';
import 'package:nuist_sta_app/core/network/owned_api_client.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_export_api.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_export_models.dart';
import 'package:nuist_sta_app/shell/announcement/announcement_api.dart';
import 'package:nuist_sta_app/shell/profile/about/contributor_api.dart';
import 'package:nuist_sta_app/shell/profile/about/contributor_avatar.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) => closed = true;
}

class _ControlledAvatarLoader extends ContributorAvatarLoader {
  final requests = <String, Completer<Uint8List?>>{};

  @override
  Future<Uint8List?> load(String url) =>
      requests.putIfAbsent(url, Completer<Uint8List?>.new).future;
}

const _metadata = ClientMetadata(
  platform: 'android',
  appPackage: 'org.example.nuist',
  appChannel: 'ci',
  appVersion: '0.2.8+test',
  appVersionCode: 2800,
  clientId: 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd',
  androidVersion: '16',
  androidSdk: 36,
  romName: 'OriginOS',
  romVersion: '5',
);

const _snapshot = TimetableExportSnapshot(
  payload: {'name': '测试课表', 'items': <Object>[]},
  courseCount: 0,
  examCount: 0,
  otherCount: 0,
  skippedItems: [],
  warnings: [],
);

ResponseBody _json(Object value) => ResponseBody.fromString(
  jsonEncode(value),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

(Dio, _Adapter) _client(
  ResponseBody Function(RequestOptions) respond, {
  BaseOptions? options,
}) {
  final adapter = _Adapter(respond);
  final dio = createOwnedApiDio(
    options: options,
    metadataProvider: () async => _metadata,
  )..httpClientAdapter = adapter;
  addTearDown(() => dio.close(force: true));
  return (dio, adapter);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('公告、贡献者、分享与同域头像均通过相同元数据协议', () async {
    final (dio, adapter) = _client((request) {
      if (request.path.endsWith('/announcement')) return _json({'items': []});
      if (request.path.endsWith('/contributors')) {
        return _json({'code': 0, 'data': []});
      }
      if (request.path.endsWith('/wakeup-share')) {
        return _json({
          'code': 0,
          'data': {'shareText': '测试口令'},
        });
      }
      return ResponseBody.fromBytes([1, 2, 3], 200);
    });
    final announcements = AnnouncementApi(dio: dio);
    final contributors = ContributorApi(dio: dio);
    final exports = TimetableExportApi(dio: dio);
    final avatars = ContributorAvatarLoader(dio: dio);
    await announcements.fetch(etag: '"existing"');
    await contributors.fetch();
    await exports.generate(_snapshot);
    expect(await avatars.load('$kContributorsEndpoint/avatars/sample'), [
      1,
      2,
      3,
    ]);
    expect(adapter.requests, hasLength(4));
    for (final request in adapter.requests) {
      for (final entry in _metadata.headers.entries) {
        expect(request.headers[entry.key], entry.value);
      }
      expect(request.followRedirects, isTrue);
      expect(
        request.headers.keys.map((e) => e.toLowerCase()),
        isNot(contains('cookie')),
      );
    }
    expect(adapter.requests.first.headers['If-None-Match'], '"existing"');
    expect(adapter.requests[2].data, _snapshot.payload);
    expect(adapter.requests[2].method, 'POST');
    announcements.close();
    contributors.close();
    exports.close();
    avatars.close();
    expect(adapter.closed, isFalse);
  });

  test('外域、假后缀域、HTTP、非标准端口与带用户信息的地址被拒绝', () async {
    final (dio, adapter) = _client((_) => _json({}));
    final origin = Uri.parse(kApiBase);
    for (final url in [
      'https://example.com/api',
      'https://${origin.host}.example.com/api',
      'http://${origin.host}/api',
      'https://${origin.host}:444/api',
      'https://user@${origin.host}/api',
    ]) {
      await expectLater(dio.get<Object?>(url), throwsA(isA<DioException>()));
    }
    expect(adapter.requests, isEmpty);
  });

  test('添加元数据时保留调用方的普通扩展头和其他请求头', () async {
    final (dio, adapter) = _client((_) => _json({}));
    const headers = {
      'X-App-Feature': 'test-feature',
      'x-device-feature': 'test-device-feature',
      'Authorization': 'test-credential',
      'Cookie': 'test-session',
      'traceparent': 'test-trace',
      'tracestate': 'test-state',
    };
    await dio.get<Object?>(
      kAnnouncementEndpoint,
      options: Options(headers: headers),
    );
    final request = adapter.requests.single;
    expect(request.headers['X-Client-ID'], _metadata.clientId);
    expect(request.headers['X-App-Channel'], 'ci');
    for (final entry in headers.entries) {
      expect(request.headers[entry.key], entry.value);
    }
  });

  test('保留客户端默认的重定向设置', () async {
    final (dio, adapter) = _client(
      (_) => _json({}),
      options: BaseOptions(followRedirects: false, maxRedirects: 2),
    );
    await dio.get<Object?>(kAnnouncementEndpoint);
    expect(adapter.requests.single.followRedirects, isFalse);
    expect(adapter.requests.single.maxRedirects, 2);
  });

  test('单次请求可以开启或关闭重定向并覆盖跳转次数', () async {
    final (dio, adapter) = _client(
      (_) => _json({}),
      options: BaseOptions(followRedirects: false, maxRedirects: 2),
    );
    await dio.get<Object?>(
      kAnnouncementEndpoint,
      options: Options(followRedirects: true, maxRedirects: 4),
    );
    await dio.get<Object?>(
      kAnnouncementEndpoint,
      options: Options(followRedirects: false, maxRedirects: 1),
    );
    expect(adapter.requests.first.followRedirects, isTrue);
    expect(adapter.requests.first.maxRedirects, 4);
    expect(adapter.requests.last.followRedirects, isFalse);
    expect(adapter.requests.last.maxRedirects, 1);
  });

  test('元数据加载失败不阻断业务，也不把异常正文写入日志', () async {
    final records = <Map<String, Object?>>[];
    await AppLog.resetForTesting();
    AppLog.recordListenerForTesting = records.add;
    addTearDown(AppLog.resetForTesting);
    final adapter = _Adapter((_) => _json({}));
    final dio = createOwnedApiDio(
      metadataProvider: () async {
        throw StateError('private-header-${_metadata.clientId}');
      },
    )..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    await dio.get<Object?>(kAnnouncementEndpoint);
    expect(adapter.requests.single.headers['X-Client-Metadata-Version'], '1');
    expect(adapter.requests.single.headers.containsKey('X-Client-ID'), isFalse);
    expect(jsonEncode(records), isNot(contains(_metadata.clientId!)));
    expect(jsonEncode(records), isNot(contains('private-header')));
  });

  test('头像请求合并、缓存到期重取且失败不缓存', () async {
    var now = DateTime(2026, 11, 9);
    var fail = false;
    final (dio, adapter) = _client(
      (_) => fail
          ? ResponseBody.fromString('', 503)
          : ResponseBody.fromBytes([1], 200),
    );
    final avatars = ContributorAvatarLoader(dio: dio, now: () => now);
    const url = '$kContributorsEndpoint/avatars/sample';
    await Future.wait([avatars.load(url), avatars.load(url)]);
    expect(adapter.requests, hasLength(1));
    await avatars.load(url);
    expect(adapter.requests, hasLength(1));
    now = now.add(const Duration(hours: 1));
    fail = true;
    expect(await avatars.load(url), isNull);
    fail = false;
    expect(await avatars.load(url), [1]);
    expect(adapter.requests, hasLength(3));
    expect(await avatars.load('https://example.com/a.png'), isNull);
    expect(adapter.requests, hasLength(3));
  });

  test('WakeUp POST 失败只请求一次，已取消请求不发出', () async {
    final (dio, adapter) = _client((_) => ResponseBody.fromString('', 503));
    final api = TimetableExportApi(dio: dio);
    await expectLater(
      api.generate(_snapshot),
      throwsA(isA<TimetableExportException>()),
    );
    expect(adapter.requests, hasLength(1));
    final cancel = CancelToken()..cancel();
    await expectLater(
      api.generate(_snapshot, cancelToken: cancel),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('关闭头像加载器取消自己的在途请求，不关闭借用客户端或回写缓存', () async {
    final started = Completer<void>();
    final body = StreamController<Uint8List>();
    final (dio, adapter) = _client((_) {
      started.complete();
      return ResponseBody(body.stream, 200);
    });
    final avatars = ContributorAvatarLoader(dio: dio);
    const url = '$kContributorsEndpoint/avatars/pending';
    final pending = avatars.load(url);
    await started.future;
    avatars.close();
    body.add(Uint8List.fromList([1, 2, 3]));
    unawaited(body.close());
    expect(await pending, isNull);
    expect(await avatars.load(url), isNull);
    expect(adapter.closed, isFalse);
    expect(adapter.requests, hasLength(1));
  });

  test('图片解码失败驱逐后可以重新获取；超大响应不缓存', () async {
    var oversized = false;
    final (dio, adapter) = _client(
      (_) => ResponseBody.fromBytes(
        oversized ? Uint8List(2 * 1024 * 1024 + 1) : [1, 2, 3],
        200,
      ),
    );
    final avatars = ContributorAvatarLoader(dio: dio);
    const url = '$kContributorsEndpoint/avatars/decode-failure';
    await avatars.load(url);
    avatars.evict(url);
    await avatars.load(url);
    expect(adapter.requests, hasLength(2));
    avatars.evict(url);
    oversized = true;
    expect(await avatars.load(url), isNull);
    oversized = false;
    expect(await avatars.load(url), [1, 2, 3]);
    expect(adapter.requests, hasLength(4));
  });

  for (final changeLoader in [false, true]) {
    testWidgets('切换头像${changeLoader ? '加载器' : 'URL'}后等待新图时显示当前占位', (
      tester,
    ) async {
      final firstLoader = _ControlledAvatarLoader();
      final nextLoader = changeLoader ? _ControlledAvatarLoader() : firstLoader;
      addTearDown(firstLoader.close);
      if (changeLoader) addTearDown(nextLoader.close);
      const firstUrl = '$kContributorsEndpoint/avatars/first';
      final nextUrl = changeLoader
          ? firstUrl
          : '$kContributorsEndpoint/avatars/next';
      final firstPng = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      final nextPng = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg==',
      );
      Widget subject(String url, ContributorAvatarLoader loader, String name) =>
          MaterialApp(
            home: ContributorAvatar(
              url: url,
              loader: loader,
              fallback: Text(name),
            ),
          );
      Uint8List displayedBytes() {
        final image = tester.widget<Image>(find.byType(Image));
        final resized = image.image as ResizeImage;
        return (resized.imageProvider as MemoryImage).bytes;
      }

      await tester.pumpWidget(subject(firstUrl, firstLoader, '旧占位'));
      firstLoader.requests[firstUrl]!.complete(firstPng);
      await tester.pumpAndSettle();
      expect(displayedBytes(), firstPng);

      await tester.pumpWidget(subject(nextUrl, nextLoader, '新占位'));
      expect(nextLoader.requests[nextUrl]!.isCompleted, isFalse);
      expect(find.text('新占位'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      nextLoader.requests[nextUrl]!.complete(nextPng);
      await tester.pumpAndSettle();
      expect(find.text('新占位'), findsNothing);
      expect(displayedBytes(), nextPng);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('旧缓存外部头像继续使用不带设备头的图片加载', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ContributorAvatar(
          url: 'https://example.com/avatar.png',
          fallback: Text('占位'),
        ),
      ),
    );
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<NetworkImage>());
    expect((provider as NetworkImage).headers, isNull);
    await tester.pumpAndSettle();
  });
}
