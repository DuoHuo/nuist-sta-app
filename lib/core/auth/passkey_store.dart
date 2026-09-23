import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'passkey_bundle.dart';

/// 统一门户 Passkey 的安全存储（Android Keystore / iOS Keychain）。
///
/// 私钥只在这里落盘，任何地方都不要把 bundle 打到日志里。
///
/// 读到的结果在内存里缓存：每个小程序每次刷新都要问一句「绑了没」，没必要
/// 每次都过一遍平台通道。
class PasskeyStore {
  PasskeyStore._();

  static const _key = 'nuist_portal_passkey';
  static const _storage = FlutterSecureStorage();

  static PasskeyBundle? _cached;
  static bool _loaded = false;

  /// 读取已绑定的凭据；未绑定或存储不可用（如 widget 测试环境）时返回 null。
  static Future<PasskeyBundle?> read() async {
    if (_loaded) return _cached;
    try {
      final raw = await _storage.read(key: _key);
      _cached = raw == null || raw.isEmpty
          ? null
          : PasskeyBundle.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _loaded = true;
      return _cached;
    } catch (_) {
      // 存储不可用时不记为已加载，下次还会再试。
      return null;
    }
  }

  static Future<void> save(PasskeyBundle bundle) async {
    await _storage.write(key: _key, value: jsonEncode(bundle.toJson()));
    _cached = bundle;
    _loaded = true;
  }

  static Future<void> delete() async {
    await _storage.delete(key: _key);
    _cached = null;
    _loaded = true;
  }
}
