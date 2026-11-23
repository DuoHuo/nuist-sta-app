import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../core/logging/app_log.dart';
import 'campus_map_canvas.dart';
import 'campus_map_data.dart';
import 'campus_map_heading.dart';
import 'campus_map_panels.dart';
import 'shuttle_map_layer.dart';
import 'shuttle_models.dart';
import 'shuttle_stations.dart';

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

/// Lightweight bridge over [MapLibreMapController] for layer/source mutations.
///
/// Production uses [_MapLibreBridge] directly; tests can inspect or override
/// the bridge via [CampusMapNative.debugBridgeOverride].
@visibleForTesting
abstract interface class CampusMapBridge {
  CameraPosition? get cameraPosition;

  Future<void> addImage(String name, Uint8List bytes);

  Future<void> addGeoJsonSource(String sourceId, Map<String, dynamic> geojson);

  Future<void> setGeoJsonSource(String sourceId, Map<String, dynamic> geojson);

  Future<void> removeSource(String sourceId);

  Future<void> addFillLayer(
    String sourceId,
    String layerId,
    FillLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  });

  Future<void> addFillExtrusionLayer(
    String sourceId,
    String layerId,
    FillExtrusionLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  });

  Future<void> addLineLayer(
    String sourceId,
    String layerId,
    LineLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  });

  Future<void> addCircleLayer(
    String sourceId,
    String layerId,
    CircleLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  });

  Future<void> addSymbolLayer(
    String sourceId,
    String layerId,
    SymbolLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  });

  Future<void> setLayerProperties(String layerId, LayerProperties properties);

  Future<void> setLayerFilter(String layerId, dynamic filter);

  Future<void> removeLayer(String layerId);

  Future<List<dynamic>> queryRenderedFeaturesInRect(
    Rect rect,
    List<String> layerIds,
    String? filter,
  );

  Future<List<Point>> toScreenLocationBatch(Iterable<LatLng> latLngs);

  Future<bool?> moveCamera(CameraUpdate update);

  Future<bool?> animateCamera(CameraUpdate update, {Duration? duration});
}

final class _MapLibreBridge implements CampusMapBridge {
  _MapLibreBridge(this._controller);

  final MapLibreMapController _controller;

  @override
  CameraPosition? get cameraPosition => _controller.cameraPosition;

  @override
  Future<void> addImage(String name, Uint8List bytes) =>
      _controller.addImage(name, bytes);

  @override
  Future<void> addGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson,
  ) => _controller.addGeoJsonSource(sourceId, geojson);

  @override
  Future<void> setGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson,
  ) => _controller.setGeoJsonSource(sourceId, geojson);

  @override
  Future<void> removeSource(String sourceId) =>
      _controller.removeSource(sourceId);

  @override
  Future<void> addFillLayer(
    String sourceId,
    String layerId,
    FillLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) => _controller.addFillLayer(
    sourceId,
    layerId,
    properties,
    belowLayerId: belowLayerId,
    filter: filter,
    enableInteraction: enableInteraction,
  );

  @override
  Future<void> addFillExtrusionLayer(
    String sourceId,
    String layerId,
    FillExtrusionLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) => _controller.addFillExtrusionLayer(
    sourceId,
    layerId,
    properties,
    belowLayerId: belowLayerId,
    filter: filter,
    enableInteraction: enableInteraction,
  );

  @override
  Future<void> addLineLayer(
    String sourceId,
    String layerId,
    LineLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) => _controller.addLineLayer(
    sourceId,
    layerId,
    properties,
    belowLayerId: belowLayerId,
    filter: filter,
    enableInteraction: enableInteraction,
  );

  @override
  Future<void> addCircleLayer(
    String sourceId,
    String layerId,
    CircleLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) => _controller.addCircleLayer(
    sourceId,
    layerId,
    properties,
    belowLayerId: belowLayerId,
    filter: filter,
    enableInteraction: enableInteraction,
  );

  @override
  Future<void> addSymbolLayer(
    String sourceId,
    String layerId,
    SymbolLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) => _controller.addSymbolLayer(
    sourceId,
    layerId,
    properties,
    belowLayerId: belowLayerId,
    filter: filter,
    enableInteraction: enableInteraction,
  );

  @override
  Future<void> setLayerProperties(String layerId, LayerProperties properties) =>
      _controller.setLayerProperties(layerId, properties);

  @override
  Future<void> setLayerFilter(String layerId, dynamic filter) =>
      _controller.setLayerFilter(layerId, filter);

  @override
  Future<void> removeLayer(String layerId) => _controller.removeLayer(layerId);

  @override
  Future<List<dynamic>> queryRenderedFeaturesInRect(
    Rect rect,
    List<String> layerIds,
    String? filter,
  ) => _controller.queryRenderedFeaturesInRect(rect, layerIds, filter);

  @override
  Future<List<Point>> toScreenLocationBatch(Iterable<LatLng> latLngs) =>
      _controller.toScreenLocationBatch(latLngs);

  @override
  Future<bool?> moveCamera(CameraUpdate update) =>
      _controller.moveCamera(update);

  @override
  Future<bool?> animateCamera(CameraUpdate update, {Duration? duration}) =>
      _controller.animateCamera(update, duration: duration);
}

class CampusMapNative extends StatefulWidget {
  const CampusMapNative({super.key, required this.configuration});
  final CampusMapCanvas configuration;

  /// Minimum interval between intermediate shuttle GeoJSON pushes.
  @visibleForTesting
  static const Duration shuttleThrottleInterval = Duration(milliseconds: 33);

  /// Override clock for deterministic throttle unit/widget tests.
  @visibleForTesting
  static DateTime Function() debugClock = DateTime.now;

  /// Optional controller wrapper hook for unit/widget tests.
  @visibleForTesting
  static CampusMapBridge Function(MapLibreMapController controller)?
  debugBridgeOverride;

  @override
  State<CampusMapNative> createState() => _CampusMapNativeState();
}

class _CampusMapNativeState extends State<CampusMapNative>
    with SingleTickerProviderStateMixin {
  static final _log = AppLog.logger('campus_map.native');
  late final AnimationController _shuttleAnimation;
  Map<String, GeoPoint> _shuttleOrigins = {};
  bool _shuttleUpdateQueued = false;
  bool _shuttleStationsDirty = true;
  bool _shuttleForceFlush = false;
  int _shuttleStyleEpoch = 0;
  int _styleEpoch = 0;
  Duration? _lastShuttlePushElapsed;
  DateTime? _lastShuttleWallPushAt;
  List<ShuttleVehicle>? _lastShuttlePushedVehicles;
  Map<String, ShuttleDirection>? _lastShuttlePushedDirections;
  Map<String, GeoPoint>? _lastShuttlePushedOrigins;
  double? _lastShuttlePushedProgress;
  int? _lastShuttlePushedEpoch;
  Uint8List? _shuttleOnlineBytes;
  Uint8List? _shuttleOfflineBytes;
  double? _shuttleIconRatio;
  int? _shuttleImagesEpoch;
  Timer? _shuttleCameraTimer;
  CampusMapBridge? _bridge;
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
  Timer? _loadTimeout;
  Future<void> _queue = Future.value();
  // 已挂载的数据源与图层（按组序和挂载顺序保存），group 为所属图层组序号。
  final _sources = <({String id, int group})>[];
  final _layers = <({String id, int group})>[];

  // 各图层组已同步到原生端的输入/样式状态，用于原地更新与去重。
  Map<String, dynamic>? _appliedBuildingGeoJson;
  Map<String, dynamic>? _appliedFeaturesGeoJson;
  Map<String, dynamic>? _appliedCity3dBuildingGeoJson;
  List<CampusPlace>? _appliedCity3dPlaces;
  String? _appliedCity3dSelectedId;
  List<CampusPlace>? _appliedTransitPlaces;
  final Map<
    String,
    ({Map<String, dynamic> raw, String buildingId, double base, double opacity})
  >
  _appliedStackFloors = {};
  Map<String, dynamic>? _appliedFloorGeoJson;
  String? _appliedFloorId;
  String? _appliedFloorBuildingId;
  String? _appliedFloorSlabRoomId;
  double? _appliedFloorSlabBase;
  double? _appliedFloorWallsBase;
  double? _appliedLabelOffsetEm;
  String? _appliedRoomLabelSelectedId;
  bool _appliedBuildingHighlightVisible = false;
  String? _appliedBuildingHighlightId;
  bool _appliedFeatureHighlightVisible = false;
  int? _appliedFeatureHighlightId;
  bool _appliedPinVisible = false;
  double? _appliedPinLat;
  double? _appliedPinLng;
  List<Object?>? _appliedRouteKey;
  Map<String, dynamic>? _appliedRoutePassedGeoJson;
  Map<String, dynamic>? _appliedStreetGeoJson;
  List<CampusPlace>? _appliedMarkersPlaces;
  String? _appliedMarkersSelectedId;
  bool _appliedMarkersVisible = false;
  double? _appliedUserLat;
  double? _appliedUserLng;
  bool _appliedUserVisible = false;
  bool _appliedHeadingVisible = false;
  int? _headingImageEpoch;

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
          ..addListener(_onShuttleAnimationTick)
          ..addStatusListener(_onShuttleAnimationStatus);
    _startTimeout();
  }

  void _startTimeout() {
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 25), () {
      if (mounted && !_ready) setState(() => _error = '地图加载超时，请检查网络后重试');
    });
  }

  void _resetStyleState() {
    _sources.clear();
    _layers.clear();
    _appliedBuildingGeoJson = null;
    _appliedFeaturesGeoJson = null;
    _appliedCity3dBuildingGeoJson = null;
    _appliedCity3dPlaces = null;
    _appliedCity3dSelectedId = null;
    _appliedTransitPlaces = null;
    _appliedStackFloors.clear();
    _appliedFloorGeoJson = null;
    _appliedFloorId = null;
    _appliedFloorBuildingId = null;
    _appliedFloorSlabRoomId = null;
    _appliedFloorSlabBase = null;
    _appliedFloorWallsBase = null;
    _appliedLabelOffsetEm = null;
    _appliedRoomLabelSelectedId = null;
    _appliedBuildingHighlightVisible = false;
    _appliedBuildingHighlightId = null;
    _appliedFeatureHighlightVisible = false;
    _appliedFeatureHighlightId = null;
    _appliedPinVisible = false;
    _appliedPinLat = null;
    _appliedPinLng = null;
    _appliedRouteKey = null;
    _appliedRoutePassedGeoJson = null;
    _appliedStreetGeoJson = null;
    _appliedMarkersPlaces = null;
    _appliedMarkersSelectedId = null;
    _appliedMarkersVisible = false;
    _appliedUserLat = null;
    _appliedUserLng = null;
    _appliedUserVisible = false;
    _appliedHeading = null;
    _appliedHeadingVisible = false;
    _headingSentAt = DateTime.fromMillisecondsSinceEpoch(0);
    _headingImageEpoch = null;
    _shuttleImagesEpoch = null;
    _lastShuttlePushElapsed = null;
    _lastShuttleWallPushAt = null;
    _lastShuttlePushedVehicles = null;
    _lastShuttlePushedDirections = null;
    _lastShuttlePushedOrigins = null;
    _lastShuttlePushedProgress = null;
    _lastShuttlePushedEpoch = null;
  }

  @override
  void didUpdateWidget(covariant CampusMapNative oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.configuration;
    final shuttleVehiclesChanged = !identical(
      old.shuttleVehicles,
      config.shuttleVehicles,
    );
    final shuttleDirectionsChanged = !identical(
      old.shuttleDirections,
      config.shuttleDirections,
    );
    final mapLayerChanged = old.mapLayer != config.mapLayer;
    if (shuttleVehiclesChanged) {
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
        _shuttleForceFlush = true;
        _lastShuttlePushElapsed = null;
        _lastShuttleWallPushAt = null;
        _shuttleAnimation.forward(from: 0);
        if (_shuttleForceFlush) _scheduleShuttleUpdate(immediate: true);
      }
    } else if (shuttleDirectionsChanged &&
        config.mapLayer == CampusMapLayer.transit) {
      _shuttleForceFlush = true;
    }
    if (mapLayerChanged) {
      _shuttleAnimation.stop();
      _shuttleAnimation.value = 1;
      _shuttleStationsDirty = true;
      _shuttleForceFlush = true;
      _lastShuttlePushElapsed = null;
      _lastShuttleWallPushAt = null;
      if (config.mapLayer != CampusMapLayer.transit) {
        _shuttleCameraTimer?.cancel();
        _shuttleCameraTimer = null;
      }
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
      _styleEpoch++;
      _generation++;
      _ready = false;
      _shuttleCameraTimer?.cancel();
      _shuttleCameraTimer = null;
      _startTimeout();
      return;
    }
    final layersChanged = _hasLayerInputChanges(old, config);
    if (old.userHeading != config.userHeading) _syncHeading();
    if (!layersChanged &&
        !identical(old.routePassedGeoJson, config.routePassedGeoJson)) {
      _syncPassedRoute();
    }
    if (!layersChanged &&
        !shuttleVehiclesChanged &&
        shuttleDirectionsChanged &&
        config.mapLayer == CampusMapLayer.transit) {
      _scheduleShuttleUpdate(immediate: true);
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
      final b = _bridge;
      if (b == null) return;
      try {
        if (sync) {
          await _sync(b, config);
          if (!mounted || generation != _generation) return;
          _scheduleShuttleUpdate(immediate: _shuttleForceFlush);
        }
        if (_cameraPending) {
          await _updateCamera(b);
          if (mounted && generation == _generation) _cameraPending = false;
        }
        if (mounted && _error != null) setState(() => _error = null);
      } catch (error, stackTrace) {
        if (mounted && generation == _generation) {
          _log.warning(
            'layers.sync_failed',
            fields: {'stage': sync ? 'layers.sync' : 'camera.update'},
            error: error,
            stackTrace: stackTrace,
          );
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

  Future<void> _addSource(
    CampusMapBridge b,
    String id,
    Map<String, dynamic> data, {
    required int group,
  }) async {
    await b.addGeoJsonSource(id, data);
    _sources.add((id: id, group: group));
  }

  void _registerLayer(String id, int group) {
    final idx = _layers.indexWhere((layer) => layer.group > group);
    final entry = (id: id, group: group);
    if (idx == -1) {
      _layers.add(entry);
    } else {
      _layers.insert(idx, entry);
    }
  }

  bool _hasLayer(String id) => _layers.any((layer) => layer.id == id);

  String? _belowAfterGroup(int group) {
    for (final layer in _layers) {
      if (layer.group > group) return layer.id;
    }
    return null;
  }

  Future<void> _removeLayerById(CampusMapBridge b, String id) async {
    if (!_hasLayer(id)) return;
    await b.removeLayer(id);
    _layers.removeWhere((layer) => layer.id == id);
  }

  Future<void> _removeSourceById(CampusMapBridge b, String id) async {
    if (!_sources.any((source) => source.id == id)) return;
    await b.removeSource(id);
    _sources.removeWhere((source) => source.id == id);
  }

  Future<void> _clearGroup(CampusMapBridge b, int group) async {
    for (final layer in _layers.reversed.toList()) {
      if (layer.group != group) continue;
      await b.removeLayer(layer.id);
      _layers.remove(layer);
    }
    for (final source in _sources.reversed.toList()) {
      if (source.group != group) continue;
      await b.removeSource(source.id);
      _sources.remove(source);
    }
  }

  String? _selectedBuildingId(CampusMapCanvas value) =>
      value.selectedPlace?.buildingId ?? value.selectedPlace?.id;

  static bool _hasValidUser(GeoPoint? point) => point != null && point.isValid;

  static bool _sameGeoPoint(GeoPoint? a, GeoPoint? b) =>
      a?.latitude == b?.latitude && a?.longitude == b?.longitude;

  static bool _sameJsonValue(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        if (!b.containsKey(entry.key) ||
            !_sameJsonValue(entry.value, b[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameJsonValue(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static bool _sameMarkerPlaces(List<CampusPlace>? a, List<CampusPlace> b) {
    if (a == null) return false;
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.id != y.id ||
          x.name != y.name ||
          x.category != y.category ||
          !_sameGeoPoint(x.center, y.center)) {
        return false;
      }
    }
    return true;
  }

  bool _hasLayerInputChanges(CampusMapCanvas a, CampusMapCanvas b) {
    final aPin = a.selectedPlace?.center ?? a.selectedPlace?.entrance;
    final bPin = b.selectedPlace?.center ?? b.selectedPlace?.entrance;
    final aUserValid = _hasValidUser(a.userPoint);
    final bUserValid = _hasValidUser(b.userPoint);
    return !identical(a.buildingGeoJson, b.buildingGeoJson) ||
        !identical(a.featuresGeoJson, b.featuresGeoJson) ||
        !identical(a.places, b.places) ||
        a.mapLayer != b.mapLayer ||
        a.selectedPlace?.id != b.selectedPlace?.id ||
        _selectedBuildingId(a) != _selectedBuildingId(b) ||
        a.selectedPlace?.poiId != b.selectedPlace?.poiId ||
        a.selectedPlace?.featureId != b.selectedPlace?.featureId ||
        !_sameGeoPoint(aPin, bPin) ||
        !identical(a.selectedPlace?.floors, b.selectedPlace?.floors) ||
        a.floor?.id != b.floor?.id ||
        a.floor?.number != b.floor?.number ||
        a.selectedRoom?.id != b.selectedRoom?.id ||
        !identical(a.floorGeoJson, b.floorGeoJson) ||
        !identical(a.ghostFloorsGeoJson, b.ghostFloorsGeoJson) ||
        a.showRoute != b.showRoute ||
        !identical(a.routeGeoJson, b.routeGeoJson) ||
        a.streetCoverage != b.streetCoverage ||
        !identical(a.streetCoverageGeoJson, b.streetCoverageGeoJson) ||
        !identical(a.markerPlaces, b.markerPlaces) ||
        aUserValid != bUserValid ||
        (bUserValid && !_sameGeoPoint(a.userPoint, b.userPoint)) ||
        (!_hasLayer('campus-user-heading') &&
            (a.userHeading != null) != (b.userHeading != null));
  }

  static bool _sameKey(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (identical(x, y)) continue;
      if (x is Map || x is Iterable || x != y) return false;
    }
    return true;
  }

  /// 按图层组独立增量同步：只更新输入发生变化的组，尽可能原地更新
  /// 数据源或完整图层属性，不连带拆毁并重建其他无关图层组。
  Future<void> _sync(CampusMapBridge b, CampusMapCanvas value) async {
    await _syncBuildingHits(b, value);
    await _syncFeatureHits(b, value);
    await _syncCity3d(b, value);
    await _syncTransit(b, value);
    await _syncStackedFloors(b, value);
    await _syncCurrentFloor(b, value);
    await _syncHighlight(b, value);
    await _syncRoute(b, value);
    await _syncStreet(b, value);
    await _syncMarkers(b, value);
    await _syncUser(b, value);
    await _syncShuttle(b, value);
  }

  Future<void> _syncBuildingHits(
    CampusMapBridge b,
    CampusMapCanvas value,
  ) async {
    // 户外只渲染底图本身：建筑与 POI 由底图样式呈现。楼宇轮廓以全透明图层
    // 挂载，仅作为点击命中区域（碰撞箱），不改变地图外观。
    final buildings = value.buildingGeoJson;
    if (buildings == null) {
      await _removeLayerById(b, 'campus-selected-line');
      await _removeLayerById(b, 'campus-selected-fill');
      _appliedBuildingHighlightVisible = false;
      _appliedBuildingHighlightId = null;
      await _clearGroup(b, 0);
      _appliedBuildingGeoJson = null;
      return;
    }
    if (!_hasLayer('campus-buildings-hit')) {
      await _addSource(b, 'campus-buildings', buildings, group: 0);
      await b.addFillLayer(
        'campus-buildings',
        'campus-buildings-hit',
        const FillLayerProperties(
          fillColor: '#000000',
          // 近乎全透明：肉眼不可见，但保留可查询性（0 不透明度在部分渲染器
          // 上会被查询跳过），从而只作碰撞箱使用。
          fillOpacity: 0.01,
          fillOutlineColor: 'rgba(0,0,0,0)',
        ),
        belowLayerId: _belowAfterGroup(0),
      );
      _registerLayer('campus-buildings-hit', 0);
      _appliedBuildingGeoJson = buildings;
    } else if (!identical(buildings, _appliedBuildingGeoJson)) {
      await b.setGeoJsonSource('campus-buildings', buildings);
      _appliedBuildingGeoJson = buildings;
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

  FillExtrusionLayerProperties _city3dProps(String selectedBuildingId) =>
      FillExtrusionLayerProperties(
        // 选中楼宇的体块染成浅蓝，3D 下不再另画平面高亮（会被体块盖住）。
        fillExtrusionColor: [
          'case',
          [
            '==',
            ['get', 'building_id'],
            selectedBuildingId,
          ],
          '#8DB8F5',
          '#DCE4EE',
        ],
        fillExtrusionOpacity: 0.85,
        fillExtrusionHeight: const ['get', 'height_m'],
        visibility: 'visible',
      );

  Map<String, dynamic> _buildCity3dGeoJson(
    Map<String, dynamic> buildings,
    List<CampusPlace> places,
  ) {
    final heights = <String, double>{
      for (final place in places)
        if (place.poiId == null)
          place.id:
              (place.floors.isEmpty ? 3 : place.floors.length) *
              kDisplayFloorHeightM,
    };
    return <String, dynamic>{
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
  }

  Future<void> _syncCity3d(CampusMapBridge b, CampusMapCanvas value) async {
    final buildings = value.buildingGeoJson;
    // 3D 城市：建筑轮廓按楼层数拉伸成体块（无楼层数据时按 3 层估算）；
    // 室内分层模式下不叠加，避免与就地分层模型重合。
    final active =
        value.mapLayer == CampusMapLayer.city3d &&
        value.floor == null &&
        buildings != null;
    if (!active) {
      await _clearGroup(b, 2);
      _appliedCity3dBuildingGeoJson = null;
      _appliedCity3dPlaces = null;
      _appliedCity3dSelectedId = null;
      return;
    }
    final selectedId = _selectedBuildingId(value) ?? '';
    final sourceChanged =
        !identical(buildings, _appliedCity3dBuildingGeoJson) ||
        !identical(value.places, _appliedCity3dPlaces);
    if (!_hasLayer('campus-city3d-volume')) {
      final extruded = _buildCity3dGeoJson(buildings, value.places);
      await _addSource(b, 'campus-city3d', extruded, group: 2);
      await b.addFillExtrusionLayer(
        'campus-city3d',
        'campus-city3d-volume',
        _city3dProps(selectedId),
        enableInteraction: false,
        // 插在底图第一个文字图层下面：自绘图层默认叠在整套样式最上层，
        // 体块会把楼名、道路名等底图标注盖住。
        belowLayerId:
            _firstSymbolLayerId(value.styleUrl) ?? _belowAfterGroup(2),
      );
      _registerLayer('campus-city3d-volume', 2);
      _appliedCity3dBuildingGeoJson = buildings;
      _appliedCity3dPlaces = value.places;
      _appliedCity3dSelectedId = selectedId;
      return;
    }
    if (sourceChanged) {
      final extruded = _buildCity3dGeoJson(buildings, value.places);
      await b.setGeoJsonSource('campus-city3d', extruded);
      _appliedCity3dBuildingGeoJson = buildings;
      _appliedCity3dPlaces = value.places;
    }
    if (_appliedCity3dSelectedId != selectedId) {
      await b.setLayerProperties(
        'campus-city3d-volume',
        _city3dProps(selectedId),
      );
      _appliedCity3dSelectedId = selectedId;
    }
  }

  Future<void> _syncTransit(CampusMapBridge b, CampusMapCanvas value) async {
    // 公交地铁：高亮公交站类地物点位（按 kind 白名单匹配，不按名称猜测）。
    if (value.mapLayer != CampusMapLayer.transit) {
      await _clearGroup(b, 3);
      _appliedTransitPlaces = null;
      return;
    }
    if (_hasLayer('campus-transit-stops') &&
        identical(value.places, _appliedTransitPlaces)) {
      return;
    }
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
              'coordinates': [place.center!.longitude, place.center!.latitude],
            },
            'properties': {'name': place.name},
          },
    ];
    if (stops.isEmpty) {
      await _clearGroup(b, 3);
      _appliedTransitPlaces = value.places;
      return;
    }
    final collection = {'type': 'FeatureCollection', 'features': stops};
    if (!_hasLayer('campus-transit-stops')) {
      await _addSource(b, 'campus-transit', collection, group: 3);
      await b.addCircleLayer(
        'campus-transit',
        'campus-transit-stops',
        const CircleLayerProperties(
          circleColor: '#E67E22',
          circleRadius: 7,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2.5,
        ),
        belowLayerId: _belowAfterGroup(3),
        enableInteraction: false,
      );
      _registerLayer('campus-transit-stops', 3);
    } else {
      await b.setGeoJsonSource('campus-transit', collection);
    }
    _appliedTransitPlaces = value.places;
  }

  Future<void> _syncShuttle(CampusMapBridge b, CampusMapCanvas value) async {
    if (value.mapLayer != CampusMapLayer.transit) {
      await _clearGroup(b, 11);
      _lastShuttlePushedVehicles = null;
      _lastShuttlePushedDirections = null;
      _lastShuttlePushedOrigins = null;
      _lastShuttlePushedProgress = null;
      _lastShuttlePushedEpoch = null;
      return;
    }
    if (_hasLayer('shuttle-vehicle-icons')) return;
    final epoch = _shuttleStyleEpoch;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final iconScale = Theme.of(context).platform == TargetPlatform.android
        ? 1 / ratio
        : 1.0;
    // 图标是地图上的固定设计素材，沿用已审核的天蓝与离线灰。
    var online = _shuttleOnlineBytes;
    var offline = _shuttleOfflineBytes;
    if (online == null || offline == null || _shuttleIconRatio != ratio) {
      online = await ShuttleMapLayer.icon(const Color(0xFF409CE8), ratio);
      offline = await ShuttleMapLayer.icon(const Color(0xFF929AA3), ratio);
      _shuttleOnlineBytes = online;
      _shuttleOfflineBytes = offline;
      _shuttleIconRatio = ratio;
    }
    if (!mounted ||
        epoch != _shuttleStyleEpoch ||
        config.mapLayer != CampusMapLayer.transit) {
      return;
    }
    if (_shuttleImagesEpoch != epoch) {
      await b.addImage('shuttle-online', online);
      await b.addImage('shuttle-offline', offline);
      _shuttleImagesEpoch = epoch;
    }
    final below = _belowAfterGroup(11);
    await _addSource(
      b,
      'shuttle-stations',
      ShuttleMapLayer.stations(List.filled(shuttleStations.length, 0)),
      group: 11,
    );
    await b.addCircleLayer(
      'shuttle-stations',
      'shuttle-stop-dots',
      const CircleLayerProperties(
        circleColor: '#E67E22',
        circleRadius: 5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      ),
      belowLayerId: below,
      enableInteraction: false,
    );
    _registerLayer('shuttle-stop-dots', 11);
    await b.addSymbolLayer(
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
      belowLayerId: below,
      enableInteraction: false,
    );
    _registerLayer('shuttle-stop-labels', 11);
    final vehicles = config.shuttleVehicles;
    final directions = config.shuttleDirections;
    final origins = _shuttleOrigins;
    final progress = _shuttleAnimation.value;
    await _addSource(
      b,
      'shuttle-vehicles',
      ShuttleMapLayer.vehicles(vehicles, directions, origins, progress),
      group: 11,
    );
    await b.addSymbolLayer(
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
      belowLayerId: below,
      enableInteraction: false,
    );
    _registerLayer('shuttle-vehicle-icons', 11);
    _lastShuttlePushedVehicles = vehicles;
    _lastShuttlePushedDirections = directions;
    _lastShuttlePushedOrigins = origins;
    _lastShuttlePushedProgress = progress;
    _lastShuttlePushedEpoch = epoch;
    _shuttleStationsDirty = true;
  }

  void _onShuttleAnimationTick() {
    final t = _shuttleAnimation.value;
    final status = _shuttleAnimation.status;
    final isBoundary =
        _shuttleForceFlush ||
        t == 0.0 ||
        t == 1.0 ||
        status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed;
    _scheduleShuttleUpdate(immediate: isBoundary);
  }

  void _onShuttleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _scheduleShuttleUpdate(immediate: true);
    }
  }

  bool _isSameShuttleSnapshot(int epoch) =>
      _lastShuttlePushedEpoch == epoch &&
      identical(_lastShuttlePushedVehicles, config.shuttleVehicles) &&
      identical(_lastShuttlePushedDirections, config.shuttleDirections) &&
      identical(_lastShuttlePushedOrigins, _shuttleOrigins) &&
      _lastShuttlePushedProgress == _shuttleAnimation.value;

  bool _shouldFlushShuttleTick() {
    final elapsed = _shuttleAnimation.lastElapsedDuration;
    final lastElapsed = _lastShuttlePushElapsed;
    if (elapsed != null) {
      if (lastElapsed == null || elapsed < lastElapsed) return true;
      return elapsed - lastElapsed >= CampusMapNative.shuttleThrottleInterval;
    }
    final lastWall = _lastShuttleWallPushAt;
    if (lastWall == null) return true;
    return CampusMapNative.debugClock().difference(lastWall) >=
        CampusMapNative.shuttleThrottleInterval;
  }

  void _recordShuttlePushTime() {
    _lastShuttlePushElapsed =
        _shuttleAnimation.lastElapsedDuration ??
        (_shuttleAnimation.value == 0.0 ? Duration.zero : null);
    _lastShuttleWallPushAt = CampusMapNative.debugClock();
  }

  // 与既有图层同步共用串行队列；中间动画帧节流至 >=33ms，起止边界与状态变化立即刷新。
  void _scheduleShuttleUpdate({bool immediate = false}) {
    if (!mounted || !_ready || config.mapLayer != CampusMapLayer.transit) {
      return;
    }
    final epoch = _shuttleStyleEpoch;
    final stationsDirty = _shuttleStationsDirty;
    if (!stationsDirty && _isSameShuttleSnapshot(epoch)) {
      _shuttleForceFlush = false;
      return;
    }
    final force = immediate || _shuttleForceFlush || stationsDirty;
    if (!force && !_shouldFlushShuttleTick()) {
      return;
    }
    _shuttleForceFlush = false;
    _recordShuttlePushTime();
    if (_shuttleUpdateQueued) return;
    _shuttleUpdateQueued = true;
    _queue = _queue.then((_) async {
      _shuttleUpdateQueued = false;
      final b = _bridge;
      if (!mounted ||
          !_ready ||
          b == null ||
          epoch != _shuttleStyleEpoch ||
          config.mapLayer != CampusMapLayer.transit ||
          !_hasLayer('shuttle-vehicle-icons')) {
        return;
      }
      try {
        if (_shuttleStationsDirty) {
          _shuttleStationsDirty = false;
          final pixels = await b.toScreenLocationBatch([
            for (final station in shuttleStations) ...[
              LatLng(station.first.latitude, station.first.longitude),
              LatLng(station.second.latitude, station.second.longitude),
            ],
          ]);
          if (!mounted ||
              !_ready ||
              epoch != _shuttleStyleEpoch ||
              config.mapLayer != CampusMapLayer.transit) {
            return;
          }
          // 0.28 起各平台的屏幕坐标都是逻辑像素，不再需要按 Android 的设备像素比换算。
          final distances = [
            for (var i = 0; i < pixels.length; i += 2)
              ShuttleMapLayer.screenDistance(pixels[i], pixels[i + 1], 1),
          ];
          await b.setGeoJsonSource(
            'shuttle-stations',
            ShuttleMapLayer.stations(distances),
          );
        }
        if (!mounted ||
            !_ready ||
            epoch != _shuttleStyleEpoch ||
            config.mapLayer != CampusMapLayer.transit) {
          return;
        }
        if (_isSameShuttleSnapshot(epoch)) return;
        final vehicles = config.shuttleVehicles;
        final directions = config.shuttleDirections;
        final origins = _shuttleOrigins;
        final progress = _shuttleAnimation.value;
        await b.setGeoJsonSource(
          'shuttle-vehicles',
          ShuttleMapLayer.vehicles(vehicles, directions, origins, progress),
        );
        _lastShuttlePushedVehicles = vehicles;
        _lastShuttlePushedDirections = directions;
        _lastShuttlePushedOrigins = origins;
        _lastShuttlePushedProgress = progress;
        _lastShuttlePushedEpoch = epoch;
      } catch (_) {
        // 样式切换期间原生 source 可能已释放，下一次同步恢复当前状态。
        _shuttleStationsDirty = true;
      }
    });
  }

  Future<void> _syncFeatureHits(
    CampusMapBridge b,
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
    final hasFeatures =
        features != null && featureRows is List && featureRows.isNotEmpty;
    if (!hasFeatures) {
      await _removeLayerById(b, 'campus-selected-feature');
      _appliedFeatureHighlightVisible = false;
      _appliedFeatureHighlightId = null;
      await _clearGroup(b, 1);
      _appliedFeaturesGeoJson = null;
      return;
    }
    if (!_hasLayer('campus-features-fill')) {
      final below = _belowAfterGroup(1);
      await _addSource(b, 'campus-features', features, group: 1);
      await b.addFillLayer(
        'campus-features',
        'campus-features-fill',
        const FillLayerProperties(
          fillColor: '#000000',
          fillOpacity: 0.01,
          fillOutlineColor: 'rgba(0,0,0,0)',
        ),
        belowLayerId: below,
      );
      _registerLayer('campus-features-fill', 1);
      await b.addLineLayer(
        'campus-features',
        'campus-features-line',
        const LineLayerProperties(
          lineColor: '#000000',
          lineOpacity: 0.01,
          lineWidth: 1.8,
        ),
        belowLayerId: below,
      );
      _registerLayer('campus-features-line', 1);
      await b.addCircleLayer(
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
        belowLayerId: below,
      );
      _registerLayer('campus-features-point', 1);
      _appliedFeaturesGeoJson = features;
    } else if (!identical(features, _appliedFeaturesGeoJson)) {
      await b.setGeoJsonSource('campus-features', features);
      _appliedFeaturesGeoJson = features;
    }
  }

  static Map<String, dynamic> _pointGeoJson(
    GeoPoint point, {
    Map<String, dynamic> properties = const <String, dynamic>{},
  }) => {
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [point.longitude, point.latitude],
        },
        'properties': properties,
      },
    ],
  };

  Future<bool> _ensureHeadingImage(CampusMapBridge b) async {
    final epoch = _styleEpoch;
    if (_headingImageEpoch == epoch) return true;
    final bytes = await _headingBeam();
    if (!mounted || epoch != _styleEpoch) return false;
    await b.addImage(_headingImage, bytes);
    if (!mounted || epoch != _styleEpoch) return false;
    _headingImageEpoch = epoch;
    return true;
  }

  Future<void> _syncUser(CampusMapBridge b, CampusMapCanvas value) async {
    final user = value.userPoint;
    final hasUser = _hasValidUser(user);
    if (!_hasLayer('campus-user-dot')) {
      final epoch = _styleEpoch;
      final initialGeoJson = hasUser
          ? _pointGeoJson(user!, properties: const {'kind': 'user'})
          : _emptyCollection;
      final heading = value.userHeading;
      final showHeading = hasUser && heading != null;
      final initialAngle = heading ?? _appliedHeading ?? 0.0;
      await _addSource(b, 'campus-user', initialGeoJson, group: 10);
      if (!mounted || epoch != _styleEpoch) return;
      final imageReady = await _ensureHeadingImage(b);
      if (!imageReady) return;
      final below = _belowAfterGroup(10);
      // 朝向光束：画在蓝点下面，随手机朝向转动（相对正北，地图旋转时自动跟着转）。
      await b.addSymbolLayer(
        'campus-user',
        'campus-user-heading',
        _headingProps(initialAngle, visible: showHeading),
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-user-heading', 10);
      await b.addCircleLayer(
        'campus-user',
        'campus-user-halo',
        _haloProps(visible: hasUser),
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-user-halo', 10);
      await b.addCircleLayer(
        'campus-user',
        'campus-user-dot',
        _dotProps(visible: hasUser),
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-user-dot', 10);
      _appliedUserLat = hasUser ? user!.latitude : null;
      _appliedUserLng = hasUser ? user!.longitude : null;
      _appliedUserVisible = hasUser;
      _appliedHeadingVisible = showHeading;
      if (heading != null) {
        _appliedHeading = heading;
        _headingSentAt = CampusMapNative.debugClock();
      }
      return;
    }

    final nextLat = hasUser ? user!.latitude : null;
    final nextLng = hasUser ? user!.longitude : null;
    if (_appliedUserVisible != hasUser ||
        _appliedUserLat != nextLat ||
        _appliedUserLng != nextLng) {
      await b.setGeoJsonSource(
        'campus-user',
        hasUser
            ? _pointGeoJson(user!, properties: const {'kind': 'user'})
            : _emptyCollection,
      );
      _appliedUserLat = nextLat;
      _appliedUserLng = nextLng;
    }
    if (_appliedUserVisible != hasUser) {
      await b.setLayerProperties(
        'campus-user-halo',
        _haloProps(visible: hasUser),
      );
      await b.setLayerProperties(
        'campus-user-dot',
        _dotProps(visible: hasUser),
      );
      _appliedUserVisible = hasUser;
    }
    final showHeading = hasUser && value.userHeading != null;
    if (_appliedHeadingVisible != showHeading) {
      final angle = value.userHeading ?? _appliedHeading ?? 0.0;
      await b.setLayerProperties(
        'campus-user-heading',
        _headingProps(angle, visible: showHeading),
      );
      _appliedHeadingVisible = showHeading;
      if (value.userHeading != null) {
        _appliedHeading = value.userHeading;
        _headingSentAt = CampusMapNative.debugClock();
      }
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

  SymbolLayerProperties _headingProps(
    double heading, {
    required bool visible,
  }) => SymbolLayerProperties(
    iconImage: _headingImage,
    iconRotate: heading,
    iconRotationAlignment: 'map',
    iconPitchAlignment: 'map',
    iconAllowOverlap: true,
    iconIgnorePlacement: true,
    iconAnchor: 'center',
    visibility: visible ? 'visible' : 'none',
  );

  CircleLayerProperties _haloProps({required bool visible}) =>
      CircleLayerProperties(
        circleColor: '#1475F5',
        circleOpacity: 0.18,
        circleRadius: 16,
        visibility: visible ? 'visible' : 'none',
      );

  CircleLayerProperties _dotProps({required bool visible}) =>
      CircleLayerProperties(
        circleColor: '#1475F5',
        circleRadius: 7,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
        visibility: visible ? 'visible' : 'none',
      );

  /// 朝向变化只改图层的旋转角与可见性，不重建定位图层；可见状态下转动不足 3° 或间隔不足 80ms 时跳过。
  void _syncHeading() {
    final b = _bridge;
    if (b == null || !_ready || !_hasLayer('campus-user-heading')) return;
    final hasUser = _hasValidUser(config.userPoint);
    final heading = config.userHeading;
    final showHeading = hasUser && heading != null;
    if (!showHeading) {
      if (!_appliedHeadingVisible) return;
      _appliedHeadingVisible = false;
      final angle = _appliedHeading ?? 0.0;
      unawaited(
        b
            .setLayerProperties(
              'campus-user-heading',
              _headingProps(angle, visible: false),
            )
            .catchError((Object _) {}),
      );
      return;
    }
    final wasVisible = _appliedHeadingVisible;
    final applied = _appliedHeading;
    final now = CampusMapNative.debugClock();
    if (wasVisible &&
        applied != null &&
        (headingDelta(applied, heading).abs() < 3 ||
            now.difference(_headingSentAt) <
                const Duration(milliseconds: 80))) {
      return;
    }
    _appliedHeading = heading;
    _appliedHeadingVisible = true;
    _headingSentAt = now;
    unawaited(
      b
          .setLayerProperties(
            'campus-user-heading',
            _headingProps(heading, visible: true),
          )
          .catchError((Object _) {}),
    );
  }

  FillExtrusionLayerProperties _floorSlabProps(
    double baseElevation,
    String? selectedRoomId,
  ) => FillExtrusionLayerProperties(
    fillExtrusionColor: [
      'case',
      [
        '==',
        ['get', 'room_id'],
        selectedRoomId ?? '',
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
    fillExtrusionHeight: baseElevation + kFloorSlabThicknessM,
    fillExtrusionBase: baseElevation,
    visibility: 'visible',
  );

  FillExtrusionLayerProperties _floorWallsProps(double baseElevation) =>
      FillExtrusionLayerProperties(
        fillExtrusionColor: '#B9C4D0',
        // 顶面 = 楼层底面 + 墙基座 + 墙高（绝对高度，见上楼板注释）。
        fillExtrusionHeight: [
          '+',
          baseElevation,
          [
            'coalesce',
            ['get', 'base_m'],
            0,
          ],
          ['get', 'height_m'],
        ],
        fillExtrusionBase: [
          '+',
          baseElevation,
          [
            'coalesce',
            ['get', 'base_m'],
            0,
          ],
        ],
        fillExtrusionOpacity: 1,
        visibility: 'visible',
      );

  Future<void> _syncCurrentFloor(
    CampusMapBridge b,
    CampusMapCanvas value,
  ) async {
    final floorId = value.floor?.id;
    final buildingId = _selectedBuildingId(value);
    if (value.floor == null || value.floorGeoJson == null) {
      await _clearGroup(b, 5);
      _appliedFloorGeoJson = null;
      _appliedFloorId = null;
      _appliedFloorBuildingId = null;
      _appliedFloorSlabRoomId = null;
      _appliedFloorSlabBase = null;
      _appliedFloorWallsBase = null;
      _appliedLabelOffsetEm = null;
      _appliedRoomLabelSelectedId = null;
      return;
    }
    final sourceChanged =
        !_hasLayer('campus-floor-slab') ||
        !identical(value.floorGeoJson, _appliedFloorGeoJson) ||
        floorId != _appliedFloorId ||
        buildingId != _appliedFloorBuildingId;
    final base = _floorBase(value, floorId);
    final selectedRoomId = value.selectedRoom?.id;
    final labelOffset = _labelOffsetEm(b);
    if (!_hasLayer('campus-floor-slab')) {
      final floor = _subset(
        value.floorGeoJson,
        (p) => p['building_id'] == buildingId && p['floor_id'] == floorId,
      );
      if (floor == null) return;
      final below = _belowAfterGroup(5);
      await _addSource(b, 'campus-floor', floor, group: 5);
      // 当前楼层做成有厚度的楼板并抬到该层高度，房间/走廊按类型着色；
      // 平面填充在这里不再使用，否则俯视时会与楼板重影。
      await b.addFillExtrusionLayer(
        'campus-floor',
        'campus-floor-slab',
        _floorSlabProps(base, selectedRoomId),
        filter: [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['room', 'corridor', 'facility', 'door'],
          ],
        ],
        belowLayerId: below,
        enableInteraction: true,
      );
      _registerLayer('campus-floor-slab', 5);
      // Only supplied wall polygons are extruded; room polygons stay roofless.
      await b.addFillExtrusionLayer(
        'campus-floor',
        'campus-floor-walls',
        _floorWallsProps(base),
        filter: [
          'all',
          [
            '==',
            ['get', 'kind'],
            'wall',
          ],
          ['has', 'height_m'],
        ],
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-floor-walls', 5);
      // 门牌标注：贴在当前层楼板顶面上。MapLibre Native 尚不支持
      // symbol-z-elevate，用 textOffset 按「楼层高度 × sin(倾角)」手动抬升，
      // 相机变化时动态校正（见 _syncLabelOffset）。
      await b.addSymbolLayer(
        'campus-floor',
        'campus-floor-room-labels',
        _roomLabelProps(labelOffset, selectedRoomId: selectedRoomId),
        filter: [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['room', 'facility'],
          ],
        ],
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-floor-room-labels', 5);
      _appliedFloorGeoJson = value.floorGeoJson;
      _appliedFloorId = floorId;
      _appliedFloorBuildingId = buildingId;
      _appliedFloorSlabBase = base;
      _appliedFloorSlabRoomId = selectedRoomId;
      _appliedFloorWallsBase = base;
      _appliedLabelOffsetEm = labelOffset;
      _appliedRoomLabelSelectedId = selectedRoomId;
      return;
    }

    if (sourceChanged) {
      final floor = _subset(
        value.floorGeoJson,
        (p) => p['building_id'] == buildingId && p['floor_id'] == floorId,
      );
      if (floor != null) {
        await b.setGeoJsonSource('campus-floor', floor);
        _appliedFloorGeoJson = value.floorGeoJson;
        _appliedFloorId = floorId;
        _appliedFloorBuildingId = buildingId;
      }
    }
    if (_appliedFloorSlabBase != base ||
        _appliedFloorSlabRoomId != selectedRoomId) {
      await b.setLayerProperties(
        'campus-floor-slab',
        _floorSlabProps(base, selectedRoomId),
      );
      _appliedFloorSlabBase = base;
      _appliedFloorSlabRoomId = selectedRoomId;
    }
    if (_appliedFloorWallsBase != base) {
      await b.setLayerProperties('campus-floor-walls', _floorWallsProps(base));
      _appliedFloorWallsBase = base;
    }
    final offsetChanged =
        _appliedLabelOffsetEm == null ||
        (labelOffset - _appliedLabelOffsetEm!).abs() >= 0.08;
    if (_appliedRoomLabelSelectedId != selectedRoomId || offsetChanged) {
      await b.setLayerProperties(
        'campus-floor-room-labels',
        _roomLabelProps(labelOffset, selectedRoomId: selectedRoomId),
      );
      _appliedLabelOffsetEm = labelOffset;
      _appliedRoomLabelSelectedId = selectedRoomId;
    }
  }

  Future<void> _syncRoute(CampusMapBridge b, CampusMapCanvas value) async {
    final routeKey = <Object?>[
      value.showRoute,
      value.routeGeoJson,
      value.floor?.id,
      if (value.floor != null) _selectedBuildingId(value),
    ];
    if (_appliedRouteKey != null && _sameKey(_appliedRouteKey!, routeKey)) {
      await _syncPassedRouteInQueue(b, value);
      return;
    }
    await _clearGroup(b, 7);
    _appliedRoutePassedGeoJson = null;
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
    if (route == null) {
      _appliedRouteKey = routeKey;
      return;
    }
    final below = _belowAfterGroup(7);
    await _addSource(b, 'campus-route', route, group: 7);
    // 仿百度：白色描边 + 粗蓝线，压在底图道路上依然醒目。
    await b.addLineLayer(
      'campus-route',
      'campus-route-casing',
      const LineLayerProperties(
        lineColor: '#FFFFFF',
        lineWidth: 11,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      belowLayerId: below,
      enableInteraction: false,
    );
    _registerLayer('campus-route-casing', 7);
    await b.addLineLayer(
      'campus-route',
      'campus-route-line',
      const LineLayerProperties(
        lineColor: '#1475F5',
        lineWidth: 7,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      belowLayerId: below,
      enableInteraction: false,
    );
    _registerLayer('campus-route-line', 7);
    // 导航中已走过的部分：灰线盖在蓝线上，数据由 _syncPassedRoute 原地更新。
    final passedInitial =
        value.floor == null && value.routePassedGeoJson != null
        ? value.routePassedGeoJson!
        : _emptyCollection;
    await _addSource(b, 'campus-route-passed', passedInitial, group: 7);
    _appliedRoutePassedGeoJson = passedInitial;
    await b.addLineLayer(
      'campus-route-passed',
      'campus-route-passed-line',
      const LineLayerProperties(
        lineColor: '#A6AFBB',
        lineWidth: 7,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      belowLayerId: below,
      enableInteraction: false,
    );
    _registerLayer('campus-route-passed-line', 7);
    // 起点绿点、终点红点。
    final ends = _routeEnds(value.routeGeoJson);
    if (ends != null) {
      await _addSource(b, 'campus-route-ends', {
        'type': 'FeatureCollection',
        'features': [
          for (final (kind, point) in [('start', ends.$1), ('end', ends.$2)])
            {
              'type': 'Feature',
              'geometry': {'type': 'Point', 'coordinates': point},
              'properties': {'kind': kind},
            },
        ],
      }, group: 7);
      await b.addCircleLayer(
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
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-route-ends-dot', 7);
    }
    _appliedRouteKey = routeKey;
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

  Future<void> _syncPassedRouteInQueue(
    CampusMapBridge b,
    CampusMapCanvas value,
  ) async {
    if (!_hasLayer('campus-route-passed-line')) return;
    final data = value.floor == null && value.routePassedGeoJson != null
        ? value.routePassedGeoJson!
        : _emptyCollection;
    if (_appliedRoutePassedGeoJson != null &&
        _sameJsonValue(_appliedRoutePassedGeoJson, data)) {
      return;
    }
    await b.setGeoJsonSource('campus-route-passed', data);
    _appliedRoutePassedGeoJson = data;
  }

  /// 已走过路线只换数据，不动图层（每次定位都会变），并对等价空/重复载荷去重。
  void _syncPassedRoute() {
    final b = _bridge;
    if (b == null || !_ready || !_hasLayer('campus-route-passed-line')) return;
    final data = config.floor == null && config.routePassedGeoJson != null
        ? config.routePassedGeoJson!
        : _emptyCollection;
    if (_appliedRoutePassedGeoJson != null &&
        _sameJsonValue(_appliedRoutePassedGeoJson, data)) {
      return;
    }
    _appliedRoutePassedGeoJson = data;
    unawaited(
      b.setGeoJsonSource('campus-route-passed', data).catchError((Object _) {
        if (identical(_appliedRoutePassedGeoJson, data)) {
          _appliedRoutePassedGeoJson = null;
        }
      }),
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

  Future<void> _syncStreet(CampusMapBridge b, CampusMapCanvas value) async {
    final active = value.streetCoverage && value.streetCoverageGeoJson != null;
    if (!active) {
      await _clearGroup(b, 8);
      _appliedStreetGeoJson = null;
      return;
    }
    final data = value.streetCoverageGeoJson!;
    if (!_hasLayer('campus-street-line')) {
      final below = _belowAfterGroup(8);
      await _addSource(b, 'campus-street', data, group: 8);
      await b.addLineLayer(
        'campus-street',
        'campus-street-line',
        const LineLayerProperties(lineColor: '#109DBE', lineWidth: 4),
        filter: [
          '==',
          ['geometry-type'],
          'LineString',
        ],
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-street-line', 8);
      await b.addCircleLayer(
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
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-street-points', 8);
      _appliedStreetGeoJson = data;
    } else if (!identical(data, _appliedStreetGeoJson)) {
      await b.setGeoJsonSource('campus-street', data);
      _appliedStreetGeoJson = data;
    }
  }

  FillLayerProperties _selectedBuildingFillProps({required bool visible}) =>
      FillLayerProperties(
        fillColor: '#1475F5',
        fillOpacity: 0.16,
        visibility: visible ? 'visible' : 'none',
      );

  LineLayerProperties _selectedBuildingLineProps({required bool visible}) =>
      LineLayerProperties(
        lineColor: '#1475F5',
        lineWidth: 2.5,
        lineJoin: 'round',
        visibility: visible ? 'visible' : 'none',
      );

  LineLayerProperties _selectedFeatureProps({required bool visible}) =>
      LineLayerProperties(
        lineColor: '#1475F5',
        lineOpacity: 0.85,
        lineWidth: 4,
        lineCap: 'round',
        lineJoin: 'round',
        visibility: visible ? 'visible' : 'none',
      );

  CircleLayerProperties _selectedPinHaloProps({required bool visible}) =>
      CircleLayerProperties(
        circleColor: '#E8453C',
        circleOpacity: 0.2,
        circleRadius: 15,
        visibility: visible ? 'visible' : 'none',
      );

  CircleLayerProperties _selectedPinDotProps({required bool visible}) =>
      CircleLayerProperties(
        circleColor: '#E8453C',
        circleRadius: 7.5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
        visibility: visible ? 'visible' : 'none',
      );

  /// 选中高亮（仅户外）：楼宇/地物轮廓描蓝，并在中心点落一枚红色图钉，
  /// 让点选有明确的地图反馈。复用碰撞箱数据源按编号过滤，切换目标时原地
  /// 更新过滤条件与完整样式属性，不拆毁重建图层。
  Future<void> _syncHighlight(CampusMapBridge b, CampusMapCanvas value) async {
    final place = value.selectedPlace;
    final outdoor = place != null && value.floor == null;
    final city3d = value.mapLayer == CampusMapLayer.city3d;
    final featureId = place?.featureId;
    final hasBuildings = _hasLayer('campus-buildings-hit');
    final hasFeatures = _hasLayer('campus-features-fill');

    final showBuilding =
        outdoor &&
        place.poiId == null &&
        featureId == null &&
        !city3d &&
        hasBuildings;
    final showFeature =
        outdoor && !showBuilding && featureId != null && hasFeatures;
    final outlinedBy3d =
        outdoor &&
        city3d &&
        place.poiId == null &&
        featureId == null &&
        _hasLayer('campus-city3d-volume');
    final pinCenter = place?.center ?? place?.entrance;
    final showPin =
        outdoor &&
        !showBuilding &&
        !showFeature &&
        !outlinedBy3d &&
        pinCenter != null &&
        pinCenter.isValid;

    // 1. 2D 楼宇高亮
    if (!hasBuildings) {
      await _removeLayerById(b, 'campus-selected-line');
      await _removeLayerById(b, 'campus-selected-fill');
      _appliedBuildingHighlightVisible = false;
      _appliedBuildingHighlightId = null;
    } else if (!_hasLayer('campus-selected-fill')) {
      if (showBuilding) {
        final buildingId = _selectedBuildingId(value) ?? '';
        final filter = [
          '==',
          ['get', 'building_id'],
          buildingId,
        ];
        final below = _belowAfterGroup(6);
        await b.addFillLayer(
          'campus-buildings',
          'campus-selected-fill',
          _selectedBuildingFillProps(visible: true),
          filter: filter,
          belowLayerId: below,
          enableInteraction: false,
        );
        _registerLayer('campus-selected-fill', 6);
        await b.addLineLayer(
          'campus-buildings',
          'campus-selected-line',
          _selectedBuildingLineProps(visible: true),
          filter: filter,
          belowLayerId: below,
          enableInteraction: false,
        );
        _registerLayer('campus-selected-line', 6);
        _appliedBuildingHighlightVisible = true;
        _appliedBuildingHighlightId = buildingId;
      }
    } else {
      final buildingId = showBuilding ? (_selectedBuildingId(value) ?? '') : '';
      if (showBuilding && _appliedBuildingHighlightId != buildingId) {
        final filter = [
          '==',
          ['get', 'building_id'],
          buildingId,
        ];
        await b.setLayerFilter('campus-selected-fill', filter);
        await b.setLayerFilter('campus-selected-line', filter);
        _appliedBuildingHighlightId = buildingId;
      }
      if (_appliedBuildingHighlightVisible != showBuilding) {
        await b.setLayerProperties(
          'campus-selected-fill',
          _selectedBuildingFillProps(visible: showBuilding),
        );
        await b.setLayerProperties(
          'campus-selected-line',
          _selectedBuildingLineProps(visible: showBuilding),
        );
        _appliedBuildingHighlightVisible = showBuilding;
      }
    }

    // 2. 通用地物高亮
    if (!hasFeatures) {
      await _removeLayerById(b, 'campus-selected-feature');
      _appliedFeatureHighlightVisible = false;
      _appliedFeatureHighlightId = null;
    } else if (!_hasLayer('campus-selected-feature')) {
      if (showFeature) {
        await b.addLineLayer(
          'campus-features',
          'campus-selected-feature',
          _selectedFeatureProps(visible: true),
          filter: [
            '==',
            ['get', 'feature_id'],
            featureId,
          ],
          belowLayerId: _belowAfterGroup(6),
          enableInteraction: false,
        );
        _registerLayer('campus-selected-feature', 6);
        _appliedFeatureHighlightVisible = true;
        _appliedFeatureHighlightId = featureId;
      }
    } else {
      if (showFeature && _appliedFeatureHighlightId != featureId) {
        await b.setLayerFilter('campus-selected-feature', [
          '==',
          ['get', 'feature_id'],
          featureId,
        ]);
        _appliedFeatureHighlightId = featureId;
      }
      if (_appliedFeatureHighlightVisible != showFeature) {
        await b.setLayerProperties(
          'campus-selected-feature',
          _selectedFeatureProps(visible: showFeature),
        );
        _appliedFeatureHighlightVisible = showFeature;
      }
    }

    // 3. 点位红色图钉（仅无轮廓高亮的 POI / 入口）
    if (!_hasLayer('campus-selected-pin-dot')) {
      if (showPin) {
        final below = _belowAfterGroup(6);
        await _addSource(
          b,
          'campus-selected-pin',
          _pointGeoJson(pinCenter),
          group: 6,
        );
        await b.addCircleLayer(
          'campus-selected-pin',
          'campus-selected-pin-halo',
          _selectedPinHaloProps(visible: true),
          belowLayerId: below,
          enableInteraction: false,
        );
        _registerLayer('campus-selected-pin-halo', 6);
        await b.addCircleLayer(
          'campus-selected-pin',
          'campus-selected-pin-dot',
          _selectedPinDotProps(visible: true),
          belowLayerId: below,
          enableInteraction: false,
        );
        _registerLayer('campus-selected-pin-dot', 6);
        _appliedPinLat = pinCenter.latitude;
        _appliedPinLng = pinCenter.longitude;
        _appliedPinVisible = true;
      }
    } else {
      if (showPin &&
          (_appliedPinLat != pinCenter.latitude ||
              _appliedPinLng != pinCenter.longitude)) {
        await b.setGeoJsonSource(
          'campus-selected-pin',
          _pointGeoJson(pinCenter),
        );
        _appliedPinLat = pinCenter.latitude;
        _appliedPinLng = pinCenter.longitude;
      }
      if (_appliedPinVisible != showPin) {
        await b.setLayerProperties(
          'campus-selected-pin-halo',
          _selectedPinHaloProps(visible: showPin),
        );
        await b.setLayerProperties(
          'campus-selected-pin-dot',
          _selectedPinDotProps(visible: showPin),
        );
        _appliedPinVisible = showPin;
      }
    }
  }

  CircleLayerProperties _markersDotProps({required bool visible}) =>
      CircleLayerProperties(
        circleColor: const ['get', 'color'],
        circleRadius: 6.5,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2.5,
        visibility: visible ? 'visible' : 'none',
      );

  SymbolLayerProperties _markersLabelProps({required bool visible}) =>
      SymbolLayerProperties(
        textField: const ['get', 'name'],
        textFont: const ['Noto Sans Regular'],
        textSize: 11.5,
        textColor: '#20252D',
        textHaloColor: 'rgba(255,255,255,0.95)',
        textHaloWidth: 1.4,
        textAnchor: 'top',
        textOffset: const [0, 0.9],
        textOptional: true,
        visibility: visible ? 'visible' : 'none',
      );

  /// 分类/搜索结果标注：按分类着色的圆点 + 名称，点击直接选中该地点。
  Future<void> _syncMarkers(CampusMapBridge b, CampusMapCanvas value) async {
    if (value.markerPlaces.isEmpty) {
      await _clearGroup(b, 9);
      _appliedMarkersPlaces = null;
      _appliedMarkersSelectedId = null;
      _appliedMarkersVisible = false;
      return;
    }
    final visible = value.floor == null;
    final selectedId = value.selectedPlace?.id;
    final filter = selectedId == null
        ? null
        : [
            '!=',
            ['get', 'place_id'],
            selectedId,
          ];
    if (!_hasLayer('campus-markers-dot')) {
      if (!visible) return;
      final features = _buildMarkerFeatures(value.markerPlaces);
      if (features.isEmpty) return;
      final below = _belowAfterGroup(9);
      await _addSource(b, 'campus-markers', {
        'type': 'FeatureCollection',
        'features': features,
      }, group: 9);
      await b.addCircleLayer(
        'campus-markers',
        'campus-markers-dot',
        _markersDotProps(visible: true),
        filter: filter,
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-markers-dot', 9);
      await b.addSymbolLayer(
        'campus-markers',
        'campus-markers-label',
        _markersLabelProps(visible: true),
        filter: filter,
        belowLayerId: below,
        enableInteraction: false,
      );
      _registerLayer('campus-markers-label', 9);
      _appliedMarkersPlaces = value.markerPlaces;
      _appliedMarkersSelectedId = selectedId;
      _appliedMarkersVisible = true;
      return;
    }

    if (!_sameMarkerPlaces(_appliedMarkersPlaces, value.markerPlaces)) {
      final features = _buildMarkerFeatures(value.markerPlaces);
      if (features.isEmpty) {
        await _clearGroup(b, 9);
        _appliedMarkersPlaces = null;
        _appliedMarkersSelectedId = null;
        _appliedMarkersVisible = false;
        return;
      }
      await b.setGeoJsonSource('campus-markers', {
        'type': 'FeatureCollection',
        'features': features,
      });
      _appliedMarkersPlaces = value.markerPlaces;
    }
    if (visible && _appliedMarkersSelectedId != selectedId) {
      await b.setLayerFilter('campus-markers-dot', filter);
      await b.setLayerFilter('campus-markers-label', filter);
      _appliedMarkersSelectedId = selectedId;
    }
    if (_appliedMarkersVisible != visible) {
      await b.setLayerProperties(
        'campus-markers-dot',
        _markersDotProps(visible: visible),
      );
      await b.setLayerProperties(
        'campus-markers-label',
        _markersLabelProps(visible: visible),
      );
      _appliedMarkersVisible = visible;
    }
  }

  List<Map<String, dynamic>> _buildMarkerFeatures(List<CampusPlace> places) => [
    for (final place in places)
      if (place.center != null && place.center!.isValid)
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

  static String _hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// 楼板厚度（米）。楼板是显示用的薄片，让每层在同一坐标系里可见。
  static const double kFloorSlabThicknessM = 0.8;

  /// 门牌标注的完整属性（setLayerProperties 会重置未列字段，必须全量下发）。
  SymbolLayerProperties _roomLabelProps(
    double offsetEm, {
    String? selectedRoomId,
  }) => SymbolLayerProperties(
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
        selectedRoomId ?? '',
      ],
      '#1475F5',
      '#37415C',
    ],
    textHaloColor: 'rgba(255,255,255,0.92)',
    textHaloWidth: 1.2,
    textOffset: [0, -offsetEm],
    visibility: 'visible',
  );

  /// 门牌抬升量（em）：楼层顶面相对地面的屏幕上移 = 高度 × sin(倾角) / 地面分辨率。
  double _labelOffsetEm(CampusMapBridge b) {
    final cam = _camera ?? b.cameraPosition;
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
    final b = _bridge;
    if (b == null ||
        !_ready ||
        config.floor == null ||
        !_hasLayer('campus-floor-room-labels')) {
      return;
    }
    final em = _labelOffsetEm(b);
    if (_appliedLabelOffsetEm != null &&
        (em - _appliedLabelOffsetEm!).abs() < 0.08) {
      return;
    }
    _appliedLabelOffsetEm = em;
    unawaited(
      b
          .setLayerProperties(
            'campus-floor-room-labels',
            _roomLabelProps(em, selectedRoomId: config.selectedRoom?.id),
          )
          .catchError((Object _) {}),
    );
  }

  /// 某层的底面高度：优先后端 elevation_m，缺失时按层号推算。
  double _floorBase(CampusMapCanvas value, String? floorId) {
    for (final floor in value.selectedPlace?.floors ?? const <CampusFloor>[]) {
      if (floor.id == floorId) return floorBaseElevation(floor);
    }
    return 0;
  }

  FillExtrusionLayerProperties _ghostFloorProps(
    double baseElevation,
    double opacity,
  ) => FillExtrusionLayerProperties(
    fillExtrusionColor: '#E3E9F0',
    fillExtrusionOpacity: opacity,
    // 顶面同样要是绝对高度，否则每层楼板会倒挂成通高立柱（重影根因）。
    fillExtrusionHeight: baseElevation + kFloorSlabThicknessM * 0.4,
    fillExtrusionBase: baseElevation,
    visibility: 'visible',
  );

  /// 楼层叠放：每个楼层按自身海拔铺一块楼板，一层层叠起来；
  /// 当前层实色着色，下方楼层按距离递减透明度托底；
  /// 当前层上方的楼层不显示，避免遮挡当前层。
  Future<void> _syncStackedFloors(
    CampusMapBridge b,
    CampusMapCanvas value,
  ) async {
    final floors = value.selectedPlace?.floors ?? const <CampusFloor>[];
    final current = value.floor;
    if (current == null || floors.isEmpty) {
      await _clearGroup(b, 4);
      _appliedStackFloors.clear();
      return;
    }
    final buildingId = _selectedBuildingId(value) ?? '';
    final desired =
        <
          ({
            CampusFloor floor,
            Map<String, dynamic> raw,
            Map<String, dynamic>? subset,
            double base,
            double opacity,
          })
        >[];
    for (final floor in floors) {
      if (floor.id == current.id) continue;
      // 高于当前层的幽灵层会压在当前层上面，直接跳过。
      if (floor.number > current.number) continue;
      final raw = value.ghostFloorsGeoJson[floor.id];
      if (raw == null) continue;
      final existing = _appliedStackFloors[floor.id];
      Map<String, dynamic>? subset;
      if (existing == null ||
          !identical(existing.raw, raw) ||
          existing.buildingId != buildingId) {
        subset = _subset(
          raw,
          (p) => p['building_id'] == buildingId && p['floor_id'] == floor.id,
        );
        if (subset == null || (subset['features'] as List).isEmpty) continue;
      }
      final distance = (floor.number - current.number).abs();
      final opacity = (0.34 - 0.07 * distance).clamp(0.08, 0.34);
      desired.add((
        floor: floor,
        raw: raw,
        subset: subset,
        base: floorBaseElevation(floor),
        opacity: opacity,
      ));
    }
    final desiredIds = {for (final item in desired) item.floor.id};
    for (final mountedId in _appliedStackFloors.keys.toList()) {
      if (desiredIds.contains(mountedId)) continue;
      final sourceId = 'campus-stack-$mountedId';
      await _removeLayerById(b, '$sourceId-slab');
      await _removeSourceById(b, sourceId);
      _appliedStackFloors.remove(mountedId);
    }
    for (var i = 0; i < desired.length; i++) {
      final item = desired[i];
      final sourceId = 'campus-stack-${item.floor.id}';
      final layerId = '$sourceId-slab';
      final prev = _appliedStackFloors[item.floor.id];
      if (prev == null) {
        String? below;
        for (var j = i + 1; j < desired.length; j++) {
          final nextLayerId = 'campus-stack-${desired[j].floor.id}-slab';
          if (_hasLayer(nextLayerId)) {
            below = nextLayerId;
            break;
          }
        }
        below ??= _belowAfterGroup(4);
        await _addSource(b, sourceId, item.subset!, group: 4);
        await b.addFillExtrusionLayer(
          sourceId,
          layerId,
          _ghostFloorProps(item.base, item.opacity),
          filter: [
            'in',
            ['get', 'kind'],
            [
              'literal',
              ['room', 'corridor', 'facility', 'door'],
            ],
          ],
          belowLayerId: below,
          enableInteraction: false,
        );
        _registerLayer(layerId, 4);
      } else {
        if (item.subset != null) {
          await b.setGeoJsonSource(sourceId, item.subset!);
        }
        if (prev.base != item.base || prev.opacity != item.opacity) {
          await b.setLayerProperties(
            layerId,
            _ghostFloorProps(item.base, item.opacity),
          );
        }
      }
      _appliedStackFloors[item.floor.id] = (
        raw: item.raw,
        buildingId: buildingId,
        base: item.base,
        opacity: item.opacity,
      );
    }
  }

  /// 命中选择：插件返回的 Feature 不带图层信息，因此按图层分别查询，
  /// 顺序为「当前楼层房间 → 建筑碰撞箱 → 街景覆盖」，取最先命中的目标。
  Future<void> _onTap(Point<double> point, LatLng _) async {
    final b = _bridge;
    if (b == null || !_ready) return;
    // 0.28 起点击位置在各平台都是逻辑像素，查询矩形同为其坐标系。
    final rect = Rect.fromCenter(
      center: Offset(point.x, point.y),
      width: 48,
      height: 48,
    );
    Future<List> hitsOn(List<String> layerIds) =>
        b.queryRenderedFeaturesInRect(rect, layerIds, null);
    Map<String, dynamic> propertiesOf(Object? raw) => raw is Map
        ? Map<String, dynamic>.from(raw['properties'] as Map? ?? const {})
        : const {};
    try {
      if (config.floor == null &&
          config.markerPlaces.isNotEmpty &&
          _hasLayer('campus-markers-dot')) {
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
    } catch (error, stackTrace) {
      _log.warning(
        'feature.query_failed',
        error: error,
        stackTrace: stackTrace,
      );
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

  Future<void> _updateCamera(CampusMapBridge b) async {
    final current = b.cameraPosition;
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
      await _followCamera(b, current);
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
        await b.moveCamera(update);
      } else {
        await b.animateCamera(
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
        await b.moveCamera(update);
      } else {
        await b.animateCamera(
          update,
          duration: const Duration(milliseconds: 400),
        );
      }
    }
  }

  /// 导航跟随：锁定在当前位置，按前进方向旋转、倾斜 50° 看前方（仿百度步行导航）。
  Future<void> _followCamera(CampusMapBridge b, CameraPosition? current) async {
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
      await b.moveCamera(update);
    } else {
      await b.animateCamera(
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
    _shuttleStyleEpoch++;
    _styleEpoch++;
    _ready = false;
    _shuttleCameraTimer?.cancel();
    _shuttleCameraTimer = null;
    final epoch = _mapRevision;
    await _queue;
    if (!mounted || epoch != _mapRevision) return;
    _bridge = null;
    _resetStyleState();
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
    _styleEpoch++;
    _shuttleCameraTimer?.cancel();
    _shuttleCameraTimer = null;
    _shuttleAnimation.dispose();
    _loadTimeout?.cancel();
    _bridge = null;
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
          // Android 上用 TextureView 承载地图，由 Flutter 当普通纹理层合成。插件默认的
          // SurfaceView 在 release 包里时常出现多帧叠成一片、地图发白的重影。
          // 只影响合成方式，3D 体块、倾斜视角照常渲染；iOS 和 web 忽略该参数。
          androidView: const AndroidMapView(
            surface: AndroidMapSurface.textureView,
          ),
          onMapCreated: (c) => _bridge =
              CampusMapNative.debugBridgeOverride?.call(c) ??
              _MapLibreBridge(c),
          onStyleLoadedCallback: () {
            _shuttleStyleEpoch++;
            _styleEpoch++;
            _shuttleStationsDirty = true;
            _loadTimeout?.cancel();
            // 新样式不含任何自绘图层：清空登记，整组重新挂载。排进队列执行，
            // 让旧样式上还没跑完的同步先收尾，避免它在清空后又登记旧图层。
            _queue = _queue.then((_) {
              _resetStyleState();
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
            if (config.mapLayer == CampusMapLayer.transit) {
              _shuttleStationsDirty = true;
              _shuttleCameraTimer ??= Timer(
                const Duration(milliseconds: 100),
                () {
                  _shuttleCameraTimer = null;
                  _scheduleShuttleUpdate(immediate: true);
                },
              );
            }
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
