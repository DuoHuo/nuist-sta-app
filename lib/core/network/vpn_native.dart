import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

typedef _NativeCallback = Void Function(Pointer<Uint8>, UintPtr, Uint64);

/// Rust 控制接口。原生后台线程执行阻塞控制操作，连接数据不跨 FFI。
class VpnNative {
  const VpnNative();

  static final _events = StreamController<Map<String, dynamic>>.broadcast();
  static final _pending = <int, Completer<Map<String, dynamic>>>{};
  static int _requestId = 0;
  static final _bindings = _VpnBindings();
  static final _callback = NativeCallable<_NativeCallback>.listener(_received)
    ..keepIsolateAlive = false;

  /// 原生状态推送。订阅不会加载动态库，首次控制调用才初始化。
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// 测试用：模拟原生主动推送的事件，验证所有订阅者共享事件流。
  @visibleForTesting
  static void debugPublishEventForTesting(Map<String, dynamic> event) {
    _events.add(event);
  }

  static void _received(Pointer<Uint8> pointer, int length, int requestId) {
    final pending = requestId == 0 ? null : _pending.remove(requestId);
    try {
      if (pointer == nullptr || length == 0 || length > 1024 * 1024) {
        throw const SocketException('VPN 原生接口未返回有效结果');
      }
      final response = jsonDecode(
        utf8.decode(pointer.asTypedList(length)),
      ) as Map<String, dynamic>;
      if (requestId == 0) {
        _events.add(response);
      } else {
        pending?.complete(response);
      }
    } catch (error, stackTrace) {
      pending?.completeError(error, stackTrace);
      if (requestId == 0) {
        vpnLog('native.event_invalid', error: error, stackTrace: stackTrace);
      }
    } finally {
      if (pointer != nullptr) _bindings.freeResult(pointer);
    }
  }

  /// 执行一条控制命令；动态库和函数指针只在本进程首次调用时加载。
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    final method = request['method'] as String;
    final timeout = method == 'start'
        ? const Duration(seconds: 30)
        : method == 'probe'
        ? const Duration(seconds: 5)
        : const Duration(seconds: 3);
    final stage = 'native.$method';
    return vpnStage(
      stage,
      () async {
        _bindings.register(_callback.nativeFunction);
        final id = ++_requestId;
        final pending = Completer<Map<String, dynamic>>();
        _pending[id] = pending;
        final bytes = utf8.encode(jsonEncode(request));
        Pointer<Uint8>? input;
        try {
          input = _bindings.allocate(bytes.length);
          if (input == nullptr) {
            throw const SocketException('VPN 控制消息过大');
          }
          input.asTypedList(bytes.length).setAll(0, bytes);
          _bindings.callAsync(
            input,
            bytes.length,
            id,
            _callback.nativeFunction,
          );
        } catch (_) {
          _pending.remove(id);
          rethrow;
        } finally {
          bytes.fillRange(0, bytes.length, 0);
          if (input != null && input != nullptr) {
            _bindings.free(input, bytes.length);
          }
        }
        var expired = false;
        final work = pending.future.then((response) {
          if (response['ok'] != true) {
            throw VpnNativeException.fromResponse(response, method: method);
          }
          return response['data'] as Map<String, dynamic>;
        });
        unawaited(
          work.then(
            (result) async {
              if (!expired) return;
              final cleanup = method == 'start' && result['engineId'] is int
                  ? {'method': 'stop', 'id': result['engineId']}
                  : method == 'prepareStart' && result['startId'] is int
                  ? {'method': 'cancelStart', 'startId': result['startId']}
                  : null;
              if (cleanup != null) {
                try {
                  await call(cleanup);
                } catch (error, stackTrace) {
                  vpnLog(
                    'native.late_cleanup_failed',
                    error: error,
                    stackTrace: stackTrace,
                  );
                }
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (expired) {
                vpnLog(
                  'native.late_failure',
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
}

/// 一次加载所有 C 符号；静态监听在进程结束前不关闭，防止原生线程调用失效指针。
class _VpnBindings {
  _VpnBindings() {
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
    try {
      library = DynamicLibrary.open(name);
      allocate = library
          .lookupFunction<
            Pointer<Uint8> Function(UintPtr),
            Pointer<Uint8> Function(int)
          >('nuist_vpn_alloc');
      free = library
          .lookupFunction<
            Void Function(Pointer<Uint8>, UintPtr),
            void Function(Pointer<Uint8>, int)
          >('nuist_vpn_free');
      freeResult = library
          .lookupFunction<
            Void Function(Pointer<Uint8>),
            void Function(Pointer<Uint8>)
          >('nuist_vpn_result_free');
      callAsync = library
          .lookupFunction<
            Void Function(
              Pointer<Uint8>,
              UintPtr,
              Uint64,
              Pointer<NativeFunction<_NativeCallback>>,
            ),
            void Function(
              Pointer<Uint8>,
              int,
              int,
              Pointer<NativeFunction<_NativeCallback>>,
            )
          >('nuist_vpn_call_async');
      _setEventCallback = library
          .lookupFunction<
            Void Function(Pointer<NativeFunction<_NativeCallback>>),
            void Function(Pointer<NativeFunction<_NativeCallback>>)
          >('nuist_vpn_set_event_callback');
    } catch (error, stackTrace) {
      throw VpnNativeException(
        '未找到校园 VPN 原生接口，请使用包含 Rust 核心的构建',
        code: 'native_library_load_failed',
        stage: 'native.load',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }
  late final DynamicLibrary library;
  late final Pointer<Uint8> Function(int) allocate;
  late final void Function(Pointer<Uint8>, int) free;
  late final void Function(Pointer<Uint8>) freeResult;
  late final void Function(
    Pointer<Uint8>,
    int,
    int,
    Pointer<NativeFunction<_NativeCallback>>,
  )
  callAsync;
  late final void Function(Pointer<NativeFunction<_NativeCallback>>)
  _setEventCallback;
  bool _registered = false;
  void register(Pointer<NativeFunction<_NativeCallback>> callback) {
    if (_registered) return;
    _setEventCallback(callback);
    _registered = true;
  }
}
