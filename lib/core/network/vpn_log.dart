import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../logging/app_log.dart';

final _log = AppLog.logger('core.network.vpn');

/// VPN 的结构化事件出口，仅接受由日志层校验的字段。
void vpnLog(
  String event, {
  Map<String, Object?>? fields,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (error == null) {
    _log.debug(event, fields: fields);
  } else {
    _log.warning(event, fields: fields, error: error, stackTrace: stackTrace);
  }
}

int _stageSequence = 0;

/// 快速成功的内部步骤保持安静，慢步骤、等待进度与失败始终记录。
Future<T> vpnStage<T>(
  String name,
  Future<T> Function() action, {
  Duration timeout = const Duration(seconds: 60),
  Map<String, Object?>? fields,
}) => _log.startSpan().run(() async {
  final sequence = ++_stageSequence;
  final watch = Stopwatch()..start();
  var waiting = false;
  final progress = Timer.periodic(const Duration(seconds: 5), (_) {
    waiting = true;
    _log.info(
      'stage.waiting',
      fields: {
        ...?fields,
        'stage_id': sequence,
        'stage': name,
        'duration_ms': watch.elapsedMilliseconds,
        'timeout_ms': timeout.inMilliseconds,
      },
    );
  });
  try {
    final work = Future.sync(action);
    final result = await work.timeout(timeout);
    if (waiting || watch.elapsed >= const Duration(seconds: 1)) {
      _log.info(
        'stage.completed',
        fields: {
          ...?fields,
          'stage_id': sequence,
          'stage': name,
          'duration_ms': watch.elapsedMilliseconds,
        },
      );
    }
    return result;
  } catch (error, stackTrace) {
    _log.warning(
      'stage.failed',
      fields: {
        ...?fields,
        ..._nativeErrorFields(error),
        'stage_id': sequence,
        'stage': name,
        'duration_ms': watch.elapsedMilliseconds,
      },
      error: error,
      stackTrace: stackTrace,
      errorKind: vpnErrorKind(error),
    );
    rethrow;
  } finally {
    progress.cancel();
  }
});

/// 单次 HTTP 请求的日志，贯穿 Cookie 准备、选路与响应，避免重复输出。
class VpnRequestLog {
  VpnRequestLog._(RequestOptions options)
    : requestId = ++_sequence,
      method = options.method,
      host = options.uri.host,
      port = options.uri.port;

  static int _sequence = 0;
  static final _requests = Expando<VpnRequestLog>();

  /// 请求身份只保存在本地，不放入请求头、URL 或 Dio extra。
  static VpnRequestLog? of(RequestOptions options) => _requests[options];

  /// 相同请求共用编号；重试同一 RequestOptions 时分配新的编号。
  static VpnRequestLog? start(
    RequestOptions options, {
    bool managedByInterceptor = false,
  }) {
    var log = of(options);
    if (log == null || log._finished) {
      log = VpnRequestLog._(options);
      _requests[options] = log;
      final request = log;
      request.run(
        () => _log.debug('http.started', fields: request._baseFields),
      );
    }
    log.managedByInterceptor |= managedByInterceptor;
    return log;
  }

  final int requestId;
  final String method;
  final String host;
  final int port;
  final AppLogSpan _span = _log.startSpan();

  /// 请求准备、选路与响应回调使用同一个请求 Span。
  T run<T>(T Function() body) => _span.run(body);
  final watch = Stopwatch()..start();
  bool managedByInterceptor = false;
  String route = '请求准备';
  int? preparationMs;
  bool _finished = false;

  /// 内部阶段沿用请求编号和服务类别；主机由统一日志层匿名化。
  Map<String, Object?> get requestFields => _baseFields;

  Map<String, Object?> get _baseFields => {
    'request_id': requestId,
    'method': method,
    'service': AppLog.serviceForHost(host),
    'host': host,
    'port': port,
  };

  /// 只记录状态码与重定向主机，不记录路径、参数或响应内容。
  void complete(int? status, Uri uri, String? location) {
    if (_finished) return;
    _finished = true;
    watch.stop();
    final target = location == null ? null : Uri.tryParse(location);
    final redirect = target == null ? null : uri.resolveUri(target);
    run(
      () => _log.debug(
        'http.completed',
        fields: {
          ..._baseFields,
          'status_code': ?status,
          if (redirect != null) 'redirect_host': redirect.host,
          if (redirect != null)
            'redirect_service': AppLog.serviceForHost(redirect.host),
          if (redirect != null) 'redirect_port': redirect.port,
          'route': route,
          'preparation_ms': ?preparationMs,
          'duration_ms': watch.elapsedMilliseconds,
        },
      ),
    );
  }

  /// 失败也沿用请求编号；不展开 Dio 的多行异常说明或业务数据。
  void fail(Object error, {int? status}) {
    if (_finished) return;
    _finished = true;
    watch.stop();
    run(
      () => _log.warning(
        'http.failed',
        fields: {
          ..._baseFields,
          'status_code': ?status,
          'route': route,
          'preparation_ms': ?preparationMs,
          'duration_ms': watch.elapsedMilliseconds,
        },
        error: error,
        errorKind: vpnErrorKind(error),
      ),
    );
  }
}

final _connectionLogKey = Object();

/// 单次目标 TCP/TLS 连接的日志上下文；HTTP 连接池可被多个请求复用。
class VpnConnectionLog {
  VpnConnectionLog(Uri uri)
    : connectionId = ++_sequence,
      host = uri.host,
      port = uri.port;

  static int _sequence = 0;

  /// 连接工厂与网关共用编号，异步握手也保留该编号。
  static VpnConnectionLog? get current =>
      Zone.current[_connectionLogKey] as VpnConnectionLog?;

  final int connectionId;
  final String host;
  final int port;
  final AppLogSpan _span = _log.startSpan();
  final watch = Stopwatch()..start();

  /// 只在本地传递连接身份，不改变连接工厂或服务器协议。
  Future<T> run<T>(Future<T> Function() action) =>
      _span.run(() => runZoned(action, zoneValues: {_connectionLogKey: this}));

  /// 记录不含目标路径或凭据的连接事件。
  void write(String event, {Map<String, Object?>? fields, Object? error}) =>
      _span.run(
        () => vpnLog(
          event,
          error: error,
          fields: {
            ...?fields,
            'connection_id': connectionId,
            'host': host,
            'service': AppLog.serviceForHost(host),
            'port': port,
            'duration_ms': watch.elapsedMilliseconds,
          },
        ),
      );
}

/// 只记录错误类别，不展开可能包含 URL、响应体或凭据的异常消息。
String vpnErrorKind(Object error) => AppLog.errorKindFor(error);

/// 原生阶段只接受固定枚举，原始响应文本不会写入日志。
String vpnNativeStage(Object? stage) => switch (stage) {
  '配置' => 'config',
  'DNS' => 'dns',
  'TCP' => 'tcp',
  'TLS' => 'tls',
  '协议鉴权' => 'protocol_auth',
  '完成' => 'done',
  '等待调用' => 'waiting',
  '回环鉴权' => 'loopback_auth',
  _ => 'unknown',
};

/// 将原生阶段耗时拆成固定字段，避免记录完整原生结果。
Map<String, Object?> vpnNativeTimings(Object? timings) {
  final fields = <String, Object?>{};
  if (timings is! Iterable) return fields;
  for (final item in timings.take(20)) {
    if (item is! List || item.length != 2) continue;
    final stage = vpnNativeStage(item.first);
    if (stage != 'unknown' && stage != 'done') {
      fields['${stage}_ms'] = item.last;
    }
  }
  return fields;
}

Map<String, Object?> _nativeErrorFields(Object error) {
  if (error is! SocketException) return {};
  // 只匹配预定义阶段，禁止将异常正文传给日志出口。
  final stage = RegExp(r'阶段="?(配置|DNS|TCP|TLS|协议鉴权)"?')
      .firstMatch(error.message)
      ?.group(1);
  for (final phase in [?stage, 'DNS', 'TCP', '回环鉴权']) {
    if (phase == stage ||
        error.message.contains('VPN 目标 $phase') ||
        error.message.contains('VPN $phase超时')) {
      return {'native_stage': vpnNativeStage(phase)};
    }
  }
  return {};
}
