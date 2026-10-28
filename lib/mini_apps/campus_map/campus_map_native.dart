import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'campus_map_canvas.dart';
import 'campus_map_data.dart';
import 'campus_map_heading.dart';
import 'campus_map_panels.dart';
import 'shuttle_stations.dart';
import 'shuttle_map_layer.dart';

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

class _CampusMapNativeState extends State<CampusMapNative>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shuttleAnimation;
  Map<String, GeoPoint> _shuttleOrigins = {};
  bool _shuttleUpdateQueued = false;
  bool _shuttleStationsDirty = true;
  int _shuttleStyleEpoch = 0;
  Timer? _shuttleCameraTimer;
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
    _shuttleAnimation =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 500),
          )
          ..value = 1
          ..addListener(_scheduleShuttleUpdate);
    // Android 上用 TextureView 承载地图，由 Flutter 当普通纹理层合成。插件默认的
    // SurfaceView + Virtual Display 在 release 包里时常出现多帧叠成一片、
    // 地图发白的重影。只影响合成方式，3D 体块、倾斜视角照常渲染；
    // 必须在第一张地图创建前设好（静态开关，这里早于本组件的 build）。
    MapLibreMap.useHybridComposition = true;
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
    if (!identical(old.shuttleVehicles, config.shuttleVehicles)) {
      final t = _shuttleAnimation.value;
      _shuttleOrigins = {
        for (final v in old.shuttleVehicles)
          v.id: GeoPoint(
            longitude:
                (_shuttleOrigins[v.id]?.longitude ?? v.point.longitude) *
                    (1 - t) +
                v.point.longitude * t,
            latitude:
                (_shuttleOrigins[v.id]?.latitude ?? v.point.latitude) *
                    (1 - t) +
                v.point.latitude * t,
          ),
      };
      if (config.mapLayer == CampusMapLayer.transit) {
        _shuttleAnimation.forward(from: 0);
      }
    }
    if (old.mapLayer != config.mapLayer) {
      _shuttleAnimation.stop();
      _shuttleAnimation.value = 1;
      _shuttleStationsDirty = true;
    }
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
            old.viewportInsets != config.viewportInsets) ||
        // 出现 / 更换路线时取景到整条路线；进出导航切换跟随视角。
        old.showRoute != config.showRoute ||
        !identical(old.routeGeoJson, config.routeGeoJson) ||
        old.navigating != config.navigating ||
        old.fitRoute != config.fitRoute ||
        (config.navigating && _followMoved(old, config));
    // 样式串变了：插件会原地 setStyle，旧样式上的自绘图层全部失效，
    // 等新样式的 onStyleLoaded 再从头同步（不销毁原生地图视图）。
    if (old.styleUrl != config.styleUrl) {
      _shuttleStyleEpoch++;
      _generation++;
      _ready = false;
      _startTimeout();
      return;
    }
    // 图层按组比对签名，只有输入真正变化的组才会重建（见 _sync）。
    final layersChanged = !_sameKeys(_keysFor(old), _keysFor(config));
    if (old.userHeading != config.userHeading) _syncHeading();
    if (!identical(old.routePassedGeoJson, config.routePassedGeoJson)) {
      _syncPassedRoute();
    }
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
          _scheduleShuttleUpdate();
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
      // 朝向只看「有没有」：角度变化走 _syncHeading，不重建图层。
      [user?.latitude, user?.longitude, v.userHeading != null],
      [v.mapLayer == CampusMapLayer.transit],
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
    10 => _addUser(c, value),
    _ => _addShuttle(c, value),
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

  String? _symbolStyle;
  String? _symbolLayerId;

  /// 底图样式里第一个 symbol（文字/图标）图层的 id，按样式串缓存。
  /// 样式是地址而非内联 JSON、或没有文字图层时返回 null（照旧叠在最上层）。
  String? _firstSymbolLayerId(String style) {
    if (style == _symbolStyle) return _symbolLayerId;
    _symbolStyle = style;
    _symbolLayerId = null;
    try {
      final parsed = jsonDecode(style);
      final layers = parsed is Map ? parsed['layers'] : null;
      if (layers is List) {
        for (final layer in layers) {
          if (layer is Map &&
              layer['type'] == 'symbol' &&
              layer['id'] is String) {
            _symbolLayerId = layer['id'] as String;
            break;
          }
        }
      }
    } catch (_) {
      // 非 JSON（样式地址）：无从得知图层顺序。
    }
    return _symbolLayerId;
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
        // 插在底图第一个文字图层下面：自绘图层默认叠在整套样式最上层，
        // 体块会把楼名、道路名等底图标注盖住。
        belowLayerId: _firstSymbolLayerId(value.styleUrl),
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

  Future<void> _addShuttle(
    MapLibreMapController c,
    CampusMapCanvas value,
  ) async {
    if (value.mapLayer != CampusMapLayer.transit) return;
    final epoch = _shuttleStyleEpoch;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final iconScale = Theme.of(context).platform == TargetPlatform.android
        ? 1 / ratio
        : 1.0;
    // 图标是地图上的固定设计素材，沿用已审核的天蓝与离线灰。
    final online = await ShuttleMapLayer.icon(const Color(0xFF409CE8), ratio);
    final offline = await ShuttleMapLayer.icon(const Color(0xFF929AA3), ratio);
    if (!mounted || epoch != _shuttleStyleEpoch) return;
    await c.addImage('shuttle-online', online);
    await c.addImage('shuttle-offline', offline);
    await _source(
      c,
      'shuttle-stations',
      ShuttleMapLayer.stations(List.filled(shuttleStations.length, 0)),
    );
    await c.addCircleLayer(
      'shuttle-stations',
      'shuttle-stop-dots',
      const CircleLayerProperties(
        circleColor: '#E67E22',
        circleRadius: 5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      ),
      enableInteraction: false,
    );
    _layer('shuttle-stop-dots');
    await c.addSymbolLayer(
      'shuttle-stations',
      'shuttle-stop-labels',
      const SymbolLayerProperties(
        textField: ['get', 'name'],
        textFont: ['Noto Sans Regular'],
        textSize: 12,
        textColor: '#20252D',
        textHaloColor: '#FFFFFF',
        textHaloWidth: 1.5,
        textAnchor: 'top',
        textOffset: [0, .8],
        textAllowOverlap: false,
        textIgnorePlacement: false,
      ),
      enableInteraction: false,
    );
    _layer('shuttle-stop-labels');
    await _source(
      c,
      'shuttle-vehicles',
      ShuttleMapLayer.vehicles(
        config.shuttleVehicles,
        config.shuttleDirections,
        _shuttleOrigins,
        _shuttleAnimation.value,
      ),
    );
    await c.addSymbolLayer(
      'shuttle-vehicles',
      'shuttle-vehicle-icons',
      SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconRotate: ['get', 'heading'],
        iconRotationAlignment: 'map',
        iconPitchAlignment: 'map',
        iconAnchor: 'center',
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
        iconSize: iconScale,
      ),
      enableInteraction: false,
    );
    _layer('shuttle-vehicle-icons');
    _shuttleStationsDirty = true;
  }

  // 与既有图层同步共用串行队列，每帧合并为至多一个待处理的 source 更新。
  void _scheduleShuttleUpdate() {
    if (!mounted ||
        !_ready ||
        config.mapLayer != CampusMapLayer.transit ||
        _shuttleUpdateQueued) {
      return;
    }
    _shuttleUpdateQueued = true;
    final epoch = _shuttleStyleEpoch;
    _queue = _queue.then((_) async {
      _shuttleUpdateQueued = false;
      final c = _controller;
      if (!mounted ||
          !_ready ||
          c == null ||
          epoch != _shuttleStyleEpoch ||
          config.mapLayer != CampusMapLayer.transit ||
          !_hasLayer('shuttle-vehicle-icons')) {
        return;
      }
      try {
        if (_shuttleStationsDirty) {
          _shuttleStationsDirty = false;
          final pixels = await c.toScreenLocationBatch([
            for (final station in shuttleStations) ...[
              LatLng(station.first.latitude, station.first.longitude),
              LatLng(station.second.latitude, station.second.longitude),
            ],
          ]);
          if (!mounted || epoch != _shuttleStyleEpoch || !_ready) return;
          final scale = Theme.of(context).platform == TargetPlatform.android
              ? MediaQuery.devicePixelRatioOf(context)
              : 1.0;
          final distances = [
            for (var i = 0; i < pixels.length; i += 2)
              ShuttleMapLayer.screenDistance(pixels[i], pixels[i + 1], scale),
          ];
          await c.setGeoJsonSource(
            'shuttle-stations',
            ShuttleMapLayer.stations(distances),
          );
        }
        await c.setGeoJsonSource(
          'shuttle-vehicles',
          ShuttleMapLayer.vehicles(
            config.shuttleVehicles,
            config.shuttleDirections,
            _shuttleOrigins,
            _shuttleAnimation.value,
          ),
        );
      } catch (_) {
        // 样式切换期间原生 source 可能已释放，下一次同步恢复当前状态。
        _shuttleStationsDirty = true;
      }
    });
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
      // 朝向光束：画在蓝点下面，随手机朝向转动（相对正北，地图旋转时自动跟着转）。
      if (value.userHeading != null) {
        await c.addImage(_headingImage, await _headingBeam());
        await c.addSymbolLayer(
          'campus-user',
          'campus-user-heading',
          _headingProps(value.userHeading!),
          enableInteraction: false,
        );
        _layer('campus-user-heading');
        _appliedHeading = value.userHeading;
      }
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

  static const _headingImage = 'campus-user-heading-beam';

  /// 光束图标的逻辑尺寸（dp），蓝点在正中，扇形朝上。
  static const double _beamSize = 76;
  Uint8List? _beamBytes;
  double? _beamRatio;
  double? _appliedHeading;
  DateTime _headingSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 朝向光束图：按屏幕像素密度绘制，插件按设备密度解码，显示出来就是 [_beamSize] dp。
  Future<Uint8List> _headingBeam() async {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final cached = _beamBytes;
    if (cached != null && _beamRatio == ratio) return cached;
    final size = _beamSize * ratio;
    final center = Offset(size / 2, size / 2);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final radius = size / 2;
    final beam = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        -pi / 2 - pi / 5,
        2 * pi / 5,
        false,
      )
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..shader = ui.Gradient.radial(center, radius, const [
          Color(0x991475F5),
          Color(0x001475F5),
        ]),
    );
    final image = await recorder.endRecording().toImage(
      size.ceil(),
      size.ceil(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final bytes = data!.buffer.asUint8List();
    _beamBytes = bytes;
    _beamRatio = ratio;
    return bytes;
  }

  SymbolLayerProperties _headingProps(double heading) => SymbolLayerProperties(
    iconImage: _headingImage,
    iconRotate: heading,
    iconRotationAlignment: 'map',
    iconPitchAlignment: 'map',
    iconAllowOverlap: true,
    iconIgnorePlacement: true,
    iconAnchor: 'center',
  );

  /// 朝向变化只改图层的旋转角，不重建定位图层；转动不足 3° 或间隔不足 80ms 时跳过。
  void _syncHeading() {
    final c = _controller;
    final heading = config.userHeading;
    if (c == null || heading == null || !_hasLayer('campus-user-heading')) {
      return;
    }
    final applied = _appliedHeading;
    final now = DateTime.now();
    if (applied != null &&
        (headingDelta(applied, heading).abs() < 3 ||
            now.difference(_headingSentAt) <
                const Duration(milliseconds: 80))) {
      return;
    }
    _appliedHeading = heading;
    _headingSentAt = now;
    unawaited(
      c
          .setLayerProperties('campus-user-heading', _headingProps(heading))
          .catchError((Object _) {}),
    );
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
    if (route == null) return;
    await _source(c, 'campus-route', route);
    // 仿百度：白色描边 + 粗蓝线，压在底图道路上依然醒目。
    await c.addLineLayer(
      'campus-route',
      'campus-route-casing',
      const LineLayerProperties(
        lineColor: '#FFFFFF',
        lineWidth: 11,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      enableInteraction: false,
    );
    _layer('campus-route-casing');
    await c.addLineLayer(
      'campus-route',
      'campus-route-line',
      const LineLayerProperties(
        lineColor: '#1475F5',
        lineWidth: 7,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      enableInteraction: false,
    );
    _layer('campus-route-line');
    // 导航中已走过的部分：灰线盖在蓝线上，数据由 _syncPassedRoute 原地更新。
    await _source(
      c,
      'campus-route-passed',
      value.floor == null && value.routePassedGeoJson != null
          ? value.routePassedGeoJson!
          : _emptyCollection,
    );
    await c.addLineLayer(
      'campus-route-passed',
      'campus-route-passed-line',
      const LineLayerProperties(
        lineColor: '#A6AFBB',
        lineWidth: 7,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      enableInteraction: false,
    );
    _layer('campus-route-passed-line');
    // 起点绿点、终点红点。
    final ends = _routeEnds(value.routeGeoJson);
    if (ends != null) {
      await _source(c, 'campus-route-ends', {
        'type': 'FeatureCollection',
        'features': [
          for (final (kind, point) in [('start', ends.$1), ('end', ends.$2)])
            {
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': point},
              'properties': {'kind': kind},
            },
        ],
      });
      await c.addCircleLayer(
        'campus-route-ends',
        'campus-route-ends-dot',
        const CircleLayerProperties(
          circleColor: [
            'match',
            ['get', 'kind'],
            'start',
            '#34A853',
            '#E5484D',
          ],
          circleRadius: 7,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
        enableInteraction: false,
      );
      _layer('campus-route-ends-dot');
    }
  }

  static const _emptyCollection = <String, dynamic>{
    'type': 'FeatureCollection',
    'features': <Object>[],
  };

  /// 整条路线的首尾坐标（[经度, 纬度]）；没有可用几何时为 null。
  static (List<double>, List<double>)? _routeEnds(Map<String, dynamic>? data) {
    final coordinates = <List<double>>[];
    for (final feature
        in (data?['features'] as List? ?? const []).whereType<Map>()) {
      final geometry = feature['geometry'];
      if (geometry is! Map) continue;
      final raw = geometry['coordinates'];
      final lines = switch (geometry['type']) {
        'LineString' => [raw],
        'MultiLineString' when raw is List => raw,
        _ => const [],
      };
      for (final line in lines) {
        if (line is! List) continue;
        for (final c in line) {
          if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
            coordinates.add([
              (c[0] as num).toDouble(),
              (c[1] as num).toDouble(),
            ]);
          }
        }
      }
    }
    if (coordinates.length < 2) return null;
    return (coordinates.first, coordinates.last);
  }

  /// 已走过路线只换数据，不动图层（每次定位都会变）。
  void _syncPassedRoute() {
    final c = _controller;
    if (c == null || !_hasLayer('campus-route-passed-line')) return;
    final data = config.floor == null && config.routePassedGeoJson != null
        ? config.routePassedGeoJson!
        : _emptyCollection;
    unawaited(
      c.setGeoJsonSource('campus-route-passed', data).catchError((Object _) {}),
    );
  }

  /// 导航跟随点移动 1 米以上或前进方向变化 3° 以上才挪相机，避免抖动。
  static bool _followMoved(CampusMapCanvas old, CampusMapCanvas now) {
    final a = old.navPoint, b = now.navPoint;
    if ((a == null) != (b == null)) return true;
    if (a != null && b != null) {
      final dLat = (a.latitude - b.latitude) * 111320;
      final dLng =
          (a.longitude - b.longitude) * 111320 * cos(a.latitude * pi / 180);
      if (dLat * dLat + dLng * dLng >= 1) return true;
    }
    final x = old.navBearing, y = now.navBearing;
    if ((x == null) != (y == null)) return true;
    return x != null && y != null && headingDelta(x, y).abs() >= 3;
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
    // 楼宇/地物已有轮廓高亮（3D 下体块染色）时不再落图钉，免得盖住楼名；
    // 只有 POI 这类没有轮廓的点位才用图钉标出。
    final outlined =
        _hasLayer('campus-selected-fill') ||
        _hasLayer('campus-selected-feature') ||
        (city3d &&
            place.poiId == null &&
            featureId == null &&
            _hasLayer('campus-city3d-volume'));
    if (outlined) return;
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
    // 导航与路线预览独占相机：其余取景请求（定位回中、缩放等）视为已处理，
    // 退出后不再补放。
    if (config.navigating || config.showRoute) {
      _appliedFocus = config.focusToken;
      _appliedZoom = config.zoomDelta;
      _appliedReset = config.resetToken;
      _appliedLayer = config.mapLayer;
    }
    if (config.navigating) {
      await _followCamera(c, current);
      return;
    }
    final bounds = config.showRoute && config.fitRoute
        ? _routeBounds(config.routeGeoJson)
        : null;
    if (bounds != null) {
      final insets = config.viewportInsets;
      final update = CameraUpdate.newLatLngBounds(
        bounds,
        left: insets.left + 48,
        top: insets.top + 48,
        right: insets.right + 48,
        bottom: insets.bottom + 48,
      );
      if (MediaQuery.disableAnimationsOf(context)) {
        await c.moveCamera(update);
      } else {
        await c.animateCamera(
          update,
          duration: const Duration(milliseconds: 500),
        );
      }
      return;
    }
    // 导航中拖动过地图：保留用户视角，等「继续导航」再接管。
    if (config.showRoute && !config.fitRoute) return;
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

  /// 导航跟随：锁定在当前位置，按前进方向旋转、倾斜 50° 看前方（仿百度步行导航）。
  Future<void> _followCamera(
    MapLibreMapController c,
    CameraPosition? current,
  ) async {
    final point = config.navPoint ?? config.userPoint;
    if (point == null || !point.isValid) return;
    final camera = _insetAware(
      CameraPosition(
        target: LatLng(point.latitude, point.longitude),
        zoom: 18.6,
        bearing: config.navBearing ?? current?.bearing ?? 0,
        tilt: 50,
      ),
    );
    final update = CameraUpdate.newCameraPosition(camera);
    if (MediaQuery.disableAnimationsOf(context)) {
      await c.moveCamera(update);
    } else {
      await c.animateCamera(
        update,
        duration: const Duration(milliseconds: 900),
      );
    }
  }

  /// 路线外包框；没有可用几何时为 null。
  static LatLngBounds? _routeBounds(Map<String, dynamic>? data) {
    double? south, west, north, east;
    void visit(Object? node) {
      if (node is List &&
          node.length >= 2 &&
          node[0] is num &&
          node[1] is num) {
        final lng = (node[0] as num).toDouble(),
            lat = (node[1] as num).toDouble();
        south = south == null ? lat : min(south!, lat);
        north = north == null ? lat : max(north!, lat);
        west = west == null ? lng : min(west!, lng);
        east = east == null ? lng : max(east!, lng);
      } else if (node is List) {
        node.forEach(visit);
      }
    }

    for (final feature
        in (data?['features'] as List? ?? const []).whereType<Map>()) {
      final geometry = feature['geometry'];
      if (geometry is Map) visit(geometry['coordinates']);
    }
    if (south == null || west == null) return null;
    return LatLngBounds(
      southwest: LatLng(south!, west!),
      northeast: LatLng(north!, east!),
    );
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
    _shuttleStyleEpoch++;
    _shuttleCameraTimer?.cancel();
    _shuttleAnimation.dispose();
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
            _shuttleStyleEpoch++;
            _shuttleStationsDirty = true;
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
            _shuttleStationsDirty = true;
            _shuttleCameraTimer ??= Timer(
              const Duration(milliseconds: 100),
              () {
                _shuttleCameraTimer = null;
                _scheduleShuttleUpdate();
              },
            );
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
