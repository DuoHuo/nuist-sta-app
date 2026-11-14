import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'app_log.dart';
import 'diagnostic_error.dart';

final _exchanges = Expando<_HttpExchange>();
int _requestSequence = 0;

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
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final exchange = _exchanges[response.requestOptions];
    if (exchange != null && !exchange.adapterReached) {
      exchange.status = response.statusCode;
      exchange.statusMessage = response.statusMessage;
      exchange.responseHeaders = response.headers.map;
      exchange.interceptedResponse = response.data;
    }
    if (response.requestOptions.responseType != ResponseType.stream) {
      exchange?.finish();
    }
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    (_exchanges[error.requestOptions] ?? _exchangeFor(error.requestOptions))
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
        exchange.finish(error: error, stackTrace: stackTrace);
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
  final BytesBuilder requestBytes = BytesBuilder(copy: false);
  final BytesBuilder responseBytes = BytesBuilder(copy: false);
  Map<String, Object?> requestHeaders = {};
  Map<String, List<String>> responseHeaders = {};
  List<Map<String, Object?>> redirects = [];
  int? status;
  String? statusMessage;
  bool requestComplete = false;
  bool responseComplete = false;
  bool finished = false;
  Map<String, Object?>? evidence;
  bool adapterReached = false;
  Object? interceptedResponse;
  Object? captureError;

  Stream<Uint8List> observe(Stream<Uint8List> source, {required bool request}) {
    late StreamController<Uint8List> controller;
    StreamSubscription<Uint8List>? subscription;
    var ended = false;
    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        subscription = source.listen(
          (bytes) {
            try {
              if (!finished) {
                (request ? requestBytes : responseBytes).add(
                  Uint8List.fromList(bytes),
                );
              }
            } catch (error) {
              captureError = error;
            }
            controller.add(bytes);
          },
          onError: (Object error, StackTrace stackTrace) {
            controller.addError(error, stackTrace);
            if (!request) finish(error: error, stackTrace: stackTrace);
          },
          onDone: () {
            ended = true;
            if (request) {
              requestComplete = true;
            } else {
              responseComplete = true;
              if (options.responseType == ResponseType.stream) finish();
            }
            controller.close();
          },
          cancelOnError: false,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        await subscription?.cancel();
        if (!ended && !request) {
          // 下一微任务给 Dio 的超时/取消错误回调保留补充原始异常的机会。
          scheduleMicrotask(
            () => finish(
              error: const DiagnosticException(
                '响应流在读完之前终止，已保存实际收到的内容',
                code: 'response_stream_incomplete',
                stage: 'response.read',
              ),
            ),
          );
        }
      },
    );
    return controller.stream;
  }

  Map<String, Object?> body(
    BytesBuilder builder,
    String? contentType,
    bool complete,
  ) {
    final bytes = builder.takeBytes();
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
          'complete': complete && captureError == null,
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
      'complete': complete && captureError == null,
    };
  }

  void finish({Object? error, StackTrace? stackTrace}) {
    if (finished) return;
    finished = true;
    watch.stop();
    try {
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
          if (!requestComplete && options.data != null)
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
          ...body(requestBytes, options.contentType, requestComplete),
        },
        'response': {
          'status': status,
          'status_message': statusMessage,
          'headers': responseHeaders,
          if (!adapterReached) 'logical_body': interceptedResponse,
          ...body(
            responseBytes,
            responseHeaders[Headers.contentTypeHeader]?.firstOrNull,
            responseComplete,
          ),
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
      evidence = span.run(
        () => AppLog.recordHttpExchange(
          'http',
          exchange,
          error: error,
          stackTrace: stackTrace,
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
    }
  }
}
