import 'package:flutter/services.dart';

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
  Stream<UpdateTask> get states =>
      _states ??= _events.receiveBroadcastStream().map(UpdateTask.fromJson);

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
