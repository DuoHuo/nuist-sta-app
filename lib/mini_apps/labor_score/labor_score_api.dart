import '../../core/auth/portal_exceptions.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/service_auth_spec.dart';
import '../../core/auth/session_executor.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/html_table.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import '../../core/refresh/silent_refresh.dart';
import 'labor_score_models.dart';

/// 劳动教育平台：四个 HTML 页面，没有 JSON 接口。
///
/// 四个页面共用统一鉴权会话，登录失效时各自重放一次。
class LaborScoreApi {
  LaborScoreApi._();
  static final _log = AppLog.logger('labor_score.api');

  static final _base = 'https://${CampusHosts.labor}';
  static final Uri _resultPage = Uri.parse('$_base/ResultManage/StudentResult');
  static final Uri _lifePage = Uri.parse(
    '$_base/Activity/StudentJiFen/Index?pc=生活',
  );
  static final Uri _servicePage = Uri.parse(
    '$_base/Activity/StudentJiFen/Index?pc=服务',
  );
  static final Uri _majorPage = Uri.parse(
    '$_base/ResultManage/ZYLDScoreHZ/Index4DefaultGrades',
  );

  static const _resultTable = 'ResultManage_StudentResult_Index_table';
  static const _jifenTable = 'c_app_page_index_StudentJiFen_table';
  static const _majorTable = 'ResultManage_ZYLDScoreHZ_Index_table';

  /// 测试时替换统一鉴权执行器。
  @visibleForTesting
  static SessionExecutor? debugExecutor;

  static Future<LaborScore> fetch() async {
    final result = await _table(_resultPage, _resultTable);
    final pages = await Future.wait([
      _optionalTable(_lifePage, _jifenTable),
      _optionalTable(_servicePage, _jifenTable),
      _optionalTable(_majorPage, _majorTable),
    ]);
    return LaborScore.fromRows(
      result: result,
      life: pages[0],
      service: pages[1],
      major: pages[2],
      fetchedAt: DateTime.now(),
    );
  }

  /// 校验 HTTP 状态后解析目标表格，缺失表格保留为解析异常。
  static Future<List<Map<String, String>>> _table(
    Uri page,
    String tableId,
  ) async {
    final response = await (debugExecutor ?? PortalSession.instance.executor)
        .execute(
          const LaborSpec(),
          () => RequestOptions(
            path: page.toString(),
            responseType: ResponseType.plain,
            headers: {'Accept': 'text/html,application/xhtml+xml'},
            extra: {'authTableId': tableId},
          ),
          idempotent: true,
        );
    requireServiceSuccess(
      response,
      endpoint: _endpoint(page),
      service: 'labor',
    );
    final body = '${response.data ?? ''}';
    final rows = parseHtmlTable(body, tableId);
    if (rows != null) return rows;
    throw DiagnosticException(
      '劳动积分页面缺少目标表格',
      code: 'response_table_missing',
      stage: 'response.parse',
      context: {'endpoint': _endpoint(page), 'service': 'labor'},
    );
  }

  static String _endpoint(Uri page) => identical(page, _resultPage)
      ? 'labor_score.summary'
      : identical(page, _lifePage)
      ? 'labor_score.life'
      : identical(page, _servicePage)
      ? 'labor_score.service'
      : 'labor_score.major';

  static Future<List<Map<String, String>>?> _optionalTable(
    Uri page,
    String tableId,
  ) async {
    try {
      return await _table(page, tableId);
    } on PortalLoginError catch (error, stackTrace) {
      if (error.code == 'session_generation_changed') rethrow;
      _degradeSection(page, error, stackTrace);
      return null;
    } on DiagnosticException catch (error, stackTrace) {
      final status = error.context['status_code'];
      final serverError =
          error.code == 'http_status_rejected' &&
          status is int &&
          status >= 500;
      if (!serverError && error.code != 'response_table_missing') rethrow;
      _degradeSection(page, error, stackTrace);
      return null;
    } on FormatException catch (error, stackTrace) {
      _degradeSection(page, error, stackTrace);
      return null;
    }
  }

  static void _degradeSection(Uri page, Object error, StackTrace stackTrace) {
    SilentRefresh.degradeCurrent(reason: 'optional_section_unavailable');
    _log.warning(
      'section.unavailable',
      fields: {'endpoint': _endpoint(page), 'outcome': 'degraded'},
      error: error,
      stackTrace: stackTrace,
    );
  }
}
