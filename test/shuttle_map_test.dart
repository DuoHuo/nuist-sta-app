import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_canvas.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_native.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/shuttle_models.dart';

class MapSurface extends MapLibreMethodChannel {
  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) => const SizedBox();
}

CampusMapCanvas configuration(
  List<ShuttleVehicle> vehicles, {
  String style = 'synthetic-style',
}) => CampusMapCanvas(
  styleUrl: style,
  selectedPlace: null,
  floor: null,
  selectedRoom: null,
  onPlaceSelected: (_) {},
  onRoomSelected: (_) {},
  mapLayer: CampusMapLayer.transit,
  shuttleVehicles: vehicles,
  shuttleDirections: {for (final v in vehicles) v.id: ShuttleDirection.east},
);

void main() {
  testWidgets('车辆独立更新、覆盖站点、随地图旋转，样式重载恢复图层', (tester) async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('plugins.flutter.io/maplibre_gl_912');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'map#toScreenLocationBatch') {
            return Float64List.fromList(
              List.generate(52, (i) => i.toDouble() * 30),
            );
          }
          return null;
        });
    final originalFactory = MapLibrePlatform.createInstance;
    final platform = MapSurface();
    await platform.initPlatform(912);
    MapLibrePlatform.createInstance = () => platform;
    addTearDown(() {
      MapLibrePlatform.createInstance = originalFactory;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = MapLibreMapController(
      maplibrePlatform: platform,
      annotationOrder: const [],
      annotationConsumeTapEvents: const [],
      initialCameraPosition: const CameraPosition(
        target: LatLng(32.2, 118.7),
        zoom: 16,
      ),
    );
    const vehicle = ShuttleVehicle(
      id: 'a',
      point: GeoPoint(longitude: 118.71, latitude: 32.2),
      heading: 90,
      online: true,
    );
    Widget page(CampusMapCanvas c) =>
        MaterialApp(home: CampusMapNative(configuration: c));
    Future<void> drain() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
      }
      await tester.pump();
    }

    await tester.pumpWidget(page(configuration(const [vehicle])));
    var map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onMapCreated!(controller);
    map.onStyleLoadedCallback!();
    await drain();
    final layers = calls.where((c) => c.method == 'symbolLayer#add').toList();
    expect(
      layers.map((c) => (c.arguments as Map)['layerId']),
      containsAllInOrder(['shuttle-stop-labels', 'shuttle-vehicle-icons']),
    );
    final properties = (layers.last.arguments as Map)['properties'] as Map;
    expect(properties['icon-rotation-alignment'], 'map');
    expect(properties['icon-anchor'], 'center');
    final initialAdds = calls
        .where((c) => c.method == 'source#addGeoJson')
        .length;
    final initialCameraCalls = calls
        .where((c) => c.method == 'camera#animate')
        .length;
    const moved = ShuttleVehicle(
      id: 'a',
      point: GeoPoint(longitude: 118.72, latitude: 32.21),
      heading: 90,
      online: false,
    );
    await tester.pumpWidget(page(configuration(const [moved])));
    await tester.pump(const Duration(milliseconds: 250));
    await drain();
    await tester.pump(const Duration(milliseconds: 500));
    await drain();
    expect(
      calls.where((c) => c.method == 'source#addGeoJson').length,
      initialAdds,
    );
    expect(
      calls.where((c) => c.method == 'camera#animate').length,
      initialCameraCalls,
    );
    final updates = calls.where(
      (c) =>
          c.method == 'source#setGeoJson' &&
          (c.arguments as Map)['sourceId'] == 'shuttle-vehicles',
    );
    expect(updates, isNotEmpty);
    final geojson = jsonDecode(
      (updates.last.arguments as Map)['geojson'] as String,
    );
    expect(geojson['features'].single['geometry']['coordinates'], [
      118.72,
      32.21,
    ]);
    expect(geojson['features'].single['properties']['icon'], 'shuttle-offline');
    map.onCameraMove!(
      const CameraPosition(target: LatLng(32.2, 118.7), zoom: 17, bearing: 90),
    );
    await tester.pump(const Duration(milliseconds: 110));
    await drain();
    await tester.pumpWidget(
      page(configuration(const [moved], style: 'synthetic-style-2')),
    );
    map = tester.widget<MapLibreMap>(find.byType(MapLibreMap));
    map.onStyleLoadedCallback!();
    await drain();
    expect(
      calls.where(
        (c) =>
            c.method == 'symbolLayer#add' &&
            (c.arguments as Map)['layerId'] == 'shuttle-vehicle-icons',
      ),
      hasLength(2),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
