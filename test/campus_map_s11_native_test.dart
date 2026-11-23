import 'dart:math' show Point;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_canvas.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_native.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_models.dart';

class _Call {
  _Call(this.name, this.positional, this.named, this.frameTime);

  final String name;
  final List<Object?> positional;
  final Map<String, Object?> named;
  final Duration frameTime;

  Object? arg(int index) =>
      index < positional.length ? positional[index] : null;
}

class _FakeMapLibrePlatform extends MapLibrePlatform {
  final calls = <_Call>[];
  Duration simulatedElapsed = Duration.zero;

  Iterable<_Call> where(String name) => calls.where((c) => c.name == name);

  void clearCalls() => calls.clear();

  @override
  Future<void> initPlatform(int id) async {}

  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) => const SizedBox();

  @override
  Future<List<Point>> toScreenLocationBatch(Iterable<LatLng> latLngs) async {
    calls.add(
      _Call('toScreenLocationBatch', [latLngs], const {}, simulatedElapsed),
    );
    return [
      for (var i = 0; i < latLngs.length; i++)
        Point(i.toDouble() * 30, i.toDouble() * 30),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName
        .toString()
        .replaceFirst('Symbol("', '')
        .replaceFirst('")', '');
    calls.add(
      _Call(name, invocation.positionalArguments, {
        for (final entry in invocation.namedArguments.entries)
          entry.key
                  .toString()
                  .replaceFirst('Symbol("', '')
                  .replaceFirst('")', ''):
              entry.value,
      }, simulatedElapsed),
    );
    return Future<Null>.value();
  }
}

class _SpyBridge implements CampusMapBridge {
  _SpyBridge(this._inner);

  final MapLibreMapController _inner;
  final List<(String layerId, LayerProperties props)> layerPropertyUpdates = [];

  @override
  CameraPosition? get cameraPosition => _inner.cameraPosition;

  @override
  Future<void> addImage(String name, Uint8List bytes) =>
      _inner.addImage(name, bytes);

  @override
  Future<void> addGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson,
  ) => _inner.addGeoJsonSource(sourceId, geojson);

  @override
  Future<void> setGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson,
  ) => _inner.setGeoJsonSource(sourceId, geojson);

  @override
  Future<void> removeSource(String sourceId) => _inner.removeSource(sourceId);

  @override
  Future<void> addFillLayer(
    String sourceId,
    String layerId,
    FillLayerProperties properties, {
    String? belowLayerId,
    dynamic filter,
    bool enableInteraction = true,
  }) => _inner.addFillLayer(
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
  }) => _inner.addFillExtrusionLayer(
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
  }) => _inner.addLineLayer(
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
  }) => _inner.addCircleLayer(
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
  }) => _inner.addSymbolLayer(
    sourceId,
    layerId,
    properties,
    belowLayerId: belowLayerId,
    filter: filter,
    enableInteraction: enableInteraction,
  );

  @override
  Future<void> setLayerProperties(String layerId, LayerProperties properties) {
    layerPropertyUpdates.add((layerId, properties));
    return _inner.setLayerProperties(layerId, properties);
  }

  @override
  Future<void> setLayerFilter(String layerId, dynamic filter) =>
      _inner.setLayerFilter(layerId, filter);

  @override
  Future<void> removeLayer(String layerId) => _inner.removeLayer(layerId);

  @override
  Future<List<dynamic>> queryRenderedFeaturesInRect(
    Rect rect,
    List<String> layerIds,
    String? filter,
  ) => _inner.queryRenderedFeaturesInRect(rect, layerIds, filter);

  @override
  Future<List<Point>> toScreenLocationBatch(Iterable<LatLng> latLngs) =>
      _inner.toScreenLocationBatch(latLngs);

  @override
  Future<bool?> moveCamera(CameraUpdate update) => _inner.moveCamera(update);

  @override
  Future<bool?> animateCamera(CameraUpdate update, {Duration? duration}) =>
      _inner.animateCamera(update, duration: duration);
}

Map<String, dynamic> _polygonFeature(
  String idKey,
  Object idValue, {
  Map<String, dynamic> extra = const {},
}) => {
  'type': 'Feature',
  'geometry': {
    'type': 'Polygon',
    'coordinates': [
      [
        [118.700, 32.200],
        [118.701, 32.200],
        [118.701, 32.201],
        [118.700, 32.201],
        [118.700, 32.200],
      ],
    ],
  },
  'properties': {idKey: idValue, ...extra},
};

Map<String, dynamic> _buildingsGeoJson() => {
  'type': 'FeatureCollection',
  'features': [
    _polygonFeature('building_id', 'b1'),
    _polygonFeature('building_id', 'b2'),
  ],
};

Map<String, dynamic> _featuresGeoJson() => {
  'type': 'FeatureCollection',
  'features': [
    _polygonFeature('feature_id', 101),
    _polygonFeature('feature_id', 102),
  ],
};

Map<String, dynamic> _floorGeoJson(String buildingId, String floorId) => {
  'type': 'FeatureCollection',
  'features': [
    _polygonFeature(
      'room_id',
      'r1',
      extra: {
        'building_id': buildingId,
        'floor_id': floorId,
        'kind': 'room',
        'room_code': '101',
      },
    ),
    _polygonFeature(
      'room_id',
      'r2',
      extra: {
        'building_id': buildingId,
        'floor_id': floorId,
        'kind': 'room',
        'room_code': '102',
      },
    ),
  ],
};

const _floor1 = CampusFloor(id: 'f1', label: '1F', number: 1, levelIndex: 0);
const _placeB1 = CampusPlace(
  id: 'b1',
  name: '明德楼',
  category: PlaceCategory.study,
  center: GeoPoint(longitude: 118.7005, latitude: 32.2005),
  hasIndoor: true,
  floors: [_floor1],
);
const _placeB2 = CampusPlace(
  id: 'b2',
  name: '文德楼',
  category: PlaceCategory.study,
  center: GeoPoint(longitude: 118.7025, latitude: 32.2025),
);
const _placeF1 = CampusPlace(
  id: 'feat-101',
  name: '操场',
  featureId: 101,
  center: GeoPoint(longitude: 118.703, latitude: 32.203),
);
const _placeF2 = CampusPlace(
  id: 'feat-102',
  name: '广场',
  featureId: 102,
  center: GeoPoint(longitude: 118.704, latitude: 32.204),
);
const _placePoi1 = CampusPlace(
  id: 'poi-1',
  name: '咖啡厅',
  poiId: 1,
  center: GeoPoint(longitude: 118.705, latitude: 32.205),
);
const _placePoi2 = CampusPlace(
  id: 'poi-2',
  name: '打印店',
  poiId: 2,
  center: GeoPoint(longitude: 118.706, latitude: 32.206),
);

Map<String, dynamic> _routeGeoJson() => {
  'type': 'FeatureCollection',
  'features': [
    {
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          [118.700, 32.200],
          [118.701, 32.201],
          [118.702, 32.202],
        ],
      },
      'properties': const <String, dynamic>{},
    },
  ],
};

CampusMapCanvas _canvas({
  CampusPlace? selectedPlace,
  CampusFloor? floor,
  CampusRoom? selectedRoom,
  CampusMapLayer mapLayer = CampusMapLayer.standard,
  Map<String, dynamic>? buildingGeoJson,
  Map<String, dynamic>? featuresGeoJson,
  Map<String, dynamic>? floorGeoJson,
  Map<String, dynamic>? routeGeoJson,
  Map<String, dynamic>? routePassedGeoJson,
  bool showRoute = false,
  List<CampusPlace> places = const [_placeB1, _placeB2, _placeF1, _placeF2],
  List<CampusPlace> markerPlaces = const [],
  GeoPoint? userPoint,
  double? userHeading,
  List<ShuttleVehicle> shuttleVehicles = const [],
  Map<String, ShuttleDirection> shuttleDirections = const {},
}) => CampusMapCanvas(
  styleUrl: '{"version":8,"sources":{},"layers":[]}',
  selectedPlace: selectedPlace,
  floor: floor,
  selectedRoom: selectedRoom,
  onPlaceSelected: (_) {},
  onRoomSelected: (_) {},
  places: places,
  buildingGeoJson: buildingGeoJson,
  featuresGeoJson: featuresGeoJson,
  floorGeoJson: floorGeoJson,
  routeGeoJson: routeGeoJson,
  routePassedGeoJson: routePassedGeoJson,
  showRoute: showRoute,
  mapLayer: mapLayer,
  markerPlaces: markerPlaces,
  userPoint: userPoint,
  userHeading: userHeading,
  shuttleVehicles: shuttleVehicles,
  shuttleDirections: shuttleDirections,
);

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump();
}

Future<MapLibreMapController> _mountMap(
  WidgetTester tester,
  _FakeMapLibrePlatform platform,
  CampusMapCanvas initial,
) async {
  final controller = MapLibreMapController(
    maplibrePlatform: platform,
    annotationOrder: const [],
    annotationConsumeTapEvents: const [],
    initialCameraPosition: const CameraPosition(
      target: LatLng(32.2, 118.7),
      zoom: 17,
      tilt: 45,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(home: CampusMapNative(configuration: initial)),
  );
  final map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
  map.onMapCreated!(controller);
  map.onStyleLoadedCallback!();
  await _drain(tester);
  return controller;
}

void main() {
  late _FakeMapLibrePlatform platform;
  late MapLibrePlatform Function() originalFactory;

  setUp(() {
    platform = _FakeMapLibrePlatform();
    originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => platform;
    CampusMapNative.debugClock = DateTime.now;
    CampusMapNative.debugBridgeOverride = null;
  });

  tearDown(() {
    MapLibrePlatform.createInstance = originalFactory;
    CampusMapNative.debugClock = DateTime.now;
    CampusMapNative.debugBridgeOverride = null;
  });

  testWidgets(
    'campus-user GPS and heading updates happen in-place with complete properties and zero teardown',
    (tester) async {
      var now = DateTime(2026, 11, 23, 12, 0, 0);
      CampusMapNative.debugClock = () => now;

      final spyBridges = <_SpyBridge>[];
      CampusMapNative.debugBridgeOverride = (c) {
        final bridge = _SpyBridge(c);
        spyBridges.add(bridge);
        return bridge;
      };

      const vehicle = ShuttleVehicle(
        id: 'bus-1',
        point: GeoPoint(longitude: 118.71, latitude: 32.2),
        heading: 90,
        online: true,
      );

      final controller = await _mountMap(
        tester,
        platform,
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: null,
          userHeading: null,
        ),
      );

      // Initial mount created campus-user source + 3 layers once, hidden initially.
      expect(
        platform
            .where('addGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-user'),
        hasLength(1),
      );
      expect(
        platform
            .where('addSymbolLayer')
            .where((c) => c.arg(1) == 'campus-user-heading'),
        hasLength(1),
      );
      expect(
        platform
            .where('addCircleLayer')
            .where((c) => c.arg(1) == 'campus-user-halo'),
        hasLength(1),
      );
      expect(
        platform
            .where('addCircleLayer')
            .where((c) => c.arg(1) == 'campus-user-dot'),
        hasLength(1),
      );

      platform.clearCalls();

      // 1. First valid GPS fix + heading -> updates source and makes all 3 layers visible.
      Future<void> push(CampusMapCanvas next) async {
        await tester.pumpWidget(
          MaterialApp(home: CampusMapNative(configuration: next)),
        );
        await _drain(tester);
      }

      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: const GeoPoint(longitude: 118.701, latitude: 32.201),
          userHeading: 45,
        ),
      );

      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('removeSource'), isEmpty);
      expect(platform.where('addGeoJsonSource'), isEmpty);
      expect(platform.where('addSymbolLayer'), isEmpty);
      expect(platform.where('addCircleLayer'), isEmpty);

      final userSourceUpdates = platform
          .where('setGeoJsonSource')
          .where((c) => c.arg(0) == 'campus-user')
          .toList();
      expect(userSourceUpdates, hasLength(1));
      final feature =
          (userSourceUpdates.single.arg(1) as Map)['features'].single as Map;
      expect(feature['geometry']['coordinates'], [118.701, 32.201]);

      // Verify COMPLETE non-null serialized properties for all 3 layers.
      final propCalls = platform.where('setLayerProperties').toList();
      final haloJson =
          propCalls.singleWhere((c) => c.arg(0) == 'campus-user-halo').arg(1)
              as Map<String, dynamic>;
      expect(haloJson['circle-color'], '#1475F5');
      expect(haloJson['circle-opacity'], 0.18);
      expect(haloJson['circle-radius'], 16);
      expect(haloJson['visibility'], 'visible');

      final dotJson =
          propCalls.singleWhere((c) => c.arg(0) == 'campus-user-dot').arg(1)
              as Map<String, dynamic>;
      expect(dotJson['circle-color'], '#1475F5');
      expect(dotJson['circle-radius'], 7);
      expect(dotJson['circle-stroke-color'], '#FFFFFF');
      expect(dotJson['circle-stroke-width'], 3);
      expect(dotJson['visibility'], 'visible');

      final headingJson =
          propCalls.singleWhere((c) => c.arg(0) == 'campus-user-heading').arg(1)
              as Map<String, dynamic>;
      expect(headingJson['icon-image'], 'campus-user-heading-beam');
      expect(headingJson['icon-rotate'], 45);
      expect(headingJson['icon-rotation-alignment'], 'map');
      expect(headingJson['icon-pitch-alignment'], 'map');
      expect(headingJson['icon-allow-overlap'], isTrue);
      expect(headingJson['icon-ignore-placement'], isTrue);
      expect(headingJson['icon-anchor'], 'center');
      expect(headingJson['visibility'], 'visible');

      expect(
        spyBridges.single.layerPropertyUpdates.map((e) => e.$1),
        containsAll([
          'campus-user-halo',
          'campus-user-dot',
          'campus-user-heading',
        ]),
      );

      // 2. Subsequent GPS moves + heading rotations >= 3 deg & >= 80ms.
      platform.clearCalls();
      now = now.add(const Duration(milliseconds: 100));
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: const GeoPoint(longitude: 118.702, latitude: 32.202),
          userHeading: 90,
        ),
      );
      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('removeSource'), isEmpty);
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-user'),
        hasLength(1),
      );
      final rotatedJson =
          platform
                  .where('setLayerProperties')
                  .singleWhere((c) => c.arg(0) == 'campus-user-heading')
                  .arg(1)
              as Map<String, dynamic>;
      expect(rotatedJson['icon-rotate'], 90);
      expect(rotatedJson['icon-image'], 'campus-user-heading-beam');
      expect(rotatedJson['icon-rotation-alignment'], 'map');
      expect(rotatedJson['icon-pitch-alignment'], 'map');
      expect(rotatedJson['icon-anchor'], 'center');
      expect(rotatedJson['visibility'], 'visible');

      // 3. Repeated identical coordinate & heading skips redundant platform calls.
      platform.clearCalls();
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: GeoPoint(longitude: 118.702, latitude: 32.202),
          userHeading: 90,
        ),
      );
      expect(platform.where('setGeoJsonSource'), isEmpty);
      expect(platform.where('setLayerProperties'), isEmpty);

      // 4. Small heading jitter (< 3 deg) and fast tick (< 80ms) are skipped.
      now = now.add(const Duration(milliseconds: 200));
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: const GeoPoint(longitude: 118.702, latitude: 32.202),
          userHeading: 91.5,
        ),
      );
      expect(platform.where('setLayerProperties'), isEmpty);

      // Now advance only 20ms since the last actual heading push at 90 deg?
      // Reset baseline with a real rotation, then test a 20ms fast tick.
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: const GeoPoint(longitude: 118.702, latitude: 32.202),
          userHeading: 120,
        ),
      );
      expect(platform.where('setLayerProperties'), hasLength(1));
      platform.clearCalls();

      now = now.add(const Duration(milliseconds: 20));
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: const GeoPoint(longitude: 118.702, latitude: 32.202),
          userHeading: 160,
        ),
      );
      expect(platform.where('setLayerProperties'), isEmpty);

      // 5. Turning heading off (null) and back on hides/shows immediately without teardown.
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: const GeoPoint(longitude: 118.702, latitude: 32.202),
          userHeading: null,
        ),
      );
      final hiddenHeading =
          platform
                  .where('setLayerProperties')
                  .singleWhere((c) => c.arg(0) == 'campus-user-heading')
                  .arg(1)
              as Map<String, dynamic>;
      expect(hiddenHeading['visibility'], 'none');
      expect(hiddenHeading['icon-image'], 'campus-user-heading-beam');
      expect(hiddenHeading['icon-anchor'], 'center');

      platform.clearCalls();
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: const GeoPoint(longitude: 118.702, latitude: 32.202),
          userHeading: 140,
        ),
      );
      final shownHeading =
          platform
                  .where('setLayerProperties')
                  .singleWhere((c) => c.arg(0) == 'campus-user-heading')
                  .arg(1)
              as Map<String, dynamic>;
      expect(shownHeading['visibility'], 'visible');
      expect(shownHeading['icon-rotate'], 140);

      // 6. Clearing userPoint hides user layers in-place with zero removals.
      platform.clearCalls();
      await push(
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vehicle],
          userPoint: null,
          userHeading: 140,
        ),
      );
      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('removeSource'), isEmpty);
      final clearProps = platform.where('setLayerProperties').toList();
      expect(
        clearProps.map((c) => c.arg(0)),
        containsAll([
          'campus-user-halo',
          'campus-user-dot',
          'campus-user-heading',
        ]),
      );
      for (final call in clearProps) {
        expect((call.arg(1) as Map)['visibility'], 'none');
      }

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    '3D building and indoor room highlights update via complete setLayerProperties without teardown',
    (tester) async {
      final buildings = _buildingsGeoJson();
      final floorData = _floorGeoJson('b1', 'f1');

      final controller = await _mountMap(
        tester,
        platform,
        _canvas(
          mapLayer: CampusMapLayer.city3d,
          buildingGeoJson: buildings,
          selectedPlace: null,
        ),
      );

      expect(
        platform
            .where('addFillExtrusionLayer')
            .where((c) => c.arg(1) == 'campus-city3d-volume'),
        hasLength(1),
      );
      platform.clearCalls();

      Future<void> push(CampusMapCanvas next) async {
        await tester.pumpWidget(
          MaterialApp(home: CampusMapNative(configuration: next)),
        );
        await _drain(tester);
      }

      // Switch 3D selected buildings: null -> b1 -> b2 -> b2 (repeat) -> null.
      await push(
        _canvas(
          mapLayer: CampusMapLayer.city3d,
          buildingGeoJson: buildings,
          selectedPlace: _placeB1,
        ),
      );
      await push(
        _canvas(
          mapLayer: CampusMapLayer.city3d,
          buildingGeoJson: buildings,
          selectedPlace: _placeB2,
        ),
      );

      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('removeSource'), isEmpty);
      expect(platform.where('addFillExtrusionLayer'), isEmpty);
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-city3d'),
        isEmpty,
      );

      final cityUpdates = platform
          .where('setLayerProperties')
          .where((c) => c.arg(0) == 'campus-city3d-volume')
          .toList();
      expect(cityUpdates, hasLength(2));
      for (final call in cityUpdates) {
        final props = call.arg(1) as Map<String, dynamic>;
        expect(props['fill-extrusion-opacity'], 0.85);
        expect(props['fill-extrusion-height'], ['get', 'height_m']);
        expect(props['visibility'], 'visible');
      }
      expect(
        (cityUpdates[0].arg(1) as Map)['fill-extrusion-color'][1][2],
        'b1',
      );
      expect(
        (cityUpdates[1].arg(1) as Map)['fill-extrusion-color'][1][2],
        'b2',
      );

      // Identical repeated state skips MapLibre calls completely.
      platform.clearCalls();
      await push(
        _canvas(
          mapLayer: CampusMapLayer.city3d,
          buildingGeoJson: buildings,
          selectedPlace: _placeB2,
        ),
      );
      expect(platform.where('setLayerProperties'), isEmpty);
      expect(platform.where('setGeoJsonSource'), isEmpty);
      expect(platform.where('setLayerFilter'), isEmpty);
      expect(platform.where('setFilter'), isEmpty);

      // Enter indoor mode on b1 floor f1 and switch selected rooms.
      await push(
        _canvas(
          mapLayer: CampusMapLayer.standard,
          buildingGeoJson: buildings,
          selectedPlace: _placeB1,
          floor: _floor1,
          floorGeoJson: floorData,
          selectedRoom: null,
        ),
      );
      platform.clearCalls();

      const room1 = CampusRoom(id: 'r1', name: '101', floorId: 'f1');
      const room2 = CampusRoom(id: 'r2', name: '102', floorId: 'f1');

      await push(
        _canvas(
          mapLayer: CampusMapLayer.standard,
          buildingGeoJson: buildings,
          selectedPlace: _placeB1,
          floor: _floor1,
          floorGeoJson: floorData,
          selectedRoom: room1,
        ),
      );
      await push(
        _canvas(
          mapLayer: CampusMapLayer.standard,
          buildingGeoJson: buildings,
          selectedPlace: _placeB1,
          floor: _floor1,
          floorGeoJson: floorData,
          selectedRoom: room2,
        ),
      );

      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('removeSource'), isEmpty);
      expect(platform.where('addFillExtrusionLayer'), isEmpty);
      expect(platform.where('addSymbolLayer'), isEmpty);
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-floor'),
        isEmpty,
      );

      final slabUpdates = platform
          .where('setLayerProperties')
          .where((c) => c.arg(0) == 'campus-floor-slab')
          .toList();
      final labelUpdates = platform
          .where('setLayerProperties')
          .where((c) => c.arg(0) == 'campus-floor-room-labels')
          .toList();
      expect(slabUpdates, hasLength(2));
      expect(labelUpdates, hasLength(2));

      for (final call in slabUpdates) {
        final props = call.arg(1) as Map<String, dynamic>;
        expect(props['fill-extrusion-opacity'], 1);
        expect(props['fill-extrusion-height'], isNotNull);
        expect(props['fill-extrusion-base'], isNotNull);
        expect(props['visibility'], 'visible');
      }
      for (final call in labelUpdates) {
        final props = call.arg(1) as Map<String, dynamic>;
        expect(props['text-field'], isNotNull);
        expect(props['text-font'], ['Noto Sans Regular']);
        expect(props['text-size'], 11);
        expect(props['text-halo-color'], 'rgba(255,255,255,0.92)');
        expect(props['text-halo-width'], 1.2);
        expect(props['text-offset'], isNotNull);
        expect(props['visibility'], 'visible');
      }
      expect(
        (slabUpdates[1].arg(1) as Map)['fill-extrusion-color'][1][2],
        'r2',
      );
      expect((labelUpdates[1].arg(1) as Map)['text-color'][1][2], 'r2');

      // Repeating identical selectedRoom skips all layer calls.
      platform.clearCalls();
      await push(
        _canvas(
          mapLayer: CampusMapLayer.standard,
          buildingGeoJson: buildings,
          selectedPlace: _placeB1,
          floor: _floor1,
          floorGeoJson: floorData,
          selectedRoom: room2,
        ),
      );
      expect(platform.where('setLayerProperties'), isEmpty);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    '2D building/feature/pin/marker highlights and route-passed GeoJSON update in-place without redundant pushes',
    (tester) async {
      final buildings = _buildingsGeoJson();
      final features = _featuresGeoJson();
      final route = _routeGeoJson();
      final markers = [_placeB1, _placeB2, _placePoi1];

      final controller = await _mountMap(
        tester,
        platform,
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
        ),
      );

      Future<void> push(CampusMapCanvas next) async {
        await tester.pumpWidget(
          MaterialApp(home: CampusMapNative(configuration: next)),
        );
        await _drain(tester);
      }

      // First building highlight mounts highlight layers once.
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placeB1,
        ),
      );
      platform.clearCalls();

      // Switch building -> building -> deselect -> building -> feature -> poi1 -> poi2 -> null.
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placeB2,
        ),
      );
      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('removeSource'), isEmpty);
      expect(platform.where('addFillLayer'), isEmpty);
      expect(platform.where('addLineLayer'), isEmpty);
      expect(platform.where('setGeoJsonSource'), isEmpty);
      expect(
        platform
            .where('setFilter')
            .where((c) => c.arg(0) == 'campus-selected-fill')
            .single
            .arg(1),
        [
          '==',
          ['get', 'building_id'],
          'b2',
        ],
      );
      expect(
        platform
            .where('setFilter')
            .where((c) => c.arg(0) == 'campus-markers-dot')
            .single
            .arg(1),
        [
          '!=',
          ['get', 'place_id'],
          'b2',
        ],
      );

      // Deselect hides highlight layers via complete setLayerProperties without removing them.
      platform.clearCalls();
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: null,
        ),
      );
      expect(platform.where('removeLayer'), isEmpty);
      final hiddenFill =
          platform
                  .where('setLayerProperties')
                  .singleWhere((c) => c.arg(0) == 'campus-selected-fill')
                  .arg(1)
              as Map<String, dynamic>;
      expect(hiddenFill['fill-color'], '#1475F5');
      expect(hiddenFill['fill-opacity'], 0.16);
      expect(hiddenFill['visibility'], 'none');

      // POI 1 -> POI 2 updates pin source in-place without teardown.
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placePoi1,
        ),
      );
      platform.clearCalls();
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placePoi2,
        ),
      );
      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('removeSource'), isEmpty);
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-selected-pin'),
        hasLength(1),
      );

      // Deduplicate structurally equivalent routePassedGeoJson payloads.
      platform.clearCalls();
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placePoi2,
          routePassedGeoJson: {
            'type': 'FeatureCollection',
            'features': <Object>[],
          },
        ),
      );
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-route-passed'),
        isEmpty,
      );

      final passedLine = {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [118.700, 32.200],
                [118.7005, 32.2005],
              ],
            },
            'properties': const <String, dynamic>{},
          },
        ],
      };
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placePoi2,
          routePassedGeoJson: passedLine,
        ),
      );
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-route-passed'),
        hasLength(1),
      );

      // Equivalent new map instance with identical passed coordinates is skipped.
      platform.clearCalls();
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placePoi2,
          routePassedGeoJson: {
            'type': 'FeatureCollection',
            'features': [
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'LineString',
                  'coordinates': [
                    [118.700, 32.200],
                    [118.7005, 32.2005],
                  ],
                },
                'properties': const <String, dynamic>{},
              },
            ],
          },
        ),
      );
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-route-passed'),
        isEmpty,
      );

      // Feature highlight 101 -> 102 updates via setFilter without teardown.
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placeF1,
        ),
      );
      platform.clearCalls();
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placeF2,
        ),
      );
      expect(platform.where('removeLayer'), isEmpty);
      expect(platform.where('addLineLayer'), isEmpty);
      expect(
        platform
            .where('setFilter')
            .where((c) => c.arg(0) == 'campus-selected-feature')
            .single
            .arg(1),
        [
          '==',
          ['get', 'feature_id'],
          102,
        ],
      );

      // Entering indoor mode hides markers with complete properties instead of removing them,
      // and exiting restores visibility in-place.
      platform.clearCalls();
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placeB1,
          floor: _floor1,
          floorGeoJson: _floorGeoJson('b1', 'f1'),
        ),
      );
      expect(
        platform
            .where('removeLayer')
            .where((c) => (c.arg(0) as String).startsWith('campus-markers')),
        isEmpty,
      );
      final hiddenMarkers =
          platform
                  .where('setLayerProperties')
                  .singleWhere((c) => c.arg(0) == 'campus-markers-label')
                  .arg(1)
              as Map<String, dynamic>;
      expect(hiddenMarkers['visibility'], 'none');
      expect(hiddenMarkers['text-field'], ['get', 'name']);
      expect(hiddenMarkers['text-size'], 11.5);

      platform.clearCalls();
      await push(
        _canvas(
          buildingGeoJson: buildings,
          featuresGeoJson: features,
          routeGeoJson: route,
          showRoute: true,
          markerPlaces: markers,
          selectedPlace: _placeB1,
          floor: null,
        ),
      );
      final shownMarkers =
          platform
                  .where('setLayerProperties')
                  .singleWhere((c) => c.arg(0) == 'campus-markers-label')
                  .arg(1)
              as Map<String, dynamic>;
      expect(shownMarkers['visibility'], 'visible');
      expect(shownMarkers['text-field'], ['get', 'name']);
      expect(
        platform
            .where('addGeoJsonSource')
            .where((c) => c.arg(0) == 'campus-markers'),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    '_shuttleAnimation throttles dense 16ms ticks to >=33ms intervals and flushes immediately at boundaries',
    (tester) async {
      var simulated = Duration.zero;
      var wall = DateTime(2026, 11, 23, 12, 0, 0);
      CampusMapNative.debugClock = () => wall;

      const vStart = ShuttleVehicle(
        id: 's1',
        point: GeoPoint(longitude: 118.70, latitude: 32.20),
        heading: 90,
        online: true,
      );
      const vMoved = ShuttleVehicle(
        id: 's1',
        point: GeoPoint(longitude: 118.72, latitude: 32.22),
        heading: 90,
        online: true,
      );
      const vMovedAgain = ShuttleVehicle(
        id: 's1',
        point: GeoPoint(longitude: 118.74, latitude: 32.24),
        heading: 90,
        online: true,
      );

      final controller = await _mountMap(
        tester,
        platform,
        _canvas(
          mapLayer: CampusMapLayer.transit,
          shuttleVehicles: const [vStart],
          shuttleDirections: const {'s1': ShuttleDirection.east},
        ),
      );
      platform.clearCalls();

      // Trigger animation start (t == 0.0) via vehicle poll update.
      await tester.pumpWidget(
        MaterialApp(
          home: CampusMapNative(
            configuration: _canvas(
              mapLayer: CampusMapLayer.transit,
              shuttleVehicles: const [vMoved],
              shuttleDirections: const {'s1': ShuttleDirection.east},
            ),
          ),
        ),
      );
      // Let microtasks complete for t == 0.0 boundary flush.
      await tester.pump();

      // Pump 16ms frames for 512ms total (32 ticks > 500ms duration).
      for (var i = 0; i < 32; i++) {
        const step = Duration(milliseconds: 16);
        simulated += step;
        wall = wall.add(step);
        platform.simulatedElapsed = simulated;
        await tester.pump(step);
      }

      final pushes = platform
          .where('setGeoJsonSource')
          .where((c) => c.arg(0) == 'shuttle-vehicles')
          .toList();

      // Must be sharply fewer than 33 unthrottled ticks, and start at 0.0 & end at 1.0.
      expect(pushes.length, lessThanOrEqualTo(13));
      expect(pushes.length, greaterThanOrEqualTo(8));

      final firstCoords =
          ((pushes.first.arg(1) as Map)['features'].single
                  as Map)['geometry']['coordinates']
              as List;
      expect(firstCoords[0], closeTo(118.70, 1e-9));
      expect(firstCoords[1], closeTo(32.20, 1e-9));

      final lastCoords =
          ((pushes.last.arg(1) as Map)['features'].single
                  as Map)['geometry']['coordinates']
              as List;
      expect(lastCoords[0], closeTo(118.72, 1e-9));
      expect(lastCoords[1], closeTo(32.22, 1e-9));

      // All intermediate pushes (before final completion flush) must be >= 33ms apart.
      for (var i = 1; i < pushes.length - 1; i++) {
        final dt = pushes[i].frameTime - pushes[i - 1].frameTime;
        expect(
          dt,
          greaterThanOrEqualTo(const Duration(milliseconds: 33)),
          reason:
              'Intermediate tick $i occurred after only ${dt.inMilliseconds}ms',
        );
      }

      // Now test mid-animation vehicle update flushes immediately at t == 0.0
      // even if only 16ms passed since the previous push, and dispose mid-animation is safe.
      platform.clearCalls();
      await tester.pumpWidget(
        MaterialApp(
          home: CampusMapNative(
            configuration: _canvas(
              mapLayer: CampusMapLayer.transit,
              shuttleVehicles: const [vMovedAgain],
              shuttleDirections: const {'s1': ShuttleDirection.east},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'shuttle-vehicles'),
        hasLength(1),
      );

      // Step 16ms (throttled), then immediately switch off transit layer & dispose.
      platform.clearCalls();
      simulated += const Duration(milliseconds: 16);
      wall = wall.add(const Duration(milliseconds: 16));
      platform.simulatedElapsed = simulated;
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        platform
            .where('setGeoJsonSource')
            .where((c) => c.arg(0) == 'shuttle-vehicles'),
        isEmpty,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CampusMapNative(
            configuration: _canvas(
              mapLayer: CampusMapLayer.standard,
              shuttleVehicles: const [vMovedAgain],
            ),
          ),
        ),
      );
      await _drain(tester);
      expect(
        platform
            .where('removeLayer')
            .where((c) => c.arg(0) == 'shuttle-vehicle-icons'),
        hasLength(1),
      );

      await tester.pumpWidget(const SizedBox());
      await _drain(tester);
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
