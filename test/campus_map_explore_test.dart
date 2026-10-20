import 'package:flutter_test/flutter_test.dart';
import 'package:nuist_sta_app/core/schedule/weekly_classes.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_data.dart';
import 'package:nuist_sta_app/mini_apps/campus_map/campus_map_panels.dart';

WeeklyClass lesson(String location) => WeeklyClass(
  courseName: '课',
  location: location,
  weekday: 1,
  startNode: 1,
  endNode: 2,
);

void main() {
  test('本周上课的楼按节数排序，楼名重叠时取最长的', () {
    const places = [
      CampusPlace(id: 'a', name: '理科楼'),
      CampusPlace(id: 'b', name: '理科楼东'),
      CampusPlace(id: 'c', name: '明德楼'),
      CampusPlace(id: 'p', name: '明德楼咖啡', poiId: 9),
      CampusPlace(id: 'u', name: '未命名建筑 1'),
    ];
    final result = weekBuildings([
      lesson('明德楼N101'),
      lesson('明德楼N305'),
      lesson('理科楼东201'),
      lesson('体育馆'),
    ], places);
    expect(result.map((r) => (r.place.id, r.count)), [('c', 2), ('b', 1)]);
  });

  test('离你最近：只列建筑，按距离排序，跳过无坐标与占位名', () {
    const me = GeoPoint(longitude: 118.7000, latitude: 32.2000);
    const places = [
      CampusPlace(
        id: 'far',
        name: '远',
        center: GeoPoint(longitude: 118.7100, latitude: 32.2000),
      ),
      CampusPlace(
        id: 'near',
        name: '近',
        center: GeoPoint(longitude: 118.7005, latitude: 32.2000),
      ),
      CampusPlace(id: 'none', name: '没坐标'),
      // POI 和通用地物不算，只列建筑。
      CampusPlace(
        id: 'poi:1',
        name: '咖啡',
        poiId: 1,
        center: GeoPoint(longitude: 118.7002, latitude: 32.2000),
      ),
      CampusPlace(
        id: 'feature:1',
        name: '草坪',
        featureId: 1,
        center: GeoPoint(longitude: 118.7003, latitude: 32.2000),
      ),
      CampusPlace(
        id: 'u',
        name: '未命名建筑 2',
        center: GeoPoint(longitude: 118.7001, latitude: 32.2000),
      ),
    ];
    expect(nearestPlaces(places, me).map((p) => p.id), ['near', 'far']);
  });

  test('步行时间按直线 80 米 / 分钟估算', () {
    expect(walkingLabel(30), '就在附近');
    expect(walkingLabel(80), '约步行 1 分钟');
    expect(walkingLabel(81), '约步行 2 分钟');
    expect(walkingLabel(6000), '约 6.0 公里');
    const a = GeoPoint(longitude: 118.7, latitude: 32.2);
    const b = GeoPoint(longitude: 118.7, latitude: 32.201);
    expect(metersBetween(a, b), closeTo(111.3, 0.5));
  });
}
