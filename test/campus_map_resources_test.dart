import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_resources.dart';

import 'campus_map_api_test.dart' show FakeAdapter, response;

void main() {
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
          // 服务器可能下发容器内部地址，或遗漏代理前缀的绝对地址，都要归一。
          return response({
            'tiles': ['http://192.0.2.1:12345/campus/{z}/{x}/{y}'],
            'minzoom': 0,
            'maxzoom': 14,
            'attribution': 'OSM',
          });
        });
      addTearDown(dio.close);
      final resources = CampusMapResources(
        dio,
        Uri.parse('http://192.0.2.1:12345/'),
      );
      final style = jsonDecode(
        await resources.prepare(
          'http://192.0.2.1:3000/styles/campus',
          bounds: [118.6, 32.1, 118.8, 32.3],
        ),
      );
      expect(calls, [
        'http://192.0.2.1:12345/martin/styles/campus',
        'http://192.0.2.1:12345/martin/campus',
      ]);
      final source = style['sources']['campus'];
      expect(source['url'], isNull);
      expect(source['maxzoom'], 14);
      expect(source['tiles'], [
        'http://192.0.2.1:12345/martin/campus/{z}/{x}/{y}',
      ]);
      expect(
        style['glyphs'],
        'http://192.0.2.1:12345/martin/fonts/{fontstack}/{range}.pbf',
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
      Uri.parse('http://192.0.2.1:12345/'),
    );
    expect(
      remote.resolve('https://cdn.example.net/style.json'),
      'https://cdn.example.net/style.json',
    );
    expect(
      remote.resolve('http://192.0.2.1:12345/admin/vendor/sprite'),
      'http://192.0.2.1:12345/admin/vendor/sprite',
    );
    // 样式里的相对地址（osm-bright 用 ../../campus）按代理后的样式地址解析。
    expect(
      remote.resolve(
        '../../campus',
        relativeTo: Uri.parse(
          'http://192.0.2.1:12345/martin/styles/campus',
        ),
      ),
      'http://192.0.2.1:12345/martin/campus',
    );
    // Martin 拼出带「..」的绝对地址时同样要归一并补回代理前缀。
    expect(
      remote.resolve('http://127.0.0.1:8080/../../campus'),
      'http://192.0.2.1:12345/martin/campus',
    );
    expect(
      remote.resolve('http://192.0.2.1:12345/martin/campus/{z}/{x}/{y}'),
      'http://192.0.2.1:12345/martin/campus/{z}/{x}/{y}',
    );
    // 本地开发的 API 同样提供 /martin 代理，回环 martin 地址也归一到代理。
    final local = CampusMapResources(dio, Uri.parse('http://127.0.0.1:8080/'));
    expect(
      local.resolve('http://localhost:3000/campus'),
      'http://127.0.0.1:8080/martin/campus',
    );
  });

  test(
    'drops unreachable sprite and glyphs, and overrides template center',
    () async {
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter((r) {
          if (r.uri.path == '/martin/styles/campus') {
            return response({
              'version': 8,
              'center': [0, 0],
              'zoom': 1,
              'sprite': 'http://192.0.2.1:12345/admin/vendor/sprite',
              'glyphs':
                  'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
              'sources': {
                'campus': {
                  'type': 'vector',
                  'tiles': [
                    'http://192.0.2.1:12345/martin/campus/{z}/{x}/{y}',
                  ],
                },
              },
              'layers': [
                {'id': 'bg', 'type': 'background'},
              ],
            });
          }
          // sprite 与字形探测都失败（重定向循环 / 403），不应再发起其他请求。
          return ResponseBody.fromString('nope', 404);
        });
      addTearDown(dio.close);
      final resources = CampusMapResources(
        dio,
        Uri.parse('http://192.0.2.1:12345/'),
      );
      final style = jsonDecode(
        await resources.prepare(
          '{"version":8,"sources":{},"layers":[],'
          '"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf"}',
          bounds: [118.6, 32.1, 118.8, 32.3],
        ),
      );
      expect(style.containsKey('sprite'), isFalse);
      // 字形不可达也不能删：删掉会让每个标注层用空 URL 取字形。
      expect(
        style['glyphs'],
        'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
      );
      expect(style['center'], [(118.6 + 118.8) / 2, (32.1 + 32.3) / 2]);
      expect(style['zoom'], 15);
      expect(style['layers'], isEmpty);
    },
  );

  test('injects blue building names and rewrites labels to Chinese', () async {
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((r) {
        if (r.uri.path.startsWith('/martin/fonts/')) {
          return response({'stub': true});
        }
        if (r.uri.path == '/martin/styles/campus') {
          return response({
            'version': 8,
            'sources': {
              'openmaptiles': {
                'type': 'vector',
                'tiles': [
                  'http://192.0.2.1:12345/martin/campus/{z}/{x}/{y}',
                ],
              },
            },
            'layers': [
              {
                'id': 'poi-level-1',
                'type': 'symbol',
                'source-layer': 'poi',
                'layout': {
                  'text-field': [
                    'coalesce',
                    ['get', 'name'],
                    ['get', 'name:latin'],
                  ],
                },
              },
              {
                'id': 'highway-name-major',
                'type': 'symbol',
                'source-layer': 'transportation_name',
                'layout': {
                  'text-field': [
                    'coalesce',
                    ['get', 'name:latin'],
                  ],
                },
              },
            ],
          });
        }
        return response({
          'tiles': ['http://192.0.2.1:12345/martin/campus/{z}/{x}/{y}'],
        });
      });
    addTearDown(dio.close);
    final resources = CampusMapResources(
      dio,
      Uri.parse('http://192.0.2.1:12345/'),
    );
    final style = jsonDecode(
      await resources.prepare(
        'http://192.0.2.1:12345/martin/styles/campus',
        bounds: [118.6, 32.1, 118.8, 32.3],
        places: const [
          CampusPlace(
            id: 'b1',
            name: '明德楼',
            category: null,
            center: GeoPoint(longitude: 118.71, latitude: 32.2),
          ),
          CampusPlace(
            id: 'b2',
            name: '未命名建筑',
            category: null,
            center: GeoPoint(longitude: 118.72, latitude: 32.21),
          ),
          CampusPlace(
            id: 'poi:5',
            name: '食堂',
            category: PlaceCategory.food,
            poiId: 5,
            center: GeoPoint(longitude: 118.73, latitude: 32.22),
          ),
        ],
      ),
    );
    final layers = (style['layers'] as List).cast<Map>();
    final poi = layers.firstWhere((l) => l['id'] == 'poi-level-1');
    expect(poi['filter'], [
      'all',
      ['!in', 'name', '明德楼'],
      ['!in', 'name:latin', '明德楼'],
      ['!in', 'name:nonlatin', '明德楼'],
    ]);
    final highway = layers.firstWhere((l) => l['id'] == 'highway-name-major');
    expect(highway['layout']['text-field'], [
      'coalesce',
      ['get', 'name:nonlatin'],
      ['get', 'name'],
      ['get', 'name:latin'],
    ]);
    final label = layers.last;
    expect(label['id'], 'basemap-building-name');
    expect(label['minzoom'], 15.5);
    expect(label['paint']['text-color'], '#16307A');
    final features =
        (style['sources']['campus-building-names']['data']['features'] as List);
    // 未命名建筑与 POI 都不注入楼名。
    expect(features, hasLength(1));
    expect(features.single['properties']['name'], '明德楼');
    expect(features.single['geometry']['coordinates'], [118.71, 32.2]);
  });
}
