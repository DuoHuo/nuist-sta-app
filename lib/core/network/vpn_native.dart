import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../logging/diagnostic_error.dart';
import 'vpn_log.dart';

typedef _VpnAllocNative = Pointer<Uint8> Function(UintPtr);
typedef _VpnAllocDart = Pointer<Uint8> Function(int);
typedef _VpnFreeNative = Void Function(Pointer<Uint8>, UintPtr);
typedef _VpnFreeDart = void Function(Pointer<Uint8>, int);
typedef _VpnCallNative = Pointer<Uint8> Function(Pointer<Uint8>, UintPtr);
typedef _VpnCallDart = Pointer<Uint8> Function(Pointer<Uint8>, int);
typedef _VpnResultFreeNative = Void Function(Pointer<Uint8>);
typedef _VpnResultFreeDart = void Function(Pointer<Uint8>);

const _kShutdownMessage = '_vpn_worker_shutdown';

/// 原生库所需的 4 个 C ABI 符号名称（每个 worker Isolate 按库名仅查找一次）。
@visibleForTesting
const List<String> vpnNativeSymbolNames = <String>[
  'nuist_vpn_alloc',
  'nuist_vpn_free',
  'nuist_vpn_call',
  'nuist_vpn_result_free',
];

/// worker Isolate 内已完成打开与符号查找的原生库句柄。
@visibleForTesting
abstract interface class VpnNativePreparedLibrary {
  /// 使用已缓存的符号执行一次原生调用；入参为请求的 UTF-8 字节，返回完整 JSON 响应。
  FutureOr<Map<String, dynamic>> invoke(Uint8List requestBytes);
}

/// 在 worker Isolate 内按库名打开动态库并查找全部符号的工厂函数。
@visibleForTesting
typedef VpnNativeLibraryOpener = VpnNativePreparedLibrary Function(
  String libraryName,
);

/// 供单测检查控制面常驻 Isolate、阻塞池与退役状态的可观测快照。
@visibleForTesting
final class VpnNativePoolStats {
  const VpnNativePoolStats({
    required this.controlSpawnCount,
    required this.blockingSpawnCount,
    required this.hasControlWorker,
    required this.controlBusy,
    required this.activeBlockingWorkers,
    required this.idleBlockingWorkers,
    required this.queuedControlRequests,
    required this.queuedBlockingRequests,
    required this.retiredWorkers,
  });

  final int controlSpawnCount;
  final int blockingSpawnCount;
  final bool hasControlWorker;
  final bool controlBusy;
  final int activeBlockingWorkers;
  final int idleBlockingWorkers;
  final int queuedControlRequests;
  final int queuedBlockingRequests;
  final int retiredWorkers;
}

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

/// Rust 控制接口。控制面复用单常驻 Isolate，阻塞操作在独立 worker 池中执行。
class VpnNative {
  const VpnNative() : _executor = null;

  /// 创建带独立执行器的测试实例，可注入伪造原生库加载器与超时策略。
  @visibleForTesting
  VpnNative.forTesting({
    VpnNativeLibraryOpener? libraryOpener,
    String? libraryNameOverride,
    int maxBlockingWorkers = defaultMaxBlockingWorkers,
    int? maxIdleBlockingWorkers,
    Duration Function(Object? method)? timeoutForMethod,
  }) : _executor = _VpnWorkerExecutor(
         libraryOpener: libraryOpener ?? _openDefaultLibrary,
         libraryNameOverride: libraryNameOverride,
         maxBlockingWorkers: maxBlockingWorkers,
         maxIdleBlockingWorkers:
             maxIdleBlockingWorkers ??
             (maxBlockingWorkers < defaultMaxIdleBlockingWorkers
                 ? maxBlockingWorkers
                 : defaultMaxIdleBlockingWorkers),
         timeoutForMethod: timeoutForMethod ?? _defaultTimeoutForMethod,
       );

  /// 阻塞 worker 池默认并发上限（覆盖网关 8 路并发 open 与并发 start/probe）。
  static const int defaultMaxBlockingWorkers = 10;

  /// 阻塞 worker 池默认空闲保留上限，避免突发建连后长期持有过多空闲 isolate。
  static const int defaultMaxIdleBlockingWorkers = 4;

  static final _VpnWorkerExecutor _sharedExecutor = _VpnWorkerExecutor(
    libraryOpener: _openDefaultLibrary,
    maxBlockingWorkers: defaultMaxBlockingWorkers,
    maxIdleBlockingWorkers: defaultMaxIdleBlockingWorkers,
    timeoutForMethod: _defaultTimeoutForMethod,
  );

  final _VpnWorkerExecutor? _executor;

  _VpnWorkerExecutor get _activeExecutor => _executor ?? _sharedExecutor;

  /// 返回当前执行器的 worker 数量、排队与退役状态（仅供测试校验）。
  @visibleForTesting
  VpnNativePoolStats get statsForTesting => _activeExecutor.stats;

  /// 关闭当前测试实例的 worker 池并标记为已释放（仅供测试清理）。
  @visibleForTesting
  Future<void> disposeForTesting() => _activeExecutor.shutdown(
    dispose: _executor != null,
    resetStats: _executor == null,
  );

  /// 关闭默认共享执行器的全部常驻 worker 并清零计数（仅供测试重置）。
  @visibleForTesting
  static Future<void> resetForTesting() =>
      _sharedExecutor.shutdown(resetStats: true);

  /// 执行一条控制命令，业务流量不经过此接口。
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) {
    final executor = _activeExecutor;
    final method = request['method'];
    final timeout = executor.timeoutForMethod(method);
    final stage = 'native.$method';
    // 只输出操作名，绝不展开 request/result。
    return vpnStage(
      stage,
      () {
        var expired = false;
        final dispatch = executor.dispatch(request);
        final work = dispatch.future;
        unawaited(
          work.then(
            (result) async {
              if (!expired || !executor.isEpochCurrent(dispatch.epoch)) {
                return;
              }
              // 即使 isolate 调度迟到，过期的启动或预留结果也不能留下孤立资源。
              if (method == 'start' && result['id'] is int) {
                try {
                  await call({'method': 'stop', 'id': result['id']});
                } catch (_) {}
              }
              if (method == 'prepareStart' && result['startId'] is int) {
                try {
                  await call({
                    'method': 'cancelStart',
                    'startId': result['startId'],
                  });
                } catch (_) {}
              }
              if (method == 'prepareOpen' && result['openId'] is int) {
                try {
                  await call({
                    'method': 'cancelOpen',
                    'id': request['id'],
                    'openId': result['openId'],
                  });
                } catch (_) {}
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (expired && executor.isEpochCurrent(dispatch.epoch)) {
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
            dispatch.onTimeout();
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

bool _isBlockingMethod(Object? method) =>
    method == 'start' || method == 'open' || method == 'probe';

Duration _defaultTimeoutForMethod(Object? method) => switch (method) {
  'start' => const Duration(seconds: 30),
  'open' => const Duration(seconds: 24),
  'probe' => const Duration(seconds: 5),
  _ => const Duration(seconds: 3),
};

String _resolveLibraryName() {
  const configured = String.fromEnvironment('VPN_NATIVE_LIBRARY');
  if (configured.isNotEmpty) return configured;
  return switch (Platform.operatingSystem) {
    'android' || 'linux' => 'libnuist_vpn.so',
    'windows' => 'nuist_vpn.dll',
    'macos' => 'libnuist_vpn.dylib',
    _ => throw VpnNativeException(
      '当前平台尚未接入校园 VPN 原生库',
      code: 'native_platform_unsupported',
      stage: 'native.load',
    ),
  };
}

VpnNativePreparedLibrary _openDefaultLibrary(String name) =>
    _RealVpnLibrary.open(name);

/// 生产环境 FFI 符号缓存：每个 worker Isolate 按库名仅打开并查找 4 个符号一次。
final class _RealVpnLibrary implements VpnNativePreparedLibrary {
  _RealVpnLibrary._({
    required this.library,
    required this.allocate,
    required this.free,
    required this.call,
    required this.freeResult,
  });

  factory _RealVpnLibrary.open(String name) {
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
    try {
      final allocate = library.lookupFunction<_VpnAllocNative, _VpnAllocDart>(
        vpnNativeSymbolNames[0],
      );
      final free = library.lookupFunction<_VpnFreeNative, _VpnFreeDart>(
        vpnNativeSymbolNames[1],
      );
      final call = library.lookupFunction<_VpnCallNative, _VpnCallDart>(
        vpnNativeSymbolNames[2],
      );
      final freeResult = library
          .lookupFunction<_VpnResultFreeNative, _VpnResultFreeDart>(
            vpnNativeSymbolNames[3],
          );
      return _RealVpnLibrary._(
        library: library,
        allocate: allocate,
        free: free,
        call: call,
        freeResult: freeResult,
      );
    } catch (error, stackTrace) {
      throw VpnNativeException(
        '校园 VPN 原生库符号不完整，请使用包含完整 Rust 核心的构建',
        code: 'native_library_load_failed',
        stage: 'native.load',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// 持有动态库引用，确保缓存期间句柄与符号指针持续有效。
  final DynamicLibrary library;
  final _VpnAllocDart allocate;
  final _VpnFreeDart free;
  final _VpnCallDart call;
  final _VpnResultFreeDart freeResult;

  @override
  Map<String, dynamic> invoke(Uint8List requestBytes) {
    final input = allocate(requestBytes.length);
    if (input == nullptr) throw const SocketException('VPN 控制消息过大');
    Pointer<Uint8> result = nullptr;
    try {
      input.asTypedList(requestBytes.length).setAll(0, requestBytes);
      result = call(input, requestBytes.length);
      if (result == nullptr) throw const SocketException('VPN 原生接口未返回结果');
      var length = 0;
      while (length < 1024 * 1024 && (result + length).value != 0) {
        length++;
      }
      if (length == 1024 * 1024) throw const SocketException('VPN 响应长度异常');
      return jsonDecode(utf8.decode(result.asTypedList(length)))
          as Map<String, dynamic>;
    } finally {
      free(input, requestBytes.length);
      if (result != nullptr) freeResult(result);
    }
  }
}

final class _VpnWorkerConfig {
  const _VpnWorkerConfig({
    required this.replyPort,
    required this.libraryOpener,
    this.libraryNameOverride,
  });

  final SendPort replyPort;
  final VpnNativeLibraryOpener libraryOpener;
  final String? libraryNameOverride;
}

final class _VpnWorkerRequest {
  const _VpnWorkerRequest(this.id, this.request);

  final int id;
  final Map<String, dynamic> request;
}

Future<void> _vpnWorkerEntry(_VpnWorkerConfig config) async {
  final commands = ReceivePort();
  final libraryCache = <String, VpnNativePreparedLibrary>{};
  config.replyPort.send(commands.sendPort);
  await for (final message in commands) {
    if (message == _kShutdownMessage) {
      commands.close();
      break;
    }
    if (message is! _VpnWorkerRequest) continue;
    try {
      final data = await _executeInWorker(
        message.request,
        libraryCache: libraryCache,
        openLibrary: config.libraryOpener,
        libraryNameOverride: config.libraryNameOverride,
      );
      _sendSuccess(config.replyPort, message.id, data);
    } catch (error, stackTrace) {
      _sendFailure(config.replyPort, message.id, error, stackTrace);
    }
  }
}

FutureOr<Map<String, dynamic>> _executeInWorker(
  Map<String, dynamic> request, {
  required Map<String, VpnNativePreparedLibrary> libraryCache,
  required VpnNativeLibraryOpener openLibrary,
  String? libraryNameOverride,
}) {
  final name = libraryNameOverride ?? _resolveLibraryName();
  final cached = libraryCache[name] ??= openLibrary(name);
  final bytes = utf8.encode(jsonEncode(request));
  final FutureOr<Map<String, dynamic>> raw;
  try {
    raw = cached.invoke(bytes);
  } catch (_) {
    bytes.fillRange(0, bytes.length, 0);
    rethrow;
  }
  if (raw is Future<Map<String, dynamic>>) {
    return raw.then(
      (response) {
        bytes.fillRange(0, bytes.length, 0);
        return _unwrapNativeResponse(response, request);
      },
      onError: (Object error, StackTrace stackTrace) {
        bytes.fillRange(0, bytes.length, 0);
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }
  bytes.fillRange(0, bytes.length, 0);
  return _unwrapNativeResponse(raw, request);
}

Map<String, dynamic> _unwrapNativeResponse(
  Map<String, dynamic> response,
  Map<String, dynamic> request,
) {
  if (response['ok'] != true) {
    // 错误回到主 isolate 的阶段日志中归类，避免丢失业务 Trace。
    throw VpnNativeException.fromResponse(
      response,
      method: request['method']?.toString() ?? 'unknown',
    );
  }
  return response['data'] as Map<String, dynamic>;
}

void _sendSuccess(SendPort replyPort, int reqId, Map<String, dynamic> data) {
  try {
    replyPort.send((reqId, true, data, null));
  } catch (error, stackTrace) {
    _sendFailure(replyPort, reqId, error, stackTrace);
  }
}

void _sendFailure(
  SendPort replyPort,
  int reqId,
  Object error,
  StackTrace stackTrace,
) {
  try {
    replyPort.send((reqId, false, error, stackTrace));
  } catch (_) {
    // 某些底层异常可能包含不可跨 isolate 传输的对象；降级为可发送副本保留诊断信息。
    final safeStack = StackTrace.fromString(stackTrace.toString());
    final Object safeError;
    if (error is VpnNativeException) {
      safeError = VpnNativeException(
        error.message,
        code: error.code,
        stage: error.stage,
        cause: error.cause?.toString(),
        causeStackTrace: error.causeStackTrace == null
            ? null
            : StackTrace.fromString(error.causeStackTrace.toString()),
        context: _sanitizeContextForSend(error.context),
        osError: error.osError == null
            ? null
            : OSError(error.osError!.message, error.osError!.errorCode),
      );
    } else if (error is SocketException) {
      safeError = SocketException(error.message, osError: error.osError);
    } else {
      safeError = StateError(error.toString());
    }
    replyPort.send((reqId, false, safeError, safeStack));
  }
}

Map<String, Object?> _sanitizeContextForSend(Map<String, Object?> source) => {
  for (final entry in source.entries)
    entry.key: _sanitizeValueForSend(entry.value),
};

Object? _sanitizeValueForSend(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        '${entry.key}': _sanitizeValueForSend(entry.value),
    };
  }
  if (value is Iterable) {
    return <Object?>[for (final item in value) _sanitizeValueForSend(item)];
  }
  return value.toString();
}

final class _VpnDispatchHandle {
  const _VpnDispatchHandle({
    required this.future,
    required this.epoch,
    required this.onTimeout,
  });

  final Future<Map<String, dynamic>> future;
  final int epoch;
  final void Function() onTimeout;
}

final class _QueuedVpnRequest {
  _QueuedVpnRequest({
    required this.request,
    required this.isBlocking,
    required this.epoch,
  });

  final Map<String, dynamic> request;
  final bool isBlocking;
  final int epoch;
  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();
  bool timedOut = false;
  _VpnIsolateWorker? assignedWorker;

  String get method => request['method']?.toString() ?? 'unknown';
}

final class _WorkerInFlight {
  const _WorkerInFlight({
    required this.reqId,
    required this.method,
    required this.completer,
  });

  final int reqId;
  final String method;
  final Completer<Map<String, dynamic>> completer;
}

final class _VpnIsolateWorker {
  _VpnIsolateWorker({
    required this.id,
    required this.isBlocking,
    required this._libraryOpener,
    required this._libraryNameOverride,
    required this._onExited,
  });

  final int id;
  final bool isBlocking;
  final VpnNativeLibraryOpener _libraryOpener;
  final String? _libraryNameOverride;
  final void Function(_VpnIsolateWorker worker) _onExited;

  Isolate? _isolate;
  Future<Isolate>? _spawningIsolate;
  SendPort? _commands;
  ReceivePort? _responses;
  ReceivePort? _exitPort;
  Future<void>? _readyFuture;
  final Completer<void> _exitDone = Completer<void>();
  int _nextRequestId = 0;
  _WorkerInFlight? _inFlight;
  bool _retired = false;
  bool _closing = false;
  bool _closed = false;

  bool get isRetired => _retired;
  bool get isClosed => _closed;

  Future<void> ensureReady() {
    if (_closed) {
      return Future<void>.error(
        VpnNativeException(
          'VPN 后台工作线程已退出',
          code: 'native_worker_exited',
          stage: 'native.worker',
        ),
      );
    }
    if (_commands != null) return Future<void>.value();
    return _readyFuture ??= _start();
  }

  Future<void> _start() async {
    final responses = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<void>();
    ready.future.ignore();
    _responses = responses;
    _exitPort = exitPort;
    exitPort.listen((_) {
      if (!ready.isCompleted) {
        ready.completeError(
          VpnNativeException(
            'VPN 后台工作线程启动失败',
            code: 'native_worker_exited',
            stage: 'native.worker',
          ),
        );
      }
      _handleExit();
    });
    responses.listen((Object? message) {
      if (message is SendPort) {
        _commands = message;
        if (!ready.isCompleted) ready.complete();
        if (_closing && _inFlight == null) {
          message.send(_kShutdownMessage);
        }
        return;
      }
      if (message is (int, bool, Object?, StackTrace?)) {
        final (reqId, ok, payload, stackTrace) = message;
        final inflight = _inFlight;
        if (inflight == null || inflight.reqId != reqId) return;
        _inFlight = null;
        if (!inflight.completer.isCompleted) {
          if (ok) {
            inflight.completer.complete(payload as Map<String, dynamic>);
          } else {
            inflight.completer.completeError(
              payload ?? StateError('VPN 原生调用失败'),
              stackTrace,
            );
          }
        }
        if (_closing) {
          _commands?.send(_kShutdownMessage);
        }
      }
    });
    try {
      final spawnFuture = Isolate.spawn(
        _vpnWorkerEntry,
        _VpnWorkerConfig(
          replyPort: responses.sendPort,
          libraryOpener: _libraryOpener,
          libraryNameOverride: _libraryNameOverride,
        ),
        onExit: exitPort.sendPort,
        debugName: 'nuist-vpn-${isBlocking ? 'blocking' : 'control'}-$id',
      );
      _spawningIsolate = spawnFuture;
      final isolate = await spawnFuture;
      _spawningIsolate = null;
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
      await ready.future;
    } catch (error, stackTrace) {
      _spawningIsolate = null;
      if (!ready.isCompleted) {
        ready.completeError(error, stackTrace);
      }
      _forceClose();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> invoke(Map<String, dynamic> request) {
    final commands = _commands;
    if (_closed || commands == null) {
      return Future<Map<String, dynamic>>.error(
        VpnNativeException(
          'VPN 后台工作线程不可用',
          code: 'native_worker_exited',
          stage: 'native.${request['method']}',
        ),
      );
    }
    final reqId = ++_nextRequestId;
    final completer = Completer<Map<String, dynamic>>();
    _inFlight = _WorkerInFlight(
      reqId: reqId,
      method: request['method']?.toString() ?? 'unknown',
      completer: completer,
    );
    try {
      commands.send(_VpnWorkerRequest(reqId, request));
    } catch (error, stackTrace) {
      _inFlight = null;
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  /// 发生超时后立即退役：不再归还池中，待迟到结果返回后优雅退出。
  void retire() {
    _retired = true;
    closeGracefully();
  }

  /// 标记优雅关闭：空闲时立即通知退出；有在途调用时待其返回后退出。
  void closeGracefully() {
    if (_closed || _closing) return;
    _closing = true;
    if (_inFlight == null) {
      _commands?.send(_kShutdownMessage);
    }
  }

  /// 执行器整体关闭时使用：空闲 worker 优雅退出，挂起/启动中的 worker 及时终止。
  Future<void> shutdown() async {
    if (_closed) return;
    _retired = true;
    _closing = true;
    if (_spawningIsolate case final spawning?) {
      try {
        final isolate = await spawning;
        _isolate ??= isolate;
      } catch (_) {}
    }
    if (_closed) return;
    final canGracefullyExit = _inFlight == null && _commands != null;
    if (canGracefullyExit) {
      _commands!.send(_kShutdownMessage);
      try {
        await _exitDone.future.timeout(const Duration(milliseconds: 500));
        return;
      } catch (_) {}
    }
    _forceClose();
  }

  void _forceClose() {
    final isolate = _isolate;
    _handleExit(closedByShutdown: true);
    isolate?.kill(priority: Isolate.immediate);
  }

  void _handleExit({bool closedByShutdown = false}) {
    if (_closed) return;
    _closed = true;
    _isolate = null;
    _commands = null;
    final responses = _responses;
    final exitPort = _exitPort;
    _responses = null;
    _exitPort = null;
    responses?.close();
    exitPort?.close();
    final inflight = _inFlight;
    _inFlight = null;
    if (inflight != null && !inflight.completer.isCompleted) {
      inflight.completer.completeError(
        VpnNativeException(
          closedByShutdown ? 'VPN 原生执行器已关闭' : 'VPN 后台工作线程意外退出',
          code: closedByShutdown
              ? 'native_worker_closed'
              : 'native_worker_exited',
          stage: 'native.${inflight.method}',
        ),
      );
    }
    if (!_exitDone.isCompleted) _exitDone.complete();
    _onExited(this);
  }
}

final class _VpnWorkerExecutor {
  _VpnWorkerExecutor({
    required this.libraryOpener,
    this.libraryNameOverride,
    required this.maxBlockingWorkers,
    required this.maxIdleBlockingWorkers,
    required this.timeoutForMethod,
  }) : assert(maxBlockingWorkers >= 1),
       assert(
         maxIdleBlockingWorkers >= 0 &&
             maxIdleBlockingWorkers <= maxBlockingWorkers,
       );

  final VpnNativeLibraryOpener libraryOpener;
  final String? libraryNameOverride;
  final int maxBlockingWorkers;
  final int maxIdleBlockingWorkers;
  final Duration Function(Object? method) timeoutForMethod;

  int _epoch = 0;
  bool _disposed = false;
  int _nextWorkerId = 0;
  int _controlSpawnCount = 0;
  int _blockingSpawnCount = 0;

  _VpnIsolateWorker? _controlWorker;
  bool _controlBusy = false;
  final Queue<_QueuedVpnRequest> _controlQueue = Queue<_QueuedVpnRequest>();

  final Set<_VpnIsolateWorker> _activeBlockingWorkers = <_VpnIsolateWorker>{};
  final List<_VpnIsolateWorker> _idleBlockingWorkers = <_VpnIsolateWorker>[];
  final Queue<_QueuedVpnRequest> _blockingQueue = Queue<_QueuedVpnRequest>();

  final Set<_VpnIsolateWorker> _retiredWorkers = <_VpnIsolateWorker>{};
  final Set<_VpnIsolateWorker> _closingWorkers = <_VpnIsolateWorker>{};

  bool isEpochCurrent(int epoch) => !_disposed && _epoch == epoch;

  VpnNativePoolStats get stats => VpnNativePoolStats(
    controlSpawnCount: _controlSpawnCount,
    blockingSpawnCount: _blockingSpawnCount,
    hasControlWorker: _controlWorker != null && !_controlWorker!.isClosed,
    controlBusy: _controlBusy,
    activeBlockingWorkers: _activeBlockingWorkers.length,
    idleBlockingWorkers: _idleBlockingWorkers.length,
    queuedControlRequests: _controlQueue.length,
    queuedBlockingRequests: _blockingQueue.length,
    retiredWorkers: _retiredWorkers.length,
  );

  _VpnDispatchHandle dispatch(Map<String, dynamic> request) {
    if (_disposed) {
      final completer = Completer<Map<String, dynamic>>()
        ..completeError(
          VpnNativeException(
            'VPN 原生执行器已关闭',
            code: 'native_worker_closed',
            stage: 'native.${request['method']}',
          ),
        );
      return _VpnDispatchHandle(
        future: completer.future,
        epoch: _epoch,
        onTimeout: () {},
      );
    }
    final blocking = _isBlockingMethod(request['method']);
    final item = _QueuedVpnRequest(
      request: request,
      isBlocking: blocking,
      epoch: _epoch,
    );
    if (blocking) {
      _blockingQueue.addLast(item);
      _pumpBlockingQueue();
    } else {
      _controlQueue.addLast(item);
      _pumpControlQueue();
    }
    return _VpnDispatchHandle(
      future: item.completer.future,
      epoch: item.epoch,
      onTimeout: () => _handleRequestTimeout(item),
    );
  }

  _VpnIsolateWorker _spawnWorker({required bool isBlocking}) {
    if (isBlocking) {
      _blockingSpawnCount++;
    } else {
      _controlSpawnCount++;
    }
    return _VpnIsolateWorker(
      id: ++_nextWorkerId,
      isBlocking: isBlocking,
      libraryOpener: libraryOpener,
      libraryNameOverride: libraryNameOverride,
      onExited: _handleWorkerExited,
    );
  }

  void _pumpControlQueue() {
    if (_disposed || _controlBusy) return;
    while (_controlQueue.isNotEmpty) {
      final next = _controlQueue.removeFirst();
      if (next.timedOut || next.completer.isCompleted) continue;

      var worker = _controlWorker;
      if (worker == null || worker.isRetired || worker.isClosed) {
        worker = _spawnWorker(isBlocking: false);
        _controlWorker = worker;
      }
      _controlBusy = true;
      next.assignedWorker = worker;
      unawaited(_runOnWorker(worker, next));
      return;
    }
  }

  void _pumpBlockingQueue() {
    if (_disposed) return;
    while (_blockingQueue.isNotEmpty) {
      final next = _blockingQueue.first;
      if (next.timedOut || next.completer.isCompleted) {
        _blockingQueue.removeFirst();
        continue;
      }
      _VpnIsolateWorker? worker;
      while (_idleBlockingWorkers.isNotEmpty) {
        final candidate = _idleBlockingWorkers.removeLast();
        if (!candidate.isRetired && !candidate.isClosed) {
          worker = candidate;
          break;
        }
      }
      if (worker == null) {
        if (_activeBlockingWorkers.length >= maxBlockingWorkers) {
          return;
        }
        worker = _spawnWorker(isBlocking: true);
      }
      _blockingQueue.removeFirst();
      _activeBlockingWorkers.add(worker);
      next.assignedWorker = worker;
      unawaited(_runOnWorker(worker, next));
    }
  }

  Future<void> _runOnWorker(
    _VpnIsolateWorker worker,
    _QueuedVpnRequest item,
  ) async {
    try {
      await worker.ensureReady();
      if (_disposed || item.timedOut || worker.isRetired || worker.isClosed) {
        if (worker.isRetired) {
          worker.closeGracefully();
        }
        return;
      }
      final result = await worker.invoke(item.request);
      if (!item.completer.isCompleted) {
        item.completer.complete(result);
      }
    } catch (error, stackTrace) {
      if (!item.completer.isCompleted) {
        item.completer.completeError(error, stackTrace);
      }
    } finally {
      _onWorkerFinished(worker);
    }
  }

  void _onWorkerFinished(_VpnIsolateWorker worker) {
    if (worker.isRetired) {
      worker.closeGracefully();
      return;
    }
    if (!worker.isBlocking) {
      if (identical(_controlWorker, worker)) {
        _controlBusy = false;
        if (worker.isClosed) {
          _controlWorker = null;
        }
        _pumpControlQueue();
      }
      return;
    }
    _activeBlockingWorkers.remove(worker);
    if (!_disposed && !worker.isClosed) {
      _idleBlockingWorkers.add(worker);
    }
    _pumpBlockingQueue();
    while (_idleBlockingWorkers.length > maxIdleBlockingWorkers) {
      final excess = _idleBlockingWorkers.removeAt(0);
      if (!excess.isClosed) {
        _closingWorkers.add(excess);
        excess.closeGracefully();
      }
    }
  }

  void _handleRequestTimeout(_QueuedVpnRequest item) {
    if (item.timedOut || item.completer.isCompleted) return;
    item.timedOut = true;
    final worker = item.assignedWorker;
    if (worker == null) {
      // 尚在队列中未派发：直接移出队列，不污染健康 worker。
      if (item.isBlocking) {
        _blockingQueue.remove(item);
      } else {
        _controlQueue.remove(item);
      }
      return;
    }
    // 已派发到 worker：原生调用可能仍卡住，立即将该 worker 剥离退役并释放槽位。
    _retireWorker(worker);
  }

  void _retireWorker(_VpnIsolateWorker worker) {
    if (!worker.isClosed) {
      _retiredWorkers.add(worker);
    }
    if (!worker.isBlocking) {
      if (identical(_controlWorker, worker)) {
        _controlWorker = null;
        _controlBusy = false;
      }
      worker.retire();
      _pumpControlQueue();
      return;
    }
    _activeBlockingWorkers.remove(worker);
    _idleBlockingWorkers.remove(worker);
    worker.retire();
    _pumpBlockingQueue();
  }

  void _handleWorkerExited(_VpnIsolateWorker worker) {
    _retiredWorkers.remove(worker);
    _closingWorkers.remove(worker);
    if (!worker.isBlocking) {
      if (identical(_controlWorker, worker)) {
        _controlWorker = null;
        _controlBusy = false;
        _pumpControlQueue();
      }
      return;
    }
    final wasActive = _activeBlockingWorkers.remove(worker);
    _idleBlockingWorkers.remove(worker);
    if (wasActive) {
      _pumpBlockingQueue();
    }
  }

  Future<void> shutdown({bool dispose = false, bool resetStats = false}) async {
    _epoch++;
    if (dispose) _disposed = true;
    _failQueue(_controlQueue);
    _failQueue(_blockingQueue);

    final workers = <_VpnIsolateWorker>{
      ?_controlWorker,
      ..._activeBlockingWorkers,
      ..._idleBlockingWorkers,
      ..._retiredWorkers,
      ..._closingWorkers,
    };
    _controlWorker = null;
    _controlBusy = false;
    _activeBlockingWorkers.clear();
    _idleBlockingWorkers.clear();
    _retiredWorkers.clear();
    _closingWorkers.clear();

    await Future.wait(workers.map((worker) => worker.shutdown()));

    if (resetStats) {
      _controlSpawnCount = 0;
      _blockingSpawnCount = 0;
    }
  }

  void _failQueue(Queue<_QueuedVpnRequest> queue) {
    while (queue.isNotEmpty) {
      final item = queue.removeFirst();
      if (!item.completer.isCompleted) {
        item.completer.completeError(
          VpnNativeException(
            'VPN 原生执行器已关闭',
            code: 'native_worker_closed',
            stage: 'native.${item.method}',
          ),
        );
      }
    }
  }
}
