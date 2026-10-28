import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_navigation.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_source.dart';

const _origin = GeoPoint(longitude: 118.7, latitude: 32.2);

/// 从 [_origin] 向东 [east] 米、向北 [north] 米处的点。
GeoPoint _at(double east, double north) => GeoPoint(
  longitude:
      _origin.longitude + east / (111320 * cos(_origin.latitude * pi / 180)),
  latitude: _origin.latitude + north / 111320,
);

List<double> _c(double east, double north) {
  final p = _at(east, north);
  return [p.longitude, p.latitude];
}

Map<String, dynamic> _feature(
  List<List<double>> coordinates, [
  Map<String, dynamic> properties = const {},
]) => {
  'type': 'Feature',
  'geometry': {'type': 'LineString', 'coordinates': coordinates},
  'properties': properties,
};

CampusRouteResult _result(List<Map<String, dynamic>> features) =>
    CampusRouteResult(
      geoJson: {'type': 'FeatureCollection', 'features': features},
      instructions: const ['沿校园道路步行', '到达目的地'],
    );

void main() {
  // 先向东 100 米，再向北 100 米：中途应有一次左转。
  final route = NavRoute.fromResult(
    _result([
      _feature([_c(0, 0), _c(50, 0), _c(100, 0), _c(100, 50), _c(100, 100)]),
    ]),
  );

  test('turn detection finds the left turn between two straight legs', () {
    expect(route.length, closeTo(200, 1));
    expect(route.steps.first.maneuver, NavManeuver.depart);
    expect(route.steps.last.maneuver, NavManeuver.arrive);
    final turns = route.steps
        .where((s) => s.maneuver == NavManeuver.left)
        .toList();
    expect(turns, hasLength(1));
    expect(turns.single.along, closeTo(100, 1));
    expect(route.steps, hasLength(3));
  });

  test('locate snaps to the route and reports the next maneuver', () {
    final progress = route.locate(_at(50, 5));
    expect(progress.along, closeTo(50, 1));
    expect(progress.offRoute, closeTo(5, 0.5));
    expect(progress.bearing, closeTo(90, 2));
    expect(progress.next.maneuver, NavManeuver.left);
    expect(progress.distanceToNext, closeTo(50, 1));
    expect(progress.remaining, closeTo(150, 1));

    final later = route.locate(_at(102, 60), hint: progress.along);
    expect(later.next.maneuver, NavManeuver.arrive);
    expect(later.bearing, closeTo(0, 2));
    expect(later.distanceToNext, closeTo(40, 1));
  });

  test('passed geometry ends at the current position', () {
    final passed = route.passedGeoJson(50);
    final features = passed['features'] as List;
    expect(features, hasLength(1));
    final coordinates =
        (features.single as Map)['geometry']['coordinates'] as List;
    final last = coordinates.last as List<double>;
    expect(
      metersBetween(
        GeoPoint(longitude: last[0], latitude: last[1]),
        _at(50, 0),
      ),
      lessThan(0.5),
    );
    expect(route.passedGeoJson(0)['features'], isEmpty);
  });

  test('floor change segments become their own maneuver', () {
    final indoor = NavRoute.fromResult(
      _result([
        _feature([_c(0, 0), _c(30, 0)], {'type': 'indoor'}),
        _feature(
          [_c(30, 0), _c(30, 1)],
          {
            'type': 'floor_change',
            'action': 'stairs',
            'instruction': '经楼梯从 1F 前往 3F',
          },
        ),
        _feature([_c(30, 1), _c(60, 1)], {'type': 'indoor'}),
      ]),
    );
    final change = indoor.steps.singleWhere(
      (s) => s.maneuver == NavManeuver.floorChange,
    );
    expect(change.title, '走楼梯');
    expect(change.detail, '经楼梯从 1F 前往 3F');
    expect(change.along, closeTo(30, 1));
  });

  test('empty route degrades to arrival without throwing', () {
    final empty = NavRoute.fromResult(_result(const []));
    expect(empty.isEmpty, isTrue);
    expect(empty.locate(_origin).next.maneuver, NavManeuver.arrive);
  });

  test('distance and time labels', () {
    expect(navDistanceLabel(8.4), '8 米');
    expect(navDistanceLabel(123), '120 米');
    expect(navDistanceLabel(1530), '1.5 公里');
    expect(navWalkMinutes(10), 1);
    expect(navWalkMinutes(650), 9);
  });

  test('places along the route skip far ones and the endpoints', () {
    final near = CampusPlace(id: 'a', name: '文德楼', center: _at(60, 10));
    final far = CampusPlace(id: 'b', name: '远处楼', center: _at(60, 200));
    final atStart = CampusPlace(id: 'c', name: '起点楼', center: _at(2, 3));
    final via = route.placesAlong([far, atStart, near]);
    expect(via.map((p) => p.name), ['文德楼']);
    expect(route.locate(_at(50, 0)).after?.maneuver, NavManeuver.arrive);
    expect(route.progressAt(100).fraction, closeTo(.5, .01));
  });
}
