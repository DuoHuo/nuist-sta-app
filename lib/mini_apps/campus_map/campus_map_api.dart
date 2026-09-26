import 'dart:convert';

import 'package:dio/dio.dart';

import 'campus_building_model.dart';
import 'campus_map_data.dart';
import 'campus_map_photos.dart';
import 'campus_map_resources.dart';
import 'campus_map_source.dart';

class CampusMapApiException implements Exception {
  const CampusMapApiException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Adapter for the campus backend's /api/v1 contracts.
class CampusMapApi
    implements
        CampusMapSource,
        CampusMapRemoteSource,
        CampusBuildingModelSource,
        CampusBuildingPhotosSource {
  CampusMapApi({
    String baseUrl = const String.fromEnvironment(
      'CAMPUS_API_BASE_URL',
      defaultValue: 'http://202.195.237.186:12345',
    ),
    Dio? dio,
  }) : _baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
       _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10))),
       _ownsDio = dio == null;

  final String _baseUrl;
  final Dio _dio;
  final bool _ownsDio;
  bool _closed = false;
  final Map<String, CampusPlace> _places = {};
  final Map<String, Map<String, dynamic>> _buildingDetails = {};
  final Map<(String, String), CampusFloorSnapshot> _floors = {};

  @override
  bool get isConfigured => _baseUrl.isNotEmpty;

  String _url(String path) =>
      '$_baseUrl${_baseUrl.endsWith('/api/v1') ? '' : '/api/v1'}$path';

  CampusMapResources get _resources =>
      CampusMapResources(_dio, Uri.parse('$_baseUrl/'));
  String _resourceUrl(String value) => _resources.resolve(value);

  Uri get _serverRoot {
    final base = Uri.tryParse(_baseUrl);
    if (base == null ||
        !base.hasAuthority ||
        !['http', 'https'].contains(base.scheme)) {
      throw const CampusMapApiException('请配置有效的地图服务地址');
    }
    return Uri.parse('${base.origin}/');
  }

  @override
  Uri buildingModelViewerUri(String buildingId, {int? levelIndex}) =>
      _serverRoot
          .resolve('admin/model-viewer.html')
          .replace(
            queryParameters: {
              'building_id': buildingId,
              'floor': levelIndex?.toString() ?? 'all',
            },
          );

  @override
  Future<CampusBuildingModel?> loadBuildingModel(String buildingId) async {
    try {
      final data = await _request(
        '/buildings/${Uri.encodeComponent(buildingId)}/model',
      );
      return CampusBuildingModel.fromJson(data, _serverRoot);
    } on CampusMapApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    } on FormatException catch (error) {
      throw CampusMapApiException(error.message);
    }
  }

  @override
  Future<List<CampusPhoto>> loadBuildingPhotos(String buildingId) async {
    final data = await _request(
      '/buildings/${Uri.encodeComponent(buildingId)}/photos',
    );
    final raw = data['photos'];
    if (raw is! List) {
      throw const CampusMapApiException('实拍图片数据格式不正确');
    }
    try {
      return parsePhotos(_serverRoot, raw);
    } on CampusPhotoException catch (error) {
      throw CampusMapApiException(error.message);
    }
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Map<String, dynamic>? data,
    Map<String, dynamic>? headers,
    bool raw = false,
  }) async {
    if (_closed) {
      throw const CampusMapApiException('地图连接已关闭');
    }
    try {
      final response = await _dio.request<dynamic>(
        _url(path),
        queryParameters: query,
        data: data,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final body = _object(response.data);
      final code = _text(body['code']);
      if (code != null && code != 'ok') {
        throw CampusMapApiException(
          _text(body['message']) ?? '地图服务请求失败',
          code: code,
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode != null && response.statusCode! >= 400) {
        throw CampusMapApiException(
          _text(body['message']) ?? '地图服务请求失败',
          statusCode: response.statusCode,
        );
      }
      if (raw && code == null) return body;
      if (code != 'ok') {
        throw const CampusMapApiException('地图服务返回的数据格式不正确');
      }
      return _object(body['data']);
    } on DioException catch (error) {
      Map<String, dynamic>? body;
      try {
        body = _object(error.response?.data);
      } on CampusMapApiException {
        // A proxy or transport failure need not have a JSON response.
      }
      final message = _text(body?['message']);
      throw CampusMapApiException(
        message ??
            switch (error.type) {
              DioExceptionType.connectionTimeout ||
              DioExceptionType.sendTimeout ||
              DioExceptionType.receiveTimeout => '地图服务连接超时，请稍后重试',
              DioExceptionType.cancel => '地图请求已取消',
              DioExceptionType.badResponse =>
                '地图服务请求失败（HTTP ${error.response?.statusCode ?? '未知'}）',
              _ => '无法连接地图服务，请检查网络或服务地址',
            },
        code: _text(body?['code']),
        statusCode: error.response?.statusCode,
      );
    }
  }

  @override
  Future<CampusMapSnapshot> loadCampus() async {
    final results = await Future.wait([
      _request('/map/config'),
      _request('/buildings'),
      _request('/pois', query: {'limit': 100}),
      _request('/features'),
    ]);
    final config = results[0];
    final buildings = _objects(results[1]['buildings']);
    final featureRows = _objects(results[3]['features']);
    final places = [
      for (final building in buildings) _building(building),
      for (final poi in _objects(results[2]['pois'])) _poi(poi),
      for (final feature in featureRows) _feature(feature),
    ];
    final geometries = List<List<Map<String, dynamic>>?>.filled(
      buildings.length,
      null,
    );
    var next = 0;
    // Six workers, rather than one Future per building (248 in production).
    Future<void> worker() async {
      while (next < buildings.length) {
        final index = next++;
        final building = buildings[index];
        final id = _requiredText(building['building_id']);
        final geometry = await _request(
          '/buildings/${Uri.encodeComponent(id)}/geometry',
          raw: true,
        );
        geometries[index] = [
          for (final feature in _features(geometry))
            _withProperties(feature, {
              'building_id': id,
              if (_number(building['height_m']) != null)
                'height_m': _number(building['height_m']),
            }),
        ];
      }
    }

    await Future.wait(
      List.generate(buildings.length.clamp(0, 6), (_) => worker()),
    );
    final bounds = _bounds(config['bounds']);
    final attribution = _text(config['attribution']);
    final styleUrl = _text(config['style_url']);
    String? preparedStyle;
    String? warning;
    try {
      preparedStyle = await _resources.prepare(
        styleUrl ?? _basicStyle(config, bounds, attribution),
        bounds: bounds,
        places: places,
      );
    } catch (_) {
      warning = '底图资源加载失败，地点和路线仍可使用，请刷新重试';
    }
    return CampusMapSnapshot(
      places: places,
      buildingGeoJson: _collection([
        for (final features in geometries) ...?features,
      ]),
      featuresGeoJson: _collection([
        for (final feature in featureRows)
          _withProperties(
            {
              'type': 'Feature',
              'geometry': feature['geometry'],
              'properties': const <String, dynamic>{},
            },
            {
              'feature_id': _integer(feature['feature_id']),
              'kind': _text(feature['kind']) ?? '',
              'name': _text(feature['name']) ?? '',
            },
          ),
      ]),
      styleString: preparedStyle,
      attribution: attribution,
      bounds: bounds,
      warning: warning,
    );
  }

  @override
  Future<CampusPlace> loadPlace(CampusPlace place) async {
    final poiId = place.poiId ?? _poiId(place.id);
    if (poiId != null) return _poi(await _request('/pois/$poiId'));
    final featureId = place.featureId ?? _featureId(place.id);
    if (featureId != null) {
      return _feature(await _request('/features/$featureId'));
    }
    final id = place.buildingId ?? place.id;
    return _building(await _detail(id));
  }

  Future<Map<String, dynamic>> _detail(String id) async {
    final cached = _buildingDetails[id];
    if (cached != null) return cached;
    final detail = await _request('/buildings/${Uri.encodeComponent(id)}');
    _buildingDetails[id] = detail;
    _building(detail);
    return detail;
  }

  @override
  Future<List<CampusPlace>> searchPlaces(String query) async {
    final results = await Future.wait([
      _request('/buildings', query: {'q': query.trim()}),
      _request('/pois', query: {'q': query.trim(), 'limit': 100}),
      _request('/features', query: {'q': query.trim()}),
    ]);
    return [
      for (final building in _objects(results[0]['buildings']))
        _building(building),
      for (final poi in _objects(results[1]['pois'])) _poi(poi),
      for (final feature in _objects(results[2]['features'])) _feature(feature),
    ];
  }

  CampusPlace _building(Map<String, dynamic> data) {
    final id = _requiredText(data['building_id']);
    // Search/list responses must not erase details loaded earlier.
    data = _buildingDetails[id] ?? data;
    final entrances = _objects(data['entrances']);
    final entrance = entrances.isEmpty ? null : entrances.first;
    final floors = [
      for (final floor in _objects(data['floors']))
        CampusFloor(
          id: _requiredText(floor['floor_id']),
          label: _text(floor['display_name']) ?? '',
          number: _requiredInt(floor['sort_order']),
          levelIndex: _integer(floor['level_index']),
          elevationM: _number(floor['elevation_m']),
        ),
    ]..sort((a, b) => a.number.compareTo(b.number));
    final place = CampusPlace(
      id: id,
      name: _text(data['name']) ?? '',
      category: null,
      buildingId: id,
      center: _point(data['centroid_lng'], data['centroid_lat']),
      entrance: entrance == null
          ? null
          : _point(entrance['lng'], entrance['lat']),
      navNodeId: _integer(entrance?['nav_node_id']),
      hasIndoor: data['has_indoor_map'] == true,
      floors: floors,
      sceneId: _text(data['splat_scene_id']),
    );
    _places[id] = place;
    return place;
  }

  CampusPlace _poi(Map<String, dynamic> data) {
    final id = _requiredInt(data['poi_id']);
    final place = CampusPlace(
      id: 'poi:$id',
      name: _text(data['name']) ?? '',
      subtitle: [
        _text(data['building_name']),
        _text(data['floor_name']),
      ].whereType<String>().join(' · '),
      category: switch (_text(data['category'])) {
        'study' || '教学' || '教室' || 'library' => PlaceCategory.study,
        'food' ||
        '餐饮' ||
        'restaurant' ||
        'cafe' ||
        'canteen' => PlaceCategory.food,
        'sports' || 'pitch' || 'sports_centre' || '运动' => PlaceCategory.sports,
        'services' ||
        '出入口' ||
        '公交站' ||
        '轨道交通' ||
        'post_office' ||
        'toilets' => PlaceCategory.services,
        _ => null,
      },
      buildingId: _text(data['building_id']),
      poiId: id,
      floorId: _text(data['floor_id']),
      navNodeId: _integer(data['nav_node_id']),
      center: _point(data['lng'], data['lat']),
    );
    _places[place.id] = place;
    return place;
  }

  /// 通用地物（道路/绿地/广场等）。与建筑、POI 并列的第三类地物：
  /// 没有楼层与室内结构，但有稳定编号，因此同样可以点开自己的详情页。
  CampusPlace _feature(Map<String, dynamic> data) {
    final id = _requiredInt(data['feature_id']);
    final kind = _text(data['kind']);
    final place = CampusPlace(
      id: 'feature:$id',
      name: _text(data['name']) ?? '',
      subtitle: featureKindLabel(kind),
      category: _featureCategory(kind),
      featureId: id,
      kind: kind,
      description: _text(data['description']) ?? '',
      center: _point(data['centroid_lng'], data['centroid_lat']),
    );
    _places[place.id] = place;
    return place;
  }

  /// 地物类别到 App 分类的映射：可归入四类筛选的归入，其余保持未分类
  /// （与 POI 的处理一致，不按名字猜测）。
  static PlaceCategory? _featureCategory(String? kind) => switch (kind) {
    'study' => PlaceCategory.study,
    'food' => PlaceCategory.food,
    'sports' => PlaceCategory.sports,
    'gate' ||
    'bus_stop' ||
    'parking' ||
    'shop' ||
    'service' ||
    'facility' => PlaceCategory.services,
    _ => null,
  };

  @override
  Future<CampusFloorSnapshot> loadFloor(
    String buildingId,
    String floorId,
  ) async {
    final results = await Future.wait([
      _request('/floors/${Uri.encodeComponent(floorId)}/features', raw: true),
      _request('/pois', query: {'building_id': buildingId, 'limit': 100}),
    ]);
    final pois = _objects(results[1]['pois']);
    for (final poi in pois) {
      _poi(poi);
    }
    final features = <Map<String, dynamic>>[];
    final rooms = <CampusRoom>[];
    for (final feature in _features(results[0])) {
      final properties = _properties(feature);
      final kind = _text(properties['kind']);
      final id = _text(properties['feature_id']);
      if (id != null && (kind == 'room' || kind == 'facility')) {
        var poiId = _integer(properties['poi_id']);
        var nodeId = _integer(properties['nav_node_id']);
        for (final poi in pois) {
          if (_text(poi['floor_id']) != floorId) continue;
          // Only explicit identifiers can link a feature to a POI.
          final linked =
              (poiId != null && _integer(poi['poi_id']) == poiId) ||
              (nodeId != null && _integer(poi['nav_node_id']) == nodeId) ||
              (_text(poi['feature_id']) == id);
          if (linked) {
            poiId ??= _integer(poi['poi_id']);
            nodeId ??= _integer(poi['nav_node_id']);
            break;
          }
        }
        rooms.add(
          CampusRoom(
            id: id,
            name:
                _text(properties['name']) ??
                _text(properties['room_code']) ??
                '',
            floorId: floorId,
            isFacility: kind == 'facility',
            poiId: poiId,
            navNodeId: nodeId,
          ),
        );
        properties['room_id'] = id;
      }
      features.add(
        _withProperties(feature, {
          ...properties,
          'building_id': buildingId,
          'floor_id': floorId,
        }),
      );
    }
    final snapshot = CampusFloorSnapshot(
      rooms: rooms,
      geoJson: _collection(features),
    );
    _floors[(buildingId, floorId)] = snapshot;
    return snapshot;
  }

  Future<Map<String, dynamic>> _placeRef(
    String id, {
    String? floorId,
    String? roomId,
    required bool accessible,
  }) async {
    var place = _places[id];
    final poiId = place?.poiId ?? _poiId(id);
    if (poiId != null && roomId == null) return {'poi_id': poiId};
    // 通用地物（道路/广场/绿地等）没有「入口」概念，直接导航到其中心点。
    if (place?.featureId != null && roomId == null) {
      final center = place!.center;
      if (center != null && center.isValid) {
        return {'lng': center.longitude, 'lat': center.latitude};
      }
      throw const CampusMapApiException('该地物缺少位置信息，暂时无法规划路线');
    }
    final buildingId = place?.buildingId ?? id;
    if (roomId != null) {
      if (floorId == null) {
        throw const CampusMapApiException('请先选择房间所在楼层');
      }
      final floor =
          _floors[(buildingId, floorId)] ??
          await loadFloor(buildingId, floorId);
      for (final room in floor.rooms) {
        if (room.id != roomId) continue;
        if (room.poiId != null) return {'poi_id': room.poiId};
        if (room.navNodeId != null) return {'node_id': room.navNodeId};
        break;
      }
      throw const CampusMapApiException('该房间尚未关联导航地点或节点，暂时无法规划到房间的路线');
    }
    final detail = await _detail(buildingId);
    place = _places[buildingId]!;
    if (floorId != null) {
      for (final floor in place.floors) {
        if (floor.id == floorId && floor.levelIndex != null) {
          return {'building_id': buildingId, 'level_index': floor.levelIndex};
        }
      }
      throw const CampusMapApiException('该楼层缺少导航楼层信息，暂时无法规划路线');
    }
    for (final entrance in _objects(detail['entrances'])) {
      if (accessible && entrance['is_accessible'] != true) continue;
      final nodeId = _integer(entrance['nav_node_id']);
      if (nodeId != null) return {'node_id': nodeId};
      final point = _point(entrance['lng'], entrance['lat']);
      if (point != null) return {'lng': point.longitude, 'lat': point.latitude};
    }
    throw CampusMapApiException(
      accessible ? '该建筑尚无可用的无障碍入口，暂时无法规划路线' : '该建筑尚无可用的入口数据，暂时无法规划路线',
    );
  }

  @override
  Future<CampusRouteResult?> planRoute(CampusRouteRequest request) async {
    final originPoint = request.originPoint;
    final origin = originPoint != null
        ? {'lng': originPoint.longitude, 'lat': originPoint.latitude}
        : await _placeRef(
            request.originPlaceId!,
            accessible: request.accessible,
          );
    final destination = await _placeRef(
      request.destinationPlaceId,
      floorId: request.destinationFloorId,
      roomId: request.destinationRoomId,
      accessible: request.accessible,
    );
    final result = await _request(
      '/route',
      method: 'POST',
      data: {
        'origin': origin,
        'destination': destination,
        'options': {'accessible_only': request.accessible},
      },
    );
    final features = <Map<String, dynamic>>[];
    final segments = _objects(result['segments']);
    for (final segment in segments) {
      if (segment['geometry'] == null) continue;
      final geometry = _object(segment['geometry']);
      final properties = Map<String, dynamic>.from(segment)..remove('geometry');
      if (properties['floor_id'] != null) {
        properties['floor_id'] = properties['floor_id'].toString();
      }
      features.addAll(
        _features(geometry)
            .map((feature) => _withProperties(feature, properties)),
      );
    }
    final steps = result['steps'];
    final instructions = steps is List
        ? steps.whereType<String>().toList()
        : [
            for (final segment in segments)
              if (_text(segment['instruction']) != null)
                segment['instruction'] as String,
          ];
    final length = _number(result['total_length_m']);
    return CampusRouteResult(
      geoJson: _collection(features),
      instructions: instructions,
      summary: length == null
          ? null
          : '全程 ${length.toStringAsFixed(length == length.roundToDouble() ? 0 : 1)} 米',
    );
  }

  @override
  Future<Map<String, dynamic>> locateWifi(
    List<Map<String, dynamic>> observations,
  ) => _request(
    '/locate/wifi',
    method: 'POST',
    data: {'observations': observations},
  );

  @override
  Future<Map<String, dynamic>> loadFingerprints({
    String? buildingId,
    String? floorId,
  }) => _request(
    '/fingerprints',
    query: {'building_id': ?buildingId, 'floor_id': ?floorId},
  );

  @override
  Future<Map<String, dynamic>> submitFingerprint(
    Map<String, dynamic> sample, {
    String? collectToken,
  }) => _request(
    '/fingerprints',
    method: 'POST',
    data: sample,
    headers: {'X-Collect-Token': ?collectToken},
  );

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsDio) _dio.close(force: true);
  }

  String _basicStyle(
    Map<String, dynamic> config,
    List<double>? bounds,
    String? attribution,
  ) {
    final tile = _text(config['tile_url']);
    final glyphs = _text(config['glyphs_url']);
    final sprites = _text(config['sprites_url']);
    return jsonEncode({
      'version': 8,
      'name': 'campus-basic',
      if (bounds != null)
        'center': [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2],
      if (bounds != null) 'zoom': 15,
      if (glyphs != null) 'glyphs': _resourceUrl(glyphs),
      if (sprites != null) 'sprite': _resourceUrl(sprites),
      'sources': {
        if (tile != null)
          'campus': {
            'type': 'vector',
            'tiles': [_resourceUrl(tile)],
            'bounds': ?bounds,
            'attribution': ?attribution,
          },
      },
      'layers': [
        {
          'id': 'background',
          'type': 'background',
          'paint': {'background-color': '#f2efe9'},
        },
        if (tile != null) ...[
          {
            'id': 'water',
            'type': 'fill',
            'source': 'campus',
            'source-layer': 'water',
            'paint': {'fill-color': '#a0c8f0'},
          },
          {
            'id': 'road-minor',
            'type': 'line',
            'source': 'campus',
            'source-layer': 'transportation',
            'filter': [
              'all',
              [
                '!',
                ['has', 'brunnel'],
              ],
            ],
            'paint': {'line-color': '#ffffff', 'line-width': 1.5},
          },
          {
            'id': 'building',
            'type': 'fill',
            'source': 'campus',
            'source-layer': 'building',
            'paint': {'fill-color': '#d9d0c7'},
          },
        ],
      ],
    });
  }

  static String? _text(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static String _requiredText(dynamic value) =>
      _text(value) ?? (throw const CampusMapApiException('地图服务返回的数据缺少必要字段'));

  static int? _integer(dynamic value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '');
  static int _requiredInt(dynamic value) =>
      _integer(value) ?? (throw const CampusMapApiException('地图服务返回的数据缺少有效编号'));
  static int? _poiId(String id) =>
      id.startsWith('poi:') ? int.tryParse(id.substring(4)) : null;
  static int? _featureId(String id) =>
      id.startsWith('feature:') ? int.tryParse(id.substring(8)) : null;
  static double? _number(dynamic value) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return number != null && number.isFinite ? number : null;
  }

  static GeoPoint? _point(dynamic lng, dynamic lat) {
    final longitude = _number(lng);
    final latitude = _number(lat);
    if (longitude == null || latitude == null) return null;
    final point = GeoPoint(longitude: longitude, latitude: latitude);
    return point.isValid ? point : null;
  }

  static List<double>? _bounds(dynamic value) {
    if (value is! List || value.length != 4) return null;
    final numbers = value.map(_number).whereType<double>().toList();
    return numbers.length == 4 ? numbers : null;
  }

  static Map<String, dynamic> _object(dynamic value) {
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        throw const CampusMapApiException('地图服务返回的数据格式不正确');
      }
    }
    if (value is Map<String, dynamic>) return Map<String, dynamic>.from(value);
    throw const CampusMapApiException('地图服务返回的数据格式不正确');
  }

  static List<Map<String, dynamic>> _objects(dynamic value) {
    if (value == null) return [];
    if (value is! List) throw const CampusMapApiException('地图服务返回的数据格式不正确');
    return value.map(_object).toList();
  }

  static Map<String, dynamic> _properties(Map<String, dynamic> feature) =>
      feature['properties'] == null ? {} : _object(feature['properties']);

  static List<Map<String, dynamic>> _features(Map<String, dynamic> value) {
    switch (value['type']) {
      case 'FeatureCollection':
        return _objects(value['features']);
      case 'Feature':
        return [value];
      case 'Point':
      case 'MultiPoint':
      case 'LineString':
      case 'MultiLineString':
      case 'Polygon':
      case 'MultiPolygon':
      case 'GeometryCollection':
        return [
          {
            'type': 'Feature',
            'properties': <String, dynamic>{},
            'geometry': value,
          },
        ];
      default:
        throw const CampusMapApiException('地图服务返回的地理数据格式不正确');
    }
  }

  static Map<String, dynamic> _withProperties(
    Map<String, dynamic> feature,
    Map<String, dynamic> properties,
  ) => {
    ...feature,
    'properties': {..._properties(feature), ...properties},
  };

  static Map<String, dynamic> _collection(
    List<Map<String, dynamic>> features,
  ) => {'type': 'FeatureCollection', 'features': features};
}
