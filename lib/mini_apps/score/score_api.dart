import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import 'score_models.dart';

/// 教务 EMAP「学生成绩」应用（cjcx）的接口。
///
/// 教务模块接口要求先访问应用首页建立应用级会话，然后再 POST
/// `modules/cjcx/xscjcx.do`。响应不是 JSON 时按会话失效处理，强制走一次
/// 统一门户登录后重放。
class ScoreApi {
  ScoreApi._();

  static const _base = 'https://jwxt.nuist.edu.cn';
  static final Uri _indexUrl = Uri.parse(
    '$_base/jwapp/sys/cjcx/*default/index.do?EMAP_LANG=zh',
  );
  static final Uri _queryUrl = Uri.parse(
    '$_base/jwapp/sys/cjcx/modules/cjcx/xscjcx.do',
  );

  static bool _appReady = false;

  static Future<ScoreReport> fetch() async {
    var rows = await _send(force: false);
    if (rows == null) {
      portalLog('教务 cjcx 会话失效，重新登录');
      rows = await _send(force: true);
    }
    if (rows == null) {
      throw const PortalLoginError('重新登录后教务仍未返回成绩，请稍后再试');
    }
    return ScoreReport(records: rows, fetchedAt: DateTime.now());
  }

  static Future<List<ScoreRecord>?> _send({required bool force}) async {
    final http = await _client(force: force);
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
    final response = await http.followRedirects(
      await http.post(
        _queryUrl,
        data: encoded,
        contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
        headers: {
          'Accept': 'application/json, text/javascript, */*; q=0.01',
          'X-Requested-With': 'XMLHttpRequest',
          'Origin': _base,
          'Referer': _indexUrl.toString(),
        },
      ),
    );
    final raw = response.data;
    if (raw == null) return null;
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map<String, dynamic>) {
        _appReady = false;
        return null;
      }
      final code = '${decoded['code'] ?? ''}';
      if (code.isNotEmpty && code != '0') {
        throw PortalLoginError('教务成绩接口返回错误：${decoded['msg'] ?? code}');
      }
      final datas = decoded['datas'];
      final section = datas is Map<String, dynamic>
          ? datas['xscjcx'] ?? _findRowsSection(datas)
          : null;
      final rows = section is Map<String, dynamic> ? section['rows'] : null;
      if (rows is! List) return const [];
      return [
        for (final row in rows)
          if (row is Map<String, dynamic>) ScoreRecord.fromRow(row),
      ];
    } on FormatException {
      _appReady = false;
      return null;
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

  static Future<PortalHttp> _client({required bool force}) async {
    final session = PortalSession.instance;
    final http = await session.clientFor(PortalServices.jwxt, force: force);
    if (_appReady && !force) return http;
    final response = await http.followRedirects(
      await http.get(
        _indexUrl,
        headers: {'Accept': 'text/html,application/xhtml+xml'},
      ),
    );
    if (_looksLikeLoginPage(response)) {
      _appReady = false;
      if (!force) {
        final fresh = await session.clientFor(PortalServices.jwxt, force: true);
        final retry = await fresh.followRedirects(
          await fresh.get(
            _indexUrl,
            headers: {'Accept': 'text/html,application/xhtml+xml'},
          ),
        );
        if (_looksLikeLoginPage(retry)) {
          throw const PortalLoginError('重新登录后仍被教务拦回登录页，请稍后再试');
        }
        _appReady = true;
        return fresh;
      }
      throw const PortalLoginError('重新登录后仍被教务拦回登录页，请稍后再试');
    }
    _appReady = true;
    return http;
  }

  static bool _looksLikeLoginPage(Response<dynamic> response) {
    if (response.realUri.host.contains('authserver')) return true;
    final body = response.data;
    return body is String &&
        body.contains('authserver/login') &&
        body.contains('name="execution"');
  }
}
