import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../config/campus_config.dart';
import 'app_log.dart';
import 'diagnostic_error.dart';
import 'diagnostic_redactor.dart';
import 'diagnostic_worker.dart';

int _nextSpoolId = 0;

// 大正文旁路写入本机临时密文，避免完整字节与 base64 长期占住 UI 堆。
class _BodyCapture {
  _BodyCapture({this.privateBufferLimit});

  static const inlineLimit = 64 * 1024;
  static const _chunkBytes = 64 * 1024;
  static const _highWaterBytes = 512 * 1024;
  static const _lowWaterBytes = 256 * 1024;

  final int? privateBufferLimit;
  final _bytes = BytesBuilder(copy: false);
  final int _spoolId = ++_nextSpoolId;
  File? _file;
  bool _ownsTempDir = false;
  Uint8List? _key;
  Uint8List? _iv;
  bool _spooled = false;
  bool _spoolOpened = false;
  bool _spoolClosed = false;
  bool _openStarted = false;
  Future<void>? _openFuture;
  Future<void>? _testHookTail;
  int _pendingOps = 0;
  Completer<void>? _idleCompleter;
  int length = 0;
  int _written = 0;
  int _inFlightBytes = 0;
  Completer<void>? _backpressure;
  Object? error;

  bool get isSpooled => _spooled;

  Future<void> _waitForPendingOps() => _pendingOps == 0
      ? Future<void>.value()
      : (_idleCompleter ??= Completer<void>()).future;

  void _finishOp() {
    _pendingOps--;
    if (_pendingOps == 0) {
      final idle = _idleCompleter;
      if (idle != null && !idle.isCompleted) {
        _idleCompleter = null;
        idle.complete();
      }
    }
  }

  void _releaseBackpressureIfReady() {
    if (error != null || _inFlightBytes <= _lowWaterBytes) {
      final waiter = _backpressure;
      if (waiter != null && !waiter.isCompleted) {
        _backpressure = null;
        waiter.complete();
      }
    }
  }

  Future<void>? enqueue(Uint8List bytes) {
    length += bytes.length;
    if (error != null) return null;
    // 需整段遮蔽的原文不进入后台附件；检索请求仅暂存在有上限的内存中。
    if (privateBufferLimit case final limit?) {
      if (length <= limit) {
        _bytes.add(Uint8List.fromList(bytes));
      } else {
        _bytes.clear();
      }
      return null;
    }
    if (!_spooled && _bytes.length + bytes.length <= inlineLimit) {
      _bytes.add(Uint8List.fromList(bytes));
      return null;
    }
    Uint8List? initial;
    if (!_spooled) {
      _spooled = true;
      initial = _bytes.takeBytes();
    }
    if (initial != null && initial.isNotEmpty) {
      _enqueueChunks(initial);
    }
    if (bytes.isNotEmpty) {
      _enqueueChunks(bytes);
    }
    if (error == null && _inFlightBytes >= _highWaterBytes) {
      return (_backpressure ??= Completer<void>()).future;
    }
    return null;
  }

  Future<void> _ensureOpen() {
    if (_openStarted) return _openFuture!;
    _openStarted = true;
    final future = () async {
      final overrideDir = diagnosticSpoolDirectoryForTesting;
      late final Directory directory;
      if (overrideDir != null) {
        directory = overrideDir;
        _ownsTempDir = false;
      } else {
        directory = await Directory.systemTemp.createTemp('nuist-http-body-');
        _ownsTempDir = true;
      }
      final file = File('${directory.path}/body.bin');
      _file = file;
      final random = Random.secure();
      final key = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256)),
      );
      final iv = Uint8List.fromList(
        List.generate(16, (_) => random.nextInt(256)),
      );
      _key = key;
      _iv = iv;
      await DiagnosticWorker.spoolOpen(
        _spoolId,
        file.path,
        key,
        iv,
        failAfterBytes: diagnosticSpoolFailAfterBytesForTesting,
      );
      _spoolOpened = true;
    }();
    // 防止多个并发或后续等待前就已失败时在根分支产生未捕获异步异常。
    future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return _openFuture = future;
  }

  Future<void> _writePipelinedSlice(
    Future<void> openFuture,
    Uint8List slice,
  ) async {
    try {
      await openFuture;
      if (error != null) return;
      await DiagnosticWorker.spoolWrite(_spoolId, slice);
      _written += slice.length;
    } catch (failure) {
      error ??= failure;
    } finally {
      _inFlightBytes -= slice.length;
      _releaseBackpressureIfReady();
      _finishOp();
    }
  }

  void _enqueueChunks(Uint8List bytes) {
    final testHook = diagnosticSpoolWriteForTesting;
    for (var offset = 0; offset < bytes.length; offset += _chunkBytes) {
      final end = min(offset + _chunkBytes, bytes.length);
      final slice = Uint8List.fromList(
        Uint8List.sublistView(bytes, offset, end),
      );
      if (testHook != null) {
        _pendingOps++;
        final previous = _testHookTail ?? Future<void>.value();
        late final Future<void> current;
        current = previous.then((_) async {
          try {
            if (error != null) return;
            await _ensureOpen();
            await testHook(_written);
            await DiagnosticWorker.spoolWrite(_spoolId, slice);
            _written += slice.length;
          } catch (failure) {
            error ??= failure;
          } finally {
            if (identical(_testHookTail, current)) _testHookTail = null;
            _finishOp();
          }
        });
        _testHookTail = current;
      } else {
        _inFlightBytes += slice.length;
        _pendingOps++;
        final openFuture = _ensureOpen();
        unawaited(_writePipelinedSlice(openFuture, slice));
      }
    }
  }

  Future<DiagnosticBodyFile?> finish(String? contentType, bool complete) async {
    await _waitForPendingOps();
    if (_spoolOpened && !_spoolClosed) {
      _spoolClosed = true;
      try {
        await DiagnosticWorker.spoolClose(_spoolId);
      } catch (failure) {
        error ??= failure;
      }
    }
    _releaseBackpressureIfReady();
    if (_file == null) return null;
    if (error != null && _written == 0 && !_spoolOpened) {
      return null;
    }
    return DiagnosticBodyFile(
      path: _file!.path,
      length: _written,
      complete: complete && error == null,
      contentType: contentType,
      key: _key,
      iv: _iv,
      deleteAfterRead: _ownsTempDir,
      incompleteReason: error == null ? null : 'capture_spool_write_failed',
    );
  }

  Uint8List peekBytes() => _bytes.toBytes();

  Future<void> dispose() async {
    try {
      await _waitForPendingOps();
      if (_spoolOpened && !_spoolClosed) {
        _spoolClosed = true;
        await DiagnosticWorker.spoolAbort(_spoolId, _file?.path);
      }
    } catch (_) {
    } finally {
      final waiter = _backpressure;
      if (waiter != null && !waiter.isCompleted) {
        _backpressure = null;
        waiter.complete();
      }
      final file = _file;
      if (file != null) {
        try {
          if (await FileSystemEntity.isFile(file.path)) await file.delete();
          if (_ownsTempDir) await file.parent.delete();
        } catch (_) {}
      }
      _key?.fillRange(0, _key!.length, 0);
      _bytes.clear();
    }
  }
}

final _exchanges = Expando<_HttpExchange>();
int _requestSequence = 0;
Future<void>? _finishPipeline;
bool _barrierRegistered = false;

void _ensureBarrierRegistered() {
  if (_barrierRegistered) return;
  _barrierRegistered = true;
  AppLog.registerPendingBarrier(waitForPendingHttpDiagnostics);
}

/// 等待后台串行诊断管线完成当前已入队的所有 HTTP 交流写入。
Future<void> waitForPendingHttpDiagnostics() =>
    _finishPipeline ?? Future<void>.value();

/// 仅测试中模拟已收到正文、但诊断副本的后续写入失败。
@visibleForTesting
Future<void> Function(int written)? diagnosticSpoolWriteForTesting;

/// 仅测试中覆盖加密暂存目录，用于模拟 spoolOpen 失败路径。
@visibleForTesting
Directory? diagnosticSpoolDirectoryForTesting;

/// 仅测试中在后台 Worker 写入指定字节数后注入真实 spoolWrite 失败。
@visibleForTesting
int? diagnosticSpoolFailAfterBytesForTesting;

/// 仅测试中模拟后台落盘前阻塞，验证业务响应交付不被阻塞。
@visibleForTesting
Future<void> Function()? diagnosticBeforePersistForTesting;

Future<Map<String, Object?>> _describeBodyInBackground(
  Uint8List bytes,
  String? contentType,
  bool complete,
) => DiagnosticWorker.describeBody(bytes, contentType, complete);

/// 校园和普通客户端共用的请求编号，只存在于本机诊断上下文。
int httpDiagnosticRequestId(RequestOptions options) =>
    _exchangeFor(options).requestId;

/// Dio 拦截器之间显式复用同一阶段，不依赖 handler.next 的 Zone 传播。
AppLogSpan httpDiagnosticSpan(RequestOptions options) =>
    _exchangeFor(options).span;

/// 获取已经读完或中断的真实交流快照；不二次读取流、不拼造缺失响应。
Map<String, Object?>? httpDiagnosticEvidence(RequestOptions options) =>
    _exchanges[options]?.currentEvidence();

_HttpExchange _exchangeFor(RequestOptions options) {
  _ensureBarrierRegistered();
  var exchange = _exchanges[options];
  if (exchange == null || exchange.finished) {
    exchange = _HttpExchange(options);
    _exchanges[options] = exchange;
  }
  return exchange;
}

/// 在最终适配器上安装正文采集，重复调用不会重复包装或重复输出。
///
/// 采集位置在 Dio 的 JSON 转换之前；只旁路复制消费者实际读取的字节，
/// 不重放请求、不提前耗尽流，也不更改 TLS、Cookie 或业务错误策略。
void installHttpDiagnostics(Dio dio) {
  _ensureBarrierRegistered();
  if (dio.httpClientAdapter is! _DiagnosticHttpAdapter) {
    dio.httpClientAdapter = _DiagnosticHttpAdapter(dio.httpClientAdapter);
  }
  if (!dio.interceptors.any(
    (interceptor) => interceptor is _DiagnosticInterceptor,
  )) {
    dio.interceptors.insert(0, _DiagnosticInterceptor());
  }
}

/// 证书补链等调用可取得被包装的原始适配器。
HttpClientAdapter unwrapHttpDiagnostics(HttpClientAdapter adapter) =>
    adapter is _DiagnosticHttpAdapter ? adapter.delegate : adapter;

class _DiagnosticInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final exchange = _exchangeFor(options);
    exchange.span.run(() => handler.next(options));
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final exchange = _exchanges[response.requestOptions];
    if (exchange != null && !exchange.adapterReached) {
      exchange.status = response.statusCode;
      exchange.statusMessage = response.statusMessage;
      exchange.responseHeaders = response.headers.map;
      exchange.interceptedResponse = response.data;
    }
    if (response.requestOptions.responseType != ResponseType.stream) {
      exchange?.enqueueFinish();
    }
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) async {
    await (_exchanges[error.requestOptions] ??
            _exchangeFor(error.requestOptions))
        .enqueueFinish(error: error, stackTrace: error.stackTrace);
    handler.next(error);
  }
}

class _DiagnosticHttpAdapter implements HttpClientAdapter {
  _DiagnosticHttpAdapter(this.delegate);
  final HttpClientAdapter delegate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final exchange = _exchangeFor(options);
    return exchange.span.run(() async {
      exchange.adapterReached = true;
      exchange.requestHeaders = Map<String, Object?>.from(options.headers);
      exchange.requestComplete = requestStream == null;
      try {
        final response = await delegate.fetch(
          options,
          requestStream == null
              ? null
              : exchange.observe(requestStream, request: true),
          cancelFuture,
        );
        exchange.status = response.statusCode;
        exchange.responseHeaders = response.headers;
        exchange.statusMessage = response.statusMessage;
        exchange.redirects = [
          for (final redirect in response.redirects ?? const <RedirectRecord>[])
            {
              'status': redirect.statusCode,
              'method': redirect.method,
              'url': redirect.location.toString(),
              'body_available': false,
              'reason': 'adapter_followed_redirect',
            },
        ];
        response.stream = exchange.observe(response.stream, request: false);
        return response;
      } catch (error, stackTrace) {
        await exchange.enqueueFinish(error: error, stackTrace: stackTrace);
        rethrow;
      }
    });
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

class _HttpExchange {
  _HttpExchange(this.options)
    : requestId = ++_requestSequence,
      span = AppLog.logger('http').startSpan();

  final RequestOptions options;
  final int requestId;
  final AppLogSpan span;
  final Stopwatch watch = Stopwatch()..start();
  late final _librarySearch =
      options.uri.host == CampusHosts.library &&
      options.method == 'POST' &&
      options.uri.path == '/meta-local/opac/search/';
  late final _libraryReader =
      options.uri.host == CampusHosts.library &&
      options.uri.path.startsWith('/meta-local/opac/users/');
  late final requestBytes = _BodyCapture(
    privateBufferLimit: _librarySearch ? _BodyCapture.inlineLimit : null,
  );
  late final responseBytes = _BodyCapture(
    privateBufferLimit: _libraryReader ? 0 : null,
  );
  final _bodyFiles = <String, DiagnosticBodyFile>{};
  Map<String, Object?> requestHeaders = {};
  Map<String, List<String>> responseHeaders = {};
  List<Map<String, Object?>> redirects = [];
  int? status;
  String? statusMessage;
  bool requestComplete = false;
  bool responseComplete = false;
  bool finished = false;
  int? _reservedSeq;
  Future<void>? _finishing;
  Map<String, Object?>? evidence;
  bool adapterReached = false;
  Object? interceptedResponse;
  Object? captureError;

  Stream<Uint8List> observe(Stream<Uint8List> source, {required bool request}) {
    late StreamController<Uint8List> controller;
    StreamSubscription<Uint8List>? subscription;
    var ended = false;
    var cancelled = false;
    var downstreamPaused = false;
    var backpressurePaused = false;
    Future<void>? terminalError;

    void syncPause() {
      if (subscription == null || cancelled) return;
      if (downstreamPaused || backpressurePaused) {
        if (!subscription!.isPaused) subscription!.pause();
      } else {
        if (subscription!.isPaused) subscription!.resume();
      }
    }

    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        subscription = source.listen(
          (bytes) {
            if (!cancelled) controller.add(bytes);
            if (!finished) {
              try {
                final backpressure = (request ? requestBytes : responseBytes)
                    .enqueue(bytes);
                if (backpressure != null && !backpressurePaused) {
                  backpressurePaused = true;
                  syncPause();
                  backpressure.whenComplete(() {
                    backpressurePaused = false;
                    syncPause();
                  });
                }
              } catch (error) {
                captureError = error;
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            final previous = terminalError;
            terminalError = () async {
              await previous;
              if (!request) {
                await enqueueFinish(error: error, stackTrace: stackTrace);
              }
              if (!cancelled) controller.addError(error, stackTrace);
            }();
          },
          onDone: () async {
            ended = true;
            // listen 不等待 async onError，关闭之前必须串行交付原始流错误。
            await terminalError;
            if (request) {
              requestComplete = true;
            } else {
              responseComplete = true;
              if (options.responseType == ResponseType.stream) {
                enqueueFinish();
              }
            }
            controller.close();
          },
          cancelOnError: false,
        );
      },
      onPause: () {
        downstreamPaused = true;
        syncPause();
      },
      onResume: () {
        downstreamPaused = false;
        syncPause();
      },
      onCancel: () async {
        cancelled = true;
        await subscription?.cancel();
        if (!ended && !request) {
          // 下一微任务给 Dio 错误回调保留机会；cancel 完成前已收到的正文须入队持久化。
          await Future<void>.value();
          enqueueFinish(
            error: const DiagnosticException(
              '响应流在读完之前终止，已保存实际收到的内容',
              code: 'response_stream_incomplete',
              stage: 'response.read',
            ),
          );
        }
      },
    );
    return controller.stream;
  }

  Map<String, Object?>? currentEvidence() {
    if (evidence != null) return evidence;
    if (finished) return _materializeEvidenceSync();
    return null;
  }

  Map<String, Object?> _buildExchangePayload(
    Map<String, Object?> requestBody,
    Map<String, Object?> responseBody,
  ) => <String, Object?>{
    'request_id': requestId,
    'method': options.method,
    'service': AppLog.serviceForHost(options.uri.host),
    'status_code': status,
    'duration_ms': watch.elapsedMilliseconds,
    'capture_source': adapterReached
        ? 'http_adapter_entity'
        : 'request_interceptor',
    'request': {
      'url': options.uri.toString(),
      'headers': requestHeaders,
      if (!_librarySearch && !requestComplete && options.data != null)
        'logical_body': switch (options.data) {
          String() || Map() || List() => options.data,
          FormData data => {
            'fields': {for (final field in data.fields) field.key: field.value},
            'files': [
              for (final file in data.files)
                {
                  'field': file.key,
                  'filename': file.value.filename,
                  'length': file.value.length,
                },
            ],
          },
          _ => {'unavailable_reason': 'request_stream_not_consumed'},
        },
      ...requestBody,
    },
    'response': {
      'status': status,
      'status_message': statusMessage,
      'headers': responseHeaders,
      if (!_libraryReader && !adapterReached)
        'logical_body': interceptedResponse,
      ...responseBody,
      if (!responseComplete)
        'incomplete_reason': !adapterReached
            ? 'interceptor_response_without_transport'
            : status == null
            ? 'no_response_received'
            : 'consumer_did_not_read_to_end',
    },
    if (redirects.isNotEmpty) 'redirects': redirects,
    if (captureError != null) 'capture_error': captureError.toString(),
  };

  Map<String, Object?> _describeCapturedSync(
    _BodyCapture capture,
    String? contentType,
    bool complete,
  ) {
    if (capture.isSpooled) {
      return {
        'body_attachment': true,
        'captured_bytes': capture.length,
        'complete': complete && capture.error == null && captureError == null,
        'content_type': contentType,
        if (capture.error != null)
          'incomplete_reason': 'capture_spool_write_failed',
      };
    }
    return describeDiagnosticBody(
      capture.peekBytes(),
      contentType,
      complete && captureError == null,
    );
  }

  Map<String, Object?> _materializeEvidenceSync() {
    if (evidence != null) return evidence!;
    final requestBody = _librarySearch
        ? _privateLibraryBody(
            requestBytes,
            requestComplete,
            logicalBody: options.data,
            search: true,
          )
        : _describeCapturedSync(
            requestBytes,
            options.contentType,
            requestComplete,
          );
    final responseBody = _libraryReader
        ? _privateLibraryBody(
            responseBytes,
            responseComplete,
            logicalBody: interceptedResponse,
          )
        : _describeCapturedSync(
            responseBytes,
            responseHeaders[Headers.contentTypeHeader]?.firstOrNull,
            responseComplete,
          );
    final exchange = _buildExchangePayload(requestBody, responseBody);
    final cleaned = DiagnosticRedactor.value(exchange) as Map<String, Object?>;
    final ref = <String, Object?>{
      'session_id': AppLog.sessionId,
      'seq': _reservedSeq ?? AppLog.reserveSequence(),
    };
    return evidence = {'record_ref': ref, 'exchange': cleaned};
  }

  Map<String, Object?> _materializeTraceEvidenceEntry() {
    final snapshot = _materializeEvidenceSync();
    final ref = snapshot['record_ref']! as Map<String, Object?>;
    final details = snapshot['exchange']! as Map<String, Object?>;
    final identity = '${ref['session_id']}:${ref['seq']}';
    return {
      'id': identity,
      'label': 'http.exchange',
      'details': {'record_ref': ref, ...details},
    };
  }

  Future<Map<String, Object?>> _bodyAsync(
    _BodyCapture builder,
    String? contentType,
    bool complete,
  ) async {
    final file = await builder.finish(contentType, complete);
    if (file != null) {
      final part = identical(builder, requestBytes) ? 'request' : 'response';
      _bodyFiles[part] = file;
      return {
        'body_attachment': true,
        'captured_bytes': file.length,
        'complete': file.complete,
        'content_type': contentType,
        if (file.incompleteReason != null)
          'incomplete_reason': file.incompleteReason,
      };
    }
    if (builder.error != null) {
      return {
        'captured_bytes': 0,
        'complete': false,
        'content_type': contentType,
        'incomplete_reason': 'capture_spool_write_failed',
      };
    }
    final bytes = builder.peekBytes();
    final intact = complete && captureError == null;
    return bytes.length > 16 * 1024
        ? await _describeBodyInBackground(bytes, contentType, intact)
        : describeDiagnosticBody(bytes, contentType, intact);
  }

  Map<String, Object?> _privateLibraryBody(
    _BodyCapture capture,
    bool complete, {
    Object? logicalBody,
    bool search = false,
  }) {
    final bytes = capture.peekBytes();
    final metadata = {
      'captured_bytes': capture.length,
      'complete': complete && captureError == null,
    };
    if (capture.length == 0 && logicalBody == null) return metadata;
    if (search && (bytes.isNotEmpty || capture.length == 0)) {
      try {
        final source = bytes.isEmpty ? logicalBody : utf8.decode(bytes);
        final json = source is String ? jsonDecode(source) : source;
        if (json is Map && json['queryFieldList'] is List) {
          final queryFields = json['queryFieldList'] as List;
          return {
            ...metadata,
            'body': jsonEncode({
              ...json,
              'queryFieldList': [
                for (final query in queryFields.cast<Map>())
                  {...query, 'values': DiagnosticRedactor.personal},
              ],
            }),
            'encoding': 'utf-8',
          };
        }
      } catch (_) {
        // 请求截断或变更格式时继续遮蔽原文。
      }
    }
    return {
      ...metadata,
      'body': DiagnosticRedactor.personal,
      'redaction_reason': search ? 'library_search_terms' : 'library_loans',
    };
  }

  Future<void> enqueueFinish({Object? error, StackTrace? stackTrace}) {
    if (_finishing != null) return _finishing!;
    finished = true;
    watch.stop();
    final seq = _reservedSeq ??= AppLog.reserveSequence();
    span.run(
      () => AppLog.registerLazyEvidence(
        '${AppLog.sessionId}:$seq',
        _materializeTraceEvidenceEntry,
      ),
    );
    final previous = _finishPipeline;
    final next = previous == null
        ? _finish(error: error, stackTrace: stackTrace)
        : previous.then((_) => _finish(error: error, stackTrace: stackTrace));
    late final Future<void> tail;
    tail = next.then<void>(
      (_) {
        if (identical(_finishPipeline, tail)) _finishPipeline = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_finishPipeline, tail)) _finishPipeline = null;
      },
    );
    _finishPipeline = tail;
    return _finishing = next;
  }

  Future<void> _finish({Object? error, StackTrace? stackTrace}) async {
    try {
      await diagnosticBeforePersistForTesting?.call();
      final requestBody = _librarySearch
          ? _privateLibraryBody(
              requestBytes,
              requestComplete,
              logicalBody: options.data,
              search: true,
            )
          : await _bodyAsync(
              requestBytes,
              options.contentType,
              requestComplete,
            );
      final responseBody = _libraryReader
          ? _privateLibraryBody(
              responseBytes,
              responseComplete,
              logicalBody: interceptedResponse,
            )
          : await _bodyAsync(
              responseBytes,
              responseHeaders[Headers.contentTypeHeader]?.firstOrNull,
              responseComplete,
            );
      final exchange = _buildExchangePayload(requestBody, responseBody);
      evidence = await span.run(
        () => AppLog.recordHttpExchangeAsync(
          'http',
          exchange,
          error: error,
          stackTrace: stackTrace,
          bodyFiles: _bodyFiles.isEmpty ? null : _bodyFiles,
          reservedSequence: _reservedSeq,
        ),
      );
    } catch (error, stackTrace) {
      // 诊断失败本身必须可见，但不能改变请求返回值或吞掉业务原始错误。
      span.run(
        () => AppLog.logger('http').warning(
          'capture.failed',
          fields: {
            'request_id': requestId,
            'reason_code': 'capture_serialization_failed',
          },
          error: error,
          stackTrace: stackTrace,
        ),
      );
    } finally {
      await requestBytes.dispose();
      await responseBytes.dispose();
    }
  }
}
