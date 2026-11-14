import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/logging/app_log.dart';

/// 只负责明日提醒的原生通道，与课前 N 分钟提醒独立。
class NextDayReminderChannel {
  static const _channel = MethodChannel('nuist/timetable_next_day');
  static final _log = AppLog.logger('timetable.next_day_reminder');

  /// 更新原生缓存并重排；不支持的平台/测试环境退化为无通知。
  ///
  /// 不等待平台回执：测试里未 mock 的 [MethodChannel] 会挂起 Future，
  /// 若在同步路径上 await 会吞掉 SnackBar；原生侧仍是 best-effort。
  static Future<void> update(Map<String, Object?> configuration) async {
    try {
      unawaited(
        _log
            .operation<void>(
              'schedule',
              () async {
                final result = await _channel.invokeMethod<Object?>(
                  'update',
                  configuration,
                );
                if (result is Map && result['diagnostics'] is List) {
                  for (final item in result['diagnostics'] as List) {
                    if (item is! Map) continue;
                    AppLog.reportOutcome(
                      'degraded',
                      reason: '${item['reason_code'] ?? 'native_degraded'}',
                    );
                    _log.warning(
                      'schedule.degraded',
                      fields: {
                        'outcome': 'degraded',
                        'details': Map<String, Object?>.from(item),
                      },
                    );
                  }
                }
              },
              fields: {'stage': 'reminder.schedule'},
              successLevel: AppLogLevel.debug,
              failureLevelForError: (error) => error is MissingPluginException
                  ? AppLogLevel.debug
                  : AppLogLevel.warning,
            )
            .catchError((_) {}),
      );
    } on MissingPluginException {
      // 非 Android 平台没有原生实现。
    } on PlatformException catch (error, stackTrace) {
      _log.warning('schedule.failed', error: error, stackTrace: stackTrace);
      // 通知不可用不影响课表和设置落盘。
    } catch (error, stackTrace) {
      _log.debug('schedule.unavailable', error: error, stackTrace: stackTrace);
      // 纯 controller 测试可能尚未初始化 Flutter 平台绑定。
    }
  }

  /// 在用户操作提醒设置时请求通知权限。
  static Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error, stackTrace) {
      _log.warning('permission.failed', error: error, stackTrace: stackTrace);
      return false;
    } catch (error, stackTrace) {
      _log.debug(
        'permission.unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
