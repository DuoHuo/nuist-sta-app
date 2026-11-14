import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../logging/app_log.dart';

/// 一条已建立的会话：service 的落地 URL 与建立时间。
///
/// 落地 URL 不只是"登录成功"的标记——icard 的 JWT 就藏在它的 query 里，
/// 丢了就得重新过一遍 CAS。
class EstablishedEntry {
  const EstablishedEntry({
    required this.landing,
    required this.at,
    this.restored = false,
    this.diagnosticRecord,
  });

  final String landing;
  final DateTime at;

  /// 是否是从磁盘恢复、本进程还没验证过的条目。
  final bool restored;

  /// 原登录响应在诊断日志中的精确引用；凭据存储不重复保存响应正文。
  final Map<String, Object?>? diagnosticRecord;

  bool isExpired(Duration ttl, {DateTime? now}) =>
      (now ?? DateTime.now()).difference(at) > ttl;

  Map<String, dynamic> toJson() => {
    'landing': landing,
    'at': at.millisecondsSinceEpoch,
    'diagnostic_record': ?_readDiagnosticRecord(diagnosticRecord),
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
      diagnosticRecord: _readDiagnosticRecord(json['diagnostic_record']),
    );
  }

  static Map<String, Object?>? _readDiagnosticRecord(Object? value) {
    if (value is! Map) return null;
    final session = value['session_id'];
    final sequence = value['seq'];
    if (session is! String ||
        !RegExp(r'^[a-f0-9]{16}$').hasMatch(session) ||
        sequence is! int ||
        sequence < 0) {
      return null;
    }
    return Map.unmodifiable({'session_id': session, 'seq': sequence});
  }
}

/// 把 [PortalSession] 的 service → 落地 URL 表落到安全存储。
///
/// 与 Cookie 一样属于登录态，享受同一层 Keystore/Keychain 保护。读写失败一律
/// 静默：最坏情况只是冷启动多走一次 SSO 快路径。
class EstablishedStore {
  EstablishedStore._();
  static final _log = AppLog.logger('core.auth.established_store');

  static const _key = 'portal_established';
  static const _storage = FlutterSecureStorage();

  static Future<Map<String, EstablishedEntry>> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _log.warning(
          'cache.schema_invalid',
          fields: {
            'reason_code': 'established_cache_not_object',
            'outcome': 'cache_fallback',
          },
        );
        return {};
      }
      final entries = <String, EstablishedEntry>{};
      var invalid = 0;
      for (final MapEntry(:key, :value) in decoded.entries) {
        final entry = EstablishedEntry.fromJson(value);
        if (key is String && entry != null) {
          entries[key] = entry;
        } else {
          invalid++;
        }
      }
      if (invalid > 0) {
        _log.warning(
          'cache.entries_discarded',
          fields: {
            'skipped_count': invalid,
            'reason_code': 'established_entries_invalid',
            'outcome': 'cache_fallback',
          },
        );
      }
      return entries;
    } catch (error, stackTrace) {
      _log.warning(
        'read_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'stage': 'session.cache.read', 'outcome': 'cache_fallback'},
      );
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
    } catch (error, stackTrace) {
      _log.warning(
        'write_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'stage': 'session.cache.write', 'outcome': 'memory_fallback'},
      );
    }
  }
}
