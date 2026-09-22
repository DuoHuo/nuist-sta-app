import 'dart:convert';

import 'package:dio/dio.dart';

import 'campus_map_data.dart';

/// Resolves server-owned style and TileJSON resources before native rendering.
class CampusMapResources {
  CampusMapResources(this.dio, this.apiBase);
  final Dio dio;
  final Uri apiBase;

  static const _martinHosts = {'localhost', '127.0.0.1', '::1', 'martin'};
  static const _martinRoots = ['/campus', '/styles/', '/catalog', '/health'];

  String resolve(String value, {Uri? relativeTo}) {
    // Martin 拼接样式里的相对地址时不归一「..」，先消解点段再匹配规则。
    var uri = ((relativeTo ?? apiBase).resolve(value)).normalizePath();
    if (uri.host.isEmpty) return uri.toString();
    final apiAuthority = apiBase.authority.isEmpty
        ? uri.authority
        : apiBase.authority;
    final throughProxy =
        apiAuthority == uri.authority && uri.path.startsWith('/martin/');
    if (throughProxy) return _readable(uri);
    final martinHost = _martinHosts.contains(uri.host);
    final martinPort = uri.port == 3000 || uri.port == 30000;
    if (martinHost || martinPort) {
      uri = uri.replace(
        scheme: apiBase.scheme,
        host: apiBase.host,
        port: apiBase.port,
        path: '/martin${uri.path}',
      );
      return _readable(uri);
    }
    // Martin may ignore forwarded headers and emit tile URLs on the API origin
    // without the proxy prefix (it only knows its own stripped path).
    final onApiOrigin = uri.authority == apiAuthority;
    final martinRoot =
        uri.path == '/campus' || _martinRoots.any(uri.path.startsWith);
    if (onApiOrigin && martinRoot) {
      uri = uri.replace(path: '/martin${uri.path}');
    }
    return _readable(uri);
  }

  String _readable(Uri uri) =>
      uri.toString().replaceAll('%7B', '{').replaceAll('%7D', '}');

  Future<Map<String, dynamic>> _get(String url) async {
    final response = await dio.get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final data = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    if (data is! Map) throw const FormatException('Invalid map resource');
    return Map<String, dynamic>.from(data);
  }

  Future<String> prepare(
    String input, {
    List<double>? bounds,
    List<CampusPlace> places = const [],
  }) async {
    final inline = input.trimLeft().startsWith('{');
    final styleUri = inline ? apiBase : Uri.parse(resolve(input));
    final style = inline
        ? Map<String, dynamic>.from(jsonDecode(input) as Map)
        : await _get(styleUri.toString());
    if (style['version'] != 8 ||
        style['sources'] is! Map ||
        style['layers'] is! List) {
      throw const FormatException('Invalid MapLibre style');
    }
    for (final key in ['glyphs', 'sprite']) {
      if (style[key] is String) {
        style[key] = resolve(style[key] as String, relativeTo: styleUri);
      }
    }
    // Sprite 不可达会让原生端卡住样式加载，先探测；字形只做非空归一。
    _normalizeGlyphs(style);
    await _dropUnreachableSprite(style);
    final sources = Map<String, dynamic>.from(style['sources'] as Map);
    for (final entry in sources.entries) {
      final source = Map<String, dynamic>.from(entry.value as Map);
      final url = source['url'];
      if (url is String &&
          (source['type'] == 'vector' || source['type'] == 'raster')) {
        final metadataUri = Uri.parse(resolve(url, relativeTo: styleUri));
        final metadata = await _get(metadataUri.toString());
        if (metadata['tiles'] is! List || (metadata['tiles'] as List).isEmpty) {
          throw const FormatException('TileJSON has no tiles');
        }
        source.remove('url');
        for (final key in [
          'minzoom',
          'maxzoom',
          'bounds',
          'attribution',
          'scheme',
        ]) {
          if (metadata[key] != null) source[key] = metadata[key];
        }
        source['tiles'] = [
          for (final tile in metadata['tiles'] as List)
            resolve(tile as String, relativeTo: metadataUri),
        ];
      } else if (source['tiles'] is List) {
        source['tiles'] = [
          for (final tile in source['tiles'] as List)
            resolve(tile as String, relativeTo: styleUri),
        ];
      }
      if (source['data'] is String) {
        source['data'] = resolve(
          source['data'] as String,
          relativeTo: styleUri,
        );
      }
      sources[entry.key] = source;
    }
    style['sources'] = sources;
    // Building roofs from the basemap would obscure the selected indoor floor.
    style['layers'] = [
      for (final raw in style['layers'] as List)
        if ((raw as Map)['type'] != 'fill-extrusion') raw,
    ];
    if (bounds != null && bounds.length == 4) {
      // 样式自带的 center/zoom 可能是制作模板残留（如 [0,0]/1），以校园范围为准。
      style['center'] = [
        (bounds[0] + bounds[2]) / 2,
        (bounds[1] + bounds[3]) / 2,
      ];
      style['zoom'] = 15;
    }
    // 与管理台保持一致：中文标签字段改写 + 注入本库楼名。
    _applyChineseLabels(style);
    _injectBuildingNames(style, places);
    style['pitch'] = 0;
    return jsonEncode(style);
  }

  /// 瓦片的中文常写在 name:nonlatin（tilemaker 可能写进 name:latin），
  /// 中文优先取本地文字，避免底图显示拉丁转写。
  void _applyChineseLabels(Map<String, dynamic> style) {
    const zhField = [
      'coalesce',
      ['get', 'name:nonlatin'],
      ['get', 'name'],
      ['get', 'name:latin'],
    ];
    for (final raw in style['layers'] as List) {
      if (raw is! Map) continue;
      final layout = raw['layout'];
      if (raw['type'] != 'symbol' || layout is! Map) continue;
      final field = layout['text-field'];
      if (field == null) continue;
      if (!jsonEncode(field).contains('name:latin')) continue;
      layout['text-field'] = zhField;
    }
  }

  /// 瓦片 building 层没有楼名字段；用业务库中的命名建筑生成蓝色楼名标注，
  /// 并排除与之重名的底图 POI 文字（只保留图标），避免同一栋楼出现两份名字。
  void _injectBuildingNames(
    Map<String, dynamic> style,
    List<CampusPlace> places,
  ) {
    final named = [
      for (final place in places)
        if (place.poiId == null &&
            place.center != null &&
            place.center!.isValid &&
            place.name.trim().isNotEmpty &&
            !place.name.startsWith('未命名'))
          place,
    ];
    if (named.isEmpty) return;
    final names = [for (final place in named) place.name];
    for (final raw in style['layers'] as List) {
      if (raw is! Map || raw['type'] != 'symbol') continue;
      if (raw['source-layer'] != 'poi') continue;
      final existing = raw['filter'];
      raw['filter'] = [
        'all',
        ?existing,
        ['!in', 'name', ...names],
        ['!in', 'name:latin', ...names],
        ['!in', 'name:nonlatin', ...names],
      ];
    }
    final sources = Map<String, dynamic>.from(style['sources'] as Map);
    sources['campus-building-names'] = {
      'type': 'geojson',
      'data': {
        'type': 'FeatureCollection',
        'features': [
          for (final place in named)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [
                  place.center!.longitude,
                  place.center!.latitude,
                ],
              },
              'properties': {'name': place.name},
            },
        ],
      },
    };
    style['sources'] = sources;
    (style['layers'] as List).add({
      'id': 'basemap-building-name',
      'type': 'symbol',
      'source': 'campus-building-names',
      'minzoom': 15.5,
      'layout': {
        'text-field': ['get', 'name'],
        'text-font': ['Noto Sans Regular'],
        'text-size': [
          'interpolate',
          ['linear'],
          ['zoom'],
          15.5,
          10.5,
          19,
          13.5,
        ],
        'text-letter-spacing': 0.05,
        'text-padding': 4,
        'text-allow-overlap': false,
      },
      'paint': {
        'text-color': '#16307A',
        'text-halo-color': 'rgba(255,255,255,0.92)',
        'text-halo-width': 1.3,
      },
    });
  }

  /// Sprite 不可达时会让 MapLibre 原生端反复重试甚至卡住样式加载，先探测再丢弃。
  ///
  /// 字形（glyphs）**不能**这样处理：一旦删掉 glyphs，MapLibre 会为每个标注层
  /// 用空 URL 取字形（日志刷 "Unable to parse resourceUrl"），标注全部消失。
  /// 字形按需拉取，境外服务偶发超时只影响文字本身，不应拖垮底图。
  Future<void> _dropUnreachableSprite(Map<String, dynamic> style) async {
    final value = style['sprite'];
    if (value is! String || value.isEmpty) {
      if (style.containsKey('sprite')) style.remove('sprite');
      return;
    }
    final probe = '$value.json';
    try {
      final response = await dio.get<dynamic>(
        probe,
        options: Options(
          responseType: ResponseType.plain,
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 8),
          maxRedirects: 4,
        ),
      );
      if (response.statusCode == 200) return;
    } on DioException catch (error) {
      if (error.response?.statusCode == 200) return;
    } catch (_) {
      // 落到丢弃逻辑
    }
    style.remove('sprite');
  }

  void _normalizeGlyphs(Map<String, dynamic> style) {
    final glyphs = style['glyphs'];
    if (glyphs is! String || glyphs.trim().isEmpty) {
      style.remove('glyphs');
    }
  }
}
