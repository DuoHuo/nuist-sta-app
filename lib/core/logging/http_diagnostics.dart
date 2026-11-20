import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/stream/sic.dart';

import '../config/campus_config.dart';
import 'app_log.dart';
import 'diagnostic_error.dart';
import 'diagnostic_redactor.dart';
import 'log_store.dart';

void _spoolWorker((SendPort, String, Uint8List, Uint8List) configuration) {
  final (reply, path, key, iv) = configuration;
  final commands = ReceivePort();
  try {
    final file = File(path).openSync(mode: FileMode.write);
    final cipher = SICStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    reply.send(commands.sendPort);
    commands.listen((message) {
      try {
        if (message == null) {
          file.closeSync();
          key.fillRange(0, key.length, 0);
          reply.send(null);
          commands.close();
        } else {
          final bytes = (message as TransferableTypedData)
              .materialize()
              .asUint8List();
          final encrypted = Uint8List(bytes.length);
          cipher.processBytes(bytes, 0, bytes.length, encrypted, 0);
          file.writeFromSync(encrypted);
          reply.send(null);
        }
      } catch (error) {
        reply.send(error.toString());
      }
    });
  } catch (error) {
    reply.send(error.toString());
    commands.close();
  }
}

// 大正文旁路写入本机临时密文，避免完整字节与 base64 长期占住 UI 堆。
class _BodyCapture {
  _BodyCapture({this.privateBufferLimit});

  static const inlineLimit = 64 * 1024;
  final int? privateBufferLimit;
  final _bytes = BytesBuilder(copy: false);
  File? _file;
  Isolate? _worker;
  SendPort? _commands;
  StreamIterator<dynamic>? _responses;
  Uint8List? _key;
  Uint8List? _iv;
  int length = 0;
  int _written = 0;
  Object? error;
  Future<void>? _adding;

  Future<void> add(Uint8List bytes) {
    return _adding = _add(bytes).whenComplete(() => _adding = null);
  }

  Future<void> _add(Uint8List bytes) async {
    length += bytes.length;
    if (error != null) return;
    // 需整段遮蔽的原文不进入后台附件；检索请求仅暂存在有上限的内存中。
    if (privateBufferLimit case final limit?) {
      if (length <= limit) {
        _bytes.add(Uint8List.fromList(bytes));
      } else {
        _bytes.clear();
      }
      return;
    }
    if (_file == null && _bytes.length + bytes.length <= inlineLimit) {
      _bytes.add(Uint8List.fromList(bytes));
      return;
    }
    try {
      if (_file == null) {
        final directory = await Directory.systemTemp.createTemp(
          'nuist-http-body-',
        );
        _file = File('${directory.path}/body.bin');
        final random = Random.secure();
        _key = Uint8List.fromList(
          List.generate(32, (_) => random.nextInt(256)),
        );
        _iv = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
        final responses = ReceivePort();
        _responses = StreamIterator(responses);
        _worker = await Isolate.spawn(_spoolWorker, (
          responses.sendPort,
          _file!.path,
          _key!,
          _iv!,
        ));
        await _nextResponse();
        final ready = _responses!.current;
        if (ready is! SendPort) throw FileSystemException('$ready');
        _commands = ready;
        await _write(_bytes.takeBytes());
      }
      await _write(bytes);
    } catch (failure) {
      error = failure;
    }
  }

  Future<void> _write(Uint8List bytes) async {
    for (var offset = 0; offset < bytes.length; offset += 64 * 1024) {
      final end = min(offset + 64 * 1024, bytes.length);
      await diagnosticSpoolWriteForTesting?.call(_written);
      _commands!.send(
        TransferableTypedData.fromList([
          Uint8List.sublistView(bytes, offset, end),
        ]),
      );
      await _nextResponse();
      final failure = _responses!.current;
      if (failure != null) throw FileSystemException('$failure');
      _written += end - offset;
    }
  }

  Future<DiagnosticBodyFile?> finish(String? contentType, bool complete) async {
    await _adding;
    try {
      await _closeWorker();
    } catch (failure) {
      error ??= failure;
    }
    if (_file == null) return null;
    return DiagnosticBodyFile(
      path: _file!.path,
      length: _written,
      complete: complete && error == null,
      contentType: contentType,
      key: _key,
      iv: _iv,
      deleteAfterRead: true,
      incompleteReason: error == null ? null : 'capture_spool_write_failed',
    );
  }

  Uint8List takeBytes() => _bytes.takeBytes();
  Future<void> dispose() async {
    try {
      await _adding;
      await _closeWorker();
    } finally {
      final file = _file;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
          await file.parent.delete();
        } catch (_) {}
      }
      _key?.fillRange(0, _key!.length, 0);
      _bytes.clear();
    }
  }

  Future<void> _closeWorker() async {
    try {
      if (_commands != null && error == null) {
        _commands!.send(null);
        await _nextResponse();
      }
    } finally {
      _commands = null;
      _worker?.kill();
      _worker = null;
      await _responses?.cancel();
      _responses = null;
    }
  }

  Future<void> _nextResponse() async {
    if (!await _responses!.moveNext().timeout(const Duration(seconds: 3))) {
      throw const FileSystemException('诊断正文后台处理已结束');
    }
  }
}

final _exchanges = Expando<_HttpExchange>();
int _requestSequence = 0;

/// 仅测试中模拟已收到正文、但诊断副本的后续写入失败。
@visibleForTesting
Future<void> Function(int written)? diagnosticSpoolWriteForTesting;

Future<Map<String, Object?>> _describeBodyInBackground(
  Uint8List bytes,
  String? contentType,
  bool complete,
) => Isolate.run(
  () => _HttpExchange._describeBody(bytes, contentType, complete),
);

/// 校园和普通客户端共用的请求编号，只存在于本机诊断上下文。
int httpDiagnosticRequestId(RequestOptions options) =>
    _exchangeFor(options).requestId;

/// Dio 拦截器之间显式复用同一阶段，不依赖 handler.next 的 Zone 传播。
AppLogSpan httpDiagnosticSpan(RequestOptions options) =>
    _exchangeFor(options).span;

/// 获取已经读完或中断的真实交流快照；不二次读取流、不拼造缺失响应。
Map<String, Object?>? httpDiagnosticEvidence(RequestOptions options) =>
    _exchanges[options]?.evidence;

_HttpExchange _exchangeFor(RequestOptions options) {
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
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    final exchange = _exchanges[response.requestOptions];
    if (exchange != null && !exchange.adapterReached) {
      exchange.status = response.statusCode;
      exchange.statusMessage = response.statusMessage;
      exchange.responseHeaders = response.headers.map;
      exchange.interceptedResponse = response.data;
    }
    if (response.requestOptions.responseType != ResponseType.stream) {
      await exchange?.finish();
    }
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) async {
    await (_exchanges[error.requestOptions] ??
            _exchangeFor(error.requestOptions))
        .finish(error: error, stackTrace: error.stackTrace);
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
        await exchange.finish(error: error, stackTrace: stackTrace);
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
    Future<void>? adding;
    Future<void>? terminalError;
    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        subscription = source.listen(
          (bytes) {
            adding = () async {
              subscription?.pause();
              try {
                if (!finished) {
                  await (request ? requestBytes : responseBytes).add(bytes);
                }
              } catch (error) {
                captureError = error;
              }
              if (!cancelled) {
                controller.add(bytes);
                subscription?.resume();
              }
            }();
          },
          onError: (Object error, StackTrace stackTrace) {
            final previous = terminalError;
            terminalError = () async {
              await previous;
              if (!request) await finish(error: error, stackTrace: stackTrace);
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
              if (options.responseType == ResponseType.stream) await finish();
            }
            controller.close();
          },
          cancelOnError: false,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        cancelled = true;
        await subscription?.cancel();
        await adding;
        if (!ended && !request) {
          // 下一微任务给 Dio 错误回调保留机会；cancel 完成前已收到的正文须持久化。
          await Future<void>.value();
          await finish(
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

  Map<String, Object?> body(
    _BodyCapture builder,
    String? contentType,
    bool complete,
  ) {
    final bytes = builder.takeBytes();
    return _describeBody(bytes, contentType, complete && captureError == null);
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
    final bytes = builder.takeBytes();
    final intact = complete && captureError == null;
    return bytes.length > 16 * 1024
        ? await _describeBodyInBackground(bytes, contentType, intact)
        : _describeBody(bytes, contentType, intact);
  }

  static Map<String, Object?> _describeBody(
    Uint8List bytes,
    String? contentType,
    bool complete,
  ) {
    final type = contentType?.toLowerCase() ?? '';
    final textual =
        type.isEmpty ||
        type.startsWith('text/') ||
        type.contains('json') ||
        type.contains('xml') ||
        type.contains('javascript') ||
        type.contains('x-www-form-urlencoded');
    if (textual) {
      try {
        return {
          'body': utf8.decode(bytes),
          'encoding': 'utf-8',
          'captured_bytes': bytes.length,
          'complete': complete,
        };
      } on FormatException {
        // 保留非 UTF-8 实体原始字节，避免损坏正文冒充有效文本。
      }
    }
    return {
      'body_base64': base64Encode(bytes),
      'encoding': 'base64',
      'content_type': contentType,
      'captured_bytes': bytes.length,
      'complete': complete,
    };
  }

  Map<String, Object?> _privateLibraryBody(
    _BodyCapture capture,
    bool complete, {
    Object? logicalBody,
    bool search = false,
  }) {
    final bytes = capture.takeBytes();
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

  Future<void> finish({Object? error, StackTrace? stackTrace}) =>
      _finishing ??= _finish(error: error, stackTrace: stackTrace);

  Future<void> _finish({Object? error, StackTrace? stackTrace}) async {
    finished = true;
    watch.stop();
    try {
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
      final exchange = <String, Object?>{
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
                'fields': {
                  for (final field in data.fields) field.key: field.value,
                },
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
      evidence = await span.run(
        () => AppLog.recordHttpExchangeAsync(
          'http',
          exchange,
          error: error,
          stackTrace: stackTrace,
          bodyFiles: _bodyFiles.isEmpty ? null : _bodyFiles,
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
