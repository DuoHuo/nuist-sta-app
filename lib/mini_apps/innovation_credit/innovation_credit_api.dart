import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/portal_session.dart';
import '../../core/auth/service_auth_spec.dart';
import '../../core/auth/session_executor.dart';
import '../../core/config/campus_config.dart';
import '../../core/html_table.dart';
import '../../core/logging/diagnostic_error.dart';
import 'innovation_credit_models.dart';

/// 双创学分汇总与明细统一使用上级平台换票建立的子系统会话。
class InnovationCreditApi {
  InnovationCreditApi._();

  static final Uri _summaryPage = Uri.parse(
    'https://${CampusHosts.cxxf}/XueFen/SummaryQuery/Index',
  );
  static final Uri _detailPage = Uri.parse(
    'https://${CampusHosts.cxxf}/XueFen/Summary/Index?PageSize=200',
  );
  static const _summaryTable = 'c_app_page_index_SummaryQuery_table';
  static const _detailTable = 'c_app_page_index_Summary_table';

  /// 测试时替换统一鉴权执行器。
  @visibleForTesting
  static SessionExecutor? debugExecutor;

  static Future<InnovationCredit> fetch() async {
    final summary = await _table(_summaryPage, _summaryTable);
    final detail = await _table(_detailPage, _detailTable);
    return InnovationCredit.fromRows(
      summary: summary,
      detail: detail,
      fetchedAt: DateTime.now(),
    );
  }

  static Future<List<Map<String, String>>> _table(
    Uri page,
    String tableId,
  ) async {
    final response = await (debugExecutor ?? PortalSession.instance.executor)
        .execute(
          const InnovationSpec(),
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
      endpoint: identical(page, _summaryPage)
          ? 'innovation_credit.summary'
          : 'innovation_credit.detail',
      service: 'innovation',
    );
    final rows = parseHtmlTable('${response.data ?? ''}', tableId);
    if (rows != null) return rows;
    throw DiagnosticException(
      '双创学分页面缺少目标表格',
      code: 'response_table_missing',
      stage: 'response.parse',
      context: {
        'endpoint': identical(page, _summaryPage)
            ? 'innovation_credit.summary'
            : 'innovation_credit.detail',
        'service': 'innovation',
      },
    );
  }
}
