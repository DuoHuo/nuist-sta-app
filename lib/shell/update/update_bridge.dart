import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import 'update_models.dart';

/// 原生服务边界；测试用实现不需要 Android 平台通道。
abstract interface class UpdateDownloadBridge {
  Stream<UpdateTask> get states;
  Future<UpdateTask> getState();
  Future<UpdateTask> start(UpdateRelease release, Map<String, String> headers);
  Future<UpdateTask> resume();
  Future<UpdateTask> cancel();
  Future<UpdateTask> install();
  Future<void> openInstallSettings();
  Future<void> requestNotificationPermission();
}

/// Android 前台下载与安装通道，不在 Dart isolate 中维持下载任务。
class AppUpdateBridge implements UpdateDownloadBridge {
  AppUpdateBridge({MethodChannel? channel, EventChannel? events})
    : _channel = channel ?? const MethodChannel('nuist/app_update'),
      _events = events ?? const EventChannel('nuist/app_update/events');

  static final instance = AppUpdateBridge();
  final MethodChannel _channel;
  final EventChannel _events;
  Stream<UpdateTask>? _states;

  @override
  Stream<UpdateTask> get states => _states ??= _events
      .receiveBroadcastStream()
      .where((value) {
        if (value is Map && value['type'] == 'http_diagnostic') {
          unawaited(_recordDiagnostic(value));
          return false;
        }
        return true;
      })
      .map(UpdateTask.fromJson);

  Future<void> _recordDiagnostic(Map value) async {
    const scope = 'shell.update.native';
    try {
      final exchange = Map<String, Object?>.from(value['exchange'] as Map);
      final detail = exchange['error'];
      final error = detail is Map
          ? DiagnosticException(
              detail['message'] as String? ?? '原生更新请求失败',
              code: detail['code'] as String? ?? 'native_update_failed',
              stage: exchange['stage'] as String?,
              context: {'native_type': detail['type']},
            )
          : null;
      final stack = detail is Map && detail['stack'] is String
          ? StackTrace.fromString(detail['stack'] as String)
          : null;
      if (value['bodyFile'] case final String path) {
        // 路径只来自受信任的原生更新通道；网页消息没有读本机文件的权限。
        await AppLog.recordHttpFileExchange(
          scope,
          exchange,
          File(path),
          capturedBytes:
              (exchange['response'] as Map?)?['captured_bytes'] as int?,
          error: error,
          stackTrace: stack,
        );
      } else {
        AppLog.recordHttpExchange(
          scope,
          exchange,
          error: error,
          stackTrace: stack,
        );
      }
    } catch (error, stackTrace) {
      AppLog.logger(scope).warning(
        'capture.native_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {
          'details': {
            'capture': {
              'complete': false,
              'reason': 'native_exchange_capture_failed',
            },
          },
        },
      );
    }
  }

  Future<UpdateTask> _state(String method, [Object? args]) async =>
      UpdateTask.fromJson(await _channel.invokeMethod<Object?>(method, args));

  @override
  Future<UpdateTask> getState() => _state('getState');

  @override
  Future<UpdateTask> start(
    UpdateRelease release,
    Map<String, String> headers,
  ) => _state('startDownload', {
    'release': release.toJson(),
    'headers': headers,
  });

  @override
  Future<UpdateTask> resume() => _state('resumeDownload');

  @override
  Future<UpdateTask> cancel() => _state('cancelDownload');

  @override
  Future<UpdateTask> install() => _state('install');

  @override
  Future<void> openInstallSettings() async {
    await _channel.invokeMethod<Object?>('openInstallSettings');
  }

  @override
  Future<void> requestNotificationPermission() async {
    await _channel.invokeMethod<Object?>('requestNotificationPermission');
  }

  /// 通知请求打开更新详情，不携带页面地址。
  void setOpenHandler(void Function()? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method == 'onOpenUpdate') {
                handler();
              }
            },
    );
  }

  /// 冷启动通知请求只消费一次。
  Future<bool> takeLaunchRequest() async =>
      await _channel.invokeMethod<bool>('takeLaunchRequest') ?? false;
}
