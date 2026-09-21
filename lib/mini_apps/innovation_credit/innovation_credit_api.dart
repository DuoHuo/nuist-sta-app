import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import '../../core/html_table.dart';
import 'innovation_credit_models.dart';

/// 双创学分：数据在学分认定子系统 cxxf 的两个 HTML 页面里，没有 JSON 接口。
///
/// cxxf 自己不接 CAS，登录态要从上级平台 cxcyjy 换来，整条链路实测如下：
/// 1. CAS 登录 [PortalServices.cxcyjy]，落地「正在跳转中…」页；
/// 2. 该页 JS 用页面里的防伪 token **POST** 一次 `HomePage/UnifiedAuthenticationLogin`，
///    平台才真正记下登录态（只走完 CAS 时 `/pt` 仍显示登录按钮）；
/// 3. `GET AccessSubsystem/<guid>` → 302 到 `cxxf/authserver/access?access=…`，
///    这一跳**必须带 Referer**（不带报「访问参数获取失败」），cxxf 据此下发自己的
///    会话 Cookie。
///
/// 会话检测：未登录访问业务页会被 302 到 cxxf 的站内登录页（HTTP 200），
/// 所以按「页面里有没有目标表格」判断，没有就走一遍上述链路再试。
class InnovationCreditApi {
  InnovationCreditApi._();

  static const _platform = 'https://cxcyjy.campus.invalid/pt';
  static final Uri _completeLogin = Uri.parse(
    '$_platform/HomePage/UnifiedAuthenticationLogin',
  );
  static final Uri _accessSubsystem = Uri.parse(
    '$_platform/System/Platform/AccessSubsystem/'
    'e8051115-0e26-47d1-963d-9a79992102ff',
  );

  static final Uri _summaryPage = Uri.parse(
    'https://cxxf.campus.invalid/XueFen/SummaryQuery/Index',
  );
  static final Uri _detailPage = Uri.parse(
    'https://cxxf.campus.invalid/XueFen/Summary/Index?PageSize=200',
  );
  static const _summaryTable = 'c_app_page_index_SummaryQuery_table';
  static const _detailTable = 'c_app_page_index_Summary_table';

  static Future<InnovationCredit> fetch() async {
    final session = PortalSession.instance;
    var summary = await _table(session.http, _summaryPage, _summaryTable);
    if (summary == null) {
      portalLog('双创学分子系统会话失效，重新登录');
      await _login(session);
      summary = await _table(session.http, _summaryPage, _summaryTable);
      if (summary == null) {
        throw const PortalLoginError('登录后仍打不开双创学分汇总页，请稍后再试');
      }
    }
    final detail = await _table(session.http, _detailPage, _detailTable);
    if (detail == null) {
      throw const PortalLoginError('双创学分明细页未返回表格，请稍后再试');
    }
    return InnovationCredit.fromRows(
      summary: summary,
      detail: detail,
      fetchedAt: DateTime.now(),
    );
  }

  // ==================== 内部实现 ====================

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

  static Future<void> _login(PortalSession session) async {
    final landing = await session.ensureLoggedIn(
      PortalServices.cxcyjy,
      force: true,
    );
    final http = session.http;

    // 第二步：补 POST。token 藏在落地页的隐藏 input 里。
    final page = await http.followRedirects(await http.get(Uri.parse(landing)));
    final token = RegExp(
      r'name="__RequestVerificationToken"[^>]*value="([^"]+)"',
    ).firstMatch('${page.data}')?.group(1);
    if (token == null) {
      throw PortalLoginError('创新创业平台落地页缺少防伪 token：$landing');
    }
    final done = await http.post(
      _completeLogin,
      data: FormData.fromMap({'__RequestVerificationToken': token}),
      headers: {
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': landing,
      },
    );
    final result = _decode(done.data);
    if (result == null || result['Success'] != true) {
      throw PortalLoginError(
        '创新创业平台统一认证未完成：${result?['Message'] ?? done.data}',
      );
    }
    // 页面 JS 会跳到 Data.RedirectUrl（相对平台根，如 /System/User/LoginRole），
    // 照做一次，与浏览器行为一致。
    final redirect = '${(result['Data'] as Map?)?['RedirectUrl'] ?? ''}';
    if (redirect.isNotEmpty) {
      await http.followRedirects(await http.get(_platformUrl(redirect)));
    }

    // 第三步：经 AccessSubsystem 换 cxxf 会话。第一跳要带 Referer，所以不能
    // 直接交给 followRedirects。
    const referer = {'Referer': '$_platform/'};
    final hop = await http.get(_accessSubsystem, headers: referer);
    final location = hop.headers.value('location');
    if (!PortalHttp.isRedirect(hop.statusCode) ||
        location == null ||
        location.isEmpty) {
      throw PortalLoginError(
        'AccessSubsystem 未跳转到学分子系统（HTTP ${hop.statusCode}）',
      );
    }
    final access = await http.get(
      hop.realUri.resolve(location),
      headers: referer,
    );
    await http.followRedirects(access);
  }

  /// 平台 JS 的 getOSUrl：绝对地址原样用，否则去掉前导斜杠拼到平台根后面。
  static Uri _platformUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Uri.parse(url);
    }
    return Uri.parse('$_platform/${url.replaceFirst(RegExp(r'^/+'), '')}');
  }

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw == null) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
