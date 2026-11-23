import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/auth/service_auth_spec.dart';
import '../../core/auth/portal_http.dart' show portalLog;
import '../../core/auth/session_executor.dart';

import 'package:flutter/foundation.dart';

import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/diagnostic_error.dart';
import 'score_models.dart';
import '../../core/auth/safe_message.dart';

/// 教务 EMAP「学生成绩」应用（cjcx）的接口。
///
/// 应用会话及失效后的单次重登由统一鉴权执行器维护。
class ScoreApi {
  ScoreApi._();

  static final _base = 'https://${CampusHosts.jwxt}';
  static final Uri _indexUrl = Uri.parse(
    '$_base/jwapp/sys/cjcx/*default/index.do?EMAP_LANG=zh',
  );
  static final Uri _queryUrl = Uri.parse(
    '$_base/jwapp/sys/cjcx/modules/cjcx/xscjcx.do',
  );

  static final _spec = JwxtAppSpec(
    appId: 'cjcx',
    indexUrl: _indexUrl.toString(),
    refererUrl: _indexUrl.toString(),
  );

  /// 测试时替换统一鉴权执行器。
  @visibleForTesting
  static SessionExecutor? debugExecutor;

  static Future<ScoreReport> fetch() async {
    final rows = await _send();
    return ScoreReport(records: rows, fetchedAt: DateTime.now());
  }

  static Future<List<ScoreRecord>> _send() async {
    final body = {
      'querySetting': jsonEncode([
        {
          'name': 'SFYX',
          'caption': '是否有效',
          'builder': 'm_value_equal',
          'linkOpt': 'AND',
          'value': '1',
        },
      ]),
      '*json': '1',
      '*order': '-XNXQDM,-KCH,-KXH',
      'pageSize': '1000',
      'pageNumber': '1',
    };
    final encoded = body.entries
        .map((entry) => '${entry.key}=${Uri.encodeComponent(entry.value)}')
        .join('&');
    final response = await (debugExecutor ?? PortalSession.instance.executor)
        .execute(
          _spec,
          () => RequestOptions(
            path: _queryUrl.toString(),
            method: 'POST',
            data: encoded,
            contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
            responseType: ResponseType.plain,
            headers: {
              'Accept': 'application/json, text/javascript, */*; q=0.01',
              'X-Requested-With': 'XMLHttpRequest',
              'Origin': _base,
            },
          ),
          idempotent: true,
        );
    requireServiceSuccess(response, endpoint: 'score.query', service: 'jwxt');
    final raw = response.data;

    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map<String, dynamic>) {
        throw const DiagnosticException(
          '教务成绩响应不是对象',
          code: 'response_schema_mismatch',
          stage: 'response.validate',
          context: {'endpoint': 'score.query', 'service': 'jwxt'},
        );
      }
      final code = '${decoded['code'] ?? ''}';
      if (code.isNotEmpty && code != '0') {
        portalLog(
          'response.rejected',
          fields: {'service': 'jwxt', 'response_code': code},
        );
        throw DiagnosticException(
          prefixedServerMessage(
            '教务成绩接口返回错误：',
            decoded['msg'],
            fallback: '教务成绩接口返回错误，请稍后重试',
          ),
          code: 'service_rejected',
          stage: 'response.validate',
          context: {
            'endpoint': 'score.query',
            'service': 'jwxt',
            'response_code': code,
          },
        );
      }
      final datas = decoded['datas'];
      final section = datas is Map<String, dynamic>
          ? datas['xscjcx'] ?? _findRowsSection(datas)
          : null;
      final rows = section is Map<String, dynamic> ? section['rows'] : null;
      if (rows is! List) {
        throw const DiagnosticException(
          '教务成绩响应缺少成绩列表',
          code: 'response_rows_missing',
          stage: 'response.validate',
          context: {'endpoint': 'score.query', 'service': 'jwxt'},
        );
      }
      return [
        for (final row in rows)
          if (row is Map<String, dynamic>) ScoreRecord.fromRow(row),
      ];
    } on FormatException catch (error, stackTrace) {
      throw DiagnosticException(
        '教务成绩响应不是有效 JSON',
        code: 'response_invalid_json',
        stage: 'response.decode',
        cause: error,
        causeStackTrace: stackTrace,
        context: {'endpoint': 'score.query', 'service': 'jwxt'},
      );
    }
  }

  /// EMAP 一般把结果放在 `datas.xscjcx.rows`，部分版本会给模块名加
  /// 前缀。找不到固定键时，退化为寻找第一个带 rows 的数据段。
  static Map<String, dynamic>? _findRowsSection(Map<String, dynamic> datas) {
    for (final value in datas.values) {
      if (value is Map<String, dynamic> && value['rows'] is List) {
        return value;
      }
    }
    return null;
  }
}
