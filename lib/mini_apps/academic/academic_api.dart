import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/service_auth_spec.dart';
import '../../core/auth/session_executor.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/diagnostic_error.dart';
import 'academic_models.dart';

/// 信息门户学业概览接口：GET `/cus/jxmh/czjl?xh=`，学号留空即查自己。
///
/// 空响应和登录失效统一由鉴权执行器识别与恢复。
class AcademicApi {
  AcademicApi._();

  static final Uri _api = Uri.parse(
    'https://${CampusHosts.iportal}/cus/jxmh/czjl?xh=',
  );

  /// 测试时替换统一鉴权执行器。
  @visibleForTesting
  static SessionExecutor? debugExecutor;

  static Future<AcademicSummary> fetchSummary() async {
    final response = await (debugExecutor ?? PortalSession.instance.executor)
        .execute(
          const IportalSpec(),
          () => RequestOptions(
            path: _api.toString(),
            responseType: ResponseType.plain,
            headers: {'Accept': 'application/json'},
          ),
          idempotent: true,
        );
    requireServiceSuccess(
      response,
      endpoint: 'academic.summary',
      service: 'portal',
    );
    return AcademicSummary.fromJson(
      _decode(response.data),
      fetchedAt: DateTime.now(),
    );
  }

  static Map<String, dynamic> _decode(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map<String, dynamic> && decoded.containsKey('XH')) {
        return decoded;
      }
    } on FormatException catch (error, stackTrace) {
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
