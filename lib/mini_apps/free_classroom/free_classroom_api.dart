import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/auth/service_auth_spec.dart';
import '../../core/auth/portal_http.dart' show portalLog;
import '../../core/auth/session_executor.dart';

import 'package:flutter/foundation.dart';

import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/diagnostic_error.dart';
import 'free_classroom_models.dart';
import '../../core/auth/safe_message.dart';

/// 教务系统 EMAP「空闲教室」应用（kxjas）的接口，移植自 qqbot/jwxt/jscx.py。
///
/// 查询型表单统一经鉴权执行器发送，先进入应用首页，失效时重登并重放一次。
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

  static final _spec = JwxtAppSpec(
    appId: 'kxjas',
    indexUrl: _indexUrl.toString(),
    refererUrl: _indexUrl.toString(),
  );

  /// 测试时替换统一鉴权执行器。
  @visibleForTesting
  static SessionExecutor? debugExecutor;

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
  /// 日期不在任何学期范围内（寒暑假）时抛 [DiagnosticException] 说明原因。
  static Future<TermCalendar> calendar(DateTime date) async {
    final key = dateKeyOf(date);
    final termRows = await _rows('gjrqcxdyxnxq', {'KSRQ': key, 'JSRQ': key});
    final termCode = termRows.isEmpty
        ? ''
        : (termRows.first['XQ'] ?? '').toString();
    if (termCode.isEmpty) {
      throw const DiagnosticException(
        '该日期不在校历范围内，可能处于假期',
        code: 'calendar_date_outside_term',
        stage: 'calendar.resolve',
        context: {'endpoint': 'free_classroom.term', 'service': 'jwxt'},
      );
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
      throw const DiagnosticException(
        '教务未返回该日期的周次信息',
        code: 'calendar_week_missing',
        stage: 'calendar.resolve',
        context: {'endpoint': 'free_classroom.week', 'service': 'jwxt'},
      );
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
    if (rows is! List) {
      throw DiagnosticException(
        '教务响应缺少列表数据',
        code: 'response_rows_missing',
        stage: 'response.validate',
        context: {'endpoint': 'free_classroom.$name', 'service': 'jwxt'},
      );
    }
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
    final body = await _send(name, fields);
    final code = '${body['code']}';
    if (code != '0') {
      portalLog(
        'response.rejected',
        fields: {'service': 'jwxt', 'response_code': code},
      );
      throw DiagnosticException(
        prefixedServerMessage(
          '教务接口返回错误：',
          body['msg'],
          fallback: '教务接口返回错误，请稍后重试',
        ),
        code: 'service_rejected',
        stage: 'response.validate',
        context: {
          'endpoint': 'free_classroom.$name',
          'service': 'jwxt',
          'response_code': code,
        },
      );
    }
    final datas = body['datas'];
    final section = datas is Map<String, dynamic> ? datas[name] : null;
    if (section is Map<String, dynamic>) return section;
    throw DiagnosticException(
      '教务响应缺少目标数据段',
      code: 'response_section_missing',
      stage: 'response.validate',
      context: {'endpoint': 'free_classroom.$name', 'service': 'jwxt'},
    );
  }

  static Map<String, dynamic> _firstRowOrSelf(Map<String, dynamic> datas) {
    final rows = datas['rows'];
    if (rows is List && rows.isNotEmpty && rows.first is Map<String, dynamic>) {
      return rows.first as Map<String, dynamic>;
    }
    return datas;
  }

  static Future<Map<String, dynamic>> _send(
    String name,
    Map<String, String> fields,
  ) async {
    final body = fields.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final response = await (debugExecutor ?? PortalSession.instance.executor)
        .execute(
          _spec,
          () => RequestOptions(
            path: _module(name).toString(),
            method: 'POST',
            data: body,
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
    requireServiceSuccess(
      response,
      endpoint: 'free_classroom.$name',
      service: 'jwxt',
    );
    final raw = response.data;

    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (error, stackTrace) {
      throw DiagnosticException(
        '教务响应不是有效 JSON',
        code: 'response_invalid_json',
        stage: 'response.decode',
        cause: error,
        causeStackTrace: stackTrace,
        context: {'endpoint': 'free_classroom.$name', 'service': 'jwxt'},
      );
    }
    throw DiagnosticException(
      '教务响应不是对象',
      code: 'response_schema_mismatch',
      stage: 'response.validate',
      context: {'endpoint': 'free_classroom.$name', 'service': 'jwxt'},
    );
  }
}
