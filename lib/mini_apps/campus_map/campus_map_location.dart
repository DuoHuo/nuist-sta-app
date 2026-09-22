import 'package:geolocator/geolocator.dart';

import 'campus_map_data.dart';

class CampusLocationException implements Exception {
  const CampusLocationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Provides the device's current position for centering the map.
abstract interface class UserLocationSource {
  Future<GeoPoint> current();
}

class DeviceUserLocation implements UserLocationSource {
  const DeviceUserLocation();

  @override
  Future<GeoPoint> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const CampusLocationException('定位服务未开启，请在系统设置中打开 GPS');
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
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    final point = GeoPoint(
      longitude: position.longitude,
      latitude: position.latitude,
    );
    if (!point.isValid) throw const CampusLocationException('定位结果无效，请重试');
    return point;
  }
}
