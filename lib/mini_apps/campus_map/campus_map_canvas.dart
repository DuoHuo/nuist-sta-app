import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'campus_map_data.dart';
import 'campus_map_native.dart';

/// A renderer for the unified basemap and backend-owned campus overlays.
///
/// No default style, places, geometry, routing or street imagery is generated.
/// Tests can explicitly set [useNativeMap] to false.
class CampusMapCanvas extends StatelessWidget {
  const CampusMapCanvas({
    super.key,
    required this.styleUrl,
    required this.selectedPlace,
    required this.floor,
    required this.selectedRoom,
    required this.onPlaceSelected,
    required this.onRoomSelected,
    this.places = const [],
    this.rooms = const [],
    this.buildingGeoJson,
    this.featuresGeoJson,
    this.floorGeoJson,
    this.ghostFloorsGeoJson = const {},
    this.routeGeoJson,
    this.streetCoverageGeoJson,
    this.onStreetEntry,
    this.streetCoverage = false,
    this.showRoute = false,
    this.category,
    this.mapLayer = CampusMapLayer.standard,
    this.resetToken = 0,
    this.zoomDelta = 0,
    this.useNativeMap = true,
    this.userPoint,
    this.focusToken = 0,
    this.viewportInsets = EdgeInsets.zero,
  });

  final String styleUrl;
  final CampusPlace? selectedPlace;
  final CampusFloor? floor;
  final CampusRoom? selectedRoom;
  final ValueChanged<CampusPlace> onPlaceSelected;
  final ValueChanged<CampusRoom> onRoomSelected;
  final List<CampusPlace> places;
  final List<CampusRoom> rooms;
  final Map<String, dynamic>? buildingGeoJson;

  /// 通用地物（道路/绿地/广场等）几何；由 App 自绘，不依赖底图瓦片。
  final Map<String, dynamic>? featuresGeoJson;

  final Map<String, dynamic>? floorGeoJson;

  /// 整栋楼各层几何（按楼层 id）。当前层上色，其余层作为半透明楼板叠放，
  /// 形成「就地分层」的 2.5D 效果。
  final Map<String, Map<String, dynamic>> ghostFloorsGeoJson;
  final Map<String, dynamic>? routeGeoJson;
  final Map<String, dynamic>? streetCoverageGeoJson;
  final ValueChanged<CampusPlace>? onStreetEntry;
  final bool streetCoverage;
  final bool showRoute;
  final PlaceCategory? category;

  /// 当前底图图层模式（标准 / 3D 城市 / 公交地铁 / 街景；卫星图预留未接入）。
  final CampusMapLayer mapLayer;
  final int resetToken;
  final int zoomDelta;
  final bool useNativeMap;
  final GeoPoint? userPoint;
  final int focusToken;

  /// 被面板/卡片遮挡的区域（逻辑像素）。选中楼宇时相机按此内缩，
  /// 让目标落在未被遮挡区域的正中，而不是整屏中心。
  final EdgeInsets viewportInsets;

  @override
  Widget build(BuildContext context) {
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (styleUrl.trim().isEmpty || !useNativeMap || !mobile) {
      // Deliberately a plain surface, not an invented map or a map screenshot.
      // The containing page owns empty/configuration/unavailable messaging.
      return const ColoredBox(color: Color(0xFFF1F3F5));
    }
    return CampusMapNative(key: ValueKey(styleUrl), configuration: this);
  }
}
