import 'dart:convert';

import '../../core/auth/portal_exceptions.dart';
import '../../core/auth/portal_http.dart';
import '../../core/auth/portal_session.dart';
import 'electricity_models.dart';

/// 一卡通电费接口（对应 notifier/icard/elec_query.py）。
///
/// 鉴权靠请求头 `synjones-auth: bearer <jwt>`，token 从 CAS 登录 icard 后的落地
/// URL 里取。[PortalSession.request] 靠「被弹回登录页」识别会话过期，对这个
/// 返回 JSON 的接口不适用，所以这里自己判断 token 失效并强制重登一次。
class ElectricityApi {
  ElectricityApi._();

  static final Uri _api = Uri.parse(
    'https://icard.nuist.edu.cn/charge/feeitem/getThirdData',
  );
  static const _feeItemId = '448';

  static Future<List<ElecOption>> listCampuses() async {
    final data = await _post({'type': 'select', 'level': '0'});
    return _options(data);
  }

  static Future<List<ElecOption>> listBuildings(ElecOption campus) async {
    final data = await _post({
      'type': 'select',
      'level': '1',
      'xiaoqu_id': campus.value,
    });
    return _options(data);
  }

  static Future<List<ElecOption>> listRooms(
    ElecOption campus,
    ElecOption building,
  ) async {
    final data = await _post({
      'type': 'select',
      'level': '2',
      'xiaoqu_id': campus.value,
      'loudong_id': building.value,
    });
    return _options(data);
  }

  /// 查询剩余电量（度）。
  static Future<double> queryBalance(ElecRoom room) async {
    final data = await _post({
      'type': 'IEC',
      'level': '3',
      'xiaoqu_id': room.campus.value,
      'loudong_id': room.building.value,
      'room_id': room.room.value,
    });
    final map = data['map'];
    final kwh = _extractSurplus(map);
    if (kwh == null) {
      throw PortalLoginError('电费接口未返回剩余电量：${jsonEncode(map)}');
    }
    return kwh;
  }

  // ==================== 内部实现 ====================

  static List<ElecOption> _options(Map<String, dynamic> data) {
    final list = (data['map'] as Map<String, dynamic>?)?['data'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) ElecOption.fromJson(item),
    ];
  }

  static Future<Map<String, dynamic>> _post(Map<String, String> fields) async {
    var result = await _send(fields, force: false);
    if (_looksUnauthorized(result)) {
      portalLog('icard token 失效，重新登录');
      result = await _send(fields, force: true);
    }
    if (result['code'] != 200) {
      throw PortalLoginError('电费接口返回错误：${result['msg'] ?? '未知错误'}');
    }
    return result;
  }

  static Future<Map<String, dynamic>> _send(
    Map<String, String> fields, {
    required bool force,
  }) async {
    final landing = await PortalSession.instance.ensureLoggedIn(
      PortalServices.icard,
      force: force,
    );
    final token = _tokenFromLanding(landing);
    final http = await PortalSession.instance.clientFor(PortalServices.icard);
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
    } on FormatException {
      // 落到下面统一报错。
    }
    throw const PortalLoginError('电费接口返回了无法识别的内容');
  }

  static String _tokenFromLanding(String landing) {
    final token = Uri.tryParse(landing)?.queryParameters['synjones-auth'];
    if (token == null || token.isEmpty) {
      throw PortalLoginError('未能从一卡通落地页取得 synjones-auth：$landing');
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
