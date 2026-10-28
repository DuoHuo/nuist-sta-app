import 'dart:convert';

import 'package:dio/dio.dart';

/// 渲染前解析服务器下发的样式与 TileJSON：只做地址归一（走同源 /martin 代理）、
/// 探测 sprite、按校园范围设中心。**不改样式内容**——楼名、类型图标、标注字段都
/// 由服务器样式（数据来自业务库实时瓦片）决定，管理台与 App 看到的是同一份。
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

  Future<String> prepare(String input, {List<double>? bounds}) async {
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
    if (style['glyphs'] is String) {
      style['glyphs'] = resolve(
        style['glyphs'] as String,
        relativeTo: styleUri,
      );
    }
    // sprite 可以是单个地址，也可以是多套 [{id, url}]（OSM Bright 自带 + 建筑类型图标）
    final sprite = style['sprite'];
    if (sprite is String) {
      style['sprite'] = resolve(sprite, relativeTo: styleUri);
    } else if (sprite is List) {
      style['sprite'] = [
        for (final entry in sprite)
          if (entry is Map && entry['url'] is String)
            {
              ...entry,
              'url': resolve(entry['url'] as String, relativeTo: styleUri),
            },
      ];
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
    style['pitch'] = 0;
    return jsonEncode(style);
  }

  /// Sprite 不可达时会让 MapLibre 原生端反复重试甚至卡住样式加载，先探测再丢弃。
  ///
  /// 字形（glyphs）**不能**这样处理：一旦删掉 glyphs，MapLibre 会为每个标注层
  /// 用空 URL 取字形（日志刷 "Unable to parse resourceUrl"），标注全部消失。
  /// 字形按需拉取，境外服务偶发超时只影响文字本身，不应拖垮底图。
  Future<void> _dropUnreachableSprite(Map<String, dynamic> style) async {
    final value = style['sprite'];
    if (value is List) {
      // 多套 sprite：逐套探测，只留可达的；一套都不可达就整个去掉
      final reachable = [
        for (final entry in value)
          if (entry is Map &&
              entry['url'] is String &&
              await _spriteReachable(entry['url'] as String))
            entry,
      ];
      if (reachable.isEmpty) {
        style.remove('sprite');
      } else {
        style['sprite'] = reachable;
      }
      return;
    }
    if (value is! String || value.isEmpty || !await _spriteReachable(value)) {
      style.remove('sprite');
    }
  }

  Future<bool> _spriteReachable(String value) async {
    if (value.isEmpty) return false;
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
      return response.statusCode == 200;
    } on DioException catch (error) {
      return error.response?.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _normalizeGlyphs(Map<String, dynamic> style) {
    final glyphs = style['glyphs'];
    if (glyphs is! String || glyphs.trim().isEmpty) {
      style.remove('glyphs');
    }
  }
}
