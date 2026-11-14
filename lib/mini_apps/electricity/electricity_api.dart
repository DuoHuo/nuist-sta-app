import 'dart:convert';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_session.dart';
import '../../core/config/campus_config.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import 'electricity_models.dart';
import '../../core/auth/safe_message.dart';

/// 一卡通电费接口（对应 notifier/icard/elec_query.py）。
///
/// 鉴权靠请求头 `synjones-auth: bearer <jwt>`，token 从 CAS 登录 icard 后的落地
/// URL 里取。[PortalSession.request] 靠「被弹回登录页」识别会话过期，对这个
/// 返回 JSON 的接口不适用，所以这里自己判断 token 失效并强制重登一次。
class ElectricityApi {
  ElectricityApi._();
  static final _log = AppLog.logger('electricity.api');

  static final Uri _api = Uri.parse(
    'https://${CampusHosts.icard}/charge/feeitem/getThirdData',
  );
  static const _feeItemId = '448';

  static Future<List<ElecOption>> listCampuses() => _log.operation(
    'campuses.query',
    () async {
      final data = await _post({
        'type': 'select',
        'level': '0',
      }, endpoint: 'icard.campuses');
      return _options(data);
    },
    resultFields: (items) => {'count': items.length},
    successLevel: AppLogLevel.debug,
  );

  static Future<List<ElecOption>> listBuildings(ElecOption campus) =>
      _log.operation(
        'buildings.query',
        () async {
          final data = await _post({
            'type': 'select',
            'level': '1',
            'xiaoqu_id': campus.value,
          }, endpoint: 'icard.buildings');
          return _options(data);
        },
        resultFields: (items) => {'count': items.length},
        successLevel: AppLogLevel.debug,
      );

  static Future<List<ElecOption>> listRooms(
    ElecOption campus,
    ElecOption building,
  ) => _log.operation(
    'rooms.query',
    () async {
      final data = await _post({
        'type': 'select',
        'level': '2',
        'xiaoqu_id': campus.value,
        'loudong_id': building.value,
      }, endpoint: 'icard.rooms');
      return _options(data);
    },
    resultFields: (items) => {'count': items.length},
    successLevel: AppLogLevel.debug,
  );

  /// 查询剩余电量（度）。
  static Future<double> queryBalance(ElecRoom room, {PortalSession? session}) =>
      _log.operation(
        'balance.query',
        () async {
          final data = await _post(
            {
              'type': 'IEC',
              'level': '3',
              'xiaoqu_id': room.campus.value,
              'loudong_id': room.building.value,
              'room_id': room.room.value,
            },
            endpoint: 'icard.balance',
            session: session,
          );
          final map = data['map'];
          final kwh = _extractSurplus(map);
          if (kwh == null) {
            throw DiagnosticException(
              '电费接口未返回可识别的剩余电量，请稍后重试',
              code: 'balance_field_unavailable',
              stage: 'icard.balance',
              context: {
                'service': 'icard',
                'endpoint': 'icard.balance',
                'field_count': map is Map ? map.length : 0,
                'details': {
                  'map_present': map != null,
                  'map_type': map.runtimeType.toString(),
                  'data_type': map is Map
                      ? map['data'].runtimeType.toString()
                      : null,
                  'show_data_type': map is Map
                      ? map['showData'].runtimeType.toString()
                      : null,
                  'surplus_present':
                      map is Map && map.containsKey('surplusCharge'),
                },
              },
            );
          }
          return kwh;
        },
        fields: const {'service': 'icard', 'endpoint': 'icard.balance'},
        successLevel: AppLogLevel.debug,
      );

  // ==================== 内部实现 ====================

  static List<ElecOption> _options(Map<String, dynamic> data) {
    final list = (data['map'] as Map<String, dynamic>?)?['data'];
    if (list is! List) {
      _log.warning(
        'options.unavailable',
        fields: {
          'service': 'icard',
          'reason_code': 'options_list_missing',
          'details': {'response_type': list.runtimeType.toString()},
        },
      );
      return const [];
    }
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) ElecOption.fromJson(item),
    ];
  }

  static Future<Map<String, dynamic>> _post(
    Map<String, String> fields, {
    required String endpoint,
    PortalSession? session,
  }) async {
    var result = await _send(
      fields,
      force: false,
      endpoint: endpoint,
      session: session,
    );
    if (_looksUnauthorized(result)) {
      _log.info(
        'session.reauth_required',
        fields: {
          'service': 'icard',
          'endpoint': endpoint,
          'attempt': 1,
          'reason_code': 'icard_authorization_rejected',
          'response_code': result['code'],
        },
      );
      result = await _send(
        fields,
        force: true,
        endpoint: endpoint,
        session: session,
      );
    }
    if (result['code'] != 200) {
      throw DiagnosticException(
        prefixedServerMessage(
          '电费接口返回错误：',
          result['msg'],
          fallback: '电费接口返回错误，请稍后重试',
        ),
        code: _looksUnauthorized(result)
            ? 'icard_reauthentication_exhausted'
            : 'icard_response_rejected',
        stage: 'icard.response',
        context: {
          'service': 'icard',
          'endpoint': endpoint,
          'response_code': result['code'],
        },
      );
    }
    return result;
  }

  static Future<Map<String, dynamic>> _send(
    Map<String, String> fields, {
    required bool force,
    required String endpoint,
    PortalSession? session,
  }) async {
    final portal = session ?? PortalSession.instance;
    final login = await portal.ensureLoggedInWithEvidence(
      PortalServices.icard,
      force: force,
    );
    final token = _tokenFromLanding(login);
    final http = await portal.clientFor(PortalServices.icard);
    final body = {
      'feeitemid': _feeItemId,
      ...fields,
    }.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final response = await http.post(
      _api,
      data: body,
      contentType: 'application/x-www-form-urlencoded',
      headers: {'synjones-auth': token},
    );
    final raw = response.data;
    if (response.statusCode == 401 || response.statusCode == 403) {
      return {'code': 401, 'msg': 'unauthorized'};
    }
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DiagnosticException(
          '电费接口返回了无法解析的内容',
          code: 'icard_json_invalid',
          stage: 'icard.decode',
          cause: error,
          causeStackTrace: stackTrace,
          context: {
            'service': 'icard',
            'endpoint': endpoint,
            'status_code': response.statusCode,
          },
        ),
        stackTrace,
      );
    }
    throw DiagnosticException(
      '电费接口返回了无法识别的内容',
      code: 'icard_response_not_object',
      stage: 'icard.decode',
      context: {
        'service': 'icard',
        'endpoint': endpoint,
        'status_code': response.statusCode,
        'response_type': raw.runtimeType.toString(),
      },
    );
  }

  static String _tokenFromLanding(PortalLoginResult login) {
    final landing = login.landing;
    final details = <String, Object?>{
      ...login.diagnosticContext,
      'authorization_parameter': 'synjones-auth',
      'inspection_stage': 'before_balance_request',
    };
    AppLog.addEvidence('icard.authorization', {
      for (final entry in details.entries)
        if (entry.key != 'landing_response') entry.key: entry.value,
    });
    final token = Uri.tryParse(landing)?.queryParameters['synjones-auth'];
    if (token == null || token.isEmpty) {
      throw PortalLoginError(
        '一卡通登录未返回授权信息，请稍后重试',
        code: 'icard_authorization_missing',
        stage: 'icard.authorization',
        context: {
          'service': 'icard',
          'endpoint': 'icard.landing',
          'details': {...details, 'balance_request_sent': false},
        },
      );
    }
    return 'bearer $token';
  }

  static bool _looksUnauthorized(Map<String, dynamic> result) {
    if (result['code'] == 200) return false;
    final code = result['code'];
    if (code == 401 || code == 403) return true;
    final msg = (result['msg'] ?? '').toString().toLowerCase();
    return msg.contains('token') ||
        msg.contains('登录') ||
        msg.contains('unauthorized') ||
        msg.contains('认证');
  }

  /// 实测响应：
  /// `{"map":{"showData":{"剩余电量":"-0.75"},"data":{"dianliang":"-0.75",...},
  ///   "surplusCharge":"-0.75"}}`，三处同一个值，按顺序取第一个能解析的。
  /// 欠费时为负数，照实返回。
  static double? _extractSurplus(Object? map) {
    if (map is! Map) return null;
    final data = map['data'];
    final showData = map['showData'];
    final candidates = [
      if (data is Map) data['dianliang'],
      map['surplusCharge'],
      if (showData is Map) showData['剩余电量'],
    ];
    for (final c in candidates) {
      final n = _toDouble(c);
      if (n != null) return n;
    }
    return null;
  }

  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }
}
