import 'dart:async';

import 'package:flutter/services.dart';

/// 只负责明日提醒的原生通道，与课前 N 分钟提醒独立。
class NextDayReminderChannel {
  static const _channel = MethodChannel('nuist/timetable_next_day');

  /// 更新原生缓存并重排；不支持的平台/测试环境退化为无通知。
  ///
  /// 不等待平台回执：测试里未 mock 的 [MethodChannel] 会挂起 Future，
  /// 若在同步路径上 await 会吞掉 SnackBar；原生侧仍是 best-effort。
  static Future<void> update(Map<String, Object?> configuration) async {
    try {
      unawaited(
        _channel.invokeMethod<void>('update', configuration).catchError((_) {}),
      );
    } on MissingPluginException {
      // 非 Android 平台没有原生实现。
    } on PlatformException {
      // 通知不可用不影响课表和设置落盘。
    } catch (_) {
      // 纯 controller 测试可能尚未初始化 Flutter 平台绑定。
    }
  }

  /// 在用户操作提醒设置时请求通知权限。
  static Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
