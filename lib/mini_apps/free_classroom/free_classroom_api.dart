import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import 'free_classroom_models.dart';

/// 教务系统 EMAP「空闲教室」应用（kxjas）的接口，移植自 qqbot/jwxt/jscx.py。
///
/// 全是 `POST modules/kxjas/<name>.do` 的表单请求，响应
/// `{"code":"0","datas":{"<name>":{"rows":[...]}}}`。用 [PortalServices.jwxt]
/// 的会话，但 EMAP 要求先访问过应用首页（`*default/index.do`）才放行模块接口，
/// 所以每个进程首次调用、以及每次强制重登后，都先 GET 一次首页。
///
/// 会话失效时模块接口会被 302 到 CAS 或吐回登录页 HTML，这里把「响应不是
/// JSON」视为失效，强制重登一次再重放。
class FreeClassroomApi {
  FreeClassroomApi._();

  static final _base = 'https://${CampusHosts.jwxt}';

  /// 校区代码，教务只开放了本部一个校区，写死。
  static const _campusCode = '01';

  static final Uri _indexUrl = Uri.parse(
    '$_base/jwapp/sys/kxjas/*default/index.do?EMAP_LANG=zh',
  );

  static Uri _module(String name) =>
      Uri.parse('$_base/jwapp/sys/kxjas/modules/kxjas/$name.do');

  /// 应用首页是否已经访问过（EMAP 应用级会话已建立）。
  static bool _appReady = false;

  /// 教学楼列表，按教务给的排序。
  static Future<List<Building>> listBuildings() async {
    final rows = await _rows('jxlcx', {
      'XXXQDM': _campusCode,
      '*order': '+PX,+JXLDM',
    });
    return [
      for (final row in rows)
        if ((row['JXLDM'] ?? '').toString().isNotEmpty)
          Building(
            code: row['JXLDM'].toString(),
            name: (row['JXLMC'] ?? row['JXLDM']).toString().trim(),
          ),
    ];
  }

  /// 占用类型字典（代码 → 名称），以内置表为底。
  static Future<Map<String, String>> occupationNames() async {
    final rows = await _rows('ggzdpx', {
      'dicCode': '9955766',
      'order': '+DM',
      'SFSY': '1',
    });
    final result = Map<String, String>.of(kOccupationNames);
    for (final row in rows) {
      final code = row['DM']?.toString();
      final name = row['MC']?.toString();
      if (code != null && name != null && name.isNotEmpty) result[code] = name;
    }
    return result;
  }

  /// [date] 在校历上的学期 / 周次 / 星期，以及该学期的大节定义。
  ///
  /// 日期不在任何学期范围内（寒暑假）时抛 [PortalLoginError] 说明原因。
  static Future<TermCalendar> calendar(DateTime date) async {
    final key = dateKeyOf(date);
    final termRows = await _rows('gjrqcxdyxnxq', {'KSRQ': key, 'JSRQ': key});
    final termCode = termRows.isEmpty
        ? ''
        : (termRows.first['XQ'] ?? '').toString();
    if (termCode.isEmpty) {
      throw const PortalLoginError('该日期不在校历范围内，可能处于假期');
    }
    // `2026-2027-1` → 学年 `2026-2027`，学期 `1`。
    final dash = termCode.lastIndexOf('-');
    final year = dash > 0 ? termCode.substring(0, dash) : termCode;
    final term = dash > 0 ? termCode.substring(dash + 1) : '';

    final results = await Future.wait<Object>([
      _datas('rqzhzcjc', {'RQ': key, 'XN': year, 'XQ': term}),
      _rows('cxjcqk', {'XNXQDM': termCode}),
    ]);
    // rqzhzcjc 实测把 ZC / XQJ 直接放在 datas 这一层，不套 rows。
    final position = _firstRowOrSelf(results[0] as Map<String, dynamic>);
    final week = int.tryParse('${position['ZC']}');
    final weekday = int.tryParse('${position['XQJ']}');
    if (week == null || weekday == null) {
      throw const PortalLoginError('教务未返回该日期的周次信息');
    }
    return TermCalendar(
      termCode: termCode,
      week: week,
      weekday: weekday,
      groups: PeriodGroup.fromRows(results[1] as List<Map<String, dynamic>>),
    );
  }

  /// 某天某楼全部教室的占用情况，按楼层、教室名排序。
  static Future<List<Classroom>> classrooms({
    required DateTime date,
    required TermCalendar calendar,
    required Building building,
  }) async {
    final rows = await _rows('cxjsqk', {
      'XNXQDM': calendar.termCode,
      'ZC': '${calendar.week}',
      'XQ': '${calendar.weekday}',
      'RQ': dateKeyOf(date),
      'querySetting': jsonEncode([
        {
          'name': 'JXLDM',
          'caption': '教学楼代码',
          'builder': 'equal',
          'linkOpt': 'AND',
          'value': building.code,
        },
      ]),
      '*order': '+LC,+JASMC',
      // 实测最大的文德楼 129 间，一页拉完，不分页。
      'pageSize': '1000',
      'pageNumber': '1',
    });
    return [
      for (final row in rows)
        if ((row['JASMC'] ?? '').toString().trim().isNotEmpty)
          Classroom.fromRow(row, calendar.maxPeriod),
    ];
  }

  // ==================== 内部实现 ====================

  static Future<List<Map<String, dynamic>>> _rows(
    String name,
    Map<String, String> fields,
  ) async {
    final datas = await _datas(name, fields);
    final rows = datas['rows'];
    if (rows is! List) return const [];
    return [
      for (final row in rows)
        if (row is Map<String, dynamic>) row,
    ];
  }

  /// `datas.<name>`；有的接口（rqzhzcjc）直接在这一层给字段而不是 rows。
  static Future<Map<String, dynamic>> _datas(
    String name,
    Map<String, String> fields,
  ) async {
    var body = await _send(name, fields, force: false);
    if (body == null) {
      portalLog('教务 kxjas 会话失效，重新登录');
      body = await _send(name, fields, force: true);
    }
    if (body == null) {
      throw const PortalLoginError('重新登录后教务仍未返回数据，请稍后再试');
    }
    if ('${body['code']}' != '0') {
      throw PortalLoginError('教务接口返回错误：${body['msg'] ?? body['code']}');
    }
    final datas = body['datas'];
    final section = datas is Map<String, dynamic> ? datas[name] : null;
    return section is Map<String, dynamic> ? section : const {};
  }

  static Map<String, dynamic> _firstRowOrSelf(Map<String, dynamic> datas) {
    final rows = datas['rows'];
    if (rows is List && rows.isNotEmpty && rows.first is Map<String, dynamic>) {
      return rows.first as Map<String, dynamic>;
    }
    return datas;
  }

  /// 返回 null 表示响应不是 JSON（被拦回登录页）。
  static Future<Map<String, dynamic>?> _send(
    String name,
    Map<String, String> fields, {
    required bool force,
  }) async {
    final http = await _client(force: force);
    if (http == null) return null;
    final body = fields.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final response = await http.followRedirects(
      await http.post(
        _module(name),
        data: body,
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
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // HTML 登录页，按会话失效处理。
    }
    _appReady = false;
    return null;
  }

  /// 拿到已登录教务、且 kxjas 应用首页已访问过的客户端。
  ///
  /// 首页 GET 落到登录页说明落盘会话已过期：非强制模式下返回 null 让调用方
  /// 走强制重登；强制模式下仍失败就直接报错。
  static Future<PortalHttp?> _client({required bool force}) async {
    final session = PortalSession.instance;
    final http = await session.clientFor(PortalServices.jwxt, force: force);
    if (_appReady && !force) return http;
    final response = await http.followRedirects(await http.get(_indexUrl));
    if (_looksLikeLoginPage(response)) {
      if (!force) return null;
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
