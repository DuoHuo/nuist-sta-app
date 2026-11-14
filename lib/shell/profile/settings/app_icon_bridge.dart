import 'package:flutter/services.dart';

import 'app_icon_models.dart';

/// 平台通道失败的安全分类；页面据此给出可恢复的中文提示。
class AppIconBridgeException implements Exception {
  const AppIconBridgeException(this.kind);

  final String kind;
}

/// 应用图标功能的平台边界，便于页面测试时注入假实现。
abstract interface class AppIconBridge {
  /// 读取当前内置图标、自定义快捷方式与系统能力。
  Future<AppIconState> getState();

  /// 切换到指定内置图标并返回切换后的真实状态。
  Future<AppIconState> setBuiltin(String id);

  /// 打开系统图片选择器；用户取消时返回 null。
  Future<Uint8List?> pickImage();

  /// 提交裁剪后的 PNG，并创建或更新自定义桌面快捷方式。
  Future<AppIconState> setCustomIcon(Uint8List pngBytes);

  /// 使用已保存的自定义图标请求一个新的桌面快捷方式。
  Future<AppIconState> pinCustomIcon();
}

/// 通过 `nuist/app_icon` 调用 Android 原生实现。
class MethodChannelAppIconBridge implements AppIconBridge {
  MethodChannelAppIconBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('nuist/app_icon');

  static final instance = MethodChannelAppIconBridge();

  final MethodChannel _channel;

  @override
  Future<AppIconState> getState() async {
    try {
      final value = await _channel.invokeMethod<Object?>('getState');
      return AppIconState.fromPlatform(value);
    } on MissingPluginException {
      // 非 Android、测试环境或尚未接入原生通道时，页面显示不可用。
      return AppIconState.unsupported;
    } on PlatformException catch (error) {
      throw AppIconBridgeException(_safeKind(error.code));
    }
  }

  @override
  Future<AppIconState> setBuiltin(String id) async {
    try {
      final value = await _channel.invokeMethod<Object?>('setBuiltin', {
        'id': id,
      });
      return AppIconState.fromPlatform(value);
    } on MissingPluginException {
      throw const AppIconBridgeException('unavailable');
    } on PlatformException catch (error) {
      throw AppIconBridgeException(_safeKind(error.code));
    }
  }

  @override
  Future<Uint8List?> pickImage() async {
    try {
      return await _channel.invokeMethod<Uint8List>('pickImage');
    } on MissingPluginException {
      throw const AppIconBridgeException('unavailable');
    } on PlatformException catch (error) {
      throw AppIconBridgeException(_safeKind(error.code));
    }
  }

  @override
  Future<AppIconState> setCustomIcon(Uint8List pngBytes) async {
    try {
      final value = await _channel.invokeMethod<Object?>('setCustomIcon', {
        'bytes': pngBytes,
      });
      return AppIconState.fromPlatform(value);
    } on MissingPluginException {
      throw const AppIconBridgeException('unavailable');
    } on PlatformException catch (error) {
      throw AppIconBridgeException(_safeKind(error.code));
    }
  }

  @override
  Future<AppIconState> pinCustomIcon() async {
    try {
      final value = await _channel.invokeMethod<Object?>('pinCustomIcon');
      return AppIconState.fromPlatform(value);
    } on MissingPluginException {
      throw const AppIconBridgeException('unavailable');
    } on PlatformException catch (error) {
      throw AppIconBridgeException(_safeKind(error.code));
    }
  }

  static String _safeKind(String code) => switch (code) {
    'unsupported' || 'unavailable' => 'unavailable',
    'too_large' => 'too_large',
    'invalid_image' => 'invalid_image',
    'pick_failed' => 'pick_failed',
    'shortcut_unsupported' => 'shortcut_unsupported',
    'shortcut_failed' => 'shortcut_failed',
    'icon_failed' => 'icon_failed',
    _ => 'platform_error',
  };
}
