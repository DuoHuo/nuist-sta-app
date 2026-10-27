import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/portal_exceptions.dart';

/// VPN 独立日志出口，不依赖门户初始化；仅接收不含凭据的状态描述。
void vpnLog(String message) {
  if (kDebugMode) debugPrint('[vpn] $message');
}

int _stageSequence = 0;

/// 快速成功的内部步骤保持安静，慢步骤、等待进度与失败始终记录。
Future<T> vpnStage<T>(
  String name,
  Future<T> Function() action, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final sequence = ++_stageSequence;
  final watch = Stopwatch()..start();
  var waiting = false;
  final progress = kDebugMode
      ? Timer.periodic(const Duration(seconds: 5), (_) {
          waiting = true;
          vpnLog(
            '阶段 P$sequence $name 仍在等待，'
            '耗时=${watch.elapsedMilliseconds}ms，期限=${timeout.inMilliseconds}ms',
          );
        })
      : null;
  try {
    final work = Future.sync(action);
    final result = await work.timeout(timeout);
    if (waiting || watch.elapsed >= const Duration(seconds: 1)) {
      vpnLog('阶段 P$sequence $name 完成，耗时=${watch.elapsedMilliseconds}ms');
    }
    return result;
  } catch (error) {
    vpnLog(
      '阶段 P$sequence $name 失败，耗时=${watch.elapsedMilliseconds}ms，'
      '类别=${vpnErrorKind(error)}',
    );
    rethrow;
  } finally {
    progress?.cancel();
  }
}

/// 单次 HTTP 请求的日志，贯穿 Cookie 准备、选路与响应，避免重复输出。
class VpnRequestLog {
  VpnRequestLog._(RequestOptions options)
    : label =
          '请求 R${++_sequence} ${options.method} '
          '${options.uri.host}:${options.uri.port}';

  static int _sequence = 0;
  static final _requests = Expando<VpnRequestLog>();

  /// 请求身份只保存在本地，不放入请求头或 Dio extra。
  static VpnRequestLog? of(RequestOptions options) => _requests[options];

  /// 相同请求共用编号；重试同一 RequestOptions 时分配新的编号。
  static VpnRequestLog? start(
    RequestOptions options, {
    bool managedByInterceptor = false,
  }) {
    if (!kDebugMode) return null;
    var log = of(options);
    if (log == null || log._finished) {
      log = VpnRequestLog._(options);
      _requests[options] = log;
      vpnLog('${log.label} 开始');
    }
    log.managedByInterceptor |= managedByInterceptor;
    return log;
  }

  final String label;
  final watch = Stopwatch()..start();
  bool managedByInterceptor = false;
  String route = '请求准备';
  int? preparationMs;
  bool _finished = false;

  String get _timing =>
      '${preparationMs == null ? '' : '，准备=${preparationMs}ms'}'
      '，耗时=${watch.elapsedMilliseconds}ms';

  /// 只记录状态码与重定向主机，不记录路径、参数或响应内容。
  void complete(int? status, Uri uri, String? location) {
    if (_finished) return;
    _finished = true;
    watch.stop();
    final target = location == null ? null : Uri.tryParse(location);
    final redirect = target == null ? null : uri.resolveUri(target);
    vpnLog(
      '$label HTTP $status'
      '${redirect == null ? '' : ' → ${redirect.host}:${redirect.port}'}'
      '，出口=$route$_timing',
    );
  }

  /// 失败也沿用请求编号；不展开 Dio 的多行异常说明或业务数据。
  void fail(Object error, {int? status}) {
    if (_finished) return;
    _finished = true;
    watch.stop();
    vpnLog(
      '$label 失败'
      '${status == null ? '' : '，HTTP $status'}'
      '，类别=${vpnErrorKind(error)}，出口=$route$_timing',
    );
  }
}

final _connectionLogKey = Object();

/// 单次目标 TCP/TLS 连接的日志上下文；HTTP 连接池可被多个请求复用。
class VpnConnectionLog {
  VpnConnectionLog(Uri uri)
    : label = '连接 C${++_sequence} ${uri.host}:${uri.port}';

  static int _sequence = 0;

  /// 连接工厂与网关共用编号，异步握手也保留该编号。
  static VpnConnectionLog? get current =>
      Zone.current[_connectionLogKey] as VpnConnectionLog?;

  final String label;
  final watch = Stopwatch()..start();

  /// 只在本地传递连接身份，不改变连接工厂或服务器协议。
  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_connectionLogKey: this});

  /// 记录不含目标路径或凭据的连接事件。
  void write(String message) => vpnLog('$label $message');
}

/// 只记录错误类别，不展开可能包含 URL、响应体或凭据的异常消息。
String vpnErrorKind(Object error) => switch (error) {
  PortalCredentialError() => '门户凭据不可用',
  PortalNetworkError() => '认证网络错误',
  PortalLoginError() => '认证流程失败',
  TimeoutException() => '整体等待超时',
  DioException() =>
    '${error.type.name}'
        '${error.error == null || identical(error.error, error) ? '' : '（${vpnErrorKind(error.error!)}）'}',
  HandshakeException() => 'TLS 握手失败',
  SocketException() => '连接错误（系统码 ${error.osError?.errorCode ?? "无"}）',
  _ => '${error.runtimeType}',
};
