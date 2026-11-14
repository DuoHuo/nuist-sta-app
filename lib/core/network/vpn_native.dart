import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import '../logging/diagnostic_error.dart';
import 'vpn_log.dart';

/// 保留原生错误类别和发生阶段，同时兼容现有网络错误处理。
class VpnNativeException extends SocketException implements DiagnosticError {
  VpnNativeException(
    super.message, {
    required this.code,
    required this.stage,
    this.cause,
    this.causeStackTrace,
    this.context = const {},
    super.osError,
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
    'reason_code': code,
    'stage':
        context['native_stage'] is String &&
            context['native_stage'] != 'unknown'
        ? 'native.${context['native_stage']}'
        : stage,
    'error_kind':
        const {
          'native_platform_unsupported',
          'native_library_load_failed',
        }.contains(code)
        ? 'platform_unavailable'
        : context['native_stage'] == 'tls'
        ? 'tls_handshake'
        : context['native_kind'] == 'TimedOut' || code == 'native_call_timeout'
        ? 'timeout'
        : 'connection_error',
  };

  /// 读取新的结构化失败；旧版原生库仍可返回字符串，但明确标识信息缺失。
  factory VpnNativeException.fromResponse(
    Map<String, dynamic> response, {
    required String method,
  }) {
    final details = response['diagnostic'];
    final diagnostic = details is Map ? details : const {};
    Object? cause;
    if (diagnostic['causes'] case final List causes) {
      for (final message in causes.reversed.whereType<String>()) {
        cause = DiagnosticException(
          message,
          code: 'native_cause',
          stage: diagnostic['stage'] as String? ?? 'native.$method',
          cause: cause,
        );
      }
    }
    final osCode = diagnostic['os_code'];
    return VpnNativeException(
      response['error'] as String? ?? 'VPN 操作失败',
      code: diagnostic['code'] as String? ?? 'native_legacy_error',
      stage: diagnostic['stage'] as String? ?? 'native.$method',
      cause: cause,
      osError: osCode is int ? OSError('', osCode) : null,
      context: {
        'method': method,
        'native_kind': diagnostic['native_kind'],
        'native_stage': vpnNativeStage(diagnostic['stage']),
        'native_diagnostics_available': details is Map,
        'details': {'native_diagnostic': diagnostic},
      },
    );
  }
}

/// Rust 控制接口。阻塞的握手、DNS 和建连在后台 isolate 中执行。
class VpnNative {
  const VpnNative();

  /// 执行一条控制命令，业务流量不经过此接口。
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    final method = request['method'];
    final timeout = switch (method) {
      'start' => const Duration(seconds: 30),
      'open' => const Duration(seconds: 24),
      _ => const Duration(seconds: 3),
    };
    final stage = 'native.$method';
    // 只输出操作名，绝不展开 request/result。
    return vpnStage(
      stage,
      () async {
        var expired = false;
        final work = Isolate.run(() => _call(request));
        unawaited(
          work.then(
            (result) async {
              // 即使 isolate 调度迟到，过期的启动结果也不能留下孤立隧道。
              if (expired && method == 'start' && result['id'] is int) {
                try {
                  await call({'method': 'stop', 'id': result['id']});
                } catch (_) {}
              }
              if (expired &&
                  method == 'prepareStart' &&
                  result['startId'] is int) {
                try {
                  await call({
                    'method': 'cancelStart',
                    'startId': result['startId'],
                  });
                } catch (_) {}
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (expired) {
                vpnLog(
                  'native.late_failure',
                  fields: {'stage': stage},
                  error: error,
                  stackTrace: stackTrace,
                );
              }
            },
          ),
        );
        return work.timeout(
          timeout,
          onTimeout: () {
            expired = true;
            throw VpnNativeException(
              'VPN 原生 $method 调用超时，请重试',
              code: 'native_call_timeout',
              stage: stage,
              context: {'timeout_ms': timeout.inMilliseconds},
            );
          },
        );
      },
      timeout: timeout,
      fields: {
        'method': method,
        'native_start_id': request['startId'],
        'vpn_session_id': request['id'],
        'native_timeout_ms': timeout.inMilliseconds,
        if (VpnConnectionLog.current case final connection?)
          'connection_id': connection.connectionId,
      },
    );
  }

  static Map<String, dynamic> _call(Map<String, dynamic> request) {
    const configured = String.fromEnvironment('VPN_NATIVE_LIBRARY');
    final name = configured.isNotEmpty
        ? configured
        : switch (Platform.operatingSystem) {
            'android' || 'linux' => 'libnuist_vpn.so',
            'windows' => 'nuist_vpn.dll',
            'macos' => 'libnuist_vpn.dylib',
            _ => throw VpnNativeException(
              '当前平台尚未接入校园 VPN 原生库',
              code: 'native_platform_unsupported',
              stage: 'native.load',
            ),
          };
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(name);
    } catch (error, stackTrace) {
      throw VpnNativeException(
        '未找到校园 VPN 原生库，请使用包含 Rust 核心的构建',
        code: 'native_library_load_failed',
        stage: 'native.load',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    final allocate = library
        .lookupFunction<
          Pointer<Uint8> Function(UintPtr),
          Pointer<Uint8> Function(int)
        >('nuist_vpn_alloc');
    final free = library
        .lookupFunction<
          Void Function(Pointer<Uint8>, UintPtr),
          void Function(Pointer<Uint8>, int)
        >('nuist_vpn_free');
    final call = library
        .lookupFunction<
          Pointer<Uint8> Function(Pointer<Uint8>, UintPtr),
          Pointer<Uint8> Function(Pointer<Uint8>, int)
        >('nuist_vpn_call');
    final freeResult = library
        .lookupFunction<
          Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)
        >('nuist_vpn_result_free');
    final bytes = utf8.encode(jsonEncode(request));
    final input = allocate(bytes.length);
    if (input == nullptr) throw const SocketException('VPN 控制消息过大');
    Pointer<Uint8> result = nullptr;
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      result = call(input, bytes.length);
      if (result == nullptr) throw const SocketException('VPN 原生接口未返回结果');
      var length = 0;
      while (length < 1024 * 1024 && (result + length).value != 0) {
        length++;
      }
      if (length == 1024 * 1024) throw const SocketException('VPN 响应长度异常');
      final response = jsonDecode(
        utf8.decode(result.asTypedList(length)),
      ) as Map<String, dynamic>;
      if (response['ok'] != true) {
        // 错误回到主 isolate 的阶段日志中归类，避免丢失业务 Trace。
        throw VpnNativeException.fromResponse(
          response,
          method: request['method'] as String,
        );
      }
      return response['data'] as Map<String, dynamic>;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      free(input, bytes.length);
      if (result != nullptr) freeResult(result);
    }
  }
}
