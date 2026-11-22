import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import 'campus_map_data.dart';

class CampusLocationException implements Exception, DiagnosticError {
  const CampusLocationException(
    this.message, {
    this.code = 'location_unavailable',
    this.cause,
    this.causeStackTrace,
  });
  final String message;
  final String code;
  @override
  final Object? cause;
  @override
  final StackTrace? causeStackTrace;
  @override
  Map<String, Object?> get diagnosticContext => {
    'reason_code': code,
    'stage': 'location',
  };
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

/// 定位权限状态，对应原生通道返回的字符串。
enum _Permission { granted, denied, deniedForever }

/// 经系统 `LocationManager` 定位，不依赖 Google Play 服务。原生实现见 Android 端
/// `DeviceLocationPlugin`。
class DeviceUserLocation implements LiveUserLocationSource {
  const DeviceUserLocation();

  static final _log = AppLog.logger('campus_map.location');
  static const _channel = MethodChannel('nuist/device_location');
  static const _updates = EventChannel('nuist/device_location/updates');

  /// 最近位置超过这个时长就不拿来当「当前位置」兜底。
  static const _staleAfter = Duration(minutes: 10);

  static Future<_Permission> _permission({required bool request}) async {
    final name = await _channel.invokeMethod<String>(
      request ? 'requestPermission' : 'permission',
    );
    return switch (name) {
      'granted' => _Permission.granted,
      'deniedForever' => _Permission.deniedForever,
      _ => _Permission.denied,
    };
  }

  static Future<bool> _serviceEnabled() async =>
      await _channel.invokeMethod<bool>('isEnabled') ?? false;

  Future<void> _ensurePermission() async {
    try {
      if (!await _serviceEnabled()) {
        throw const CampusLocationException(
          '定位服务未开启，请在系统设置中打开位置信息',
          code: 'location_service_disabled',
        );
      }
      var permission = await _permission(request: false);
      if (permission == _Permission.denied) {
        permission = await _permission(request: true);
      }
      switch (permission) {
        case _Permission.denied:
          throw const CampusLocationException(
            '未获得定位权限，无法显示你的位置',
            code: 'location_permission_denied',
          );
        case _Permission.deniedForever:
          throw const CampusLocationException(
            '定位权限已被拒绝，请在系统设置中允许',
            code: 'location_permission_denied_forever',
          );
        case _Permission.granted:
          break;
      }
    } on PlatformException catch (error, stackTrace) {
      throw CampusLocationException(
        '定位暂时不可用',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static LocationFix? _fixOf(Object? raw) {
    if (raw is! Map) return null;
    final latitude = raw['latitude'];
    final longitude = raw['longitude'];
    final accuracy = raw['accuracy'];
    if (latitude is! num || longitude is! num) return null;
    final point = GeoPoint(
      longitude: longitude.toDouble(),
      latitude: latitude.toDouble(),
    );
    if (!point.isValid) return null;
    return LocationFix(
      point: point,
      accuracyM: accuracy is num ? accuracy.toDouble() : 0,
    );
  }

  static DateTime? _timeOf(Object? raw) {
    final stamp = raw is Map ? raw['timestamp'] : null;
    return stamp is int ? DateTime.fromMillisecondsSinceEpoch(stamp) : null;
  }

  @override
  Future<bool> ready() async {
    try {
      return await _serviceEnabled() &&
          await _permission(request: false) == _Permission.granted;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<LocationFix?> lastKnown() async {
    try {
      return _fixOf(await _channel.invokeMethod<Object?>('lastKnown'));
    } catch (_) {
      return null;
    }
  }

  Future<LocationFix?> _attempt({
    required bool high,
    required Duration limit,
  }) async {
    final raw = await _channel.invokeMethod<Object?>('getCurrent', {
      'high': high,
      'timeoutMs': limit.inMilliseconds,
    });
    final fix = _fixOf(raw);
    if (fix == null) {
      _log.debug(
        'fix.attempt_timed_out',
        fields: {
          'stage': 'location.${high ? 'high' : 'medium'}',
          'timeout_ms': limit.inMilliseconds,
        },
      );
    }
    return fix;
  }

  @override
  Future<LocationFix> currentFix() async {
    await _ensurePermission();
    try {
      // 室内 GPS 往往搜不到星：高精度只等 8 秒，不行就用 Wi-Fi / 基站定位。
      final fix =
          await _attempt(high: true, limit: const Duration(seconds: 8)) ??
          await _attempt(high: false, limit: const Duration(seconds: 8));
      if (fix != null) return fix;
      final raw = await _channel.invokeMethod<Object?>('lastKnown');
      final fallback = _fixOf(raw);
      final at = _timeOf(raw);
      if (fallback != null &&
          at != null &&
          DateTime.now().difference(at) < _staleAfter) {
        _log.info('fix.cached_fallback', fields: {'outcome': 'cache_fallback'});
        return fallback;
      }
    } on PlatformException catch (error, stackTrace) {
      throw CampusLocationException(
        '定位暂时不可用',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    throw const CampusLocationException('暂时没定位到，请到窗边或室外再试');
  }

  @override
  Future<GeoPoint> current() async => (await currentFix()).point;

  @override
  Stream<LocationFix> watch() => _updates
      .receiveBroadcastStream()
      .map(_fixOf)
      .where((fix) => fix != null)
      .cast<LocationFix>();
}
