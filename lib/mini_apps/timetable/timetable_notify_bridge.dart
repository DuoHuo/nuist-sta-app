import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/logging/app_log.dart';

/// 提醒相关权限状态（Android；其他平台全部视为不支持）。
@immutable
class NotifyPermissionStatus {
  const NotifyPermissionStatus({
    required this.supported,
    required this.notificationsGranted,
    required this.exactAlarmGranted,
    required this.ignoringBatteryOptimizations,
  });

  /// 非 Android / 测试环境。
  static const unsupported = NotifyPermissionStatus(
    supported: false,
    notificationsGranted: false,
    exactAlarmGranted: false,
    ignoringBatteryOptimizations: false,
  );

  /// 是否 Android 且原生通道可用。
  final bool supported;

  /// 通知权限（Android 13+ POST_NOTIFICATIONS；更低版本为通知总开关）。
  final bool notificationsGranted;

  /// 精确闹钟（Android 12+ 需授予；更低版本恒为 true）。为 false 时提醒
  /// 退化为非精确闹钟，可能晚几分钟，UI 应提示去授权。
  final bool exactAlarmGranted;

  /// 是否已在电池优化白名单。
  final bool ignoringBatteryOptimizations;

  factory NotifyPermissionStatus._fromMap(Map<Object?, Object?> m) =>
      NotifyPermissionStatus(
        supported: true,
        notificationsGranted: m['notifications'] == true,
        exactAlarmGranted: m['exactAlarm'] == true,
        ignoringBatteryOptimizations: m['ignoringBattery'] == true,
      );
}

/// 小组件添加请求的结果；[requested] 不保证桌面实际添加成功。
enum WidgetPinResult {
  requested,
  permissionRequired,
  miuiManual,
  originOsManual,
  manual,
}

/// 可添加的小组件尺寸：4×2 今日课表、2×2 当前/下一节、4×6 当周课表。
enum WidgetPinSize { wide, square, week }

/// 课表提醒 / 桌面小组件的原生通道（`dev.duohuo.nuist_sta_app/notify_widget`）。
///
/// 所有方法在非 Android 或通道缺失时安静降级，不抛异常。
class TimetableNotifyBridge {
  static final _log = AppLog.logger('timetable.notify_bridge');
  TimetableNotifyBridge({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('dev.duohuo.nuist_sta_app/notify_widget');

  static final TimetableNotifyBridge instance = TimetableNotifyBridge();

  final MethodChannel _channel;

  /// 测试可置 false 关闭平台判断。
  @visibleForTesting
  static bool? debugIsAndroid;

  bool get _android {
    final o = debugIsAndroid;
    if (o != null) return o;
    if (kIsWeb) return false;
    return Platform.isAndroid &&
        !Platform.environment.containsKey('FLUTTER_TEST');
  }

  Future<({bool ok, T? value})> _callWithStatus<T>(
    String method, [
    Object? args,
  ]) async {
    if (!_android) return (ok: true, value: null);
    final watch = Stopwatch()..start();
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      if (result is Map && result['diagnostics'] is List) {
        for (final item in result['diagnostics'] as List) {
          if (item is! Map) continue;
          AppLog.reportOutcome(
            'degraded',
            reason: '${item['reason_code'] ?? 'native_degraded'}',
          );
          _log.warning(
            'native.degraded',
            fields: {
              'endpoint': 'notify.$method',
              'outcome': 'degraded',
              'details': Map<String, Object?>.from(item),
            },
          );
        }
      }
      _log.debug(
        'native.completed',
        fields: {
          'endpoint': 'notify.$method',
          'duration_ms': watch.elapsedMilliseconds,
        },
      );
      return (ok: true, value: result);
    } on MissingPluginException catch (error, stackTrace) {
      AppLog.reportOutcome('degraded', reason: 'platform_unavailable');
      _log.debug(
        'native.unavailable',
        fields: {'endpoint': 'notify.$method'},
        error: error,
        stackTrace: stackTrace,
      );
      return (ok: false, value: null);
    } on PlatformException catch (error, stackTrace) {
      AppLog.reportOutcome('degraded', reason: 'native_call_failed');
      _log.warning(
        'native.failed',
        fields: {
          'endpoint': 'notify.$method',
          'duration_ms': watch.elapsedMilliseconds,
          'outcome': 'degraded',
        },
        error: error,
        stackTrace: stackTrace,
      );
      return (ok: false, value: null);
    }
  }

  Future<T?> _call<T>(String method, [Object? args]) async =>
      (await _callWithStatus<T>(method, args)).value;

  /// 用新列表替换全部已排提醒（空列表 = 全部取消）。
  Future<bool> scheduleReminders(List<Map<String, Object?>> alarms) async =>
      (await _callWithStatus<Object?>('scheduleReminders', {
        'alarms': jsonEncode(alarms),
      })).ok;

  /// 取消全部提醒。
  Future<void> cancelReminders() async {
    await _call<Object?>('cancelReminders');
  }

  /// 写入小组件数据并立即刷新所有小组件实例。
  Future<bool> updateWidget(Map<String, Object?> payload) async =>
      (await _callWithStatus<void>('updateWidget', {
        'payload': jsonEncode(payload),
      })).ok;

  /// 当前权限状态。
  Future<NotifyPermissionStatus> permissionStatus() async {
    final m = await _call<Map<Object?, Object?>>('permissionStatus');
    return m == null
        ? NotifyPermissionStatus.unsupported
        : NotifyPermissionStatus._fromMap(m);
  }

  /// 请求通知权限（Android 13+ 弹系统框；更低版本直接返回当前状态）。
  Future<bool> requestNotificationPermission() async =>
      await _call<bool>('requestNotificationPermission') ?? false;

  /// 打开「闹钟和提醒」精确闹钟授权页（Android 12+）；返回是否成功打开。
  Future<bool> openExactAlarmSettings() async =>
      await _call<bool>('openExactAlarmSettings') ?? false;

  /// 打开本应用的电池优化设置（优先请求加入白名单，失败退到列表页 / 应用详情）。
  Future<bool> openBatteryOptimizationSettings() async =>
      await _call<bool>('openBatteryOptimizationSettings') ?? false;

  /// 打开本应用的系统通知设置页。
  Future<bool> openNotificationSettings() async =>
      await _call<bool>('openNotificationSettings') ?? false;

  /// 请求把指定尺寸的小组件固定到桌面。
  ///
  /// 原生侧先检查厂商权限，再请求添加或返回手动指引类型；新增尺寸时
  /// 同时保留旧的 square 参数兼容。
  Future<WidgetPinResult> pinWidget({required WidgetPinSize size}) async {
    final result = await _call<String>('pinWidget', {'size': size.name});
    return WidgetPinResult.values.firstWhere(
      (value) => value.name == result,
      orElse: () => WidgetPinResult.manual,
    );
  }

  /// 用户阅读权限说明并确认后，打开本应用的桌面快捷方式权限设置。
  Future<bool> openWidgetShortcutSettings() async =>
      await _call<bool>('openWidgetShortcutSettings') ?? false;

  /// 取走（并清除）由通知 / 小组件点击带进来的待打开路由，如 `/apps/timetable`。
  Future<String?> takeLaunchRoute() => _call<String>('takeLaunchRoute');

  /// 监听 App 已在前台时的点击路由。
  void setRouteHandler(void Function(String route) onRoute) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openRoute' && call.arguments is String) {
        onRoute(call.arguments as String);
      }
      return null;
    });
  }
}
