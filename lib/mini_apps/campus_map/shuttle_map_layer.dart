import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'campus_map_data.dart';
import 'shuttle_models.dart';
import 'shuttle_stations.dart';

/// 车辆与站点的原生地图数据；车辆层由调用方放在站点层上方。
abstract final class ShuttleMapLayer {
  /// 只发送当前响应中的车辆；动画起点也仅保留当前屏幕状态。
  static Map<String, dynamic> vehicles(
    List<ShuttleVehicle> vehicles,
    Map<String, ShuttleDirection> directions,
    Map<String, GeoPoint> origins,
    double progress,
  ) => {
    'type': 'FeatureCollection',
    'features': [
      for (final v in vehicles)
        {
          'type': 'Feature',
          'id': v.id,
          'geometry': {
            'type': 'Point',
            'coordinates': [
              (origins[v.id]?.longitude ?? v.point.longitude) * (1 - progress) +
                  v.point.longitude * progress,
              (origins[v.id]?.latitude ?? v.point.latitude) * (1 - progress) +
                  v.point.latitude * progress,
            ],
          },
          'properties': {
            'icon': v.online ? 'shuttle-online' : 'shuttle-offline',
            'heading':
                (directions[v.id] ?? ShuttleDirection.fromHeading(v.heading))
                    .degrees,
          },
        },
    ],
  };

  /// 每组最多一个站名；双向点按实际屏幕间距拆分。
  static Map<String, dynamic> stations(List<double> distances) => {
    'type': 'FeatureCollection',
    'features': [
      for (var i = 0; i < shuttleStations.length; i++)
        for (final entry
            in shuttleStations[i].displayedPoints(distances[i]).indexed)
          {
            'type': 'Feature',
            'id': '${shuttleStations[i].id}-${entry.$1}',
            'geometry': {
              'type': 'Point',
              'coordinates': [entry.$2.longitude, entry.$2.latitude],
            },
            'properties': {
              'name': entry.$1 == 0 ? shuttleStations[i].name : '',
            },
          },
    ],
  };

  /// 将审核通过的俯视小巴矢量形状绘成适配屏幕像素比的透明 PNG。
  static Future<Uint8List> icon(Color bodyColor, double pixelRatio) async {
    final size = (96 * pixelRatio).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(size / 36)
      ..translate(4, 2);
    final fill = Paint()..color = bodyColor;
    final outline = Paint()
      ..color = const Color(0xFF203749)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(6, 2, 16, 28),
      const Radius.circular(5),
    );
    canvas.drawRRect(body, fill);
    canvas.drawRRect(body, outline);
    final windshield = Path()
      ..moveTo(8, 7)
      ..quadraticBezierTo(14, 4, 20, 7)
      ..lineTo(20, 11)
      ..lineTo(8, 11)
      ..close();
    canvas.drawPath(windshield, Paint()..color = const Color(0xFF203749));
    canvas.drawLine(
      const Offset(9, 25),
      const Offset(19, 25),
      Paint()
        ..color = const Color(0xFF203749)
        ..strokeWidth = 2,
    );
    final lights = Paint()
      ..color = const Color(0xFFFFF5BC)
      ..strokeWidth = 2;
    canvas.drawLine(const Offset(8, 4), const Offset(10, 4), lights);
    canvas.drawLine(const Offset(18, 4), const Offset(20, 4), lights);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  /// 插件 Android 投影使用物理像素，iOS 使用逻辑像素。
  static double screenDistance(Point a, Point b, double scale) =>
      sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2)) / scale;
}
