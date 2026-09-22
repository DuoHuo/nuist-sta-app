/// Categories assigned by the campus data service.
enum PlaceCategory { study, food, sports, services }

/// A geographic coordinate in WGS84, independent of the rendering SDK.
class GeoPoint {
  const GeoPoint({required this.longitude, required this.latitude});

  final double longitude;
  final double latitude;

  bool get isValid =>
      longitude.isFinite &&
      latitude.isFinite &&
      longitude >= -180 &&
      longitude <= 180 &&
      latitude >= -90 &&
      latitude <= 90;
}

/// Place metadata supplied by the backend. No local campus records are seeded.
class CampusPlace {
  const CampusPlace({
    required this.id,
    required this.name,
    this.subtitle = '',
    this.category,
    this.center,
    this.buildingId,
    this.poiId,
    this.floorId,
    this.navNodeId,
    this.hasIndoor = false,
    this.floors = const [],
    this.sceneId,
    this.entrance,
  });

  final String id;
  final String name;
  final String subtitle;
  final PlaceCategory? category;
  final GeoPoint? center;
  final String? buildingId;
  final int? poiId;
  final String? floorId;
  final int? navNodeId;
  final bool hasIndoor;
  final List<CampusFloor> floors;
  final String? sceneId;
  final GeoPoint? entrance;
}

class CampusFloor {
  const CampusFloor({
    required this.id,
    required this.label,
    this.description = '',
    required this.number,
    this.levelIndex,
    this.elevationM,
  });

  final int? levelIndex;

  /// 楼层底面海拔（米），来自后端；缺失时为 null。
  final double? elevationM;

  final String id;
  final String label;
  final String description;
  final int number;
}

/// 展示层高（米）。仅在后端未提供 elevation_m 时用于把楼层叠起来显示，
/// 属于渲染参数，不代表测绘结果。
const double kDisplayFloorHeightM = 3.6;

/// 楼层底面高度：优先用后端 elevation_m；缺失时按层号 × 展示层高推算。
double floorBaseElevation(CampusFloor floor) {
  final elevation = floor.elevationM;
  if (elevation != null && elevation.isFinite) return elevation;
  final index = floor.levelIndex;
  if (index != null) return index * kDisplayFloorHeightM;
  return 0;
}

/// Room metadata. The backend GeoJSON owns its shape and geographic position.
class CampusRoom {
  const CampusRoom({
    required this.id,
    required this.name,
    required this.floorId,
    this.isFacility = false,
    this.poiId,
    this.navNodeId,
  });

  final int? poiId;
  final int? navNodeId;

  final String id;
  final String name;
  final String floorId;
  final bool isFacility;
}
