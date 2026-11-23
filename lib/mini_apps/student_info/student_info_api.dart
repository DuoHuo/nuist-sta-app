import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/service_auth_spec.dart';
import '../../core/auth/session_executor.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/diagnostic_error.dart';
import 'student_info_models.dart';

/// 信息门户的两个接口：
/// - `GET /getLoginUserAndGuest`：当前登录人。**未登录时也返回 errcode 0**，
///   只是给一个 userAccount 为 null 的游客对象，所以要按学号非空来判定；
/// - `POST /execTemplateMethod`（method=getXLInfo）：某个日期所在学期的校历。
///   未登录时 errcode 为 999。
///
/// 两个查询共用信息门户会话，由统一鉴权执行器处理并发重登。
class StudentInfoApi {
  StudentInfoApi._();

  static final _base = 'https://${CampusHosts.iportal}';
  static final Uri _templateApi = Uri.parse('$_base/execTemplateMethod');

  /// 测试时替换统一鉴权执行器。
  @visibleForTesting
  static SessionExecutor? debugExecutor;

  static SessionExecutor get _executor =>
      debugExecutor ?? PortalSession.instance.executor;

  static Future<StudentInfo> fetch() async {
    final now = DateTime.now();
    final results = await Future.wait<Object?>([
      _fetchUser(),
      _fetchSemester(now),
    ]);
    return StudentInfo(
      user: results[0] as PortalUser,
      semester: results[1] as SemesterInfo?,
      fetchedAt: now,
    );
  }

  static Future<PortalUser> _fetchUser() async {
    final response = await _executor.execute(
      const IportalSpec(),
      () => RequestOptions(
        path: '$_base/getLoginUserAndGuest?_t=${Random().nextDouble()}',
        responseType: ResponseType.plain,
        headers: {'Accept': 'application/json'},
      ),
      idempotent: true,
    );
    requireServiceSuccess(
      response,
      endpoint: 'student_info.user',
      service: 'portal',
    );
    final body = _decode(response.data, 'student_info.user');
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const DiagnosticException(
        '信息门户未返回用户信息对象',
        code: 'response_schema_mismatch',
        stage: 'response.validate',
        context: {'endpoint': 'student_info.user', 'service': 'portal'},
      );
    }
    final user = PortalUser.fromJson(data);
    return user;
  }

  /// 拿 [date] 所在学期；接口正常但没有学期数据时返回 null。
  static Future<SemesterInfo?> _fetchSemester(DateTime date) async {
    String two(int n) => n.toString().padLeft(2, '0');
    final response = await _executor.execute(
      const IportalSpec(),
      () => RequestOptions(
        path: _templateApi.toString(),
        method: 'POST',
        data: jsonEncode({
          'method': 'getXLInfo',
          'param': {
            'date': '${date.year}-${two(date.month)}-${two(date.day)}',
            '_t': date.millisecondsSinceEpoch,
          },
          'n': '${Random().nextDouble()}',
        }),
        contentType: 'application/json;charset=UTF-8',
        responseType: ResponseType.plain,
        headers: {
          'Accept': 'application/json, text/plain, */*',
          'X-Requested-With': 'XMLHttpRequest',
        },
      ),
      idempotent: true,
    );
    requireServiceSuccess(
      response,
      endpoint: 'student_info.calendar',
      service: 'portal',
    );
    final body = _decode(response.data, 'student_info.calendar');
    if ('${body['errcode']}' != '0') {
      throw DiagnosticException(
        '信息门户校历接口返回错误',
        code: 'service_rejected',
        stage: 'response.validate',
        context: {
          'endpoint': 'student_info.calendar',
          'service': 'portal',
          'response_code': '${body['errcode']}',
        },
      );
    }
    final data = body['data'];
    return SemesterInfo.tryFromJson(data is Map<String, dynamic> ? data : null);
  }

  static Map<String, dynamic> _decode(Object? raw, String endpoint) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (error, stackTrace) {
      throw DiagnosticException(
        '信息门户响应不是有效 JSON',
        code: 'response_invalid_json',
        stage: 'response.decode',
        cause: error,
        causeStackTrace: stackTrace,
        context: {'endpoint': endpoint, 'service': 'portal'},
      );
    }
    throw DiagnosticException(
      '信息门户响应不是对象',
      code: 'response_schema_mismatch',
      stage: 'response.validate',
      context: {'endpoint': endpoint, 'service': 'portal'},
    );
  }
}
