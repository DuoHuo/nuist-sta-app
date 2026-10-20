import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/config/campus_config.dart';
import 'shuttle_models.dart';

/// 公交网页当前状态源，便于注入合成服务进行验证。
abstract interface class ShuttleSource {
  /// 返回当前完整车辆列表。
  Future<List<ShuttleVehicle>> load();

  /// 终止请求并释放自有连接。
  void close();
}

/// 复用原网页的登录发现和状态接口；会话与登录地址仅在内存中保存。
class ShuttleApi implements ShuttleSource {
  static final _vehicleIdPattern = RegExp(r'^NXD[0-9]{1,2}$');

  // 一次状态请求覆盖全部一位、两位数字编号，包含两位补零形式。
  static final _vehicleQuery = [
    for (var id = 0; id < 100; id++) 'NXD$id',
    for (var id = 0; id < 10; id++) 'NXD0$id',
  ].join(',');

  ShuttleApi({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 12),
            ),
          ),
      _ownsDio = dio == null;
  final Dio _dio;
  final bool _ownsDio;
  final _cancel = CancelToken();
  Uri? _login;
  String? _session;

  Future<Object?> _get(Uri uri) async {
    final response = await _dio.getUri<Object?>(
      uri,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
      ),
      cancelToken: _cancel,
    );
    return response.data;
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final raw = await _get(uri);
    final data = raw is String ? jsonDecode(raw) : raw;
    if (data is! Map) throw const FormatException('车辆响应格式错误');
    return Map<String, dynamic>.from(data);
  }

  @override
  Future<List<ShuttleVehicle>> load() async {
    if (_login == null) {
      final page = await _get(Uri.parse(kCampusShuttlePageUrl));
      final match = RegExp(
        r'''var\s+url\s*=\s*["']([^"']+StandardApiAction_login\.action[^"']*)["']''',
      ).firstMatch('$page');
      final uri = Uri.tryParse(match?.group(1) ?? '');
      // 仅访问已配置的公交服务主机；网页内容不能扩展网络出口。
      if (uri == null ||
          !uri.hasAuthority ||
          uri.scheme != 'http' ||
          uri.host != CampusHosts.shuttleApi ||
          uri.port != 8080 ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('车辆登录配置错误');
      }
      _login = uri;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_session == null) {
        final auth = await _json(_login!);
        final session = auth['jsession'];
        if (session is! String || session.isEmpty) {
          throw const FormatException('车辆会话不可用');
        }
        _session = session;
      }
      final data = await _json(
        _login!
            .resolve('StandardApiAction_getDeviceStatus.action')
            .replace(
              queryParameters: {
                'jsession': _session!,
                'vehiIdno': _vehicleQuery,
                'toMap': '1',
              },
            ),
      );
      if (data['result'] == 0) {
        final rows = data['status'];
        if (rows is! List) throw const FormatException('车辆列表格式错误');
        final byId = <String, ShuttleVehicle>{};
        for (final row in rows.whereType<Map>()) {
          final vehicle = ShuttleVehicle.parse(Map<String, dynamic>.from(row));
          if (vehicle != null && _vehicleIdPattern.hasMatch(vehicle.id)) {
            byId[vehicle.id] = vehicle;
          }
        }
        return byId.values.toList(growable: false);
      }
      _session = null;
    }
    throw const FormatException('车辆状态暂时不可用');
  }

  @override
  void close() {
    _cancel.cancel();
    _session = null;
    _login = null;
    if (_ownsDio) _dio.close(force: true);
  }
}
