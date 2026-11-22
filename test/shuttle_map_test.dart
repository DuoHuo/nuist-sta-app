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

/// 一次对原生地图的调用：方法名和实参，按调用顺序记录。
class _Call {
  _Call(this.name, this.positional, this.named);

  final String name;
  final List<Object?> positional;
  final Map<String, Object?> named;

  /// 位置参数 [index]，缺省时返回 null。
  Object? arg(int index) =>
      index < positional.length ? positional[index] : null;
}

/// 0.28 起插件经带类型的 Pigeon 消息访问原生，不能再 mock method channel，
/// 这里换成假的 [MapLibrePlatform]，记录所有调用并返回空结果。
class _FakePlatform extends MapLibrePlatform {
  final calls = <_Call>[];

  Iterable<_Call> where(String name) => calls.where((c) => c.name == name);

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
    calls.add(_Call('toScreenLocationBatch', [latLngs], const {}));
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
      }),
    );
    // 其余方法都返回空的完成态 Future，足够让控制器继续执行。
    return Future<Null>.value();
  }
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
    final platform = _FakePlatform();
    final originalFactory = MapLibrePlatform.createInstance;
    MapLibrePlatform.createInstance = () => platform;
    addTearDown(() => MapLibrePlatform.createInstance = originalFactory);
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
    final layers = platform.where('addSymbolLayer').toList();
    expect(
      layers.map((c) => c.arg(1)),
      containsAllInOrder(['shuttle-stop-labels', 'shuttle-vehicle-icons']),
    );
    final properties = layers.last.arg(2) as Map;
    expect(properties['icon-rotation-alignment'], 'map');
    expect(properties['icon-anchor'], 'center');
    final initialAdds = platform.where('addGeoJsonSource').length;
    final initialCameraCalls = platform.where('animateCamera').length;
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
    expect(platform.where('addGeoJsonSource').length, initialAdds);
    expect(platform.where('animateCamera').length, initialCameraCalls);
    final updates = platform
        .where('setGeoJsonSource')
        .where((c) => c.arg(0) == 'shuttle-vehicles');
    expect(updates, isNotEmpty);
    final geojson = updates.last.arg(1) as Map;
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
      platform
          .where('addSymbolLayer')
          .where((c) => c.arg(1) == 'shuttle-vehicle-icons'),
      hasLength(2),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
