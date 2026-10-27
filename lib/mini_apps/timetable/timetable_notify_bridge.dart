import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

/// 课表提醒 / 桌面小组件的原生通道（`dev.duohuo.nuist_sta_app/notify_widget`）。
///
/// 所有方法在非 Android 或通道缺失时安静降级，不抛异常。
class TimetableNotifyBridge {
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

  Future<T?> _call<T>(String method, [Object? args]) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 用新列表替换全部已排提醒（空列表 = 全部取消）。
  Future<void> scheduleReminders(List<Map<String, Object?>> alarms) =>
      _call<void>('scheduleReminders', {'alarms': jsonEncode(alarms)});

  /// 取消全部提醒。
  Future<void> cancelReminders() => _call<void>('cancelReminders');

  /// 写入小组件数据并立即刷新所有小组件实例。
  Future<void> updateWidget(Map<String, Object?> payload) =>
      _call<void>('updateWidget', {'payload': jsonEncode(payload)});

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
