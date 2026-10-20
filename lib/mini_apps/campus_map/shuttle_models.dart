import 'dart:math' as math;

import 'campus_map_data.dart';

/// 按地理航向量化的四个车头方向。
enum ShuttleDirection {
  north,
  east,
  south,
  west;

  /// 北为零度，顺时针增加。
  double get degrees => index * 90.0;

  /// 初次取最近方向；后续跨过分界五度才切换。
  static ShuttleDirection fromHeading(
    double heading, [
    ShuttleDirection? previous,
  ]) {
    final normalized = heading % 360;
    if (previous != null) {
      final delta = (normalized - previous.degrees + 540) % 360 - 180;
      if (delta.abs() < 50) return previous;
    }
    return values[((normalized + 45) / 90).floor() % 4];
  }
}

/// 一辆车当前的服务端状态；在线标志直接来自网页使用的 ol 字段。
class ShuttleVehicle {
  const ShuttleVehicle({
    required this.id,
    required this.point,
    required this.heading,
    required this.online,
  });
  final String id;
  final GeoPoint point;
  final double heading;
  final bool online;

  /// 解析网页采用的高德显示坐标并转为 WGS84；无效记录不参与显示。
  static ShuttleVehicle? parse(Map<String, dynamic> row) {
    double? number(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('$v');
    final id = row['vid']?.toString().trim() ?? '';
    final lng = number(row['mlng']);
    final lat = number(row['mlat']);
    final heading = number(row['hx']);
    if (id.isEmpty ||
        lng == null ||
        lat == null ||
        heading == null ||
        !heading.isFinite ||
        !lng.isFinite ||
        !lat.isFinite ||
        lng <= 0 ||
        lng > 180 ||
        lat <= 0 ||
        lat > 90) {
      return null;
    }
    return ShuttleVehicle(
      id: id,
      point: gcjToWgs84(lng, lat),
      heading: heading,
      online: number(row['ol']) == 1,
    );
  }
}

/// 已标注的双向上车点，坐标为最终 WGS84。
class ShuttleStation {
  const ShuttleStation({
    required this.id,
    required this.name,
    required this.first,
    required this.second,
  });
  final String id;
  final String name;
  final GeoPoint first;
  final GeoPoint second;

  /// 缩小时使用双向上车点的中点。
  GeoPoint unifiedPoint() => GeoPoint(
    longitude: (first.longitude + second.longitude) / 2,
    latitude: (first.latitude + second.latitude) / 2,
  );

  /// 双向点的实际屏幕距离达到 24 逻辑像素时拆开。
  List<GeoPoint> displayedPoints(double screenDistance) =>
      screenDistance >= 24 ? [first, second] : [unifiedPoint()];
}

/// 与校准工具相同的五次迭代 GCJ-02 逆变换，保留完整精度。
GeoPoint gcjToWgs84(double longitude, double latitude) {
  var lng = longitude;
  var lat = latitude;
  for (var i = 0; i < 5; i++) {
    final x = lng - 105;
    final y = lat - 35;
    var a =
        -100 +
        2 * x +
        3 * y +
        .2 * y * y +
        .1 * x * y +
        .2 * math.sqrt(x.abs());
    a +=
        (20 * math.sin(6 * x * math.pi) + 20 * math.sin(2 * x * math.pi)) *
        2 /
        3;
    a += (20 * math.sin(y * math.pi) + 40 * math.sin(y / 3 * math.pi)) * 2 / 3;
    a +=
        (160 * math.sin(y / 12 * math.pi) + 320 * math.sin(y * math.pi / 30)) *
        2 /
        3;
    var b = 300 + x + 2 * y + .1 * x * x + .1 * x * y + .1 * math.sqrt(x.abs());
    b +=
        (20 * math.sin(6 * x * math.pi) + 20 * math.sin(2 * x * math.pi)) *
        2 /
        3;
    b += (20 * math.sin(x * math.pi) + 40 * math.sin(x / 3 * math.pi)) * 2 / 3;
    b +=
        (150 * math.sin(x / 12 * math.pi) + 300 * math.sin(x / 30 * math.pi)) *
        2 /
        3;
    final sinLat = math.sin(lat * math.pi / 180);
    final m = 1 - .006693421622965943 * sinLat * sinLat;
    final deltaLng =
        b *
        180 /
        (6378245 / math.sqrt(m) * math.cos(lat * math.pi / 180) * math.pi);
    final deltaLat =
        a *
        180 /
        (6378245 * (1 - .006693421622965943) / (m * math.sqrt(m)) * math.pi);
    lng -= lng + deltaLng - longitude;
    lat -= lat + deltaLat - latitude;
  }
  return GeoPoint(longitude: lng, latitude: lat);
}
