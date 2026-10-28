import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_api.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_resources.dart';

import 'campus_map_api_test.dart' show FakeAdapter, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final remote = CampusMapResources(dio, Uri.parse('http://map.test:12345/'));
    expect(
      remote.resolve('https://cdn.example.net/style.json'),
      'https://cdn.example.net/style.json',
    );
    expect(
      remote.resolve('http://map.test:12345/admin/vendor/sprite'),
      'http://map.test:12345/admin/vendor/sprite',
    );
    // 样式里的相对地址（osm-bright 用 ../../campus）按代理后的样式地址解析。
    expect(
      remote.resolve(
        '../../campus',
        relativeTo: Uri.parse('http://map.test:12345/martin/styles/campus'),
      ),
      'http://map.test:12345/martin/campus',
    );
    // Martin 拼出带「..」的绝对地址时同样要归一并补回代理前缀。
    expect(
      remote.resolve('http://127.0.0.1:8080/../../campus'),
      'http://map.test:12345/martin/campus',
    );
    expect(
      remote.resolve('http://map.test:12345/martin/campus/{z}/{x}/{y}'),
      'http://map.test:12345/martin/campus/{z}/{x}/{y}',
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
          // sprite 与字形探测都失败（重定向循环 / 403），不应再发起其他请求。
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

  test('leaves style content untouched and keeps reachable sprites', () async {
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
                'tiles': ['http://map.test:12345/martin/campus/{z}/{x}/{y}'],
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
        // 只有建筑类型图标那套 sprite 可达
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
    // 不可达的那套 sprite 去掉，可达的保留（相对地址按样式地址解析）
    expect(style['sprite'], [
      {'id': 'campus', 'url': 'http://map.test:12345/martin/sprite/campus'},
    ]);
    // 样式内容原样：不注入楼名、不改写标注字段
    final layers = (style['layers'] as List).cast<Map>();
    expect(layers.map((l) => l['id']), ['building-name-landmark']);
    expect(layers.single['layout']['text-field'], [
      'coalesce',
      ['get', 'name'],
      ['get', 'name_en'],
    ]);
    expect((style['sources'] as Map).keys, ['openmaptiles']);
  });

  test(
    'bundled style mirrors the server style and needs no TileJSON',
    () async {
      final style =
          jsonDecode(await rootBundle.loadString(kCampusBundledStyle)) as Map;
      expect(style['version'], 8);
      final source = style['sources']['openmaptiles'] as Map;
      // 瓦片模板直接写死：离线兜底时不必再取 TileJSON
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
      // 静态瓦片时代的 POI 标注层不应再出现
      expect(layers.map((l) => l['source-layer']), isNot(contains('poi')));
    },
  );
}
