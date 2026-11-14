import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/config/campus_config.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import '../../core/logging/http_diagnostics.dart';
import 'shuttle_models.dart';

/// 公交协议错误保留格式异常语义，并携带可追踪的阶段和底层原因。
class ShuttleProtocolException extends FormatException
    implements DiagnosticError {
  const ShuttleProtocolException(
    super.message, {
    required this.code,
    required this.stage,
    this.cause,
    this.causeStackTrace,
    this.context = const {},
  });

  final String code;
  final String stage;
  @override
  final Object? cause;
  @override
  final StackTrace? causeStackTrace;
  final Map<String, Object?> context;
  @override
  Map<String, Object?> get diagnosticContext => {
    ...context,
    'code': code,
    'stage': stage,
  };
}

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
      _ownsDio = dio == null {
    installHttpDiagnostics(_dio);
  }
  static final _log = AppLog.logger('campus_map.shuttle.api');
  final Dio _dio;
  final bool _ownsDio;
  final _cancel = CancelToken();
  Uri? _login;
  String? _session;

  Future<Object?> _get(Uri uri, {required String stage}) async {
    final response = await _dio.getUri<Object?>(
      uri,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        extra: {'diagnostic_stage': stage},
      ),
      cancelToken: _cancel,
    );
    return response.data;
  }

  Future<Map<String, dynamic>> _json(Uri uri, {required String stage}) async {
    final raw = await _get(uri, stage: stage);
    try {
      final data = raw is String ? jsonDecode(raw) : raw;
      if (data is! Map) throw const FormatException('车辆响应格式错误');
      return Map<String, dynamic>.from(data);
    } catch (error, stackTrace) {
      throw ShuttleProtocolException(
        '车辆响应无法解析',
        code: 'shuttle_response_invalid',
        stage: stage,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  @override
  Future<List<ShuttleVehicle>> load() async {
    if (_login == null) {
      final page = await _get(
        Uri.parse(kCampusShuttlePageUrl),
        stage: 'shuttle.discover_login',
      );
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
        throw const ShuttleProtocolException(
          '车辆登录配置错误',
          code: 'shuttle_login_discovery_failed',
          stage: 'shuttle.discover_login',
        );
      }
      _login = uri;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_session == null) {
        final auth = await _json(_login!, stage: 'shuttle.login');
        final session = auth['jsession'];
        if (session is! String || session.isEmpty) {
          throw const ShuttleProtocolException(
            '车辆会话不可用',
            code: 'shuttle_session_missing',
            stage: 'shuttle.login',
          );
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
        stage: 'shuttle.vehicles',
      );
      if (data['result'] == 0) {
        final rows = data['status'];
        if (rows is! List) {
          throw const ShuttleProtocolException(
            '车辆列表格式错误',
            code: 'shuttle_vehicle_list_invalid',
            stage: 'shuttle.vehicles',
          );
        }
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
      _log.debug(
        'session.invalidated',
        fields: {'attempt': attempt + 1, 'response_code': data['result']},
      );
    }
    throw const ShuttleProtocolException(
      '车辆状态暂时不可用',
      code: 'shuttle_session_retry_exhausted',
      stage: 'shuttle.vehicles',
      context: {'attempt': 2},
    );
  }

  @override
  void close() {
    _cancel.cancel();
    _session = null;
    _login = null;
    if (_ownsDio) _dio.close(force: true);
  }
}
