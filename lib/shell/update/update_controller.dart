import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/logging/app_log.dart';
import '../../core/network/client_metadata.dart';
import 'update_api.dart';
import 'update_bridge.dart';
import 'update_models.dart';
import 'update_store.dart';

/// 应用级更新状态：检查与提醒由 Dart 编排，下载任务由原生服务持有。
class UpdateController extends ChangeNotifier {
  UpdateController._()
    : this(
        api: UpdateApi(),
        bridge: AppUpdateBridge.instance,
        metadataProvider: ClientMetadataProvider.instance.get,
        readPreferences: UpdateStore.read,
        savePreferences: UpdateStore.save,
        disabled:
            kIsWeb ||
            !Platform.isAndroid ||
            Platform.environment.containsKey('FLUTTER_TEST'),
      );

  /// 外部依赖可注入，测试无需启动服务、访问网络或平台存储。
  @visibleForTesting
  UpdateController({
    required this.api,
    required this.bridge,
    required this.metadataProvider,
    Future<UpdatePreferences> Function()? readPreferences,
    Future<void> Function(UpdatePreferences)? savePreferences,
    DateTime Function()? now,
    this.disabled = false,
  }) : _readPreferences =
           readPreferences ?? (() async => const UpdatePreferences()),
       _savePreferences = savePreferences ?? ((_) async {}),
       _now = now ?? DateTime.now;

  static final instance = UpdateController._();
  static final _log = AppLog.logger('shell.update.controller');
  static const checkInterval = Duration(hours: 6);

  final UpdateClient api;
  final UpdateDownloadBridge bridge;
  final Future<ClientMetadata> Function() metadataProvider;
  final Future<UpdatePreferences> Function() _readPreferences;
  final Future<void> Function(UpdatePreferences) _savePreferences;
  final DateTime Function() _now;
  final bool disabled;
  Future<void>? _initializing;
  Future<void>? _checking;
  StreamSubscription<UpdateTask>? _subscription;
  ClientMetadata _metadata = const ClientMetadata();
  UpdatePreferences _preferences = const UpdatePreferences();
  final Set<String> _prompted = {};
  final Set<String> _bannerShown = {};
  bool _disposed = false;
  bool _launched = false;
  int _nativeEpoch = 0;
  _InstallPermissionRequest? _installPermissionRequest;

  bool initialized = false;
  bool checking = false;
  bool acting = false;
  String? checkError;
  String? actionError;
  UpdateRelease? available;
  UpdateTask task = const UpdateTask();

  /// 幂等装入偏好和原生任务；不隐含一次远程检查。
  Future<void> ensureStarted() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (disabled) {
      initialized = true;
      _notify();
      return;
    }
    try {
      _metadata = await metadataProvider();
      try {
        _preferences = await _readPreferences();
      } catch (_) {
        // 注入存储同样遵循失败退化约定。
      }
      _subscription = bridge.states.listen(
        _acceptTask,
        onError: (Object error, StackTrace stackTrace) {
          _log.warning(
            'download.state_failed',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      await refreshTask();
    } catch (error, stackTrace) {
      _log.warning('initialize.failed', error: error, stackTrace: stackTrace);
    }
    initialized = true;
    _notify();
  }

  /// 每次冷启动静默检查一次，页面重建不重复启动。
  Future<void> onLaunch() async {
    if (_launched) return;
    _launched = true;
    await check(coldStart: true);
  }

  /// 权限页或后台返回后恢复任务状态，远程检查仍受六小时节流。
  Future<void> onResumed() async {
    final permissionRequest = _installPermissionRequest;
    await ensureStarted();
    if (disabled || _disposed) return;
    await refreshTask();
    if (permissionRequest != null &&
        identical(_installPermissionRequest, permissionRequest)) {
      permissionRequest.returned = true;
      await _installAfterPermission();
    }
    await check();
  }

  /// 同时发起的检查共用请求；手动操作绕过自动节流。
  Future<void> check({bool manual = false, bool coldStart = false}) =>
      _checking ??= _check(
        manual: manual,
        coldStart: coldStart,
      ).whenComplete(() => _checking = null);

  Future<void> _check({required bool manual, required bool coldStart}) async {
    await ensureStarted();
    if (_disposed) return;
    if (disabled) {
      if (manual) checkError = '检查更新失败';
      _notify();
      return;
    }
    final now = _now();
    final last = _preferences.lastAttempt;
    if (!manual &&
        !coldStart &&
        last != null &&
        !last.isAfter(now) &&
        now.difference(last) < checkInterval) {
      return;
    }
    checking = true;
    checkError = null;
    _preferences = UpdatePreferences(
      lastAttempt: now,
      readRevision: _preferences.readRevision,
    );
    _notify();
    try {
      await _log.operation('check', () async {
        final release = await api.check();
        if (_disposed) return;
        available = release;
      });
    } catch (_) {
      // 失败时不继续用旧候选自动弹窗，也不把失败当成“最新版本”。
      available = null;
      checkError = '检查更新失败';
    } finally {
      checking = false;
      await _save();
      _notify();
    }
  }

  bool get shouldPrompt {
    final release = available;
    return release != null &&
        release.popupEnabled &&
        !checking &&
        !acting &&
        !task.hasTask &&
        !_prompted.contains(release.revision);
  }

  /// 显示之前标记本次进程；返回前台不重弹，完全退出后重新提醒。
  void markPrompted(UpdateRelease release) => _prompted.add(release.revision);

  Future<void> _save() async {
    try {
      await _savePreferences(_preferences);
    } catch (_) {
      // 偏好写入失败不阻止手动检查或下载。
    }
  }

  /// 非弹窗更新作为本地伪公告，不写入真实公告缓存。
  bool get hasUnreadAnnouncement =>
      available != null &&
      !available!.popupEnabled &&
      _preferences.readRevision != available!.revision;

  bool get shouldShowBanner =>
      hasUnreadAnnouncement &&
      !task.hasTask &&
      !_bannerShown.contains(available!.revision);

  void markBannerShown() {
    final revision = available?.revision;
    if (revision != null) _bannerShown.add(revision);
  }

  Future<void> markAnnouncementRead() async {
    _preferences = UpdatePreferences(
      lastAttempt: _preferences.lastAttempt,
      readRevision: available?.revision,
    );
    _notify();
    await _save();
  }

  void _acceptTask(UpdateTask value) {
    if (_disposed) return;
    _nativeEpoch++;
    task = value;
    final permissionRequest = _installPermissionRequest;
    if (permissionRequest != null &&
        !_isReadyRelease(permissionRequest.release)) {
      _installPermissionRequest = null;
    }
    if (value.status == UpdateTaskStatus.revoked &&
        available?.revision == value.release?.revision) {
      available = null;
    }
    _notify();
  }

  /// 不让较晚返回的旧查询覆盖新到达的进度事件。
  Future<void> refreshTask() async {
    if (disabled || _disposed) return;
    final epoch = _nativeEpoch;
    try {
      final value = await bridge.getState();
      if (epoch == _nativeEpoch) _acceptTask(value);
    } catch (error, stackTrace) {
      _log.warning(
        'download.state_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 用户点击后复核精确修订，再启动有持续通知的原生下载任务。
  Future<void> download([UpdateRelease? selected]) =>
      _action('download', () async {
        final release = selected ?? available;
        if (release == null) throw PlatformException(code: 'not_ready');
        if (task.hasTask) throw PlatformException(code: 'task_exists');
        await api.validate(release);
        // 通知授权只影响通知展示，不影响下载任务。
        try {
          await bridge.requestNotificationPermission();
        } catch (_) {}
        _acceptTask(await bridge.start(release, _metadata.headers));
      });

  Future<void> resume() => _action('download.resume', () async {
    final release = task.release;
    if (release == null) throw PlatformException(code: 'not_ready');
    await api.validate(release);
    _acceptTask(await bridge.resume());
  });

  Future<void> cancel() {
    _installPermissionRequest = null;
    return _action('download.cancel', () async {
      _acceptTask(await bridge.cancel());
    });
  }

  Future<void> install() {
    _installPermissionRequest = null;
    return _installRelease(task.release);
  }

  bool _isReadyRelease(UpdateRelease release) =>
      task.status == UpdateTaskStatus.ready &&
      task.release != null &&
      release.sameArtifact(task.release!);

  Future<void> _installRelease(UpdateRelease? release) =>
      _action('install', () async {
        if (release == null) throw PlatformException(code: 'not_ready');
        if (!_isReadyRelease(release)) return;
        try {
          await api.validate(release);
        } on UpdateRevoked {
          // 复查期间任务可能已取消或更换，不用旧修订的结果清除新任务。
          if (_isReadyRelease(release)) rethrow;
          return;
        }
        if (_disposed || !_isReadyRelease(release) || !task.installAllowed) {
          return;
        }
        _acceptTask(await bridge.install());
      });

  /// 只为本次用户请求，在安装来源授权返回后继续安装当前修订。
  Future<void> openInstallSettings() async {
    if (acting || _disposed) return;
    final release = task.release;
    if (release == null || !_isReadyRelease(release)) return;
    final request = _InstallPermissionRequest(release);
    _installPermissionRequest = request;
    await _action('install.settings', () async {
      try {
        await bridge.openInstallSettings();
        request.opened = true;
      } catch (_) {
        if (identical(_installPermissionRequest, request)) {
          _installPermissionRequest = null;
        }
        rethrow;
      }
    });
    // 生命周期回调可能早于平台通道返回；等 acting 释放后补执行一次。
    await _installAfterPermission();
  }

  Future<void> _installAfterPermission() async {
    final request = _installPermissionRequest;
    if (request == null || !request.returned) return;
    if (_disposed ||
        !task.installAllowed ||
        !_isReadyRelease(request.release)) {
      _installPermissionRequest = null;
      return;
    }
    if (!request.opened || acting) return;
    _installPermissionRequest = null;
    await _installRelease(request.release);
  }

  Future<void> _action(String event, Future<void> Function() operation) async {
    if (acting || _disposed) return;
    acting = true;
    actionError = null;
    _notify();
    try {
      await _log.operation(event, operation);
    } on UpdateRevoked {
      available = null;
      actionError = '此版本已停止分发';
      // 本机任务不能在校验失败后仍保留可点击安装的状态。
      try {
        _acceptTask(await bridge.cancel());
      } catch (_) {}
    } on PlatformException catch (error) {
      actionError = updateErrorMessage(error.code);
    } catch (_) {
      actionError = '操作失败';
    } finally {
      acting = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    if (api case final UpdateApi client) client.close();
    super.dispose();
  }
}

class _InstallPermissionRequest {
  _InstallPermissionRequest(this.release);

  final UpdateRelease release;
  bool opened = false;
  bool returned = false;
}

/// 只将稳定错误分类映射成文案，不展示原生异常、地址或请求内容。
String updateErrorMessage(String? code) => switch (code) {
  'task_exists' || 'busy' => '已有更新任务',
  'revoked' || 'release_revoked' => '此版本已停止分发',
  'hash_mismatch' || 'size_mismatch' || 'verification_failed' => '安装包校验失败',
  'insufficient_space' || 'insufficient_storage' || 'no_space' => '存储空间不足',
  'storage' => '安装包保存失败',
  'foreground_required' || 'foreground_unavailable' => '下载启动失败',
  'interrupted' => '下载已中断',
  'install_blocked' => '安装被系统阻止',
  'install_failed' => '安装失败',
  'invalid_response' => '更新服务响应异常',
  'install_permission_required' || 'install_permission' => '请允许安装此来源的应用',
  'install_cancelled' => '已取消安装',
  'not_ready' => '安装包尚未准备好',
  'timeout' || 'service_timeout' => '下载已暂停',
  'network_error' || 'network' || 'http_error' => '网络连接失败',
  _ => '操作失败',
};
