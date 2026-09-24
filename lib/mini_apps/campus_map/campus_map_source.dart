import 'campus_map_data.dart';

class CampusMapSnapshot {
  const CampusMapSnapshot({
    this.places = const [],
    this.buildingGeoJson,
    this.featuresGeoJson,
    this.streetCoverageGeoJson,
    this.styleString,
    this.attribution,
    this.bounds,
    this.warning,
  });

  final String? styleString;
  final String? attribution;
  final List<double>? bounds;
  final String? warning;

  final List<CampusPlace> places;
  final Map<String, dynamic>? buildingGeoJson;

  /// 通用地物（道路/绿地/广场等）的轮廓，由 App 自建图层渲染。
  /// 底图瓦片是派生产物，新提交的地物不会立刻进瓦片，因此业务地物必须自绘。
  final Map<String, dynamic>? featuresGeoJson;

  final Map<String, dynamic>? streetCoverageGeoJson;
}

class CampusFloorSnapshot {
  const CampusFloorSnapshot({this.rooms = const [], this.geoJson});
  final List<CampusRoom> rooms;
  final Map<String, dynamic>? geoJson;
}

class CampusRouteRequest {
  const CampusRouteRequest({
    this.originPlaceId,
    this.originPoint,
    required this.destinationPlaceId,
    this.destinationFloorId,
    this.destinationRoomId,
    this.accessible = false,
  }) : assert(
         originPlaceId != null || originPoint != null,
         '起点必须是地点或坐标之一',
       );

  /// 起点地点编号；以「我的位置」为起点时为 null，由 [originPoint] 提供坐标。
  final String? originPlaceId;

  /// 起点坐标（如我的位置）；与 originPlaceId 二选一。
  final GeoPoint? originPoint;
  final String destinationPlaceId;
  final String? destinationFloorId;
  final String? destinationRoomId;
  final bool accessible;
}

class CampusRouteResult {
  const CampusRouteResult({
    required this.geoJson,
    required this.instructions,
    this.summary,
  });
  final Map<String, dynamic> geoJson;
  final List<String> instructions;
  final String? summary;
}

/// 实现方负责对接实际 API，并把返回数据转换为地图模块模型。
abstract interface class CampusMapSource {
  bool get isConfigured;
  Future<CampusMapSnapshot> loadCampus();
  Future<CampusFloorSnapshot> loadFloor(String buildingId, String floorId);
  Future<CampusRouteResult?> planRoute(CampusRouteRequest request);
}

abstract interface class CampusMapRemoteSource {
  Future<CampusPlace> loadPlace(CampusPlace place);
  Future<List<CampusPlace>> searchPlaces(String query);
  Future<Map<String, dynamic>> locateWifi(
    List<Map<String, dynamic>> observations,
  );
  Future<Map<String, dynamic>> loadFingerprints({
    String? buildingId,
    String? floorId,
  });
  Future<Map<String, dynamic>> submitFingerprint(
    Map<String, dynamic> sample, {
    String? collectToken,
  });
}

class UnconfiguredCampusMapSource implements CampusMapSource {
  const UnconfiguredCampusMapSource();
  @override
  bool get isConfigured => false;
  @override
  Future<CampusMapSnapshot> loadCampus() async => const CampusMapSnapshot();
  @override
  Future<CampusFloorSnapshot> loadFloor(
    String buildingId,
    String floorId,
  ) async => const CampusFloorSnapshot();
  @override
  Future<CampusRouteResult?> planRoute(CampusRouteRequest request) async =>
      null;
}
