import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_photos.dart';

import 'campus_map_api_test.dart' show FakeAdapter, ok, response;

void main() {
  late FakeAdapter adapter;
  late Dio dio;
  late CampusMapApi api;

  void setup(FutureOr<ResponseBody> Function(RequestOptions) handler) {
    adapter = FakeAdapter(handler);
    dio = Dio()..httpClientAdapter = adapter;
    api = CampusMapApi(baseUrl: 'http://example.test:12345', dio: dio);
  }

  tearDown(() {
    api.close();
    dio.close();
  });

  test('parses photo list and resolves relative file urls', () async {
    setup((request) {
      expect(request.uri.path, '/api/v1/buildings/b1/photos');
      return ok({
        'count': 2,
        'photos': [
          {
            'photo_id': 7,
            'building_id': 'b1',
            'url': '/photos/0123456789abcdef0123456789abcdef.jpg',
            'caption': '南门实景',
            'source': 'survey',
            'taken_at': '2026-09-01T08:30:00Z',
            'sort_order': 1,
          },
          {
            'photo_id': 8,
            'building_id': 'b1',
            'url': '/photos/fedcba9876543210fedcba9876543210.png',
            'caption': '',
            'source': '志愿者拍摄',
            'taken_at': null,
            'sort_order': 2,
          },
        ],
      });
    });
    final photos = await api.loadBuildingPhotos('b1');
    expect(photos, hasLength(2));
    expect(
      photos.first.url,
      'http://example.test:12345/photos/0123456789abcdef0123456789abcdef.jpg',
    );
    expect(photos.first.label, '南门实景');
    expect(photos.first.takenAt, DateTime.utc(2026, 9, 1, 8, 30));
    // 无说明时退回来源，便于界面仍有可读文字。
    expect(photos.last.label, '志愿者拍摄');
    expect(photos.last.takenAt, isNull);
  });

  test(
    'empty list is a normal result, malformed payload is an error',
    () async {
      setup((_) => ok({'photos': <Object>[], 'count': 0}));
      expect(await api.loadBuildingPhotos('b1'), isEmpty);

      setup((_) => ok({'photos': 'nope'}));
      await expectLater(
        api.loadBuildingPhotos('b1'),
        throwsA(
          isA<CampusMapApiException>().having(
            (e) => e.toString(),
            'message',
            contains('格式'),
          ),
        ),
      );

      setup(
        (_) => ok({
          'photos': [
            {'photo_id': 1},
          ],
        }),
      );
      await expectLater(
        api.loadBuildingPhotos('b1'),
        throwsA(
          isA<CampusMapApiException>().having(
            (e) => e.toString(),
            'message',
            contains('必要字段'),
          ),
        ),
      );
    },
  );

  test('unknown building surfaces the backend 404 message', () async {
    setup(
      (_) => response({'code': 'not_found', 'message': '建筑不存在'}, status: 404),
    );
    await expectLater(
      api.loadBuildingPhotos('missing'),
      throwsA(
        isA<CampusMapApiException>().having(
          (e) => e.toString(),
          'message',
          '建筑不存在',
        ),
      ),
    );
  });

  test('photo url must be absolute after resolution', () {
    expect(
      () => resolvePhotoUri(Uri.parse('http://example.test/'), ''),
      throwsA(isA<CampusPhotoException>()),
    );
    expect(
      resolvePhotoUri(
        Uri.parse('http://example.test/'),
        '/photos/ab.jpg',
      ).toString(),
      'http://example.test/photos/ab.jpg',
    );
  });

  test('parsePhotos can skip malformed rows when not strict', () {
    final photos = parsePhotos(Uri.parse('http://example.test/'), [
      {'photo_id': 1, 'url': '/photos/a.jpg'},
      {'url': '/photos/b.jpg'},
      'junk',
    ], strict: false);
    expect(photos.map((p) => p.id), [1]);
  });
}
