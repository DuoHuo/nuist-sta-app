import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/schedule/weekly_classes.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_heading.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_native.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_navigation.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_panels.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_resources.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_schedule.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';
import 'package:nuist_sta_app/mini_apps/timetable/timetable_models.dart';

import 'campus_map_api_test.dart' show FakeAdapter, response;

const _origin = GeoPoint(longitude: 118.7, latitude: 32.2);

GeoPoint _at(double east, double north) => GeoPoint(
  longitude:
      _origin.longitude + east / (111320 * cos(_origin.latitude * pi / 180)),
  latitude: _origin.latitude + north / 111320,
);

List<double> _c(double east, double north) {
  final p = _at(east, north);
  return [p.longitude, p.latitude];
}

Map<String, dynamic> _feature(
  List<List<double>> coordinates, [
  Map<String, dynamic> properties = const {},
]) => {
  'type': 'Feature',
  'geometry': {'type': 'LineString', 'coordinates': coordinates},
  'properties': properties,
};

CampusRouteResult _result(List<Map<String, dynamic>> features) =>
    CampusRouteResult(
      geoJson: {'type': 'FeatureCollection', 'features': features},
      instructions: const ['沿校园道路步行', '到达目的地'],
    );

WeeklyClass _lesson(String location, {int day = 2, int start = 3}) =>
    WeeklyClass(
      courseName: '高等数学',
      location: location,
      weekday: day,
      startNode: start,
      endNode: start + 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('导航路线分段、偏置与传感器朝向', () {
    final route = NavRoute.fromResult(
      _result([
        _feature([_c(0, 0), _c(50, 0), _c(100, 0), _c(100, 50), _c(100, 100)]),
      ]),
    );

    test('turn detection finds the left turn between two straight legs', () {
      expect(route.length, closeTo(200, 1));
      expect(route.steps.first.maneuver, NavManeuver.depart);
      expect(route.steps.last.maneuver, NavManeuver.arrive);
      final turns = route.steps
          .where((s) => s.maneuver == NavManeuver.left)
          .toList();
      expect(turns, hasLength(1));
      expect(turns.single.along, closeTo(100, 1));
      expect(route.steps, hasLength(3));
    });

    test('locate snaps to the route and reports the next maneuver', () {
      final progress = route.locate(_at(50, 5));
      expect(progress.along, closeTo(50, 1));
      expect(progress.offRoute, closeTo(5, 0.5));
      expect(progress.bearing, closeTo(90, 2));
      expect(progress.next.maneuver, NavManeuver.left);
      expect(progress.distanceToNext, closeTo(50, 1));
      expect(progress.remaining, closeTo(150, 1));

      final later = route.locate(_at(102, 60), hint: progress.along);
      expect(later.next.maneuver, NavManeuver.arrive);
      expect(later.bearing, closeTo(0, 2));
      expect(later.distanceToNext, closeTo(40, 1));
    });

    test('passed geometry ends at the current position', () {
      final passed = route.passedGeoJson(50);
      final features = passed['features'] as List;
      expect(features, hasLength(1));
      final coordinates =
          (features.single as Map)['geometry']['coordinates'] as List;
      final last = coordinates.last as List<double>;
      expect(
        metersBetween(
          GeoPoint(longitude: last[0], latitude: last[1]),
          _at(50, 0),
        ),
        lessThan(0.5),
      );
      expect(route.passedGeoJson(0)['features'], isEmpty);
    });

    test('floor change segments become their own maneuver', () {
      final indoor = NavRoute.fromResult(
        _result([
          _feature([_c(0, 0), _c(30, 0)], {'type': 'indoor'}),
          _feature(
            [_c(30, 0), _c(30, 1)],
            {
              'type': 'floor_change',
              'action': 'stairs',
              'instruction': '经楼梯从 1F 前往 3F',
            },
          ),
          _feature([_c(30, 1), _c(60, 1)], {'type': 'indoor'}),
        ]),
      );
      final change = indoor.steps.singleWhere(
        (s) => s.maneuver == NavManeuver.floorChange,
      );
      expect(change.title, '走楼梯');
      expect(change.detail, '经楼梯从 1F 前往 3F');
      expect(change.along, closeTo(30, 1));
    });

    test('empty route degrades to arrival without throwing', () {
      final empty = NavRoute.fromResult(_result(const []));
      expect(empty.isEmpty, isTrue);
      expect(empty.locate(_origin).next.maneuver, NavManeuver.arrive);
    });

    test('distance and time labels', () {
      expect(navDistanceLabel(8.4), '8 米');
      expect(navDistanceLabel(123), '120 米');
      expect(navDistanceLabel(1530), '1.5 公里');
      expect(navWalkMinutes(10), 1);
      expect(navWalkMinutes(650), 9);
    });

    test('places along the route skip far ones and the endpoints', () {
      final near = CampusPlace(id: 'a', name: '文德楼', center: _at(60, 10));
      final far = CampusPlace(id: 'b', name: '远处楼', center: _at(60, 200));
      final atStart = CampusPlace(id: 'c', name: '起点楼', center: _at(2, 3));
      final via = route.placesAlong([far, atStart, near]);
      expect(via.map((p) => p.name), ['文德楼']);
      expect(route.locate(_at(50, 0)).after?.maneuver, NavManeuver.arrive);
      expect(route.progressAt(100).fraction, closeTo(.5, .01));
    });

    group('传感器朝向与视口内缩偏置', () {
      const g = 9.81;
      const latitude = 32.20275;

      test('平放与竖屏朝向、传感器异常及角度差折叠', () {
        expect(azimuthFromSensors(0, 0, g, 0, 20, -40), closeTo(0, 0.01));
        expect(azimuthFromSensors(0, 0, g, -20, 0, -40), closeTo(90, 0.01));
        expect(azimuthFromSensors(0, 0, g, 20, 0, -40), closeTo(270, 0.01));
        expect(azimuthFromSensors(0, g, 0, 0, -40, -20), isNotNull);
        expect(azimuthFromSensors(0, 0, 0, 0, 20, -40), isNull);
        expect(azimuthFromSensors(0, 0, g, 0, 0, 0), isNull);
        expect(headingDelta(350, 10), closeTo(20, 1e-9));
        expect(headingDelta(10, 350), closeTo(-20, 1e-9));
        expect(headingDelta(0, 180), closeTo(180, 1e-9));
      });

      test('bottom/left/top+bottom/zero/invalid zoom cameraInsetOffset 行为', () {
        final offset = cameraInsetOffset(
          latitude: latitude,
          zoom: 17,
          insets: const EdgeInsets.only(bottom: 400),
        );
        final worldPx = 512.0 * 131072.0;
        final expected = -360.0 * cos(latitude * pi / 180.0) * 200 / worldPx;
        expect(offset.latitude, closeTo(expected, 1e-9));
        expect(offset.latitude, lessThan(0));
        expect(offset.longitude, 0);

        final leftOffset = cameraInsetOffset(
          latitude: latitude,
          zoom: 17,
          insets: const EdgeInsets.only(left: 384),
        );
        expect(leftOffset.longitude, lessThan(0));
        expect(leftOffset.latitude, 0);

        expect(
          cameraInsetOffset(
            latitude: latitude,
            zoom: 15,
            insets: const EdgeInsets.only(top: 100, bottom: 300),
          ).latitude,
          closeTo(
            cameraInsetOffset(
              latitude: latitude,
              zoom: 15,
              insets: const EdgeInsets.only(bottom: 200),
            ).latitude,
            1e-12,
          ),
        );
        expect(
          cameraInsetOffset(
            latitude: latitude,
            zoom: 17,
            insets: EdgeInsets.zero,
          ),
          (latitude: 0.0, longitude: 0.0),
        );
        expect(
          cameraInsetOffset(
            latitude: latitude,
            zoom: 0,
            insets: const EdgeInsets.only(bottom: 400),
          ),
          (latitude: 0.0, longitude: 0.0),
        );
      });

      test('zoom、tilt 与 bearing 对内缩偏置的缩放旋转及楼层基准高程', () {
        final coarse = cameraInsetOffset(
          latitude: latitude,
          zoom: 16,
          insets: const EdgeInsets.only(bottom: 400),
        );
        final fine = cameraInsetOffset(
          latitude: latitude,
          zoom: 17,
          insets: const EdgeInsets.only(bottom: 400),
        );
        expect(coarse.latitude, closeTo(fine.latitude * 2, 1e-12));

        final flat = cameraInsetOffset(
          latitude: latitude,
          zoom: 18,
          insets: const EdgeInsets.only(bottom: 600),
        );
        final tilted = cameraInsetOffset(
          latitude: latitude,
          zoom: 18,
          insets: const EdgeInsets.only(bottom: 600),
          tilt: 52,
        );
        expect(tilted.latitude.abs(), greaterThan(flat.latitude.abs()));
        expect(
          tilted.latitude.abs() / flat.latitude.abs(),
          closeTo(1 / cos(52 * pi / 180), 1e-6),
        );

        final north = cameraInsetOffset(
          latitude: latitude,
          zoom: 18,
          insets: const EdgeInsets.only(bottom: 600),
        );
        final south = cameraInsetOffset(
          latitude: latitude,
          zoom: 18,
          insets: const EdgeInsets.only(bottom: 600),
          bearing: 180,
        );
        expect(south.latitude, closeTo(-north.latitude, 1e-12));
        expect(
          cameraInsetOffset(
            latitude: latitude,
            zoom: 18,
            insets: const EdgeInsets.only(bottom: 600),
            bearing: 90,
          ).longitude,
          lessThan(0),
        );

        const withElevation = CampusFloor(
          id: '1',
          label: '3F',
          number: 3,
          levelIndex: 2,
          elevationM: 7.2,
        );
        const withoutElevation = CampusFloor(
          id: '2',
          label: '3F',
          number: 3,
          levelIndex: 2,
        );
        const basement = CampusFloor(
          id: '3',
          label: 'B1',
          number: 0,
          levelIndex: -1,
        );
        expect(floorBaseElevation(withElevation), 7.2);
        expect(floorBaseElevation(withoutElevation), 2 * kDisplayFloorHeightM);
        expect(floorBaseElevation(basement), -kDisplayFloorHeightM);
      });
    });
  });

  group('地图样式资源代理与字体精灵兜底', () {
    test(
      'routes martin resources through the same-origin /martin proxy',
      () async {
        final calls = <String>[];
        final dio = Dio()
          ..httpClientAdapter = FakeAdapter((r) {
            calls.add(r.uri.toString());
            if (r.uri.path == '/martin/styles/campus') {
              return response({
                'version': 8,
                'sources': {
                  'campus': {
                    'type': 'vector',
                    'url': 'http://localhost:3000/campus',
                  },
                },
                'glyphs': 'http://localhost:3000/fonts/{fontstack}/{range}.pbf',
                'layers': [
                  {
                    'id': 'water',
                    'type': 'fill',
                    'source': 'campus',
                    'source-layer': 'water',
                  },
                  {'id': 'roofs', 'type': 'fill-extrusion', 'source': 'campus'},
                ],
              });
            }
            expect(r.uri.path, '/martin/campus');
            return response({
              'tiles': ['http://map.test:12345/campus/{z}/{x}/{y}'],
              'minzoom': 0,
              'maxzoom': 14,
              'attribution': 'OSM',
            });
          });
        addTearDown(dio.close);
        final resources = CampusMapResources(
          dio,
          Uri.parse('http://map.test:12345/'),
        );
        final style = jsonDecode(
          await resources.prepare(
            'http://map.test:3000/styles/campus',
            bounds: [118.6, 32.1, 118.8, 32.3],
          ),
        );
        expect(calls, [
          'http://map.test:12345/martin/styles/campus',
          'http://map.test:12345/martin/campus',
        ]);
        final source = style['sources']['campus'];
        expect(source['url'], isNull);
        expect(source['maxzoom'], 14);
        expect(source['tiles'], [
          'http://map.test:12345/martin/campus/{z}/{x}/{y}',
        ]);
        expect(
          style['glyphs'],
          'http://map.test:12345/martin/fonts/{fontstack}/{range}.pbf',
        );
        expect(style['layers'], hasLength(1));
        expect(style['pitch'], 0);
        expect(style['zoom'], 15);
      },
    );

    test('keeps unrelated resources and already-proxied URLs intact', () {
      final dio = Dio();
      addTearDown(dio.close);
      final remote = CampusMapResources(
        dio,
        Uri.parse('http://map.test:12345/'),
      );
      expect(
        remote.resolve('https://cdn.example.net/style.json'),
        'https://cdn.example.net/style.json',
      );
      expect(
        remote.resolve('http://map.test:12345/admin/vendor/sprite'),
        'http://map.test:12345/admin/vendor/sprite',
      );
      expect(
        remote.resolve(
          '../../campus',
          relativeTo: Uri.parse('http://map.test:12345/martin/styles/campus'),
        ),
        'http://map.test:12345/martin/campus',
      );
      expect(
        remote.resolve('http://127.0.0.1:8080/../../campus'),
        'http://map.test:12345/martin/campus',
      );
      expect(
        remote.resolve('http://map.test:12345/martin/campus/{z}/{x}/{y}'),
        'http://map.test:12345/martin/campus/{z}/{x}/{y}',
      );
      final local = CampusMapResources(
        dio,
        Uri.parse('http://127.0.0.1:8080/'),
      );
      expect(
        local.resolve('http://localhost:3000/campus'),
        'http://127.0.0.1:8080/martin/campus',
      );
    });

    test('drops unreachable sprite and glyphs, and overrides template center', () async {
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter((r) {
          if (r.uri.path == '/martin/styles/campus') {
            return response({
              'version': 8,
              'center': [0, 0],
              'zoom': 1,
              'sprite': 'http://map.test:12345/admin/vendor/sprite',
              'glyphs':
                  'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
              'sources': {
                'campus': {
                  'type': 'vector',
                  'tiles': ['http://map.test:12345/martin/campus/{z}/{x}/{y}'],
                },
              },
              'layers': [
                {'id': 'bg', 'type': 'background'},
              ],
            });
          }
          return ResponseBody.fromString('nope', 404);
        });
      addTearDown(dio.close);
      final resources = CampusMapResources(
        dio,
        Uri.parse('http://map.test:12345/'),
      );
      final style = jsonDecode(
        await resources.prepare(
          '{"version":8,"sources":{},"layers":[],'
          '"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf"}',
          bounds: [118.6, 32.1, 118.8, 32.3],
        ),
      );
      expect(style.containsKey('sprite'), isFalse);
      expect(
        style['glyphs'],
        'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
      );
      expect(style['center'], [(118.6 + 118.8) / 2, (32.1 + 32.3) / 2]);
      expect(style['zoom'], 15);
      expect(style['layers'], isEmpty);
    });

    test(
      'leaves style content untouched and keeps reachable sprites',
      () async {
        final dio = Dio()
          ..httpClientAdapter = FakeAdapter((r) {
            if (r.uri.path == '/martin/styles/campus') {
              return response({
                'version': 8,
                'sprite': [
                  {
                    'id': 'default',
                    'url': 'http://map.test:12345/admin/vendor/sprite/sprite',
                  },
                  {'id': 'campus', 'url': '../sprite/campus'},
                ],
                'sources': {
                  'openmaptiles': {
                    'type': 'vector',
                    'tiles': [
                      'http://map.test:12345/martin/campus/{z}/{x}/{y}',
                    ],
                  },
                },
                'layers': [
                  {
                    'id': 'building-name-landmark',
                    'type': 'symbol',
                    'source': 'openmaptiles',
                    'source-layer': 'building_label',
                    'minzoom': 13.5,
                    'layout': {
                      'text-field': [
                        'coalesce',
                        ['get', 'name'],
                        ['get', 'name_en'],
                      ],
                    },
                  },
                ],
              });
            }
            if (r.uri.path == '/martin/sprite/campus.json') {
              return response({'dormitory': {}});
            }
            return ResponseBody.fromString('nope', 404);
          });
        addTearDown(dio.close);
        final resources = CampusMapResources(
          dio,
          Uri.parse('http://map.test:12345/'),
        );
        final style = jsonDecode(
          await resources.prepare('http://map.test:12345/martin/styles/campus'),
        );
        expect(style['sprite'], [
          {'id': 'campus', 'url': 'http://map.test:12345/martin/sprite/campus'},
        ]);
        final layers = (style['layers'] as List).cast<Map>();
        expect(layers.map((l) => l['id']), ['building-name-landmark']);
        expect(layers.single['layout']['text-field'], [
          'coalesce',
          ['get', 'name'],
          ['get', 'name_en'],
        ]);
        expect((style['sources'] as Map).keys, ['openmaptiles']);
      },
    );

    test(
      'bundled style mirrors the server style and needs no TileJSON',
      () async {
        final style =
            jsonDecode(await rootBundle.loadString(kCampusBundledStyle)) as Map;
        expect(style['version'], 8);
        final source = style['sources']['openmaptiles'] as Map;
        expect(source['url'], isNull);
        expect(source['tiles'], ['/martin/campus/{z}/{x}/{y}']);
        final layers = (style['layers'] as List).cast<Map>();
        expect(
          layers.map((l) => l['id']),
          containsAll([
            'building',
            'building-top',
            'building-name',
            'building-name-major',
            'building-name-landmark',
            'feature-name',
          ]),
        );
        expect(layers.map((l) => l['source-layer']), isNot(contains('poi')));
      },
    );
  });

  group('教学楼房间匹配、本周课程与探索排序', () {
    test('教学楼名（忽略「楼」字）、门牌号提取与合并区间匹配', () {
      expect(locationInBuilding('明德楼A101', '明德楼'), isTrue);
      expect(locationInBuilding('明德楼 a101', '明德楼'), isTrue);
      expect(locationInBuilding('揽江楼 N407', '明德楼'), isFalse);
      expect(locationInBuilding('东区明德楼A101', '明德楼'), isFalse);
      expect(locationInBuilding('北101', '北'), isFalse);

      expect(locationInBuilding('北辰N101', '北辰楼'), isTrue);
      expect(locationInBuilding('北辰楼N101', '北辰'), isTrue);
      expect(locationInBuilding('北辰楼N101', '北辰楼'), isTrue);
      expect(roomCodeIn('北辰N101', '北辰楼'), 'N101');
      expect(roomCodeIn('北辰楼 N101', '北辰'), 'N101');
      expect(locationInBuilding('A101', 'A楼'), isFalse);
      expect(locationInBuilding('南辰N101', '北辰楼'), isFalse);

      expect(roomCodeIn('明德楼A101', '明德楼'), 'A101');
      expect(roomCodeIn('揽江楼 N407', '揽江楼'), 'N407');
      expect(roomCodeIn('学而楼C303多媒体教室', '学而楼'), 'C303');
      expect(roomCodeIn('明德楼-205', '明德楼'), '205');
      expect(roomCodeIn('明德楼', '明德楼'), isNull);
      expect(roomCodeIn('体育馆', '明德楼'), isNull);

      expect(roomCodeMatches('N102', 'N102'), isTrue);
      expect(roomCodeMatches('n102', 'N102'), isTrue);
      expect(roomCodeMatches('N101-103', 'N102'), isTrue);
      expect(roomCodeMatches('N101-103', 'N103'), isTrue);
      expect(roomCodeMatches('N101-103', 'N104'), isFalse);
      expect(roomCodeMatches('N108-10', 'N109'), isTrue);
      expect(roomCodeMatches('N101-103', 'S102'), isFalse);
      expect(roomCodeMatches(null, 'N102'), isFalse);
      expect(roomCodeMatches('N102', 'N1020'), isFalse);
    });

    test('按楼筛出本周课程、门牌楼层查找顺序与时间标签', () {
      const place = CampusPlace(id: 'b1', name: '明德楼');
      final classes = [
        _lesson('明德楼A101'),
        _lesson('揽江楼N407'),
        _lesson('明德楼 B202', day: 4),
      ];
      final mine = classesInBuilding(classes, place);
      expect(mine.map((c) => c.location), ['明德楼A101', '明德楼 B202']);
      expect(classTimeLabel(_lesson('x')), '周二 3-4 节');

      const floors = [
        CampusFloor(id: 'f1', label: '1F', number: 1),
        CampusFloor(id: 'f2', label: '2F', number: 2),
        CampusFloor(id: 'f4', label: '4F', number: 4),
      ];
      expect(floorsToSearch(floors, 'N407').map((f) => f.id), [
        'f4',
        'f1',
        'f2',
      ]);
      expect(floorsToSearch(floors, 'A12').map((f) => f.id), [
        'f1',
        'f2',
        'f4',
      ]);
    });

    test('filterPlaces 按分类与裁剪后的关键词过滤地点', () {
      const places = [
        CampusPlace(
          id: 'b1',
          name: '明德楼',
          subtitle: '教学楼',
          category: PlaceCategory.study,
        ),
        CampusPlace(
          id: 'b2',
          name: '理科楼',
          subtitle: '北楼',
          category: PlaceCategory.study,
        ),
        CampusPlace(
          id: 'b3',
          name: '物理实验楼',
          subtitle: '理科实验',
          category: PlaceCategory.study,
        ),
        CampusPlace(
          id: 'f1',
          name: '中苑食堂',
          subtitle: '餐饮',
          category: PlaceCategory.food,
        ),
      ];
      expect(
        filterPlaces(places, PlaceCategory.study, '  理科 ').map((p) => p.id),
        ['b2', 'b3'],
      );
      expect(filterPlaces(places, PlaceCategory.study, '明德').map((p) => p.id), [
        'b1',
      ]);
      expect(filterPlaces(places, PlaceCategory.food, '').map((p) => p.id), [
        'f1',
      ]);
    });

    test('本周上课的楼按节数排序，楼名重叠时取最长的', () {
      const places = [
        CampusPlace(id: 'a', name: '理科楼'),
        CampusPlace(id: 'b', name: '理科楼东'),
        CampusPlace(id: 'c', name: '明德楼'),
        CampusPlace(id: 'p', name: '明德楼咖啡', poiId: 9),
        CampusPlace(id: 'u', name: '未命名建筑 1'),
      ];
      final result = weekBuildings([
        _lesson('明德楼N101'),
        _lesson('明德楼N305'),
        _lesson('理科楼东201'),
        _lesson('体育馆'),
      ], places);
      expect(result.map((r) => (r.place.id, r.count)), [('c', 2), ('b', 1)]);
    });

    test('离你最近：只列建筑，按距离排序，跳过无坐标与占位名', () {
      const me = GeoPoint(longitude: 118.7000, latitude: 32.2000);
      const places = [
        CampusPlace(
          id: 'far',
          name: '远',
          center: GeoPoint(longitude: 118.7100, latitude: 32.2000),
        ),
        CampusPlace(
          id: 'near',
          name: '近',
          center: GeoPoint(longitude: 118.7005, latitude: 32.2000),
        ),
        CampusPlace(id: 'none', name: '没坐标'),
        CampusPlace(
          id: 'poi:1',
          name: '咖啡',
          poiId: 1,
          center: GeoPoint(longitude: 118.7002, latitude: 32.2000),
        ),
        CampusPlace(
          id: 'feature:1',
          name: '草坪',
          featureId: 1,
          center: GeoPoint(longitude: 118.7003, latitude: 32.2000),
        ),
        CampusPlace(
          id: 'u',
          name: '未命名建筑 2',
          center: GeoPoint(longitude: 118.7001, latitude: 32.2000),
        ),
      ];
      expect(nearestPlaces(places, me).map((p) => p.id), ['near', 'far']);
    });

    test('步行时间按直线 80 米 / 分钟估算', () {
      expect(walkingLabel(30), '就在附近');
      expect(walkingLabel(80), '约步行 1 分钟');
      expect(walkingLabel(81), '约步行 2 分钟');
      expect(walkingLabel(6000), '约 6.0 公里');
      const a = GeoPoint(longitude: 118.7, latitude: 32.2);
      const b = GeoPoint(longitude: 118.7, latitude: 32.201);
      expect(metersBetween(a, b), closeTo(111.3, 0.5));
    });

    group('教务课表 fixture 联动', () {
      late List<WeeklyClass> allWeeks;

      setUpAll(() {
        final json = jsonDecode(
          File('test/fixtures/timetable/kb_mock_2026-1.json')
              .readAsStringSync(),
        ) as Map<String, dynamic>;
        final rows = (json['datas'] as Map)['cxxszhxqkb']['rows'] as List;
        final courses = TimetableParser.parseKbRows(rows).courses;
        allWeeks = [
          for (final course in courses)
            for (final slot in course.slots)
              if (slot.location.trim().isNotEmpty && slot.weeks.contains('1'))
                WeeklyClass(
                  courseName: course.name,
                  location: slot.location,
                  weekday: slot.day,
                  startNode: slot.startNode,
                  endNode: slot.endNode,
                ),
        ];
      });

      const mingde = CampusPlace(
        id: 'OSM-Way862952692',
        name: '明德楼',
        floors: [
          CampusFloor(id: '8', label: '1F', number: 1),
          CampusFloor(id: '9', label: '2F', number: 2),
          CampusFloor(id: '10', label: '3F', number: 3),
        ],
      );

      test('mock 里明德楼的课都能归到明德楼，别的楼不混进来', () {
        final mine = classesInBuilding(allWeeks, mingde);
        expect(mine, isNotEmpty);
        expect(mine.every((c) => c.location.startsWith('明德楼')), isTrue);
        expect(
          classesInBuilding(
            allWeeks,
            const CampusPlace(id: 'x', name: '文德楼'),
          ).every((c) => c.location.startsWith('文德楼')),
          isTrue,
        );
      });

      test('mock 门牌能对上明德楼真实房间（含合并门牌 N101-103）', () {
        final codes = {
          for (final c in classesInBuilding(allWeeks, mingde))
            roomCodeIn(c.location, mingde.name),
        };
        expect(codes, containsAll(['N101', 'N305']));
        expect(roomCodeMatches('N101-103', 'N101'), isTrue);
        expect(roomCodeMatches('N305', 'N305'), isTrue);
        expect(floorsToSearch(mingde.floors, 'N305').first.number, 3);
        expect(floorsToSearch(mingde.floors, 'N101').first.number, 1);
      });
    });
  });
}
