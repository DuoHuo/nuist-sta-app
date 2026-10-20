import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'campus_map_canvas.dart';
import 'campus_map_data.dart';
import 'campus_map_panels.dart';

/// 赤道周长（米），Web Mercator 的标准常量。
const double _equatorCircumferenceM = 40075016.686;

/// 每度对应的米数：取墨卡托标准常量，保证与像素换算完全一致。
const double _metersPerDegree = _equatorCircumferenceM / 360.0;

/// 面板遮挡造成相机需要反向移动的经纬度偏移（度）。
///
/// 目标点始终落在视口中心，因此要让目标显示在「未遮挡区域」的中心，必须把相机
/// 中心反向移动相应距离。以米为中间量，任意朝向下都成立：
///   地面米/像素 = 40075016.686 × cos(φ) / (512 × 2^zoom)
///   屏幕竖直方向在倾斜视角下按 1/cos(tilt) 拉长
///   屏幕「上」方向对应方位角 bearing（0 = 正北）
({double latitude, double longitude}) cameraInsetOffset({
  required double latitude,
  required double zoom,
  required EdgeInsets insets,
  double bearing = 0,
  double tilt = 0,
}) {
  if (insets == EdgeInsets.zero || zoom <= 0) {
    return (latitude: 0, longitude: 0);
  }
  final worldPx = 512.0 * pow(2.0, zoom);
  if (!worldPx.isFinite || worldPx <= 0) return (latitude: 0, longitude: 0);
  final radians = latitude * pi / 180.0;
  final cosLat = cos(radians);
  if (cosLat <= 0) return (latitude: 0, longitude: 0);
  final metersPerPixel = _equatorCircumferenceM * cosLat / worldPx;
  final tiltRadians = tilt.clamp(0.0, 60.0) * pi / 180.0;
  final tiltStretch = 1 / cos(tiltRadians);

  // 竖直遮挡（下-上）：内容需上移 (bottom-top)/2 像素 → 相机向南的反方向。
  final verticalMeters =
      ((insets.bottom - insets.top) / 2) * tiltStretch * metersPerPixel;
  // 水平遮挡（左-右）：内容需右移 (left-right)/2 像素。
  final horizontalMeters = ((insets.left - insets.right) / 2) * metersPerPixel;

  final bearingRadians = bearing * pi / 180.0;
  final northMeters =
      -verticalMeters * cos(bearingRadians) +
      horizontalMeters * sin(bearingRadians);
  final eastMeters =
      -verticalMeters * sin(bearingRadians) -
      horizontalMeters * cos(bearingRadians);

  return (
    latitude: northMeters / _metersPerDegree,
    longitude: eastMeters / (_metersPerDegree * cosLat),
  );
}

class CampusMapNative extends StatefulWidget {
  const CampusMapNative({super.key, required this.configuration});
  final CampusMapCanvas configuration;
  @override
  State<CampusMapNative> createState() => _CampusMapNativeState();
}

class _CampusMapNativeState extends State<CampusMapNative> {
  MapLibreMapController? _controller;
  CameraPosition? _overviewCamera;
  bool _ready = false;
  bool _cameraPending = true;
  String? _error;
  int _generation = 0;
  int _mapRevision = 0;
  int _appliedZoom = 0;
  int _appliedReset = 0;
  int _appliedFocus = 0;
  CampusMapLayer _appliedLayer = CampusMapLayer.standard;
  CameraPosition? _camera;
  double? _appliedLabelOffsetEm;
  Timer? _loadTimeout;
  Future<void> _queue = Future.value();
  // 已挂载的数据源与图层（按挂载顺序），group 为所属图层组序号。
  final _sources = <({String id, int group})>[];
  final _layers = <({String id, int group})>[];
  List<List<Object?>> _appliedKeys = const [];
  int _group = 0;
  CampusMapCanvas get config => widget.configuration;

  @override
  void initState() {
    super.initState();
    _startTimeout();
  }

  void _startTimeout() {
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 25), () {
      if (mounted && !_ready) setState(() => _error = '地图加载超时，请检查网络后重试');
    });
  }

  @override
  void didUpdateWidget(covariant CampusMapNative oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.configuration;
    _cameraPending =
        _cameraPending ||
        old.selectedPlace?.id != config.selectedPlace?.id ||
        old.floor?.id != config.floor?.id ||
        old.resetToken != config.resetToken ||
        old.zoomDelta != config.zoomDelta ||
        // 定位点只是图层数据，不应把用户正在浏览的相机（含 3D 倾角）拽回去；
        // 回中定位走 focusToken。
        old.focusToken != config.focusToken ||
        // 图层模式切换（如 3D 城市 ↔ 标准）需要调整相机倾角。
        old.mapLayer != config.mapLayer ||
        // 面板高度变化时重新内缩，选中目标始终停在可视区中心。
        (config.selectedPlace != null &&
            old.viewportInsets != config.viewportInsets);
    // 样式串变了：插件会原地 setStyle，旧样式上的自绘图层全部失效，
    // 等新样式的 onStyleLoaded 再从头同步（不销毁原生地图视图）。
    if (old.styleUrl != config.styleUrl) {
      _generation++;
      _ready = false;
      _startTimeout();
      return;
    }
    // 图层按组比对签名，只有输入真正变化的组才会重建（见 _sync）。
    final layersChanged = !_sameKeys(_keysFor(old), _keysFor(config));
    // 面板拖动只调整相机内缩，不必重建图层。
    if (layersChanged) {
      _enqueue(sync: true);
    } else if (_cameraPending) {
      _enqueue(sync: false);
    }
  }

  void _enqueue({bool sync = true}) {
    final generation = ++_generation;
    _queue = _queue.then((_) async {
      if (!mounted || !_ready || generation != _generation) return;
      final c = _controller;
      if (c == null) return;
      try {
        if (sync) {
          await _sync(c, config);
          if (!mounted || generation != _generation) return;
        }
        if (_cameraPending) {
          await _updateCamera(c);
          if (mounted && generation == _generation) _cameraPending = false;
        }
        if (mounted && _error != null) setState(() => _error = null);
      } catch (_) {
        if (mounted && generation == _generation) {
          setState(() => _error = '地图图层加载失败，请重试');
        }
      }
    });
  }

  List<Map<String, dynamic>> _features(Map<String, dynamic>? data) =>
      (data?['features'] as List? ?? const [])
          .whereType<Map>()
          .map((f) => Map<String, dynamic>.from(f))
          .toList();
  Map<String, dynamic> _properties(Map<String, dynamic> feature) =>
      Map<String, dynamic>.from(feature['properties'] as Map? ?? const {});
  Map<String, dynamic>? _subset(
    Map<String, dynamic>? data,
    bool Function(Map<String, dynamic>) keep,
  ) => data == null
      ? null
      : {
          ...data,
          'features': _features(data)
              .where((f) => keep(_properties(f)))
              .toList(),
        };

  Future<void> _source(
    MapLibreMapController c,
    String id,
    Map<String, dynamic> data,
  ) async {
    await c.addGeoJsonSource(id, data);
    _sources.add((id: id, group: _group));
  }

  void _layer(String id) => _layers.add((id: id, group: _group));
  bool _hasLayer(String id) => _layers.any((layer) => layer.id == id);

  String? _selectedBuildingId(CampusMapCanvas value) =>
      value.selectedPlace?.buildingId ?? value.selectedPlace?.id;

  /// 各图层组的输入签名，顺序即叠放顺序（越靠后越在上层）。
  ///
  /// 变化频繁的组放在后面：某组变化时从它开始往后全部重建，
  /// 前面体积大的楼宇/地物数据不必再经平台通道重发。
  List<List<Object?>> _keysFor(CampusMapCanvas v) {
    final indoor = v.floor != null;
    final city3d = v.mapLayer == CampusMapLayer.city3d && !indoor;
    final user = v.userPoint;
    final center = v.selectedPlace?.center;
    return [
      [v.buildingGeoJson],
      [v.featuresGeoJson],
      [city3d, v.buildingGeoJson, v.places, if (city3d) v.selectedPlace?.id],
      [v.mapLayer == CampusMapLayer.transit, v.places],
      [
        _selectedBuildingId(v),
        v.floor?.id,
        v.ghostFloorsGeoJson,
        v.selectedPlace?.floors,
      ],
      [
        v.floorGeoJson,
        v.floor?.id,
        _selectedBuildingId(v),
        v.selectedRoom?.id,
        v.selectedPlace?.floors,
      ],
      [
        v.selectedPlace?.id,
        indoor,
        city3d,
        center?.latitude,
        center?.longitude,
      ],
      [v.showRoute, v.routeGeoJson, v.floor?.id, _selectedBuildingId(v)],
      [v.streetCoverage, v.streetCoverageGeoJson],
      [v.markerPlaces, indoor, v.selectedPlace?.id],
      [user?.latitude, user?.longitude],
    ];
  }

  /// 签名比对：数据对象按引用比较（不做深比较），标量按值比较。
  static bool _sameKey(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (identical(x, y)) continue;
      if (x is Map || x is Iterable || x != y) return false;
    }
    return true;
  }

  static bool _sameKeys(List<List<Object?>> a, List<List<Object?>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameKey(a[i], b[i])) return false;
    }
    return true;
  }

  /// 增量同步：找到第一个签名变化的组，移除它及其后各组的图层与数据源，
  /// 再按顺序重新挂载。中途失败时只记下已完成的组，下次从失败处续上。
  Future<void> _sync(MapLibreMapController c, CampusMapCanvas value) async {
    final keys = _keysFor(value);
    var from = 0;
    while (from < keys.length &&
        from < _appliedKeys.length &&
        _sameKey(keys[from], _appliedKeys[from])) {
      from++;
    }
    if (from == keys.length) return;
    for (final layer in _layers.reversed.toList()) {
      if (layer.group < from) continue;
      await c.removeLayer(layer.id);
      _layers.remove(layer);
    }
    for (final source in _sources.reversed.toList()) {
      if (source.group < from) continue;
      await c.removeSource(source.id);
      _sources.remove(source);
    }
    _appliedKeys = keys.sublist(0, from);
    for (var i = from; i < keys.length; i++) {
      _group = i;
      await _addGroup(i, c, value);
      _appliedKeys = [..._appliedKeys, keys[i]];
    }
  }

  Future<void> _addGroup(
    int group,
    MapLibreMapController c,
    CampusMapCanvas value,
  ) => switch (group) {
    0 => _addBuildingHits(c, value),
    1 => _addFeatureHits(c, value),
    2 => _addCity3d(c, value),
    3 => _addTransit(c, value),
    4 => _syncStackedFloors(c, value),
    5 => _addCurrentFloor(c, value),
    6 => _addHighlight(c, value),
    7 => _addRoute(c, value),
    8 => _addStreet(c, value),
    9 => _addMarkers(c, value),
    _ => _addUser(c, value),
  };

  Future<void> _addBuildingHits(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    // 户外只渲染底图本身：建筑与 POI 由底图样式呈现。楼宇轮廓以全透明图层
    // 挂载，仅作为点击命中区域（碰撞箱），不改变地图外观。
    final buildings = value.buildingGeoJson;
    if (buildings != null) {
      await _source(c, 'campus-buildings', buildings);
      await c.addFillLayer(
        'campus-buildings',
        'campus-buildings-hit',
        const FillLayerProperties(
          fillColor: '#000000',
          // 近乎全透明：肉眼不可见，但保留可查询性（0 不透明度在部分渲染器
          // 上会被查询跳过），从而只作碰撞箱使用。
          fillOpacity: 0.01,
          fillOutlineColor: 'rgba(0,0,0,0)',
        ),
      );
      _layer('campus-buildings-hit');
    }
  }

  Future<void> _addCity3d(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    final buildings = value.buildingGeoJson;
    // 3D 城市：建筑轮廓按楼层数拉伸成体块（无楼层数据时按 3 层估算）；
    // 室内分层模式下不叠加，避免与就地分层模型重合。
    if (value.mapLayer == CampusMapLayer.city3d &&
        value.floor == null &&
        buildings != null) {
      final heights = <String, double>{
        for (final place in value.places)
          if (place.poiId == null)
            place.id:
                (place.floors.isEmpty ? 3 : place.floors.length) *
                kDisplayFloorHeightM,
      };
      final extruded = <String, dynamic>{
        ...buildings,
        'features': [
          for (final feature in _features(buildings))
            {
              ...feature,
              'properties': {
                ..._properties(feature),
                'height_m':
                    heights[_properties(feature)['building_id']] ??
                    3 * kDisplayFloorHeightM,
              },
            },
        ],
      };
      await _source(c, 'campus-city3d', extruded);
      await c.addFillExtrusionLayer(
        'campus-city3d',
        'campus-city3d-volume',
        FillExtrusionLayerProperties(
          // 选中楼宇的体块染成浅蓝，3D 下不再另画平面高亮（会被体块盖住）。
          fillExtrusionColor: [
            'case',
            [
              '==',
              ['get', 'building_id'],
              _selectedBuildingId(value) ?? '',
            ],
            '#8DB8F5',
            '#DCE4EE',
          ],
          fillExtrusionOpacity: 0.85,
          fillExtrusionHeight: const ['get', 'height_m'],
        ),
        enableInteraction: false,
      );
      _layer('campus-city3d-volume');
    }
  }

  Future<void> _addTransit(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    // 公交地铁：高亮公交站类地物点位（按 kind 白名单匹配，不按名称猜测）。
    if (value.mapLayer == CampusMapLayer.transit) {
      const transitKinds = {'bus_stop', '公交站', '轨道交通'};
      final stops = [
        for (final place in value.places)
          if (transitKinds.contains(place.kind) &&
              place.center != null &&
              place.center!.isValid)
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
      ];
      if (stops.isNotEmpty) {
        await _source(c, 'campus-transit', {
          'type': 'FeatureCollection',
          'features': stops,
        });
        await c.addCircleLayer(
          'campus-transit',
          'campus-transit-stops',
          const CircleLayerProperties(
            circleColor: '#E67E22',
            circleRadius: 7,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2.5,
          ),
          enableInteraction: false,
        );
        _layer('campus-transit-stops');
      }
    }
  }

  Future<void> _addFeatureHits(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    // 通用地物：道路、绿地、广场等由管理台提交的地物。视觉由底图瓦片负责，
    // 这里只挂三层不可见的命中体（与 campus-buildings-hit 同一套做法），供点击命中。
    // 用近零不透明度而不是 0：完全透明的图层会被命中查询跳过，0.01 肉眼不可见
    // 但仍能被 queryRenderedFeatures 命中。
    // 几何分工：面层只画面、线层画线与面的轮廓；圆层必须显式过滤 Point ——
    // 否则圆层会把面/线的每个顶点都画成一个圆点（跑道 118 个顶点那种）。
    final features = value.featuresGeoJson;
    final featureRows = features == null ? null : features['features'];
    if (features != null && featureRows is List && featureRows.isNotEmpty) {
      await _source(c, 'campus-features', features);
      await c.addFillLayer(
        'campus-features',
        'campus-features-fill',
        const FillLayerProperties(
          fillColor: '#000000',
          fillOpacity: 0.01,
          fillOutlineColor: 'rgba(0,0,0,0)',
        ),
      );
      _layer('campus-features-fill');
      await c.addLineLayer(
        'campus-features',
        'campus-features-line',
        const LineLayerProperties(
          lineColor: '#000000',
          lineOpacity: 0.01,
          lineWidth: 1.8,
        ),
      );
      _layer('campus-features-line');
      await c.addCircleLayer(
        'campus-features',
        'campus-features-point',
        const CircleLayerProperties(
          circleColor: '#000000',
          circleOpacity: 0.01,
          circleRadius: 5,
        ),
        filter: [
          '==',
          ['geometry-type'],
          'Point',
        ],
      );
      _layer('campus-features-point');
    }
  }

  Future<void> _addUser(MapLibreMapController c, CampusMapCanvas value) async {
    final user = value.userPoint;
    if (user != null && user.isValid) {
      await _source(c, 'campus-user', {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [user.longitude, user.latitude],
            },
            'properties': const <String, dynamic>{'kind': 'user'},
          },
        ],
      });
      await c.addCircleLayer(
        'campus-user',
        'campus-user-halo',
        const CircleLayerProperties(
          circleColor: '#1475F5',
          circleOpacity: 0.18,
          circleRadius: 16,
        ),
        enableInteraction: false,
      );
      _layer('campus-user-halo');
      await c.addCircleLayer(
        'campus-user',
        'campus-user-dot',
        const CircleLayerProperties(
          circleColor: '#1475F5',
          circleRadius: 7,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
        enableInteraction: false,
      );
      _layer('campus-user-dot');
    }
  }

  Future<void> _addCurrentFloor(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    final floor = value.floor == null
        ? null
        : _subset(
            value.floorGeoJson,
            (p) =>
                p['building_id'] ==
                    (value.selectedPlace?.buildingId ??
                        value.selectedPlace?.id) &&
                p['floor_id'] == value.floor?.id,
          );
    if (floor != null) {
      await _source(c, 'campus-floor', floor);
      // 当前楼层做成有厚度的楼板并抬到该层高度，房间/走廊按类型着色；
      // 平面填充在这里不再使用，否则俯视时会与楼板重影。
      await c.addFillExtrusionLayer(
        'campus-floor',
        'campus-floor-slab',
        FillExtrusionLayerProperties(
          fillExtrusionColor: [
            'case',
            [
              '==',
              ['get', 'room_id'],
              value.selectedRoom?.id ?? '',
            ],
            '#8FBEFF',
            [
              '==',
              ['get', 'kind'],
              'corridor',
            ],
            '#F7F5EF',
            [
              '==',
              ['get', 'kind'],
              'facility',
            ],
            '#CFE3F7',
            [
              '==',
              ['get', 'kind'],
              'door',
            ],
            '#EFE6DA',
            '#D6E6FB',
          ],
          fillExtrusionOpacity: 1,
          // MapLibre 的 base/height 是棱柱的两个绝对高度端点（不是厚度），
          // height < base 时墙面会在两者之间倒挂拉伸，必须把顶面算成绝对值。
          fillExtrusionHeight:
              _floorBase(value, value.floor?.id) + kFloorSlabThicknessM,
          fillExtrusionBase: _floorBase(value, value.floor?.id),
        ),
        filter: [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['room', 'corridor', 'facility', 'door'],
          ],
        ],
        enableInteraction: true,
      );
      _layer('campus-floor-slab');
      // Only supplied wall polygons are extruded; room polygons stay roofless.
      await c.addFillExtrusionLayer(
        'campus-floor',
        'campus-floor-walls',
        FillExtrusionLayerProperties(
          fillExtrusionColor: '#B9C4D0',
          // 顶面 = 楼层底面 + 墙基座 + 墙高（绝对高度，见上楼板注释）。
          fillExtrusionHeight: [
            '+',
            _floorBase(value, value.floor?.id),
            [
              'coalesce',
              ['get', 'base_m'],
              0,
            ],
            ['get', 'height_m'],
          ],
          fillExtrusionBase: [
            '+',
            _floorBase(value, value.floor?.id),
            [
              'coalesce',
              ['get', 'base_m'],
              0,
            ],
          ],
          fillExtrusionOpacity: 1,
        ),
        filter: [
          'all',
          [
            '==',
            ['get', 'kind'],
            'wall',
          ],
          ['has', 'height_m'],
        ],
        enableInteraction: false,
      );
      _layer('campus-floor-walls');
      // 门牌标注：贴在当前层楼板顶面上。MapLibre Native 尚不支持
      // symbol-z-elevate，用 textOffset 按「楼层高度 × sin(倾角)」手动抬升，
      // 相机变化时动态校正（见 _syncLabelOffset）。
      final labelOffset = _labelOffsetEm(c);
      await c.addSymbolLayer(
        'campus-floor',
        'campus-floor-room-labels',
        _roomLabelProps(labelOffset),
        filter: [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['room', 'facility'],
          ],
        ],
        enableInteraction: false,
      );
      _layer('campus-floor-room-labels');
      _appliedLabelOffsetEm = labelOffset;
    }
  }

  Future<void> _addRoute(MapLibreMapController c, CampusMapCanvas value) async {
    final route = value.showRoute
        ? _subset(
            value.routeGeoJson,
            (p) => value.floor == null
                ? p['floor_id'] == null
                : p['floor_id'] == value.floor!.id &&
                      p['building_id'] ==
                          (value.selectedPlace?.buildingId ??
                              value.selectedPlace?.id),
          )
        : null;
    if (route != null) {
      await _source(c, 'campus-route', route);
      await c.addLineLayer(
        'campus-route',
        'campus-route-line',
        const LineLayerProperties(
          lineColor: '#1475F5',
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      _layer('campus-route-line');
    }
  }

  Future<void> _addStreet(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    if (value.streetCoverage && value.streetCoverageGeoJson != null) {
      await _source(c, 'campus-street', value.streetCoverageGeoJson!);
      await c.addLineLayer(
        'campus-street',
        'campus-street-line',
        const LineLayerProperties(lineColor: '#109DBE', lineWidth: 4),
        filter: [
          '==',
          ['geometry-type'],
          'LineString',
        ],
        enableInteraction: false,
      );
      _layer('campus-street-line');
      await c.addCircleLayer(
        'campus-street',
        'campus-street-points',
        const CircleLayerProperties(
          circleColor: '#1475F5',
          circleRadius: 7,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
        filter: [
          '==',
          ['geometry-type'],
          'Point',
        ],
        enableInteraction: false,
      );
      _layer('campus-street-points');
    }
  }

  /// 选中高亮（仅户外）：楼宇/地物轮廓描蓝，并在中心点落一枚红色图钉，
  /// 让点选有明确的地图反馈。复用碰撞箱数据源按编号过滤，不重发几何。
  Future<void> _addHighlight(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    final place = value.selectedPlace;
    if (place == null || value.floor != null) return;
    final city3d = value.mapLayer == CampusMapLayer.city3d;
    final featureId = place.featureId;
    if (place.poiId == null &&
        featureId == null &&
        !city3d &&
        _hasLayer('campus-buildings-hit')) {
      final filter = [
        '==',
        ['get', 'building_id'],
        _selectedBuildingId(value) ?? '',
      ];
      await c.addFillLayer(
        'campus-buildings',
        'campus-selected-fill',
        const FillLayerProperties(fillColor: '#1475F5', fillOpacity: 0.16),
        filter: filter,
        enableInteraction: false,
      );
      _layer('campus-selected-fill');
      await c.addLineLayer(
        'campus-buildings',
        'campus-selected-line',
        const LineLayerProperties(
          lineColor: '#1475F5',
          lineWidth: 2.5,
          lineJoin: 'round',
        ),
        filter: filter,
        enableInteraction: false,
      );
      _layer('campus-selected-line');
    } else if (featureId != null && _hasLayer('campus-features-fill')) {
      await c.addLineLayer(
        'campus-features',
        'campus-selected-feature',
        const LineLayerProperties(
          lineColor: '#1475F5',
          lineOpacity: 0.85,
          lineWidth: 4,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        filter: [
          '==',
          ['get', 'feature_id'],
          featureId,
        ],
        enableInteraction: false,
      );
      _layer('campus-selected-feature');
    }
    final center = place.center ?? place.entrance;
    if (center == null || !center.isValid) return;
    await _source(c, 'campus-selected-pin', {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [center.longitude, center.latitude],
          },
          'properties': const <String, dynamic>{},
        },
      ],
    });
    await c.addCircleLayer(
      'campus-selected-pin',
      'campus-selected-pin-halo',
      const CircleLayerProperties(
        circleColor: '#E8453C',
        circleOpacity: 0.2,
        circleRadius: 15,
      ),
      enableInteraction: false,
    );
    _layer('campus-selected-pin-halo');
    await c.addCircleLayer(
      'campus-selected-pin',
      'campus-selected-pin-dot',
      const CircleLayerProperties(
        circleColor: '#E8453C',
        circleRadius: 7.5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ),
      enableInteraction: false,
    );
    _layer('campus-selected-pin-dot');
  }

  /// 分类/搜索结果标注：按分类着色的圆点 + 名称，点击直接选中该地点。
  Future<void> _addMarkers(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    if (value.floor != null || value.markerPlaces.isEmpty) return;
    final selectedId = value.selectedPlace?.id;
    final features = [
      for (final place in value.markerPlaces)
        if (place.id != selectedId &&
            place.center != null &&
            place.center!.isValid)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [place.center!.longitude, place.center!.latitude],
            },
            'properties': {
              'place_id': place.id,
              'name': place.name,
              'color': _hex(categoryColor(place.category)),
            },
          },
    ];
    if (features.isEmpty) return;
    await _source(c, 'campus-markers', {
      'type': 'FeatureCollection',
      'features': features,
    });
    await c.addCircleLayer(
      'campus-markers',
      'campus-markers-dot',
      const CircleLayerProperties(
        circleColor: ['get', 'color'],
        circleRadius: 6.5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2.5,
      ),
      enableInteraction: false,
    );
    _layer('campus-markers-dot');
    await c.addSymbolLayer(
      'campus-markers',
      'campus-markers-label',
      const SymbolLayerProperties(
        textField: ['get', 'name'],
        textFont: ['Noto Sans Regular'],
        textSize: 11.5,
        textColor: '#20252D',
        textHaloColor: 'rgba(255,255,255,0.95)',
        textHaloWidth: 1.4,
        textAnchor: 'top',
        textOffset: [0, 0.9],
        textOptional: true,
      ),
      enableInteraction: false,
    );
    _layer('campus-markers-label');
  }

  static String _hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// 楼板厚度（米）。楼板是显示用的薄片，让每层在同一坐标系里可见。
  static const double kFloorSlabThicknessM = 0.8;

  /// 门牌标注的完整属性（setLayerProperties 会重置未列字段，必须全量下发）。
  SymbolLayerProperties _roomLabelProps(double offsetEm) =>
      SymbolLayerProperties(
        textField: [
          'coalesce',
          ['get', 'room_code'],
          ['get', 'name'],
        ],
        textFont: const ['Noto Sans Regular'],
        textSize: 11,
        textColor: [
          'case',
          [
            '==',
            ['get', 'room_id'],
            config.selectedRoom?.id ?? '',
          ],
          '#1475F5',
          '#37415C',
        ],
        textHaloColor: 'rgba(255,255,255,0.92)',
        textHaloWidth: 1.2,
        textOffset: [0, -offsetEm],
      );

  /// 门牌抬升量（em）：楼层顶面相对地面的屏幕上移 = 高度 × sin(倾角) / 地面分辨率。
  double _labelOffsetEm(MapLibreMapController c) {
    final cam = _camera ?? c.cameraPosition;
    final floorId = config.floor?.id;
    if (cam == null || floorId == null) return 0;
    final elevationM = _floorBase(config, floorId) + kFloorSlabThicknessM;
    final metersPerPixel =
        _equatorCircumferenceM *
        cos(cam.target.latitude * pi / 180) /
        (512 * pow(2, cam.zoom));
    if (!metersPerPixel.isFinite || metersPerPixel <= 0) return 0;
    final shiftPx =
        elevationM * sin(cam.tilt.clamp(0, 85) * pi / 180) / metersPerPixel;
    return shiftPx / 11; // 1em ≈ textSize（11px）
  }

  /// 相机倾角/缩放变化时校正门牌抬升量，变化不足 0.08em（约 1px）不打扰原生端。
  void _syncLabelOffset() {
    final c = _controller;
    if (c == null || !_hasLayer('campus-floor-room-labels')) return;
    final em = _labelOffsetEm(c);
    if (_appliedLabelOffsetEm != null &&
        (em - _appliedLabelOffsetEm!).abs() < 0.08) {
      return;
    }
    _appliedLabelOffsetEm = em;
    unawaited(
      c.setLayerProperties('campus-floor-room-labels', _roomLabelProps(em)),
    );
  }

  /// 某层的底面高度：优先后端 elevation_m，缺失时按层号推算。
  double _floorBase(CampusMapCanvas value, String? floorId) {
    for (final floor in value.selectedPlace?.floors ?? const <CampusFloor>[]) {
      if (floor.id == floorId) return floorBaseElevation(floor);
    }
    return 0;
  }

  /// 楼层叠放：每个楼层按自身海拔铺一块楼板，一层层叠起来；
  /// 当前层实色着色，下方楼层按距离递减透明度托底；
  /// 当前层上方的楼层不显示，避免遮挡当前层。
  Future<void> _syncStackedFloors(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    final floors = value.selectedPlace?.floors ?? const <CampusFloor>[];
    final current = value.floor;
    if (current == null || floors.isEmpty) return;
    final buildingId =
        value.selectedPlace?.buildingId ?? value.selectedPlace?.id ?? '';
    for (final floor in floors) {
      if (floor.id == current.id) continue;
      // 高于当前层的幽灵层会压在当前层上面，直接跳过。
      if (floor.number > current.number) continue;
      final raw = value.ghostFloorsGeoJson[floor.id];
      if (raw == null) continue;
      final subset = _subset(
        raw,
        (p) => p['building_id'] == buildingId && p['floor_id'] == floor.id,
      );
      if (subset == null || (subset['features'] as List).isEmpty) continue;
      final distance = (floor.number - current.number).abs();
      final opacity = (0.34 - 0.07 * distance).clamp(0.08, 0.34);
      final sourceId = 'campus-stack-${floor.id}';
      await _source(c, sourceId, subset);
      await c.addFillExtrusionLayer(
        sourceId,
        '$sourceId-slab',
        FillExtrusionLayerProperties(
          fillExtrusionColor: '#E3E9F0',
          fillExtrusionOpacity: opacity,
          // 顶面同样要是绝对高度，否则每层楼板会倒挂成通高立柱（重影根因）。
          fillExtrusionHeight:
              floorBaseElevation(floor) + kFloorSlabThicknessM * 0.4,
          fillExtrusionBase: floorBaseElevation(floor),
        ),
        filter: [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['room', 'corridor', 'facility', 'door'],
          ],
        ],
        enableInteraction: false,
      );
      _layer('$sourceId-slab');
    }
  }

  /// 命中选择：插件返回的 Feature 不带图层信息，因此按图层分别查询，
  /// 顺序为「当前楼层房间 → 建筑碰撞箱 → 街景覆盖」，取最先命中的目标。
  Future<void> _onTap(Point<double> point, LatLng _) async {
    final c = _controller;
    if (c == null || !_ready) return;
    // 插件用物理像素上报点击位置，查询矩形同为其坐标系。
    final rect = Rect.fromCenter(
      center: Offset(point.x, point.y),
      width: 48,
      height: 48,
    );
    Future<List> hitsOn(List<String> layerIds) =>
        c.queryRenderedFeaturesInRect(rect, layerIds, null);
    Map<String, dynamic> propertiesOf(Object? raw) => raw is Map
        ? Map<String, dynamic>.from(raw['properties'] as Map? ?? const {})
        : const {};
    try {
      if (_hasLayer('campus-markers-dot')) {
        for (final raw in await hitsOn(const [
          'campus-markers-dot',
          'campus-markers-label',
        ])) {
          final id = propertiesOf(raw)['place_id'];
          for (final place in config.markerPlaces) {
            if (place.id == id) {
              config.onPlaceSelected(place);
              return;
            }
          }
        }
      }
      if (config.floor != null && _hasLayer('campus-floor-slab')) {
        for (final raw in await hitsOn(const ['campus-floor-slab'])) {
          final p = propertiesOf(raw);
          for (final room in config.rooms) {
            if (room.id == p['room_id'] && room.floorId == config.floor!.id) {
              config.onRoomSelected(room);
              return;
            }
          }
        }
      }
      if (_hasLayer('campus-buildings-hit')) {
        for (final raw in await hitsOn(const ['campus-buildings-hit'])) {
          final id = propertiesOf(raw)['building_id'];
          for (final place in config.places) {
            if (place.poiId == null &&
                place.id == id &&
                place.name.trim().isNotEmpty) {
              config.onPlaceSelected(place);
              return;
            }
          }
        }
      }
      if (_hasLayer('campus-features-fill')) {
        final hits = await hitsOn(const [
          'campus-features-fill',
          'campus-features-line',
          'campus-features-point',
        ]);
        for (final raw in hits) {
          final id = propertiesOf(raw)['feature_id'];
          if (id is! num) continue;
          for (final place in config.places) {
            if (place.featureId == id.toInt()) {
              config.onPlaceSelected(place);
              return;
            }
          }
        }
      }
      if (config.streetCoverage && _hasLayer('campus-street-points')) {
        final street = await hitsOn(const [
          'campus-street-points',
          'campus-street-line',
        ]);
        for (final raw in street) {
          final id = propertiesOf(raw)['building_id'];
          for (final place in config.places) {
            if (place.id == id) {
              config.onStreetEntry?.call(place);
              return;
            }
          }
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '地图信息读取失败，请重试');
    }
  }

  /// 把相机目标从整屏中心挪到「未被面板遮挡区域」的中心。
  ///
  /// 倾斜视角下该换算不成立，室内（tilt 45）保持原样。
  CameraPosition _insetAware(CameraPosition camera) {
    final insets = config.viewportInsets;
    if (insets == EdgeInsets.zero) return camera;
    final offset = cameraInsetOffset(
      latitude: camera.target.latitude,
      zoom: camera.zoom,
      insets: insets,
      bearing: camera.bearing,
      tilt: camera.tilt,
    );
    if (offset.latitude == 0 && offset.longitude == 0) return camera;
    return CameraPosition(
      target: LatLng(
        camera.target.latitude + offset.latitude,
        camera.target.longitude + offset.longitude,
      ),
      zoom: camera.zoom,
      bearing: camera.bearing,
      tilt: camera.tilt,
    );
  }

  Future<void> _updateCamera(MapLibreMapController c) async {
    final current = c.cameraPosition;
    _overviewCamera ??= current;
    CameraPosition? camera;
    if (config.focusToken != _appliedFocus) {
      final user = config.userPoint;
      if (user != null && user.isValid) {
        // 直接用定位原始坐标居中，不做道路/路网吸附。
        camera = _insetAware(
          CameraPosition(
            target: LatLng(user.latitude, user.longitude),
            zoom: (current?.zoom ?? 15).clamp(16, 22),
            bearing: current?.bearing ?? 0,
            tilt: 0,
          ),
        );
        _appliedFocus = config.focusToken;
      }
    } else if (config.resetToken != _appliedReset ||
        config.selectedPlace == null) {
      final overview = _overviewCamera;
      if (overview != null) {
        final resetRequested = config.resetToken != _appliedReset;
        final city3d =
            config.mapLayer == CampusMapLayer.city3d && config.floor == null;
        camera = CameraPosition(
          target: overview.target,
          zoom: overview.zoom,
          bearing: overview.bearing,
          // 3D 城市下倾角由用户手势自由控制；仅显式重置时回到引导角 45°。
          tilt: city3d ? (resetRequested ? 45 : (current?.tilt ?? 45)) : 0.0,
        );
      }
      _appliedReset = config.resetToken;
    } else {
      final point =
          config.selectedPlace?.center ?? config.selectedPlace?.entrance;
      final city3d =
          config.mapLayer == CampusMapLayer.city3d && config.floor == null;
      // 户外默认倾角：3D 城市保留用户当前手势角度，标准地图俯视。
      final outdoorTilt = city3d ? (current?.tilt ?? 45) : 0.0;
      if (point != null && point.isValid) {
        camera = _insetAware(
          CameraPosition(
            target: LatLng(point.latitude, point.longitude),
            zoom: config.floor == null ? 17 : 18.7,
            // 室内用倾斜视角看分层楼板；方位角沿用当前值，便于左右环绕查看。
            bearing: current?.bearing ?? 0,
            tilt: config.floor == null ? outdoorTilt : 48,
          ),
        );
      } else if (current != null) {
        camera = CameraPosition(
          target: current.target,
          zoom: current.zoom,
          bearing: current.bearing,
          tilt: config.floor == null ? outdoorTilt : 45,
        );
      }
    }
    // 图层模式切换：进入 3D 城市给一次 45° 引导角（已在倾斜状态则保留用户角度），
    // 切回其余模式回到俯视；室内分层保持 48° 不动。
    if (config.mapLayer != _appliedLayer && current != null) {
      camera = CameraPosition(
        target: camera?.target ?? current.target,
        zoom: camera?.zoom ?? current.zoom,
        bearing: camera?.bearing ?? current.bearing,
        tilt: config.floor != null
            ? 48
            : (config.mapLayer == CampusMapLayer.city3d
                  ? (current.tilt > 1 ? current.tilt : 45)
                  : 0),
      );
      _appliedLayer = config.mapLayer;
    }
    if (config.zoomDelta != _appliedZoom && current != null) {
      camera = CameraPosition(
        target: current.target,
        zoom: (current.zoom + config.zoomDelta - _appliedZoom).clamp(0, 22),
        bearing: current.bearing,
        tilt: current.tilt,
      );
      _appliedZoom = config.zoomDelta;
    }
    if (camera != null) {
      final update = CameraUpdate.newCameraPosition(camera);
      if (MediaQuery.disableAnimationsOf(context)) {
        await c.moveCamera(update);
      } else {
        await c.animateCamera(
          update,
          duration: const Duration(milliseconds: 400),
        );
      }
    }
  }

  Future<void> _retry() async {
    _generation++;
    _ready = false;
    final epoch = _mapRevision;
    await _queue;
    if (!mounted || epoch != _mapRevision) return;
    _controller = null;
    _sources.clear();
    _layers.clear();
    _appliedKeys = const [];
    _queue = Future.value();
    _cameraPending = true;
    setState(() {
      _error = null;
      _mapRevision++;
    });
    _startTimeout();
  }

  @override
  void dispose() {
    _generation++;
    _loadTimeout?.cancel();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Stack(
      children: [
        MapLibreMap(
          key: ValueKey(_mapRevision),
          styleString: config.styleUrl,
          initialCameraPosition: null,
          onMapCreated: (c) => _controller = c,
          onStyleLoadedCallback: () {
            _loadTimeout?.cancel();
            // 新样式不含任何自绘图层：清空登记，整组重新挂载。排进队列执行，
            // 让旧样式上还没跑完的同步先收尾，避免它在清空后又登记旧图层。
            _queue = _queue.then((_) {
              _sources.clear();
              _layers.clear();
              _appliedKeys = const [];
              _ready = true;
            });
            _enqueue();
          },
          onMapClick: _onTap,
          // 点击落在可交互图层上时，插件默认不再回调 onMapClick；打开此项才能
          // 在点到建筑/房间时仍走统一命中逻辑。
          featureTapsTriggersMapClick: true,
          trackCameraPosition: true,
          onCameraMove: (position) {
            _camera = position;
            _syncLabelOffset();
          },
          compassEnabled: false,
          logoEnabled: false,
          attributionButtonPosition: AttributionButtonPosition.topRight,
          attributionButtonMargins: Point(
            16,
            MediaQuery.paddingOf(context).top + 174,
          ),
          rotateGesturesEnabled: true,
          tiltGesturesEnabled: true,
        ),
        if (_error != null)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 100,
            left: box.maxWidth >= 700 ? 390 : 16,
            right: 80,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, style: const TextStyle(fontSize: 13)),
                    TextButton(onPressed: _retry, child: const Text('重试')),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
