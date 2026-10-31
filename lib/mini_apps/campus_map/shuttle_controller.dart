import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import 'shuttle_api.dart';
import 'shuttle_models.dart';

/// 页面持有的当前车辆状态，按公共交通图层和前后台生命周期启停。
class ShuttleController extends ChangeNotifier {
  ShuttleController(this.source);
  static final _log = AppLog.logger('campus_map.shuttle.controller');
  final ShuttleSource source;
  List<ShuttleVehicle> _vehicles = const [];
  Map<String, ShuttleDirection> _directions = const {};
  Timer? _timer;
  bool _active = false;
  bool _disposed = false;
  bool _busy = false;
  bool _failureNotified = false;
  bool _hasLoaded = false;
  int _generation = 0;

  /// 最新成功响应中的完整车辆列表。
  List<ShuttleVehicle> get vehicles => _vehicles;

  /// 当前车辆的四向显示状态。
  Map<String, ShuttleDirection> get directions => _directions;

  /// 页面首次获取失败时的轻量提示。
  VoidCallback? onFirstFailure;

  /// 进入图层或恢复前台立即刷新，停用后忽略尚未返回的响应。
  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _generation++;
    _timer?.cancel();
    _timer = null;
    if (active) {
      unawaited(_refresh());
      _timer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_refresh()),
      );
    }
  }

  Future<void> _refresh() async {
    if (!_active || _busy || _disposed) return;
    final generation = _generation;
    _busy = true;
    try {
      final result = await _log.operation(
        'vehicles.refresh',
        source.load,
        resultFields: (items) => {'vehicle_count': items.length},
        successLevel: AppLogLevel.debug,
        failureEvent: 'vehicles.refresh_failed',
        failureLevelForError: (_) =>
            !_disposed &&
                _active &&
                generation == _generation &&
                !_hasLoaded &&
                !_failureNotified
            ? AppLogLevel.warning
            : AppLogLevel.debug,
      );
      if (_disposed || !_active || generation != _generation) return;
      _directions = {
        for (final v in result)
          v.id: ShuttleDirection.fromHeading(v.heading, _directions[v.id]),
      };
      _hasLoaded = true;
      _vehicles = List.unmodifiable(result);
      notifyListeners();
    } catch (_) {
      if (!_disposed &&
          _active &&
          generation == _generation &&
          !_hasLoaded &&
          !_failureNotified) {
        _failureNotified = true;
        onFirstFailure?.call();
      }
    } finally {
      _busy = false;
      if (!_disposed && _active && generation != _generation) {
        unawaited(_refresh());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    onFirstFailure = null;
    source.close();
    super.dispose();
  }
}
