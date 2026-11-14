import 'dart:convert';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/diagnostic_error.dart';
import 'academic_models.dart';

/// 信息门户学业概览接口：GET `/cus/jxmh/czjl?xh=`，学号留空即查自己。
///
/// 实测未登录时不会弹回登录页，而是 HTTP 200 + 空 body，所以
/// [PortalSession.request] 的过期识别用不上；这里把「拿不到 JSON 对象」视为
/// 会话失效，强制重登一次再试。
class AcademicApi {
  AcademicApi._();

  static final Uri _api = Uri.parse(
    'https://${CampusHosts.iportal}/cus/jxmh/czjl?xh=',
  );

  static Future<AcademicSummary> fetchSummary() async {
    var json = await _send(force: false);
    if (json == null) {
      portalLog('session.expired', fields: {'service': 'portal'});
      json = await _send(force: true);
    }
    if (json == null) {
      throw const PortalLoginError(
        '学业概览接口未返回数据，请稍后再试',
        code: 'session_unavailable_after_relogin',
        stage: 'response.validate',
        context: {'endpoint': 'academic.summary', 'service': 'portal'},
      );
    }
    return AcademicSummary.fromJson(json, fetchedAt: DateTime.now());
  }

  /// 返回 null 表示响应不是 JSON 对象（多半是没登录）。
  static Future<Map<String, dynamic>?> _send({required bool force}) async {
    final http = await PortalSession.instance.clientFor(
      PortalServices.iportal,
      force: force,
    );
    final response = await http.followRedirects(
      await http.get(_api, headers: {'Accept': 'application/json'}),
    );
    final raw = response.data;
    if (raw == null || (raw is String && raw.trim().isEmpty)) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map<String, dynamic> && decoded.containsKey('XH')) {
        return decoded;
      }
    } on FormatException catch (error, stackTrace) {
      if (raw is String && raw.contains('authserver/login')) return null;
      throw DiagnosticException(
        '学业概览响应不是有效 JSON',
        code: 'response_invalid_json',
        stage: 'response.decode',
        cause: error,
        causeStackTrace: stackTrace,
        context: {'endpoint': 'academic.summary', 'service': 'portal'},
      );
    }
    throw const DiagnosticException(
      '学业概览响应缺少必要字段',
      code: 'response_schema_mismatch',
      stage: 'response.validate',
      context: {'endpoint': 'academic.summary', 'service': 'portal'},
    );
  }
}
