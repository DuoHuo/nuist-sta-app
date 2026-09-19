import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'passkey_bundle.dart';

/// 统一门户 Passkey 的安全存储（Android Keystore / iOS Keychain）。
///
/// 私钥只在这里落盘，任何地方都不要把 bundle 打到日志里。
class PasskeyStore {
  PasskeyStore._();

  static const _key = 'nuist_portal_passkey';
  static const _storage = FlutterSecureStorage();

  /// 读取已绑定的凭据；未绑定或存储不可用（如 widget 测试环境）时返回 null。
  static Future<PasskeyBundle?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return null;
      return PasskeyBundle.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(PasskeyBundle bundle) =>
      _storage.write(key: _key, value: jsonEncode(bundle.toJson()));

  static Future<void> delete() => _storage.delete(key: _key);
}
