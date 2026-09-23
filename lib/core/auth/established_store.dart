import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 一条已建立的会话：service 的落地 URL 与建立时间。
///
/// 落地 URL 不只是"登录成功"的标记——icard 的 JWT 就藏在它的 query 里，
/// 丢了就得重新过一遍 CAS。
class EstablishedEntry {
  const EstablishedEntry({
    required this.landing,
    required this.at,
    this.restored = false,
  });

  final String landing;
  final DateTime at;

  /// 是否是从磁盘恢复、本进程还没验证过的条目。
  final bool restored;

  bool isExpired(Duration ttl, {DateTime? now}) =>
      (now ?? DateTime.now()).difference(at) > ttl;

  Map<String, dynamic> toJson() => {
    'landing': landing,
    'at': at.millisecondsSinceEpoch,
  };

  static EstablishedEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final landing = json['landing'];
    final at = json['at'];
    if (landing is! String || landing.isEmpty || at is! int) return null;
    return EstablishedEntry(
      landing: landing,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      restored: true,
    );
  }
}

/// 把 [PortalSession] 的 service → 落地 URL 表落到安全存储。
///
/// 与 Cookie 一样属于登录态，享受同一层 Keystore/Keychain 保护。读写失败一律
/// 静默：最坏情况只是冷启动多走一次 SSO 快路径。
class EstablishedStore {
  EstablishedStore._();

  static const _key = 'portal_established';
  static const _storage = FlutterSecureStorage();

  static Future<Map<String, EstablishedEntry>> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final entries = <String, EstablishedEntry>{};
      for (final MapEntry(:key, :value) in decoded.entries) {
        final entry = EstablishedEntry.fromJson(value);
        if (key is String && entry != null) entries[key] = entry;
      }
      return entries;
    } catch (_) {
      return {};
    }
  }

  static Future<void> write(Map<String, EstablishedEntry> entries) async {
    try {
      if (entries.isEmpty) {
        await _storage.delete(key: _key);
        return;
      }
      await _storage.write(
        key: _key,
        value: jsonEncode({
          for (final MapEntry(:key, :value) in entries.entries)
            key: value.toJson(),
        }),
      );
    } catch (_) {}
  }
}
