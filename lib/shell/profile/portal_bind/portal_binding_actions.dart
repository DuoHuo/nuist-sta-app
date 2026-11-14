import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/passkey_bundle.dart';
import '../../../core/auth/passkey_store.dart';
import '../../../core/auth/portal_session.dart';
import '../../../core/logging/app_log.dart';
import '../../../mini_apps/registry.dart';

/// 完成本机绑定变更后，通过注册表通知首页、学习页及各模块。
class PortalBindingActions {
  PortalBindingActions._({
    required this._saveCredential,
    required this._deleteCredential,
    required this._clearSession,
    required this._notifyApps,
  });

  /// 注入本地替身，验证凭据、会话与通知的顺序而不连接学校。
  @visibleForTesting
  factory PortalBindingActions.forTesting({
    required Future<void> Function(PasskeyBundle) saveCredential,
    required Future<void> Function() deleteCredential,
    required Future<void> Function(bool) clearSession,
    required Future<bool> Function({required bool bound}) notifyApps,
  }) => PortalBindingActions._(
    saveCredential: saveCredential,
    deleteCredential: deleteCredential,
    clearSession: clearSession,
    notifyApps: notifyApps,
  );

  static final instance = PortalBindingActions._(
    saveCredential: PasskeyStore.save,
    deleteCredential: PasskeyStore.delete,
    clearSession: (includeWebView) =>
        PortalSession.instance.clear(includeWebView: includeWebView),
    notifyApps: appRegistry.notifyPortalBindingChanged,
  );
  static final _log = AppLog.logger('shell.profile.portal_binding');

  final Future<void> Function(PasskeyBundle) _saveCredential;
  final Future<void> Function() _deleteCredential;
  final Future<void> Function(bool) _clearSession;
  final Future<bool> Function({required bool bound}) _notifyApps;
  Future<void> _pending = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// 注册、重新绑定和导入共用收尾；刷新在后台完成，不阻塞成功提示。
  /// 通知发生在凭据保存且旧会话清理之后，不依赖任何页面仍然挂载。
  Future<void> bind(PasskeyBundle bundle) => _serialize(() {
    var stage = 'binding.save';
    return _log.operation(
      'bind',
      () async {
        await _saveCredential(bundle);
        stage = 'binding.clear_session';
        await _clearSession(false);
        stage = 'binding.notify';
        unawaited(
          Future<bool>.sync(() => _notifyApps(bound: true)).then<void>(
            (completed) {
              if (!completed) {
                _log.warning(
                  'reload.partial_failure',
                  fields: {
                    'reason_code': 'binding_modules_incomplete',
                    'outcome': 'partial_failure',
                  },
                );
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              _log.warning(
                'reload.failed',
                error: error,
                stackTrace: stackTrace,
              );
            },
          ),
        );
      },
      errorFields: (_) => {'stage': stage},
      resultFields: (_) => {
        'details': {'credential_saved': true, 'refresh_scheduled': true},
      },
    );
  });

  /// 解绑后等待所有模块处理完成；返回 false 表示存在未完成的刷新或清理。
  Future<bool> unbind() => _serialize(() {
    var stage = 'binding.delete';
    return _log.operation(
      'unbind',
      () async {
        await _deleteCredential();
        stage = 'binding.clear_session';
        await _clearSession(true);
        stage = 'binding.notify';
        return _notifyApps(bound: false);
      },
      errorFields: (_) => {'stage': stage},
      resultFields: (completed) => {
        'outcome': completed ? 'success' : 'partial_failure',
      },
    );
  });
}
