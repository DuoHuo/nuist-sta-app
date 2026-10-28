import 'dart:math';

import 'campus_map_data.dart';
import 'campus_map_source.dart';

/// 导航中的动作类型（决定指引条上的箭头图标）。
enum NavManeuver {
  depart,
  straight,
  slightLeft,
  left,
  sharpLeft,
  slightRight,
  right,
  sharpRight,
  uTurn,
  floorChange,
  arrive,
}

/// 路线上的一个动作点：在距起点 [along] 米处做 [maneuver]。
class NavStep {
  const NavStep({
    required this.maneuver,
    required this.along,
    required this.title,
    this.detail,
  });
  final NavManeuver maneuver;
  final double along;

  /// 动作本身，如「左转」「到达目的地」。
  final String title;

  /// 补充说明（后端分段指引，如「经楼梯从 1F 前往 3F」）。
  final String? detail;
}

/// 当前位置在路线上的进度。
class NavProgress {
  const NavProgress({
    required this.snapped,
    required this.along,
    required this.offRoute,
    required this.bearing,
    required this.remaining,
    required this.next,
    required this.distanceToNext,
    this.after,
  });

  /// 吸附到路线上的位置（导航中蓝点与相机都用它，避免定位抖动偏到路外）。
  final GeoPoint snapped;

  /// 已走过的路线长度（米）。
  final double along;

  /// 实际位置离路线的距离（米），用来判断是否偏航。
  final double offRoute;

  /// 前进方向（度，0 = 正北，顺时针）：取前方一小段路线的走向。
  final double bearing;

  /// 剩余路程（米）。
  final double remaining;

  /// 下一个动作点。
  final NavStep next;
  final double distanceToNext;

  /// 下一个动作之后的那个动作（指引条上的「随后 右转」）；没有时为 null。
  final NavStep? after;

  /// 已走过的比例（0~1），右侧进度条用。
  double get fraction => along + remaining <= 0
      ? 1
      : (along / (along + remaining)).clamp(0.0, 1.0);
}

/// 把后端路线（GeoJSON 分段）展开成一条连续折线，算出转向点，
/// 并提供「当前位置 → 路线进度」的吸附计算。
///
/// 后端只给粗分段（室外一段、每层一段、换层一段），逐路口的转向由这里
/// 按折线几何推算：前后各取 [_window] 米的走向，夹角超过 30° 记为一次转弯。
class NavRoute {
  NavRoute._(this.points, this.cumulative, this.steps);

  /// 前后取走向的距离窗口（米）：太短会把路网的小锯齿当成转弯。
  static const double _window = 10;

  /// 相邻转弯合并的距离（米）。
  static const double _mergeWithin = 12;

  factory NavRoute.fromResult(CampusRouteResult result) {
    final points = <GeoPoint>[];
    // 每个分段的起点下标，以及它的类型 / 指引，用来生成换层动作。
    final segmentStarts = <(int, Map<String, dynamic>)>[];
    final features = result.geoJson['features'];
    if (features is List) {
      for (final feature in features.whereType<Map>()) {
        final properties = Map<String, dynamic>.from(
          feature['properties'] as Map? ?? const {},
        );
        final lines = _lines(feature['geometry']);
        var first = true;
        for (final line in lines) {
          for (final point in line) {
            if (points.isNotEmpty && metersBetween(points.last, point) < 0.5) {
              // 分段首点与上一段终点重合：分段从这个已有点开始。
              if (first) {
                segmentStarts.add((points.length - 1, properties));
                first = false;
              }
              continue;
            }
            if (first) {
              segmentStarts.add((points.length, properties));
              first = false;
            }
            points.add(point);
          }
        }
      }
    }
    final cumulative = <double>[];
    var total = 0.0;
    for (var i = 0; i < points.length; i++) {
      if (i > 0) total += metersBetween(points[i - 1], points[i]);
      cumulative.add(total);
    }
    final route = NavRoute._(points, cumulative, const []);
    return NavRoute._(
      points,
      cumulative,
      route._buildSteps(segmentStarts, result.instructions),
    );
  }

  /// 展开后的路线折线。
  final List<GeoPoint> points;

  /// 每个折线点距起点的累计长度（米）。
  final List<double> cumulative;

  /// 出发、各转弯 / 换层、到达，按路线顺序。
  final List<NavStep> steps;

  double get length => cumulative.isEmpty ? 0 : cumulative.last;
  bool get isEmpty => points.length < 2;
  GeoPoint? get start => points.isEmpty ? null : points.first;
  GeoPoint? get end => points.isEmpty ? null : points.last;

  static List<List<GeoPoint>> _lines(Object? geometry) {
    if (geometry is! Map) return const [];
    final coordinates = geometry['coordinates'];
    List<GeoPoint> line(Object? raw) => [
      if (raw is List)
        for (final c in raw)
          if (c is List && c.length >= 2 && c[0] is num && c[1] is num)
            GeoPoint(
              longitude: (c[0] as num).toDouble(),
              latitude: (c[1] as num).toDouble(),
            ),
    ];
    return switch (geometry['type']) {
      'LineString' => [line(coordinates)],
      'MultiLineString' when coordinates is List => [
        for (final part in coordinates) line(part),
      ],
      _ => const [],
    };
  }

  List<NavStep> _buildSteps(
    List<(int, Map<String, dynamic>)> segmentStarts,
    List<String> instructions,
  ) {
    final firstDetail = instructions.isEmpty ? null : instructions.first;
    final steps = <NavStep>[
      NavStep(
        maneuver: NavManeuver.depart,
        along: 0,
        title: '出发',
        detail: firstDetail == '到达目的地' ? null : firstDetail,
      ),
    ];
    if (isEmpty) {
      return [
        ...steps,
        NavStep(maneuver: NavManeuver.arrive, along: 0, title: '到达目的地'),
      ];
    }
    final total = length;
    // 换层：后端的 floor_change 分段起点。
    final floorChanges = <NavStep>[
      for (final (index, properties) in segmentStarts)
        if (properties['type'] == 'floor_change' && index < cumulative.length)
          NavStep(
            maneuver: NavManeuver.floorChange,
            along: cumulative[index],
            title: switch (properties['action']) {
              'elevator' => '乘电梯',
              'ramp' => '走坡道',
              _ => '走楼梯',
            },
            detail: properties['instruction'] as String?,
          ),
    ];
    // 转弯：逐个折线点比较前后走向。
    final turns = <(double, double)>[];
    for (var i = 1; i < points.length - 1; i++) {
      final at = cumulative[i];
      if (at < 5 || total - at < 5) continue;
      final before = pointAt(at - _window);
      final after = pointAt(at + _window);
      final delta = _turnDelta(
        bearingBetween(before, points[i]),
        bearingBetween(points[i], after),
      );
      if (delta.abs() < 30) continue;
      if (turns.isNotEmpty && at - turns.last.$1 < _mergeWithin) {
        if (delta.abs() > turns.last.$2.abs()) turns.last = (at, delta);
        continue;
      }
      turns.add((at, delta));
    }
    final turnSteps = [
      for (final (at, delta) in turns)
        if (!floorChanges.any((f) => (f.along - at).abs() < _mergeWithin))
          NavStep(
            maneuver: _maneuverFor(delta),
            along: at,
            title: _titleFor(_maneuverFor(delta)),
          ),
    ];
    return [
      ...steps,
      ...[...turnSteps, ...floorChanges]
        ..sort((a, b) => a.along.compareTo(b.along)),
      NavStep(maneuver: NavManeuver.arrive, along: total, title: '到达目的地'),
    ];
  }

  /// 右转为正、左转为负，范围 (-180, 180]。
  static double _turnDelta(double from, double to) {
    var delta = (to - from) % 360;
    if (delta > 180) delta -= 360;
    if (delta <= -180) delta += 360;
    return delta;
  }

  static NavManeuver _maneuverFor(double delta) {
    final a = delta.abs();
    if (a >= 150) return NavManeuver.uTurn;
    if (delta > 0) {
      return a < 50
          ? NavManeuver.slightRight
          : a < 120
          ? NavManeuver.right
          : NavManeuver.sharpRight;
    }
    return a < 50
        ? NavManeuver.slightLeft
        : a < 120
        ? NavManeuver.left
        : NavManeuver.sharpLeft;
  }

  static String _titleFor(NavManeuver maneuver) => switch (maneuver) {
    NavManeuver.slightLeft => '向左前方走',
    NavManeuver.left => '左转',
    NavManeuver.sharpLeft => '向左后方转',
    NavManeuver.slightRight => '向右前方走',
    NavManeuver.right => '右转',
    NavManeuver.sharpRight => '向右后方转',
    NavManeuver.uTurn => '掉头',
    NavManeuver.straight => '直行',
    NavManeuver.depart => '出发',
    NavManeuver.floorChange => '换层',
    NavManeuver.arrive => '到达目的地',
  };

  /// 路线上距起点 [along] 米处的点（超出两端时取端点）。
  GeoPoint pointAt(double along) {
    if (points.isEmpty) return const GeoPoint(longitude: 0, latitude: 0);
    if (along <= 0) return points.first;
    if (along >= length) return points.last;
    var lo = 0, hi = cumulative.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cumulative[mid] <= along) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = cumulative[hi] - cumulative[lo];
    final t = span <= 0 ? 0.0 : (along - cumulative[lo]) / span;
    return _lerp(points[lo], points[hi], t);
  }

  /// 把 [point] 吸附到路线上。[hint] 为上一次的进度：优先取它附近
  /// （往回不超过 20 米）的投影，避免路线自身折返时进度来回跳。
  NavProgress locate(GeoPoint point, {double? hint}) {
    if (isEmpty) {
      final at = end ?? point;
      return NavProgress(
        snapped: at,
        along: 0,
        offRoute: metersBetween(point, at),
        bearing: 0,
        remaining: 0,
        next: steps.last,
        distanceToNext: 0,
      );
    }
    var bestAlong = 0.0;
    var bestDistance = double.infinity;
    GeoPoint bestPoint = points.first;
    for (var i = 0; i < points.length - 1; i++) {
      if (hint != null && cumulative[i + 1] < hint - 20) continue;
      final (projected, t) = _project(points[i], points[i + 1], point);
      final distance = metersBetween(point, projected);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestPoint = projected;
        bestAlong = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * t;
      }
    }
    return progressAt(bestAlong, snapped: bestPoint, offRoute: bestDistance);
  }

  /// 指定进度处的导航状态（没有定位时用它从起点开始）。
  NavProgress progressAt(
    double along, {
    GeoPoint? snapped,
    double offRoute = 0,
  }) {
    final clamped = along.clamp(0.0, length);
    var index = steps.indexWhere((step) => step.along > clamped + 3);
    if (index < 0) index = steps.length - 1;
    final next = steps[index];
    return NavProgress(
      snapped: snapped ?? pointAt(clamped),
      along: clamped,
      offRoute: offRoute,
      bearing: bearingBetween(pointAt(clamped), pointAt(clamped + 15)),
      remaining: length - clamped,
      next: next,
      distanceToNext: max(0, next.along - clamped),
      after: index + 1 < steps.length ? steps[index + 1] : null,
    );
  }

  /// 路线沿途经过的地点（离路线 [within] 米内），按经过顺序，最多 [limit] 个。
  /// 起终点附近 15 米内的不算「途经」。
  List<CampusPlace> placesAlong(
    Iterable<CampusPlace> places, {
    String? excludeId,
    double within = 35,
    int limit = 4,
  }) {
    if (isEmpty) return const [];
    final hits = <(double, CampusPlace)>[];
    for (final place in places) {
      final center = place.center;
      if (place.id == excludeId || center == null || !center.isValid) continue;
      if (place.name.trim().isEmpty) continue;
      final progress = locate(center);
      if (progress.offRoute > within) continue;
      if (progress.along < 15 || progress.remaining < 15) continue;
      hits.add((progress.along, place));
    }
    hits.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, place) in hits.take(limit)) place];
  }

  /// 已走过部分的折线（GeoJSON），地图上画成灰色。
  Map<String, dynamic> passedGeoJson(double along) {
    final coordinates = <List<double>>[
      for (var i = 0; i < points.length && cumulative[i] < along; i++)
        [points[i].longitude, points[i].latitude],
    ];
    if (coordinates.isNotEmpty) {
      final at = pointAt(along);
      coordinates.add([at.longitude, at.latitude]);
    }
    return {
      'type': 'FeatureCollection',
      'features': [
        if (coordinates.length >= 2)
          {
            'type': 'Feature',
            'geometry': {'type': 'LineString', 'coordinates': coordinates},
            'properties': const <String, dynamic>{},
          },
      ],
    };
  }

  static GeoPoint _lerp(GeoPoint a, GeoPoint b, double t) => GeoPoint(
    longitude: a.longitude + (b.longitude - a.longitude) * t,
    latitude: a.latitude + (b.latitude - a.latitude) * t,
  );

  /// 点到线段的投影（局部等距平面，校园尺度足够准）。返回投影点与参数 t。
  static (GeoPoint, double) _project(GeoPoint a, GeoPoint b, GeoPoint p) {
    final scale = cos(a.latitude * pi / 180);
    final bx = (b.longitude - a.longitude) * scale;
    final by = b.latitude - a.latitude;
    final px = (p.longitude - a.longitude) * scale;
    final py = p.latitude - a.latitude;
    final length2 = bx * bx + by * by;
    final t = length2 <= 0
        ? 0.0
        : ((px * bx + py * by) / length2).clamp(0.0, 1.0);
    return (_lerp(a, b, t), t);
  }
}

/// [from] 指向 [to] 的方位角（度，0 = 正北，顺时针）。
double bearingBetween(GeoPoint from, GeoPoint to) {
  final dx = (to.longitude - from.longitude) * cos(from.latitude * pi / 180);
  final dy = to.latitude - from.latitude;
  if (dx == 0 && dy == 0) return 0;
  return (atan2(dx, dy) * 180 / pi + 360) % 360;
}

/// 导航距离文案：「120 米」「1.2 公里」。百米以上按 10 米取整。
String navDistanceLabel(double meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} 公里';
  final rounded = meters >= 100 ? (meters / 10).round() * 10 : meters.round();
  return '$rounded 米';
}

/// 步行分钟数：与 [walkingLabel] 一致按每分钟约 80 米估算，至少 1 分钟。
int navWalkMinutes(double meters) => max(1, (meters / 80).ceil());

/// 步数：按步长约 0.7 米估算。
int navSteps(double meters) => (meters / 0.7).round();

/// 消耗热量（千卡）：按 60 公斤成人步行约每公里 50 千卡估算，至少 1。
int navCalories(double meters) => max(1, (meters / 1000 * 50).round());
