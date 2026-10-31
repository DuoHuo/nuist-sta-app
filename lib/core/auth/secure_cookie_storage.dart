import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../logging/app_log.dart';
import '../network/vpn_log.dart';

/// 把 cookie_jar 的持久化接到 [FlutterSecureStorage]。
///
/// 默认的 FileStorage 是明文落盘到应用私有目录。门户会话 Cookie 等同于登录
/// 态，值得和私钥享受同一层 Keystore/Keychain 保护；顺带省掉 path_provider。
class SecureCookieStorage implements Storage {
  const SecureCookieStorage();
  static final _log = AppLog.logger('core.auth.secure_cookie_storage');

  /// 与 [PasskeyStore] 共用一套安全存储，靠前缀区分命名空间。
  static const _prefix = 'portal_cookie_';
  static const _storage = FlutterSecureStorage();
  static const _timeout = Duration(seconds: 5);

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) => _log.inSpan(() async {
    try {
      return await _storage.read(key: '$_prefix$key').timeout(_timeout);
    } catch (error, stackTrace) {
      _log.warning(
        'read_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: vpnErrorKind(error),
      );
      return null;
    }
  });

  // 写失败只影响「下次启动免登录」，当前会话仍在内存里可用，所以静默降级，
  // 不把异常抛给正在跑登录流程的调用方。widget 测试环境没有平台通道，走的
  // 也是这条路。
  @override
  Future<void> write(String key, String value) => _log.inSpan(() async {
    try {
      await _storage.write(key: '$_prefix$key', value: value).timeout(_timeout);
    } catch (error, stackTrace) {
      _log.warning(
        'write_failed_using_memory',
        error: error,
        stackTrace: stackTrace,
        errorKind: vpnErrorKind(error),
      );
    }
  });

  @override
  Future<void> delete(String key) => _log.inSpan(() async {
    try {
      await _storage.delete(key: '$_prefix$key').timeout(_timeout);
    } catch (error, stackTrace) {
      _log.warning(
        'delete_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: vpnErrorKind(error),
      );
    }
  });

  @override
  Future<void> deleteAll(List<String> keys) async {
    for (final key in keys) {
      await delete(key);
    }
  }
}
