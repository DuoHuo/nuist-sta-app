import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';

typedef Handler = FutureOr<ResponseBody> Function(RequestOptions request);

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final Handler handler;
  final List<RequestOptions> requests = [];
  bool closed = false;

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
  void close({bool force = false}) => closed = true;
}

ResponseBody response(Object body, {int status = 200, bool geo = false}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [
          geo ? 'application/geo+json' : 'application/json',
        ],
      },
    );
ResponseBody ok(Object data) =>
    response({'code': 'ok', 'message': 'ok', 'data': data});
Map<String, dynamic> fc(List<Map<String, dynamic>> features) => {
  'type': 'FeatureCollection',
  'features': features,
};
Map<String, dynamic> feature(Map<String, dynamic> properties) => {
  'type': 'Feature',
  'properties': properties,
  'geometry': {
    'type': 'Polygon',
    'coordinates': [
      [
        [118.7, 32.2],
        [118.71, 32.2],
        [118.71, 32.21],
        [118.7, 32.2],
      ],
    ],
  },
};
Map<String, dynamic> building(
  String id, {
  List<Map<String, dynamic>> entrances = const [],
}) => {
  'building_id': id,
  'name': 'Backend $id',
  'centroid_lng': 118.7,
  'centroid_lat': 32.2,
  'has_indoor_map': true,
  'entrances': entrances,
  'floors': [
    {
      'floor_id': 41,
      'building_id': id,
      'level_index': -1,
      'display_name': 'B1',
      'sort_order': 5,
    },
  ],
};
Map<String, dynamic> poi(int id, {String category = 'study'}) => {
  'poi_id': id,
  'name': 'Room A',
  'category': category,
  'building_id': 'b1',
  'floor_id': 41,
  'lng': 118.71,
  'lat': 32.21,
  'nav_node_id': 90 + id,
};
Map<String, dynamic> route() => {
  'total_length_m': 12.5,
  'segments': [
    {
      'type': 'indoor',
      'building_id': 'b1',
      'floor_id': 41,
      'instruction': '沿走廊步行',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [118.7, 32.2],
          [118.71, 32.21],
        ],
      },
    },
  ],
  'steps': ['沿走廊步行', '到达目的地'],
};

void main() {
  late FakeAdapter adapter;
  late Dio dio;
  late CampusMapApi api;

  void setup(Handler handler, {String baseUrl = 'http://example.test'}) {
    adapter = FakeAdapter(handler);
    dio = Dio()..httpClientAdapter = adapter;
    api = CampusMapApi(baseUrl: baseUrl, dio: dio);
  }

  tearDown(() {
    api.close();
    dio.close();
  });

  group('building models', () {
    const id = 'OSM-Way862952692';
    final modelData = <String, dynamic>{
      'url': '/models/library.glb',
      'version': 'v2',
      'floors': List.generate(
        7,
        (i) => {
          'level_index': i,
          'display_name': '${i + 1}F',
          'elevation_m': i * 3.5,
          'node_name': 'Floor_$i',
          'url': 'models/library-$i.glb',
        },
      ).reversed.toList(),
    };

    for (final suffix in ['', '/', '/api/v1', '/api/v1/']) {
      test('uses configured host/port and API suffix "$suffix"', () async {
        setup((request) {
          expect(request.method, 'GET');
          expect(
            request.uri.toString(),
            'https://campus.example:8443/api/v1/buildings/$id/model',
          );
          return ok(modelData);
        }, baseUrl: 'https://campus.example:8443$suffix');
        final model = (await api.loadBuildingModel(id))!;
        expect(
          model.url.toString(),
          'https://campus.example:8443/models/library.glb',
        );
        expect(model.version, 'v2');
        expect(
          model.floors.map((f) => f.levelIndex),
          orderedEquals(List.generate(7, (i) => i)),
        );
        expect(model.floors.last.displayName, '7F');
        expect(model.floors.last.elevationM, 21);
        expect(model.floors.last.nodeName, 'Floor_6');
        expect(
          model.floors.last.url.toString(),
          'https://campus.example:8443/models/library-6.glb',
        );
        for (final level in [null, 0, 1, 2, 3, 4, 5, 6]) {
          expect(
            api.buildingModelViewerUri(id, levelIndex: level).toString(),
            'https://campus.example:8443/admin/model-viewer.html?building_id=$id&floor=${level ?? 'all'}',
          );
        }
      });
    }

    test('encodes building IDs in request and viewer query', () async {
      const specialId = 'building /?&中文';
      setup((request) {
        expect(request.uri.pathSegments, [
          'api',
          'v1',
          'buildings',
          specialId,
          'model',
        ]);
        return ok(modelData);
      });
      await api.loadBuildingModel(specialId);
      expect(api.buildingModelViewerUri(specialId).queryParameters, {
        'building_id': specialId,
        'floor': 'all',
      });
    });

    for (final html in [false, true]) {
      test('HTTP 404 is no model (HTML: $html)', () async {
        setup(
          (_) => html
              ? ResponseBody.fromString('<html>Not found</html>', 404)
              : response({'code': 'not_found', 'message': '暂无模型'}, status: 404),
        );
        expect(await api.loadBuildingModel(id), isNull);
      });
    }

    for (final status in [401, 500]) {
      test('HTTP $status remains a retryable error', () async {
        setup(
          (_) =>
              response({'code': 'error', 'message': '服务不可用'}, status: status),
        );
        await expectLater(
          api.loadBuildingModel(id),
          throwsA(
            isA<CampusMapApiException>().having(
              (e) => e.statusCode,
              'status',
              status,
            ),
          ),
        );
      });
    }

    test('rejects malformed metadata instead of claiming no model', () async {
      setup(
        (_) => ok({
          ...modelData,
          'floors': [
            {'level_index': 0},
            {'level_index': 0},
          ],
        }),
      );
      await expectLater(
        api.loadBuildingModel(id),
        throwsA(
          isA<CampusMapApiException>().having(
            (e) => e.message,
            'message',
            contains('重复'),
          ),
        ),
      );
    });
  });

  test(
    'deployed API routes legacy Martin loopback through the same origin',
    () async {
      setup((request) {
        expect(request.uri.host, 'duohuo.org.cn');
        expect(request.uri.port, 12345);
        if (request.uri.path.endsWith('/map/config')) {
          return ok({
            'tile_url': 'http://localhost:3000/campus/{z}/{x}/{y}',
            'bounds': [118.6, 32.1, 118.8, 32.3],
          });
        }
        if (request.uri.path.endsWith('/buildings')) {
          return ok({'buildings': []});
        }
        return ok({'pois': []});
      }, baseUrl: 'http://duohuo.org.cn:12345');
      final snapshot = await api.loadCampus();
      final style = jsonDecode(snapshot.styleString!) as Map;
      expect(style['sources']['campus']['tiles'], [
        'http://duohuo.org.cn:12345/martin/campus/{z}/{x}/{y}',
      ]);
      expect(snapshot.places, isEmpty);
    },
  );

  test('loads parallel metadata and bounded real geometry without eager floor requests', () async {
    var active = 0;
    var maximum = 0;
    final initialPaths = <String>[];
    final ready = Completer<void>();
    setup((request) async {
      final path = request.uri.path;
      if (path.endsWith('/geometry')) {
        active++;
        if (active > maximum) maximum = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return response(
          fc([
            feature({'kind': 'footprint'}),
          ]),
          geo: true,
        );
      }
      initialPaths.add(path);
      if (initialPaths.length == 3) ready.complete();
      await ready.future;
      if (path.endsWith('/map/config')) {
        return ok({
          'style_url': '',
          'tile_url': 'http://localhost:3000/campus/{z}/{x}/{y}',
          'bounds': [118.6, 32.1, 118.8, 32.3],
          'attribution': 'Backend attribution',
        });
      }
      if (path.endsWith('/buildings')) {
        return ok({
          'buildings': List.generate(19, (i) {
            final value = building('b$i')
              ..remove('floors')
              ..remove('entrances');
            if (i == 0) value['height_m'] = 17;
            return value;
          }),
        });
      }
      if (path.endsWith('/pois')) {
        expect(request.queryParameters, {'limit': 100});
        return ok({
          'pois': [poi(8), poi(18, category: 'unknown')],
        });
      }
      fail('Unexpected request: $path');
    });
    final snapshot = await api.loadCampus().timeout(const Duration(seconds: 5));
    expect(maximum, 6);
    expect(snapshot.places, hasLength(21));
    expect(snapshot.places.first.category, isNull);
    expect(snapshot.places.first.center!.longitude, 118.7);
    expect(snapshot.places.first.entrance, isNull);
    expect(snapshot.places.first.floors, isEmpty);
    expect(snapshot.places[19].id, 'poi:8');
    expect(snapshot.places[19].category, PlaceCategory.study);
    expect(snapshot.places.last.category, isNull);
    expect(snapshot.streetCoverageGeoJson, isNull);
    final features = snapshot.buildingGeoJson!['features'] as List;
    expect(features, hasLength(19));
    expect(features.first['properties']['height_m'], 17);
    expect(features[1]['properties'].containsKey('height_m'), isFalse);
    expect(features[1]['geometry'], feature({})['geometry']);
    final style = jsonDecode(snapshot.styleString!) as Map;
    expect(style['sources']['campus']['tiles'], [
      'http://example.test/martin/campus/{z}/{x}/{y}',
    ]);
    expect(style['sources']['campus']['bounds'], [118.6, 32.1, 118.8, 32.3]);
    expect(style['sources']['campus']['attribution'], 'Backend attribution');
    expect(style.containsKey('glyphs'), isFalse);
    expect(
      (style['layers'] as List).any(
        (layer) => layer['type'] == 'fill-extrusion',
      ),
      isFalse,
    );
    expect(snapshot.warning, isNull);
    expect(adapter.requests, hasLength(22));
  });

  test(
    'resolves configured style URL and accepts API-prefix base URL',
    () async {
      setup((request) {
        expect(request.uri.path, isNot(contains('/api/v1/api/v1')));
        if (request.uri.path == '/martin/styles/campus.json' ||
            request.uri.path == '/styles/campus.json') {
          return response({'version': 8, 'sources': {}, 'layers': []});
        }
        if (request.uri.path.endsWith('/map/config')) {
          return ok({'style_url': '/styles/campus.json'});
        }
        if (request.uri.path.endsWith('/buildings')) {
          return ok({'buildings': []});
        }
        return ok({'pois': []});
      }, baseUrl: 'http://example.test/api/v1/');
      final snapshot = await api.loadCampus();
      expect(jsonDecode(snapshot.styleString!)['version'], 8);
      expect(snapshot.warning, isNull);
    },
  );

  test(
    'loads detail floors and actual entrance; POI detail has separate identity',
    () async {
      setup((request) {
        if (request.uri.path.endsWith('/pois/8')) return ok(poi(8));
        return ok(
          building(
            'b1',
            entrances: [
              {'lng': 118.72, 'lat': 32.22, 'nav_node_id': 70},
            ],
          ),
        );
      });
      final detail = await api.loadPlace(
        const CampusPlace(id: 'b1', name: 'B'),
      );
      expect(detail.floors.single.id, '41');
      expect(detail.floors.single.number, 5);
      expect(detail.floors.single.levelIndex, -1);
      expect(detail.entrance!.longitude, 118.72);
      expect(detail.navNodeId, 70);
      final p = await api.loadPlace(const CampusPlace(id: 'poi:8', name: 'P'));
      expect(p.poiId, 8);
      expect(p.floorId, '41');
      expect(p.buildingId, 'b1');
      expect(p.entrance, isNull);
      expect(adapter.requests.last.uri.path, '/api/v1/pois/8');
    },
  );

  test('search uses both endpoints and preserves server categories', () async {
    setup((request) {
      expect(request.queryParameters['q'], 'library');
      if (request.uri.path.endsWith('/buildings')) {
        return ok({
          'buildings': [building('b1')],
        });
      }
      return ok({
        'pois': [
          poi(1, category: 'food'),
          poi(2, category: 'sports'),
          poi(3, category: 'services'),
        ],
      });
    });
    final places = await api.searchPlaces(' library ');
    expect(places.map((p) => p.category), [
      null,
      PlaceCategory.food,
      PlaceCategory.sports,
      PlaceCategory.services,
    ]);
  });

  test('floor adds context and links rooms by explicit IDs only; no default wall height', () async {
    setup((request) {
      if (request.uri.path.endsWith('/features')) {
        return response(
          fc([
            feature({'feature_id': 11, 'kind': 'room', 'name': 'Room A'}),
            feature({
              'feature_id': 12,
              'kind': 'room',
              'name': 'Linked',
              'poi_id': 8,
            }),
            feature({'feature_id': 13, 'kind': 'wall'}),
            feature({'feature_id': 14, 'kind': 'wall', 'height_m': 2.8}),
          ]),
          geo: true,
        );
      }
      return ok({
        'pois': [poi(8)],
      });
    });
    final floor = await api.loadFloor('b1', '41');
    expect(floor.rooms.first.id, '11');
    expect(floor.rooms.first.poiId, isNull);
    expect(floor.rooms.first.navNodeId, isNull);
    expect(floor.rooms.last.poiId, 8);
    expect(floor.rooms.last.navNodeId, 98);
    final features = floor.geoJson!['features'] as List;
    expect(features[0]['properties']['room_id'], '11');
    expect(features[0]['properties']['floor_id'], '41');
    expect(features[0]['properties']['building_id'], 'b1');
    expect(features[2]['properties'].containsKey('height_m'), isFalse);
    expect(features[3]['properties']['height_m'], 2.8);
    await expectLater(
      api.planRoute(
        const CampusRouteRequest(
          originPlaceId: 'poi:8',
          destinationPlaceId: 'b1',
          destinationFloorId: '41',
          destinationRoomId: '11',
        ),
      ),
      throwsA(
        isA<CampusMapApiException>().having(
          (e) => e.toString(),
          'message',
          contains('房间'),
        ),
      ),
    );
    expect(adapter.requests.any((r) => r.uri.path.endsWith('/route')), isFalse);
  });

  test('route posts backend POI references and retains real segment geometry and steps', () async {
    setup((request) {
      expect(request.uri.path, '/api/v1/route');
      expect(request.method, 'POST');
      expect(request.data, {
        'origin': {'poi_id': 8},
        'destination': {'poi_id': 18},
        'options': {'accessible_only': true},
      });
      return ok(route());
    });
    final result = (await api.planRoute(
      const CampusRouteRequest(
        originPlaceId: 'poi:8',
        destinationPlaceId: 'poi:18',
        accessible: true,
      ),
    ))!;
    expect(result.instructions, ['沿走廊步行', '到达目的地']);
    expect(result.summary, '全程 12.5 米');
    final segment = (result.geoJson['features'] as List).single;
    expect(segment['properties']['building_id'], 'b1');
    expect(segment['properties']['floor_id'], '41');
    expect(
      segment['geometry'],
      (route()['segments'] as List).single['geometry'],
    );
  });

  test('building route uses accessible entrance node and stable floor maps to level index', () async {
    setup((request) {
      if (request.uri.path.endsWith('/route')) {
        expect(request.data['origin'], {'node_id': 71});
        expect(request.data['destination'], {
          'building_id': 'b1',
          'level_index': -1,
        });
        return ok(route());
      }
      return ok(
        building(
          'b1',
          entrances: [
            {
              'lng': 118.72,
              'lat': 32.22,
              'nav_node_id': 70,
              'is_accessible': false,
            },
            {
              'lng': 118.73,
              'lat': 32.23,
              'nav_node_id': 71,
              'is_accessible': true,
            },
          ],
        ),
      );
    });
    await api.planRoute(
      const CampusRouteRequest(
        originPlaceId: 'b1',
        destinationPlaceId: 'b1',
        destinationFloorId: '41',
        accessible: true,
      ),
    );
    expect(adapter.requests, hasLength(2));
  });

  test('building without entrance is never routed to its centroid', () async {
    setup((request) => ok(building('b1')));
    await expectLater(
      api.planRoute(
        const CampusRouteRequest(
          originPlaceId: 'poi:8',
          destinationPlaceId: 'b1',
        ),
      ),
      throwsA(
        isA<CampusMapApiException>().having(
          (e) => e.message,
          'message',
          contains('入口'),
        ),
      ),
    );
    expect(adapter.requests.single.uri.path, '/api/v1/buildings/b1');
  });

  test(
    'actual entrance coordinates are used when no entrance node exists',
    () async {
      setup((request) {
        if (request.uri.path.endsWith('/route')) {
          expect(request.data['destination'], {'lng': 118.72, 'lat': 32.22});
          return ok(route());
        }
        return ok(
          building(
            'b1',
            entrances: [
              {'lng': 118.72, 'lat': 32.22},
            ],
          ),
        );
      });
      await api.planRoute(
        const CampusRouteRequest(
          originPlaceId: 'poi:8',
          destinationPlaceId: 'b1',
        ),
      );
    },
  );

  test(
    'explicit room POI and node links route without title guesses',
    () async {
      setup((request) {
        if (request.uri.path.endsWith('/features')) {
          return response(
            fc([
              feature({'feature_id': 12, 'kind': 'room', 'poi_id': 18}),
              feature({'feature_id': 13, 'kind': 'room', 'nav_node_id': 77}),
            ]),
            geo: true,
          );
        }
        if (request.uri.path.endsWith('/pois')) return ok({'pois': []});
        return ok(route());
      });
      for (final room in ['12', '13']) {
        await api.planRoute(
          CampusRouteRequest(
            originPlaceId: 'poi:8',
            destinationPlaceId: 'b1',
            destinationFloorId: '41',
            destinationRoomId: room,
          ),
        );
        expect(
          adapter.requests.last.data['destination'],
          room == '12' ? {'poi_id': 18} : {'node_id': 77},
        );
      }
    },
  );

  test('Wi-Fi and fingerprints preserve envelopes and use documented query/header/body', () async {
    setup((request) {
      if (request.uri.path.endsWith('/locate/wifi')) {
        return ok({'found': false, 'reason': 'no_candidates'});
      }
      if (request.method == 'GET') return ok({'fingerprints': [], 'count': 0});
      return ok({'session_id': 4, 'obs_count': 1});
    });
    final observations = [
      {'bssid': '00:11:22:33:44:55', 'rssi': -55},
    ];
    expect(await api.locateWifi(observations), {
      'found': false,
      'reason': 'no_candidates',
    });
    expect(adapter.requests.last.data, {'observations': observations});
    expect(await api.loadFingerprints(buildingId: 'b1', floorId: '41'), {
      'fingerprints': [],
      'count': 0,
    });
    expect(adapter.requests.last.queryParameters, {
      'building_id': 'b1',
      'floor_id': '41',
    });
    final sample = {
      'building_id': 'b1',
      'level_index': -1,
      'lng': 118.7,
      'lat': 32.2,
      'observations': observations,
    };
    expect(await api.submitFingerprint(sample, collectToken: 'test-token'), {
      'session_id': 4,
      'obs_count': 1,
    });
    expect(adapter.requests.last.data, sample);
    expect(adapter.requests.last.headers['X-Collect-Token'], 'test-token');
    await api.submitFingerprint(sample);
    expect(
      adapter.requests.last.headers.containsKey('X-Collect-Token'),
      isFalse,
    );
  });

  for (final status in [200, 422]) {
    test('normalizes backend error envelope at HTTP $status', () async {
      setup(
        (request) =>
            response({'code': 'no_route', 'message': '无法规划路线'}, status: status),
      );
      await expectLater(
        api.loadFingerprints(),
        throwsA(
          isA<CampusMapApiException>()
              .having((e) => e.code, 'code', 'no_route')
              .having((e) => e.statusCode, 'status', status)
              .having((e) => e.toString(), 'message', '无法规划路线'),
        ),
      );
    });
  }

  test('normalizes malformed response and transport failures', () async {
    setup(
      (request) => ResponseBody.fromString('<html>bad gateway</html>', 502),
    );
    await expectLater(
      api.loadFingerprints(),
      throwsA(isA<CampusMapApiException>()),
    );
    adapter = FakeAdapter(
      (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionTimeout,
      ),
    );
    dio.httpClientAdapter = adapter;
    await expectLater(
      api.loadFingerprints(),
      throwsA(
        isA<CampusMapApiException>().having(
          (e) => e.message,
          'message',
          contains('超时'),
        ),
      ),
    );
  });

  test('close is idempotent and does not dispose caller-owned Dio', () async {
    setup((request) => ok({'fingerprints': []}));
    api.close();
    api.close();
    expect(adapter.closed, isFalse);
    await expectLater(
      api.loadFingerprints(),
      throwsA(isA<CampusMapApiException>()),
    );
  });
}
