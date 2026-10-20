import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'campus_map_data.dart';

class CampusLocationException implements Exception {
  const CampusLocationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一次定位结果：位置 + 水平精度（米，越小越准）。
class LocationFix {
  const LocationFix({required this.point, required this.accuracyM});
  final GeoPoint point;
  final double accuracyM;
}

/// Provides the device's current position for centering the map.
abstract interface class UserLocationSource {
  Future<GeoPoint> current();
}

/// 能持续定位的来源：地图打开期间用它实时更新蓝点和精度圈。
abstract interface class LiveUserLocationSource implements UserLocationSource {
  /// 已有定位权限且定位服务开着（不弹权限框）。
  Future<bool> ready();

  /// 系统缓存的最近一次位置，用来先秒出一个点；没有时为 null。
  Future<LocationFix?> lastKnown();

  /// 一次尽量准的定位：先高精度，超时退到 Wi-Fi / 基站级精度，再退到最近位置。
  Future<LocationFix> currentFix();

  /// 持续位置更新（移动约 3 米以上才推送）。
  Stream<LocationFix> watch();
}

class DeviceUserLocation implements LiveUserLocationSource {
  const DeviceUserLocation();

  /// 最近位置超过这个时长就不拿来当「当前位置」兜底。
  static const _staleAfter = Duration(minutes: 10);

  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const CampusLocationException('定位服务未开启，请在系统设置中打开位置信息');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    switch (permission) {
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        throw const CampusLocationException('未获得定位权限，无法显示你的位置');
      case LocationPermission.deniedForever:
        throw const CampusLocationException('定位权限已被拒绝，请在系统设置中允许');
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        break;
    }
  }

  static LocationFix? _fixOf(Position? position) {
    if (position == null) return null;
    final point = GeoPoint(
      longitude: position.longitude,
      latitude: position.latitude,
    );
    if (!point.isValid) return null;
    return LocationFix(point: point, accuracyM: position.accuracy);
  }

  @override
  Future<bool> ready() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  @override
  Future<LocationFix?> lastKnown() async {
    try {
      return _fixOf(await Geolocator.getLastKnownPosition());
    } catch (_) {
      return null;
    }
  }

  Future<LocationFix?> _attempt(
    LocationAccuracy accuracy,
    Duration limit,
  ) async {
    try {
      return _fixOf(
        await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(
            accuracy: accuracy,
            timeLimit: limit,
          ),
        ),
      );
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<LocationFix> currentFix() async {
    await _ensurePermission();
    // 室内 GPS 往往搜不到星：高精度只等 8 秒，不行就用 Wi-Fi / 基站定位。
    final fix =
        await _attempt(LocationAccuracy.high, const Duration(seconds: 8)) ??
        await _attempt(LocationAccuracy.medium, const Duration(seconds: 8));
    if (fix != null) return fix;
    final last = await Geolocator.getLastKnownPosition();
    final fallback = _fixOf(last);
    if (last != null &&
        fallback != null &&
        DateTime.now().difference(last.timestamp) < _staleAfter) {
      return fallback;
    }
    throw const CampusLocationException('暂时没定位到，请到窗边或室外再试');
  }

  @override
  Future<GeoPoint> current() async => (await currentFix()).point;

  @override
  Stream<LocationFix> watch() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 3,
    ),
  ).map(_fixOf).where((fix) => fix != null).cast<LocationFix>();
}
