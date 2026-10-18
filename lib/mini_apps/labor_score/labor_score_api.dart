import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/html_table.dart';
import 'labor_score_models.dart';

/// 劳动教育平台：四个 HTML 页面，没有 JSON 接口。
///
/// 会话检测：未登录访问业务页会被 302 到站内 `/AuthServer/Login`（HTTP 200），
/// [PortalSession.request] 认不出，所以按「页面里有没有目标表格」判断；没有就
/// 强制走一次 CAS（[PortalServices.labor]）再试。CAS 落地 `/System/User/LoginRole`
/// 后会话即可用，不像双创平台还要补 POST。
///
/// 先用「学生成绩」页把会话建好，其余三页再并发——否则四个请求会同时发现未
/// 登录、各自触发一次强制重登。
class LaborScoreApi {
  LaborScoreApi._();

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

  static Future<LaborScore> fetch() async {
    final session = PortalSession.instance;
    var http = session.http;
    var result = await _table(http, _resultPage, _resultTable);
    if (result == null) {
      portalLog(() => '劳动教育平台会话失效，重新登录');
      http = await session.clientFor(PortalServices.labor, force: true);
      result = await _table(http, _resultPage, _resultTable);
      if (result == null) {
        throw const PortalLoginError('登录后仍打不开劳动积分页面，请稍后再试');
      }
    }
    final pages = await Future.wait([
      _table(http, _lifePage, _jifenTable),
      _table(http, _servicePage, _jifenTable),
      _table(http, _majorPage, _majorTable),
    ]);
    return LaborScore.fromRows(
      result: result,
      life: pages[0],
      service: pages[1],
      major: pages[2],
      fetchedAt: DateTime.now(),
    );
  }

  /// 拉页面并截取表格；页面里没有该表格（多半是登录页）返回 null。
  static Future<List<Map<String, String>>?> _table(
    PortalHttp http,
    Uri page,
    String tableId,
  ) async {
    final response = await http.followRedirects(
      await http.get(
        page,
        headers: {'Accept': 'text/html,application/xhtml+xml'},
      ),
    );
    return parseHtmlTable('${response.data}', tableId);
  }
}
