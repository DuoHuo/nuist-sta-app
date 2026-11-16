import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log.dart';
import 'app_icon_bridge.dart';
import 'app_icon_models.dart';

/// 应用图标页的业务状态：读取、切换、选图与提交。
///
/// 页面只调用这个控制器；平台能力、失败分类和重复提交保护都在这里收口。
/// 控制器归页面所有，页面退出时释放；设置页摘要使用独立实例刷新。
class AppIconController extends ChangeNotifier {
  AppIconController({AppIconBridge? bridge})
    : _bridge = bridge ?? MethodChannelAppIconBridge.instance;

  static final _log = AppLog.logger('app_icon.controller');

  final AppIconBridge _bridge;
  Future<void>? _starting;
  bool _disposed = false;
  bool _loading = false;
  bool _busy = false;
  bool _picking = false;
  bool _unsupported = false;
  bool _error = false;
  String? _errorMessage;
  AppIconState _state = AppIconState.unsupported;
  Uint8List? _pickedImage;

  /// 是否正在读取初始状态。
  bool get loading => _loading;

  /// 是否正在执行关键写入，界面应禁用重复操作并暂时阻止返回。
  bool get busy => _busy;

  /// 是否正在等待系统图片选择器，这个等待允许用户取消。
  bool get picking => _picking;

  /// 当前平台是否不支持图标功能。
  bool get unsupported => _unsupported;

  /// 最近一次操作是否失败。
  bool get error => _error;

  /// 给用户看的安全错误提示。
  String? get errorMessage => _errorMessage;

  /// 当前平台状态。
  AppIconState get state => _state;

  /// 从相册选出、等待裁剪的图片。
  Uint8List? get pickedImage => _pickedImage;

  /// 页面首次挂载或回到前台时刷新状态，重复调用只执行一次。
  Future<void> ensureStarted() => _starting ??= _refresh();

  /// 从系统确认页回到应用后重新查询真实状态。
  Future<void> refresh() async {
    if (_busy) return;
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    _loading = true;
    _notify();
    try {
      final next = await _log.operation(
        'state.read',
        () => _bridge.getState(),
        successLevel: AppLogLevel.debug,
      );
      if (_disposed) return;
      _state = next;
      _unsupported = !next.supported;
      _clearError();
    } on AppIconBridgeException catch (error) {
      if (_disposed) return;
      _unsupported = error.kind == 'unavailable';
      _showError(_messageFor(error.kind));
    } catch (_) {
      if (_disposed) return;
      _showError('无法读取应用图标状态，请稍后重试');
    } finally {
      if (!_disposed) {
        _loading = false;
        _notify();
      }
    }
  }

  /// 切换内置图标；失败时保留原状态并返回 false 供页面提示。
  Future<bool> setBuiltin(String id) async {
    if (_disposed || _busy || _picking || !_state.supported) return false;
    _busy = true;
    _clearError();
    _notify();
    try {
      final next = await _log.operation(
        'builtin.set',
        () => _bridge.setBuiltin(id),
        fields: {'icon_id': id},
      );
      if (_disposed) return false;
      _state = next;
      return true;
    } on AppIconBridgeException catch (error) {
      if (!_disposed) _showError(_messageFor(error.kind));
      return false;
    } catch (_) {
      if (!_disposed) _showError('切换图标失败，请稍后重试');
      return false;
    } finally {
      if (!_disposed) {
        _busy = false;
        _notify();
      }
    }
  }

  /// 打开系统图片选择器。用户取消返回 null，且不改变当前状态。
  Future<Uint8List?> pickImage() async {
    if (_disposed || _busy || _picking || !_state.supported || !_state.canPin) {
      return null;
    }
    _picking = true;
    _clearError();
    _notify();
    try {
      final bytes = await _log.operation(
        'image.pick',
        () => _bridge.pickImage(),
        resultFields: (bytes) => {'selected': bytes != null},
        successLevel: AppLogLevel.debug,
      );
      if (_disposed) return null;
      _pickedImage = bytes;
      return bytes;
    } on AppIconBridgeException catch (error) {
      if (!_disposed) _showError(_messageFor(error.kind));
      return null;
    } catch (_) {
      if (!_disposed) _showError('无法读取这张图片，请换一张重试');
      return null;
    } finally {
      if (!_disposed) {
        _picking = false;
        _notify();
      }
    }
  }

  /// 提交裁剪后的 512×512 PNG，并创建或更新桌面快捷方式。
  Future<bool> setCustomIcon(Uint8List pngBytes) async {
    if (_disposed || _busy || _picking || !_state.supported || !_state.canPin) {
      return false;
    }
    _busy = true;
    _clearError();
    _notify();
    try {
      final next = await _log.operation(
        'custom.set',
        () => _bridge.setCustomIcon(pngBytes),
      );
      if (_disposed) return false;
      _state = next;
      _pickedImage = null;
      return true;
    } on AppIconBridgeException catch (error) {
      if (!_disposed) _showError(_messageFor(error.kind));
      return false;
    } catch (_) {
      if (!_disposed) _showError('创建快捷方式失败，请稍后重试');
      return false;
    } finally {
      if (!_disposed) {
        _busy = false;
        _notify();
      }
    }
  }

  /// 使用已保存的自定义图标请求一个新的桌面快捷方式。
  Future<bool> pinCustomIcon() async {
    if (_disposed ||
        _busy ||
        _picking ||
        !_state.supported ||
        !_state.canPin ||
        _state.customIcon == null) {
      return false;
    }
    _busy = true;
    _clearError();
    _notify();
    try {
      final next = await _log.operation(
        'custom.pin',
        () => _bridge.pinCustomIcon(),
      );
      if (_disposed) return false;
      _state = next;
      return true;
    } on AppIconBridgeException catch (error) {
      if (!_disposed) _showError(_messageFor(error.kind));
      return false;
    } catch (_) {
      if (!_disposed) _showError('添加到桌面失败，请稍后重试');
      return false;
    } finally {
      if (!_disposed) {
        _busy = false;
        _notify();
      }
    }
  }

  /// 放弃本次从相册选出的图片。
  void clearPickedImage() {
    if (_pickedImage == null) return;
    _pickedImage = null;
    _notify();
  }

  /// 清除当前错误提示。
  void clearError() {
    if (!_error) return;
    _clearError();
    _notify();
  }

  void _clearError() {
    _error = false;
    _errorMessage = null;
  }

  void _showError(String message) {
    _error = true;
    _errorMessage = message;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _messageFor(String kind) => switch (kind) {
    'unavailable' => '当前系统暂不支持切换应用图标',
    'too_large' => '图片过大，请选择 20 MB 以内的图片',
    'invalid_image' => '图片格式无法识别，请换一张重试',
    'pick_failed' => '无法打开相册，请稍后重试',
    'shortcut_unsupported' => '当前桌面不支持添加快捷方式',
    'shortcut_failed' => '未能创建桌面快捷方式，请检查桌面空间后重试',
    'icon_failed' => '图标保存失败，请稍后重试',
    _ => '操作失败，请稍后重试',
  };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
