import 'package:flutter/services.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/logging/diagnostic_error.dart';
import 'app_icon_models.dart';

/// 平台通道失败的安全分类；页面据此给出可恢复的中文提示。
class AppIconBridgeException implements Exception, DiagnosticError {
  const AppIconBridgeException(
    this.kind, {
    this.method,
    this.cause,
    this.causeStackTrace,
  });

  /// 供界面选择安全提示的稳定分类。
  final String kind;

  /// 失败的平台调用，不含图片内容。
  final String? method;

  @override
  final Object? cause;

  @override
  final StackTrace? causeStackTrace;

  @override
  Map<String, Object?> get diagnosticContext => {
    'reason_code': kind,
    'stage': 'platform_channel',
    if (method != null) 'method': method,
  };

  @override
  String toString() => '应用图标平台调用失败：$kind';
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
  static final _log = AppLog.logger('app_icon.bridge');

  final MethodChannel _channel;

  @override
  Future<AppIconState> getState() async {
    try {
      final value = await _channel.invokeMethod<Object?>('getState');
      return _parseState(value);
    } on MissingPluginException {
      // 非 Android、测试环境或尚未接入原生通道时，页面显示不可用。
      return AppIconState.unsupported;
    } on PlatformException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'getState');
    }
  }

  @override
  Future<AppIconState> setBuiltin(String id) async {
    try {
      final value = await _channel.invokeMethod<Object?>('setBuiltin', {
        'id': id,
      });
      return _parseState(value);
    } on MissingPluginException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'setBuiltin');
    } on PlatformException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'setBuiltin');
    }
  }

  @override
  Future<Uint8List?> pickImage() async {
    try {
      final value = await _channel.invokeMethod<Object?>('pickImage');
      if (value is Map) {
        _recordDiagnostics(value);
        return value['bytes'] as Uint8List?;
      }
      // 兼容仅返回图片字节的旧原生实现与用户取消。
      return value as Uint8List?;
    } on MissingPluginException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'pickImage');
    } on PlatformException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'pickImage');
    }
  }

  @override
  Future<AppIconState> setCustomIcon(Uint8List pngBytes) async {
    try {
      final value = await _channel.invokeMethod<Object?>('setCustomIcon', {
        'bytes': pngBytes,
      });
      return _parseState(value);
    } on MissingPluginException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'setCustomIcon');
    } on PlatformException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'setCustomIcon');
    }
  }

  @override
  Future<AppIconState> pinCustomIcon() async {
    try {
      final value = await _channel.invokeMethod<Object?>('pinCustomIcon');
      return _parseState(value);
    } on MissingPluginException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'pinCustomIcon');
    } on PlatformException catch (error, stackTrace) {
      throw _failure(error, stackTrace, 'pinCustomIcon');
    }
  }

  static AppIconBridgeException _failure(
    Object error,
    StackTrace stackTrace,
    String method,
  ) => AppIconBridgeException(
    error is PlatformException ? _safeKind(error.code) : 'unavailable',
    method: method,
    cause: error,
    causeStackTrace: stackTrace,
  );

  static AppIconState _parseState(Object? value) {
    _recordDiagnostics(value);
    return AppIconState.fromPlatform(value);
  }

  static void _recordDiagnostics(Object? value) {
    if (value is Map && value['diagnostics'] is List) {
      final diagnostics = value['diagnostics'] as List;
      for (final diagnostic in diagnostics) {
        if (diagnostic is! Map) continue;
        _log.warning(
          'platform.degraded',
          fields: {
            'stage': diagnostic['stage'],
            'reason_code': diagnostic['reason_code'],
            'details': Map<Object?, Object?>.from(diagnostic),
          },
        );
      }
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
