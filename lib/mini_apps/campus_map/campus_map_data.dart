import 'dart:math';

/// Categories assigned by the campus data service.
enum PlaceCategory { study, food, sports, services }

/// 底图图层模式。
///
/// - standard：标准 2D 俯视；
/// - city3d：3D 城市（倾斜视角 + 建筑体块拉伸）；
/// - satellite：卫星图。**暂未接入影像源，仅预留枚举与面板入口**；
///   接入时提供卫星栅格样式/瓦片源，并在图层面板启用对应卡片即可；
/// - transit：公交地铁（高亮公交站类地物）；
/// - streetView：街景覆盖。
enum CampusMapLayer { standard, city3d, satellite, transit, streetView }

/// 通用地物类别 → 中文名。与后端 `map_features.kind` 的白名单、管理台的下拉项
/// 一一对应；新增类别需要同时改这三处（后端迁移里的 CHECK 是权威来源）。
const Map<String, String> kFeatureKindLabels = {
  'road': '道路',
  'path': '小径',
  'green': '绿地',
  'water': '水系',
  'square': '广场',
  'sports': '运动场地',
  'gate': '校门',
  'bus_stop': '公交站',
  'parking': '停车点',
  'food': '餐饮',
  'shop': '商店',
  'study': '学习场所',
  'service': '服务设施',
  'sculpture': '景观雕塑',
  'facility': '设施',
  'other': '其他',
};

String featureKindLabel(String? kind) {
  if (kind == null || kind.isEmpty) return '地物';
  return kFeatureKindLabels[kind] ?? kind;
}

/// 建筑类型 → 中文名。与后端 `buildings.category` 的 CHECK（迁移 000007）、
/// 管理台下拉项、地图图标（后端 configs/sprites/campus/*.svg）一一对应；
/// 新增类型要同时改这几处，并在面板里补图标与配色。
const Map<String, String> kBuildingTypeLabels = {
  'dormitory': '宿舍',
  'teaching': '教学楼',
  'lab': '实验楼',
  'library': '图书馆',
  'canteen': '食堂餐厅',
  'office': '办公楼',
  'commercial': '商业区',
  'sports': '体育场馆',
  'other': '其他',
};

/// 建筑类型归入 App 的分类筛选；宿舍、办公楼等没有对应分类的返回 null。
PlaceCategory? buildingTypeCategory(String? type) => switch (type) {
  'teaching' || 'lab' || 'library' => PlaceCategory.study,
  'canteen' => PlaceCategory.food,
  'sports' => PlaceCategory.sports,
  'commercial' => PlaceCategory.services,
  _ => null,
};

/// A geographic coordinate in WGS84, independent of the rendering SDK.
class GeoPoint {
  const GeoPoint({required this.longitude, required this.latitude});

  final double longitude;
  final double latitude;

  Map<String, dynamic> toJson() => {'lng': longitude, 'lat': latitude};

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
    longitude: (json['lng'] as num).toDouble(),
    latitude: (json['lat'] as num).toDouble(),
  );

  bool get isValid =>
      longitude.isFinite &&
      latitude.isFinite &&
      longitude >= -180 &&
      longitude <= 180 &&
      latitude >= -90 &&
      latitude <= 90;
}

/// 两点的近似距离（米）。校园尺度下等距投影足够准。
double metersBetween(GeoPoint a, GeoPoint b) {
  const metersPerDegree = 111320.0;
  final dLat = (a.latitude - b.latitude) * metersPerDegree;
  final dLng =
      (a.longitude - b.longitude) *
      metersPerDegree *
      cos(a.latitude * pi / 180);
  return sqrt(dLat * dLat + dLng * dLng);
}

/// 步行时间文案：按直线距离、每分钟约 80 米估算，所以带「约」。
String walkingLabel(double meters) {
  if (meters < 60) return '就在附近';
  final minutes = (meters / 80).ceil();
  return minutes > 60
      ? '约 ${(meters / 1000).toStringAsFixed(1)} 公里'
      : '约步行 $minutes 分钟';
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
    this.featureId,
    this.kind,
    this.description = '',
    this.floorId,
    this.navNodeId,
    this.hasIndoor = false,
    this.floors = const [],
    this.sceneId,
    this.entrance,
    this.buildingType,
  });

  final String id;
  final String name;
  final String subtitle;
  final PlaceCategory? category;
  final GeoPoint? center;
  final String? buildingId;
  final int? poiId;

  /// 通用地物编号（`/api/v1/features` 的 feature_id）。三类地物各有自己的
  /// 编号字段：建筑用 buildingId、POI 用 poiId、通用地物用 featureId。
  final int? featureId;

  /// 通用地物类别（road / green / gate…），来自后端 map_features.kind。
  final String? kind;

  /// 说明文字；只有通用地物带这个字段，建筑与 POI 目前为空。
  final String description;

  final String? floorId;
  final int? navNodeId;
  final bool hasIndoor;
  final List<CampusFloor> floors;
  final String? sceneId;
  final GeoPoint? entrance;

  /// 建筑类型（dormitory / teaching…，见 [kBuildingTypeLabels]），只有建筑带。
  /// 地图上的类型图标与楼名分档由服务器样式负责，这里只用于分类筛选与详情标签。
  final String? buildingType;

  /// 是否有可打开的详情页（三类地物都有稳定编号，因此都有）。
  bool get hasDetail =>
      buildingId != null || poiId != null || featureId != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'subtitle': subtitle,
    'category': category?.name,
    'center': center?.toJson(),
    'building_id': buildingId,
    'poi_id': poiId,
    'feature_id': featureId,
    'kind': kind,
    'description': description,
    'floor_id': floorId,
    'nav_node_id': navNodeId,
    'has_indoor': hasIndoor,
    'floors': [for (final floor in floors) floor.toJson()],
    'scene_id': sceneId,
    'entrance': entrance?.toJson(),
    'building_type': buildingType,
  };

  factory CampusPlace.fromJson(Map<String, dynamic> json) {
    final categoryName = json['category'];
    return CampusPlace(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      category: categoryName is String
          ? PlaceCategory.values.asNameMap()[categoryName]
          : null,
      center: json['center'] is Map
          ? GeoPoint.fromJson(Map<String, dynamic>.from(json['center'] as Map))
          : null,
      buildingId: json['building_id'] as String?,
      poiId: (json['poi_id'] as num?)?.toInt(),
      featureId: (json['feature_id'] as num?)?.toInt(),
      kind: json['kind'] as String?,
      description: json['description'] as String? ?? '',
      floorId: json['floor_id'] as String?,
      navNodeId: (json['nav_node_id'] as num?)?.toInt(),
      hasIndoor: json['has_indoor'] == true,
      floors: [
        for (final floor in (json['floors'] as List? ?? const []))
          CampusFloor.fromJson(Map<String, dynamic>.from(floor as Map)),
      ],
      sceneId: json['scene_id'] as String?,
      entrance: json['entrance'] is Map
          ? GeoPoint.fromJson(
              Map<String, dynamic>.from(json['entrance'] as Map),
            )
          : null,
      buildingType: json['building_type'] as String?,
    );
  }
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'description': description,
    'number': number,
    'level_index': levelIndex,
    'elevation_m': elevationM,
  };

  factory CampusFloor.fromJson(Map<String, dynamic> json) => CampusFloor(
    id: json['id'] as String,
    label: json['label'] as String? ?? '',
    description: json['description'] as String? ?? '',
    number: (json['number'] as num).toInt(),
    levelIndex: (json['level_index'] as num?)?.toInt(),
    elevationM: (json['elevation_m'] as num?)?.toDouble(),
  );
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
    this.category,
    this.roomCode,
  });

  final int? poiId;
  final int? navNodeId;

  /// 后端室内要素的 category（classroom / toilet / stair / service…），
  /// 面板按它给房间分组；缺失时为 null，不按名称猜。
  final String? category;

  /// 门牌号（如 N101），没有时为 null。
  final String? roomCode;

  final String id;
  final String name;
  final String floorId;
  final bool isFacility;
}
