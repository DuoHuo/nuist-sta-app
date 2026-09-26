import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';

const _live = bool.fromEnvironment('CAMPUS_LIVE_TEST');
const _baseUrl = String.fromEnvironment(
  'CAMPUS_API_BASE_URL',
  defaultValue: 'http://202.195.237.186:12345',
);

// Check actual coordinates, not just the presence of a GeoJSON envelope.
void _expectCoordinates(dynamic coordinates) {
  expect(coordinates, isA<List>());
  final values = coordinates as List;
  expect(values, isNotEmpty);
  if (values.first is num) {
    expect(values.length, greaterThanOrEqualTo(2));
    expect(values[0], isA<num>());
    expect(values[1], isA<num>());
    final longitude = (values[0] as num).toDouble();
    final latitude = (values[1] as num).toDouble();
    expect(longitude.isFinite && latitude.isFinite, isTrue);
    expect(longitude, inInclusiveRange(-180, 180));
    expect(latitude, inInclusiveRange(-90, 90));
  } else {
    for (final child in values) {
      _expectCoordinates(child);
    }
  }
}

List<dynamic> _expectFeatures(
  Map<String, dynamic>? geoJson, {
  required List<String> geometryTypes,
}) {
  expect(geoJson, isNotNull);
  expect(geoJson!['type'], 'FeatureCollection');
  expect(geoJson['features'], isA<List>());
  final features = geoJson['features'] as List;
  expect(features, isNotEmpty);
  for (final feature in features) {
    expect(feature['type'], 'Feature');
    expect(feature['geometry'], isA<Map>());
    expect(geometryTypes, contains(feature['geometry']['type']));
    _expectCoordinates(feature['geometry']['coordinates']);
  }
  return features;
}

void main() {
  test(
    'live campus geometry, search, details, fingerprints and route',
    () async {
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
      // Guard against accidentally adding collection or Wi-Fi requests here.
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'GET' ||
                (options.method == 'POST' &&
                    options.uri.path == '/api/v1/route')) {
              handler.next(options);
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: 'Live test permits only GET and route planning',
                ),
              );
            }
          },
        ),
      );
      final api = CampusMapApi(baseUrl: _baseUrl, dio: dio);
      addTearDown(() {
        api.close();
        dio.close(force: true);
      });

      final campus = await api.loadCampus();
      expect(campus.places, isNotEmpty);
      // 三类地物各有编号字段：建筑 = 既不是 POI 也不是通用地物。
      final buildings = campus.places
          .where((p) => p.poiId == null && p.featureId == null)
          .toList();
      final pois = campus.places.where((p) => p.poiId != null).toList();
      expect(buildings, isNotEmpty);
      expect(pois, isNotEmpty);
      final buildingFeatures = _expectFeatures(
        campus.buildingGeoJson,
        geometryTypes: ['Polygon', 'MultiPolygon', 'Point'],
      );
      final footprints = buildingFeatures
          .where(
            (f) => ['Polygon', 'MultiPolygon'].contains(f['geometry']['type']),
          )
          .toList();
      expect(footprints, isNotEmpty);
      final buildingIds = buildings.map((p) => p.id).toSet();
      final geometryIds = footprints
          .map((f) => f['properties']['building_id'])
          .toSet();
      expect(geometryIds, unorderedEquals(buildingIds));

      // 通用地物：管理台提交的道路/绿地/广场等。线上可以一个都没有（没人提交时），
      // 有则每个都必须带编号、类别与可渲染几何，并且能按编号打开自己的详情。
      final featurePlaces = campus.places
          .where((p) => p.featureId != null)
          .toList();
      final featureRows = campus.featuresGeoJson!['features'] as List;
      expect(featureRows, hasLength(featurePlaces.length));
      for (final row in featureRows) {
        final feature = row as Map;
        final geometry = feature['geometry'] as Map;
        expect(const [
          'Point',
          'MultiPoint',
          'LineString',
          'MultiLineString',
          'Polygon',
          'MultiPolygon',
        ], contains(geometry['type']));
        _expectCoordinates(geometry['coordinates']);
        final properties = feature['properties'] as Map;
        expect(properties['feature_id'], isA<num>());
        expect(properties['kind'], isA<String>());
      }
      for (final place in featurePlaces) {
        expect(place.hasDetail, isTrue);
        expect(place.name.trim(), isNotEmpty);
        final detail = await api.loadPlace(place);
        expect(detail.id, place.id);
        expect(detail.featureId, place.featureId);
      }

      expect(campus.bounds, hasLength(4));
      final bounds = campus.bounds!;
      expect(bounds.every((n) => n.isFinite), isTrue);
      expect(bounds[0], inInclusiveRange(-180, 180));
      expect(bounds[2], inInclusiveRange(-180, 180));
      expect(bounds[1], inInclusiveRange(-90, 90));
      expect(bounds[3], inInclusiveRange(-90, 90));
      expect(bounds[0], lessThan(bounds[2]));
      expect(bounds[1], lessThan(bounds[3]));

      expect(campus.styleString, isNotNull);
      final styleString = campus.styleString!;
      expect(styleString.trim(), isNotEmpty);
      final dynamic style;
      if (styleString.trimLeft().startsWith('{')) {
        style = jsonDecode(styleString);
      } else {
        final uri = Uri.parse(styleString);
        expect(uri.scheme, isIn(['http', 'https']));
        expect(uri.host, isNotEmpty);
        final response = await dio.get<dynamic>(
          styleString,
          options: Options(receiveTimeout: const Duration(seconds: 10)),
        );
        style = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
      }
      expect(style, isA<Map>());
      expect(style['version'], 8);
      expect(style['sources'], isA<Map>());
      expect(style['sources'], isNotEmpty);
      expect(style['layers'], isA<List>());
      expect(style['layers'], isNotEmpty);
      // 样式由服务端下发（当前是 OSM Bright 血统，源名 openmaptiles），不绑定
      // 具体源名：取第一个矢量源，再按它的 TileJSON 找瓦片地址。
      final vectorSources = (style['sources'] as Map).values
          .whereType<Map>()
          .where((s) => s['type'] == 'vector')
          .toList();
      expect(vectorSources, isNotEmpty);
      var tileSource = vectorSources.first;
      if (tileSource['url'] is String) {
        final tileJsonResponse = await dio.get<dynamic>(
          tileSource['url'] as String,
          options: Options(receiveTimeout: const Duration(seconds: 10)),
        );
        final tileJson = tileJsonResponse.data;
        tileSource = tileJson is String
            ? jsonDecode(tileJson) as Map
            : tileJson as Map;
      }
      expect(tileSource['tiles'], isA<List>());
      final template = (tileSource['tiles'] as List).first as String;
      // 真机可达的地址必须走 api 同源代理（Martin 独立端口 30000 会被防火墙重置）。
      expect(template, isNot(contains('localhost')));
      expect(Uri.parse(template).port, isNot(30000));
      final tileResponse = await dio.get<List<int>>(
        template
            .replaceAll('{z}', '14')
            .replaceAll('{x}', '13594')
            .replaceAll('{y}', '6642'),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      expect(tileResponse.statusCode, 200);
      expect(tileResponse.data!.length, greaterThan(100));
      debugPrint(
        'Live vector tile bytes=${tileResponse.data!.length}, template=$template',
      );
      debugPrint(
        'Loaded buildings=${buildings.length}, POIs=${pois.length}, '
        'footprints=${footprints.length}',
      );

      final namedPlace = campus.places.firstWhere(
        (p) => p.name.trim().isNotEmpty,
      );
      final matches = await api.searchPlaces(namedPlace.name);
      expect(matches, isNotEmpty);
      expect(matches.map((p) => p.id), contains(namedPlace.id));
      debugPrint('Search "${namedPlace.name}": ${matches.length} matches');

      final building = await api.loadPlace(buildings.first);
      expect(building.id, buildings.first.id);
      expect(building.buildingId, buildings.first.buildingId);
      expect(building.name, buildings.first.name);
      expect(building.center?.isValid, isTrue);
      final poi = await api.loadPlace(pois.first);
      expect(poi.id, pois.first.id);
      expect(poi.poiId, pois.first.poiId);
      expect(poi.name, pois.first.name);
      expect(poi.center?.isValid, isTrue);

      final fingerprints = await api.loadFingerprints();
      expect(fingerprints['fingerprints'], isA<List>());
      expect(fingerprints['count'], isA<int>());
      expect(
        fingerprints['count'],
        (fingerprints['fingerprints'] as List).length,
      );
      debugPrint('Fingerprints=${fingerprints['count']} (read only)');

      final indoorBuildings = buildings.where((p) => p.hasIndoor).toList();
      if (indoorBuildings.isEmpty) {
        debugPrint('Floors: skipped (no live building hasIndoor)');
      } else {
        final indoor = await api.loadPlace(indoorBuildings.first);
        expect(indoor.hasIndoor, isTrue);
        expect(indoor.floors, isNotEmpty);
        final floor = indoor.floors.first;
        final snapshot = await api.loadFloor(indoor.buildingId!, floor.id);
        final features = _expectFeatures(
          snapshot.geoJson,
          geometryTypes: [
            'Point',
            'MultiPoint',
            'LineString',
            'MultiLineString',
            'Polygon',
            'MultiPolygon',
          ],
        );
        expect(snapshot.rooms.every((r) => r.floorId == floor.id), isTrue);
        debugPrint(
          'Floor ${floor.id}: features=${features.length}, rooms=${snapshot.rooms.length}',
        );
      }

      // Prefer the verified real pair, but never invent a POI or node ID.
      final routable = pois.where((p) => p.navNodeId != null).toList();
      expect(
        routable.length,
        greaterThanOrEqualTo(2),
        reason: 'Live routing requires POIs linked to the navigation graph',
      );
      final origin = routable.firstWhere(
        (p) => p.poiId == 8,
        orElse: () => routable.first,
      );
      final destinations = routable
          .where((p) => p.id != origin.id && p.navNodeId != origin.navNodeId)
          .toList();
      expect(destinations, isNotEmpty);
      final destination = destinations.firstWhere(
        (p) => p.poiId == 18,
        orElse: () => destinations.first,
      );
      final route = await api.planRoute(
        CampusRouteRequest(
          originPlaceId: origin.id,
          destinationPlaceId: destination.id,
        ),
      );
      expect(route, isNotNull);
      final segments = _expectFeatures(
        route!.geoJson,
        geometryTypes: ['LineString', 'MultiLineString'],
      );
      expect(route.instructions, isNotEmpty);
      expect(route.instructions.every((s) => s.trim().isNotEmpty), isTrue);
      expect(route.summary, isNotNull);
      final length = RegExp(r'^全程 (\d+(?:\.\d+)?) 米$')
          .firstMatch(route.summary!);
      expect(length, isNotNull);
      expect(double.parse(length!.group(1)!), greaterThan(0));
      debugPrint(
        'Route ${origin.id} -> ${destination.id}: ${route.summary}; '
        'segments=${segments.length}',
      );
    },
    skip: _live ? false : 'Enable with --dart-define=CAMPUS_LIVE_TEST=true',
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
