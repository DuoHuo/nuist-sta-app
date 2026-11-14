import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webview_flutter/webview_flutter.dart';

import '../logging/app_log.dart';
import '../logging/diagnostic_error.dart';

/// WebView 加载与脚本网络诊断；仅观察原请求，不重放或替换网络实现。
///
/// 平台回调不提供主文档及原生子资源正文；脚本也看不到注入前和跨域帧请求。
/// 这些缺口会显式记录，不能把脚本采集等同于完整浏览器网络抓包。
class WebDiagnostics {
  WebDiagnostics(this.controller, {required this.scope})
    : _log = AppLog.logger(scope);

  final WebViewController controller;
  final String scope;
  final AppLogger _log;
  final _pending = <String, _WebExchange>{};
  AppLogSpan? _pageSpan;
  Stopwatch? _pageWatch;
  bool _pageFailed = false;
  bool _disposed = false;
  bool _attached = false;
  String? _pageUrl;

  /// 必须在首次加载前注册消息通道。
  Future<void> attach() async {
    if (_attached) return;
    await controller.addJavaScriptChannel(
      'NuistDiagnostics',
      onMessageReceived: (message) => _receive(message.message),
    );
    _attached = true;
  }

  /// 导航开始时建立页面上下文，旧文档未完成的采集会被标识为不完整。
  void pageStarted(String url) {
    if (_disposed) return;
    _flush('document_replaced');
    _pageSpan = _log.startSpan();
    _pageUrl = url;
    _pageWatch = Stopwatch()..start();
    _pageFailed = false;
    _pageSpan!.run(
      () => _log.info(
        'page.load_started',
        fields: {
          'details': {
            'url': url,
            'capture': {
              'source': 'javascript',
              'complete': false,
              'reason': 'webview_platform_visibility',
              'unavailable': [
                'main_document_body',
                'native_subresources',
                'requests_before_injection',
                'cross_origin_frames',
                'worker_requests',
              ],
            },
          },
        },
      ),
    );
    unawaited(_install());
  }

  /// 页面完成回调不覆盖此前的主框架错误。
  Future<void> pageFinished(String url) async {
    if (_disposed) return;
    if (!_pageFailed) {
      _pageSpan?.run(
        () => _log.info(
          'page.load_completed',
          fields: {
            'duration_ms': _pageWatch?.elapsedMilliseconds,
            'details': {'url': url},
          },
        ),
      );
    }
    await _install();
  }

  /// 保留平台提供的原始错误描述、代码和主框架标识。
  void resourceError(WebResourceError error) {
    if (_disposed) return;
    if (error.isForMainFrame != false) _pageFailed = true;
    void write() => _log.warning(
      'page.resource_failed',
      fields: {
        'details': {'url': error.url, 'main_frame': error.isForMainFrame},
      },
      error: DiagnosticException(
        error.description,
        code: error.errorType?.name ?? 'web_resource_failed',
        stage: 'webview.resource',
        context: {'platform_code': error.errorCode},
      ),
    );
    final span = _pageSpan;
    if (span == null) {
      write();
    } else {
      span.run(write);
    }
  }

  /// HTTP 错误回调只有头信息，正文不可用时明确标识。
  void httpError(HttpResponseError error) {
    if (_disposed) return;
    if (error.request?.uri.toString() == _pageUrl) _pageFailed = true;
    AppLog.recordHttpExchange(
      scope,
      {
        'source': 'webview_platform',
        'request': {'url': error.request?.uri.toString()},
        'response': {
          'status_code': error.response?.statusCode,
          'headers': error.response?.headers,
        },
        'capture': {
          'complete': false,
          'reason': 'platform_response_body_unavailable',
        },
      },
      error: const DiagnosticException(
        'WebView HTTP 请求失败',
        code: 'web_http_failed',
        stage: 'webview.response',
      ),
    );
  }

  Future<void> _install() async {
    if (!_attached || _disposed) return;
    try {
      await controller.runJavaScript(_observerScript);
    } catch (error, stackTrace) {
      _log.warning(
        'capture.install_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {
          'details': {
            'capture': {'complete': false, 'reason': 'script_injection_failed'},
          },
        },
      );
    }
  }

  void _receive(String raw) {
    if (_disposed) return;
    try {
      final message = jsonDecode(raw);
      if (message is! Map || message['id'] is! String) return;
      final id = message['id'] as String;
      final part = message['part'];
      final exchange =
          _pending[id] ??
          (message['type'] == 'metadata' && part == 'request'
              ? _pending.putIfAbsent(
                  id,
                  () => _WebExchange(
                    _pageSpan?.run(_log.startSpan) ?? _log.startSpan(),
                  ),
                )
              : null);
      if (exchange == null) return;
      switch (message['type']) {
        case 'metadata':
          if (message['value'] is Map &&
              (part == 'request' || part == 'response')) {
            exchange.data[part as String] = {
              ...?(exchange.data[part] as Map<String, Object?>?),
              ...Map<String, Object?>.from(message['value'] as Map),
            };
          }
        case 'bytes':
          if ((part == 'request' || part == 'response') &&
              message['value'] is String) {
            exchange.bytes
                .putIfAbsent(part as String, () => BytesBuilder(copy: false))
                .add(base64Decode(message['value'] as String));
          }
        case 'done':
          if (message['value'] is Map) {
            exchange.data['capture'] = message['value'];
          }
          _finish(id, exchange, error: message['error'] as String?);
      }
    } catch (error, stackTrace) {
      _log.warning(
        'capture.message_invalid',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _finish(
    String id,
    _WebExchange exchange, {
    String? error,
    String? incomplete,
  }) {
    _pending.remove(id);
    for (final entry in exchange.bytes.entries) {
      final bytes = entry.value.takeBytes();
      final part =
          (exchange.data[entry.key] as Map<String, Object?>?) ??
          <String, Object?>{};
      final headers = part['headers'];
      final type =
          '${part['content_type'] ?? (headers is Map ? headers['content-type'] : null) ?? ''}';
      part['captured_bytes'] = bytes.length;
      String? text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        /* 二进制保留字节。 */
      }
      if (type.contains('json') ||
          type.contains('text') ||
          type.contains('xml') ||
          type.contains('javascript') ||
          type.contains('x-www-form-urlencoded') ||
          (type.isEmpty &&
              text != null &&
              !text.contains(RegExp(r'[\x00-\x08\x0e-\x1f]')))) {
        part['body'] = text ?? utf8.decode(bytes, allowMalformed: true);
        part['encoding'] = 'utf8';
      } else {
        part['body_base64'] = base64Encode(bytes);
        part['encoding'] = 'base64';
      }
      part['content_type'] = type;
      exchange.data[entry.key] = part;
    }
    exchange.span.run(
      () => AppLog.recordHttpExchange(
        scope,
        {
          ...exchange.data,
          'exchange_id': id,
          'source': 'javascript',
          if (incomplete != null)
            'capture': {'complete': false, 'reason': incomplete},
        },
        error: error == null
            ? null
            : DiagnosticException(
                error,
                code: 'web_request_failed',
                stage: 'webview.javascript',
              ),
      ),
    );
  }

  void _flush(String reason) {
    for (final entry in _pending.entries.toList()) {
      _finish(entry.key, entry.value, incomplete: reason);
    }
  }

  /// 关闭页面时不丢弃已收到的部分正文。
  void dispose() {
    _flush('webview_disposed');
    _disposed = true;
  }
}

class _WebExchange {
  _WebExchange(this.span);
  final AppLogSpan span;
  final data = <String, Object?>{};
  final bytes = <String, BytesBuilder>{};
}

// 消息只经本地通道传输；异步观察使用克隆响应，不读取原请求/响应流。
const _observerScript = r'''
(() => {
  if (globalThis.__nuistDiagnosticsInstalled || !globalThis.NuistDiagnostics) return;
  globalThis.__nuistDiagnosticsInstalled = true;
  let sequence = 0;
  const prefix = Date.now().toString(36) + '-';
  const post = (id, type, part, value, error) => {
    try { NuistDiagnostics.postMessage(JSON.stringify({id, type, part, value, error})); } catch (_) {}
  };
  const headers = value => {
    try { return Object.fromEntries(new Headers(value).entries()); } catch (_) { return {}; }
  };
  const snapshot = value => {
    if (value instanceof ArrayBuffer) return value.slice(0);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
    if (value instanceof URLSearchParams) return value.toString();
    if (typeof FormData !== 'undefined' && value instanceof FormData) {
      const copy = new FormData();
      for (const [name, item] of value.entries()) copy.append(name, item);
      return copy;
    }
    return value;
  };
  const bytes = (id, part, data) => {
    for (let offset = 0; offset < data.length; offset += 16384) {
      const block = data.subarray(offset, offset + 16384);
      let binary = '';
      for (const byte of block) binary += String.fromCharCode(byte);
      post(id, 'bytes', part, btoa(binary));
    }
  };
  const body = async (id, part, value) => {
    if (value == null) return true;
    if (typeof value === 'string' || value instanceof URLSearchParams) {
      bytes(id, part, new TextEncoder().encode(String(value))); return true;
    }
    if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) {
      bytes(id, part, value instanceof ArrayBuffer ? new Uint8Array(value) :
        new Uint8Array(value.buffer, value.byteOffset, value.byteLength)); return true;
    }
    if (value instanceof Blob) { bytes(id, part, new Uint8Array(await value.arrayBuffer())); return true; }
    if (typeof FormData !== 'undefined' && value instanceof FormData) {
      const entries = Object.create(null);
      for (const [name, item] of value.entries()) {
        const values = entries[name] || (entries[name] = []);
        if (typeof item === 'string') values.push(item);
        else {
          const raw = new Uint8Array(await item.arrayBuffer());
          let binary = ''; for (const byte of raw) binary += String.fromCharCode(byte);
          values.push({file_name:item.name, content_type:item.type, body_base64:btoa(binary)});
        }
      }
      post(id,'metadata',part,{representation:'form_data_fields',content_type:'application/json'});
      bytes(id,part,new TextEncoder().encode(JSON.stringify(entries)));
      // 字段与文件都能看到，但浏览器生成的 multipart boundary 无法从 JS 取得。
      return false;
    }
    return false;
  };
  const stream = async (id, part, response) => {
    if (!response.body) return true;
    const reader = response.body.getReader();
    try {
      while (true) { const item = await reader.read(); if (item.done) break; bytes(id, part, item.value); }
      return true;
    } finally { reader.releaseLock(); }
  };
  const fetch = globalThis.fetch;
  if (typeof fetch === 'function') globalThis.fetch = function(input, init) {
    const id = prefix + (++sequence), began = Date.now();
    let requestBody, requestClone, requestComplete = true;
    try {
      const request = input instanceof Request ? input : null;
      post(id, 'metadata', 'request', {url: request ? request.url : String(input),
        method: (init && init.method) || (request && request.method) || 'GET',
        headers: headers((init && init.headers) || (request && request.headers))});
      if (init && 'body' in init) requestBody = snapshot(init.body);
      else if (request && request.body) requestClone = request.clone();
    } catch (_) { requestComplete = false; }
    let result;
    try { result = Reflect.apply(fetch, this, arguments); }
    catch (error) { post(id, 'done', null, {complete:false, reason:'request_rejected'}, String(error)); throw error; }
    const capturedRequest = Promise.resolve().then(() => requestClone ?
      stream(id, 'request', requestClone) : body(id, 'request', requestBody)).catch(() => false);
    result.then(async response => {
      let responseComplete = false, captureError;
      try {
        const clone = response.clone();
        post(id, 'metadata', 'response', {url: response.url, status_code: response.status,
          headers: headers(response.headers), response_type: response.type});
        responseComplete = response.type !== 'opaque' && await stream(id, 'response', clone);
      } catch (error) { captureError = String(error); }
      requestComplete = requestComplete && await capturedRequest;
      post(id, 'done', null, {complete: requestComplete && responseComplete,
        request_complete:requestComplete, response_complete:responseComplete,
        reason:requestComplete && responseComplete ? 'complete' : 'javascript_body_unavailable',
        capture_error:captureError, duration_ms:Date.now()-began});
    }, async error => {
      await capturedRequest;
      post(id, 'done', null, {complete:false, reason:'network_failed', duration_ms:Date.now()-began}, String(error));
    }).catch(() => {});
    return result;
  };
  const xhr = globalThis.XMLHttpRequest;
  if (!xhr) return;
  const state = new WeakMap(), open = xhr.prototype.open, send = xhr.prototype.send,
    setHeader = xhr.prototype.setRequestHeader;
  xhr.prototype.open = function(method, url) {
    const result = Reflect.apply(open, this, arguments);
    state.set(this, {method:String(method), url:String(url), headers:{}}); return result;
  };
  xhr.prototype.setRequestHeader = function(name, value) {
    const result = Reflect.apply(setHeader, this, arguments);
    const request = state.get(this);
    if (request) request.headers[String(name).toLowerCase()] = String(value);
    return result;
  };
  xhr.prototype.send = function(value) {
    const id = prefix + (++sequence), began = Date.now(), request = state.get(this) || {};
    post(id, 'metadata', 'request', request);
    let copy, copied = true; try { copy = snapshot(value); } catch (_) { copied = false; }
    const capturedRequest = Promise.resolve().then(() => copied && body(id, 'request', copy)).catch(() => false);
    this.addEventListener('loadend', async () => {
      let complete = false, captureError;
      try {
        const responseHeaders = {};
        for (const line of this.getAllResponseHeaders().split(/\r?\n/)) {
          const split = line.indexOf(':');
          if (split > 0) responseHeaders[line.slice(0,split).toLowerCase()] = line.slice(split+1).trim();
        }
        post(id, 'metadata', 'response', {url:this.responseURL, status_code:this.status,
          headers:responseHeaders, response_type:this.responseType || 'text'});
        if (!this.responseType || this.responseType === 'text') complete = await body(id,'response',this.responseText);
        else if (this.responseType === 'arraybuffer' || this.responseType === 'blob') complete = await body(id,'response',this.response);
        else if (this.responseType === 'json') {
          post(id,'metadata','response',{representation:'browser_decoded_json',content_type:'application/json'});
          await body(id,'response',JSON.stringify(this.response));
          captureError = 'original_body_unavailable_after_browser_decode';
        }
        else captureError = 'original_body_unavailable_after_browser_decode';
      } catch (error) { captureError = String(error); }
      const requestComplete = await capturedRequest;
      post(id,'done',null,{complete:complete && requestComplete && this.status !== 0,
        request_complete:requestComplete,response_complete:complete,
        reason:complete && requestComplete && this.status !== 0 ? 'complete' : 'javascript_body_unavailable',
        capture_error:captureError,duration_ms:Date.now()-began}, this.status === 0 ? 'XHR 未取得 HTTP 响应' : undefined);
    }, {once:true});
    try { return Reflect.apply(send,this,arguments); }
    catch(error) { post(id,'done',null,{complete:false,reason:'request_rejected'},String(error)); throw error; }
  };
})();
''';
