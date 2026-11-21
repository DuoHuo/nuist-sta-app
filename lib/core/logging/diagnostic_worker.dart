import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/stream/sic.dart';

import 'diagnostic_redactor.dart';

/// 尚未进入日志附件的正文文件；临时采集只写密文，密钥仅存在于进程内。
class DiagnosticBodyFile {
  const DiagnosticBodyFile({
    required this.path,
    required this.length,
    required this.complete,
    this.contentType,
    this.key,
    this.iv,
    this.deleteAfterRead = false,
    this.incompleteReason,
  });
  final String path;
  final int length;
  final bool complete;
  final String? contentType;
  final Uint8List? key;
  final Uint8List? iv;
  final bool deleteAfterRead;
  final String? incompleteReason;
}

/// 预处理后的索引或附件记录，供日志存储与后台隔离区共享。
class PreparedLogRecord {
  const PreparedLogRecord(this.record, this.bytes, this.compressed);
  final Map<String, dynamic>? record;
  final List<int> bytes;
  final List<int>? compressed;
}

/// 将原始字节描述为可序列化的诊断正文摘要（文本或 base64）。
Map<String, Object?> describeDiagnosticBody(
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

Iterable<Uint8List> _bodyChunks(DiagnosticBodyFile body) sync* {
  final file = File(body.path).openSync();
  final cipher = body.key == null
      ? null
      : (SICStreamCipher(AESEngine())
          ..init(false, ParametersWithIV(KeyParameter(body.key!), body.iv!)));
  var remaining = body.length;
  try {
    while (remaining > 0) {
      final bytes = file.readSync(
        remaining < 64 * 1024 ? remaining : 64 * 1024,
      );
      if (bytes.isEmpty) throw const FormatException('诊断正文文件被截断');
      remaining -= bytes.length;
      if (cipher == null) {
        yield bytes;
      } else {
        final plain = Uint8List(bytes.length);
        cipher.processBytes(bytes, 0, bytes.length, plain, 0);
        yield plain;
      }
    }
  } finally {
    file.closeSync();
  }
}

class _AttachmentSink implements Sink<List<int>> {
  _AttachmentSink(this.file);
  final RandomAccessFile file;
  @override
  void add(List<int> bytes) => file.writeFromSync(bytes);
  @override
  void close() {}
}

class _CountingSink implements Sink<List<int>> {
  _CountingSink(this.output);
  final Sink<List<int>> output;
  int length = 0;
  @override
  void add(List<int> bytes) {
    length += bytes.length;
    output.add(bytes);
  }

  @override
  void close() => output.close();
}

class _BodyEncodingSink implements Sink<List<int>> {
  _BodyEncodingSink(this.output);
  final Sink<List<int>> output;
  @override
  void add(List<int> bytes) => output.add(bytes);
  @override
  void close() {}
}

class _TextCounter implements StringSink {
  _TextCounter(this.consume);
  final void Function(String) consume;
  @override
  void write(Object? object) => consume('$object');
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => write('$object\n');
}

String? _bodyTextEncoding(DiagnosticBodyFile body) {
  var printable = 0;
  var controls = 0;
  var units = 0;
  var validUtf8 = true;
  final decoder = utf8.decoder.startChunkedConversion(
    StringConversionSink.fromStringSink(
      _TextCounter((text) {
        units += text.length;
        controls += text.codeUnits
            .where((u) => u < 32 && u != 9 && u != 10 && u != 13 || u == 127)
            .length;
      }),
    ),
  );
  for (final bytes in _bodyChunks(body)) {
    printable += bytes
        .where((b) => b >= 32 && b <= 126 || b == 9 || b == 10 || b == 13)
        .length;
    if (validUtf8) {
      try {
        decoder.add(bytes);
      } on FormatException {
        validUtf8 = false;
      }
    }
  }
  if (validUtf8) {
    try {
      decoder.close();
    } on FormatException {
      validUtf8 = false;
    }
  }
  if (validUtf8 && (units == 0 || controls / units < .05)) return 'utf-8';
  if (body.length == 0 || printable / body.length >= .85) return 'latin1';
  return null;
}

/// 同步流式解压/解密临时正文文件并写入脱敏压缩附件，返回未压缩记录字节数。
int writeBodyAttachmentSync(
  String path,
  Map<String, Object?> record,
  Map<String, DiagnosticBodyFile> bodies,
) {
  final output = File(path).openSync(mode: FileMode.write);
  final compressed = gzip.encoder.startChunkedConversion(
    _AttachmentSink(output),
  );
  final sink = _CountingSink(compressed);
  final attrs = record['attrs'];
  final details = attrs is Map ? attrs['details'] : null;
  final request = details is Map ? details['request'] : null;
  final url = request is Map ? request['url'] : null;
  final requestPath = url is String
      ? Uri.tryParse(url)?.path.toLowerCase()
      : null;
  final credentials = const {
    '/authserver/startassertion',
    '/authserver/finishassertion',
    '/authserver/startregister',
    '/authserver/finishregister',
  }.contains(requestPath);
  void write(String value) => sink.add(utf8.encode(value));
  void json(Object? value, List<String> route) {
    final part =
        route.length == 3 && route[0] == 'attrs' && route[1] == 'details'
        ? bodies[route[2]]
        : null;
    if (part != null && value is Map) {
      final encoding = _bodyTextEncoding(part);
      final metadata = Map<String, Object?>.from(value)
        ..remove('body_attachment');
      metadata['encoding'] = encoding ?? 'base64';
      metadata['captured_bytes'] = part.length;
      metadata['complete'] = part.complete;
      final prefix = jsonEncode(metadata);
      write(prefix.substring(0, prefix.length - 1));
      write(',');
      if (encoding != null) {
        final buffer = StringBuffer();
        final converter = (encoding == 'utf-8' ? utf8.decoder : latin1.decoder)
            .startChunkedConversion(
              StringConversionSink.fromStringSink(buffer),
            );
        for (final chunk in _bodyChunks(part)) {
          converter.add(chunk);
        }
        converter.close();
        final text = DiagnosticRedactor.text(
          buffer.toString(),
          credentialContext: credentials,
        );
        write('"body":${jsonEncode(text)}}');
      } else {
        write('"body_base64":"');
        final encoder = base64.encoder
            .fuse(ascii.encoder)
            .startChunkedConversion(_BodyEncodingSink(sink));
        for (final chunk in _bodyChunks(part)) {
          encoder.add(chunk);
        }
        // 使用不关闭总输出的 sink，正文结束后还要写 JSON 的其余字段。
        encoder.close();
        write('"}');
      }
    } else if (value is Map) {
      write('{');
      var first = true;
      for (final entry in value.entries) {
        if (!first) write(',');
        first = false;
        write('${jsonEncode(entry.key.toString())}:');
        json(entry.value, [...route, entry.key.toString()]);
      }
      write('}');
    } else if (value is Iterable) {
      write('[');
      var first = true;
      for (final item in value) {
        if (!first) write(',');
        first = false;
        json(item, const []);
      }
      write(']');
    } else {
      write(jsonEncode(value));
    }
  }

  try {
    json(record, const []);
    write('\n');
    sink.close();
    output.flushSync();
    return sink.length;
  } finally {
    output.closeSync();
    for (final body in bodies.values) {
      if (body.deleteAfterRead) {
        try {
          File(body.path).deleteSync();
        } catch (_) {}
      }
      body.key?.fillRange(0, body.key!.length, 0);
    }
  }
}

/// 标记存储缺口或超限元信息。
Map<String, dynamic> markDiagnosticStorage(
  Map<String, dynamic> record,
  Map<String, Object?> values,
) {
  final attrs = record['attrs'] is Map ? record['attrs'] as Map : const {};
  final detail = attrs['details'];
  final details = detail is Map
      ? detail
      : <String, Object?>{'original_details': ?detail};
  return {
    ...record,
    'attrs': {
      ...attrs,
      'details': {
        ...details,
        'storage': {
          ...?(details['storage'] is Map ? details['storage'] as Map : null),
          ...values,
        },
      },
    },
  };
}

/// 同步准备待写日志记录（编码、缺口标记与可选 gzip 压缩）。
PreparedLogRecord prepareLogRecordSync(
  String? line,
  Map<String, Object?>? input,
  Set<String> evictedTraces,
  bool attachmentsEnabled,
) {
  Map<String, dynamic>? record;
  if (input != null) {
    record = Map<String, dynamic>.from(input);
  } else {
    try {
      final decoded = jsonDecode(line!);
      if (decoded is Map<String, dynamic>) record = decoded;
    } catch (_) {
      /* 兼容无结构化清洗器的普通行存储。 */
    }
  }
  if (record != null) {
    final trace = record['trace_id'];
    final group = trace is String && trace.isNotEmpty
        ? '${record['session_id'] ?? ''}:$trace'
        : null;
    if (evictedTraces.contains(group)) {
      record = markDiagnosticStorage(record, {
        'history_missing': true,
        'reason': 'operation_history_evicted',
      });
      line = null;
    }
  }
  final encoded = utf8.encode('${line ?? jsonEncode(record)}\n');
  final compressed = attachmentsEnabled && encoded.length > 64 * 1024
      ? gzip.encode(encoded)
      : null;
  return PreparedLogRecord(record, encoded, compressed);
}

class _SpoolSession {
  _SpoolSession(
    this.path,
    this.file,
    this.key,
    this.cipher, {
    this.failAfterBytes,
  });
  final String path;
  final RandomAccessFile file;
  final Uint8List key;
  final SICStreamCipher cipher;
  final int? failAfterBytes;
  int writtenBytes = 0;
  bool failed = false;
  bool closed = false;

  void close() {
    if (closed) return;
    closed = true;
    try {
      file.closeSync();
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }
}

void _workerEntry(SendPort replyPort) {
  final commands = ReceivePort();
  final sessions = <int, _SpoolSession>{};
  replyPort.send(commands.sendPort);

  void sendOk(int reqId, Object? payload) =>
      replyPort.send((reqId, true, payload));

  void sendErr(int reqId, Object error, [StackTrace? stackTrace]) {
    final message = error is FormatException
        ? ('format', error.message)
        : error is FileSystemException
        ? ('fs', error.message, error.path)
        : ('error', error.toString());
    replyPort.send((reqId, false, message));
  }

  commands.listen((Object? message) {
    if (message is! (String, int, Object?)) return;
    final (op, reqId, arg) = message;
    try {
      switch (op) {
        case 'spool_open':
          final (spoolId, path, key, iv, failAfterBytes) =
              arg! as (int, String, Uint8List, Uint8List, int?);
          final file = File(path).openSync(mode: FileMode.write);
          final keyCopy = Uint8List.fromList(key);
          final cipher = SICStreamCipher(AESEngine())
            ..init(true, ParametersWithIV(KeyParameter(keyCopy), iv));
          sessions[spoolId] = _SpoolSession(
            path,
            file,
            keyCopy,
            cipher,
            failAfterBytes: failAfterBytes,
          );
          sendOk(reqId, null);
        case 'spool_write':
          final (spoolId, data) = arg! as (int, TransferableTypedData);
          final session = sessions[spoolId];
          if (session == null || session.closed) {
            throw const FileSystemException('诊断正文写入会话已关闭');
          }
          if (session.failed) {
            throw const FileSystemException('诊断正文写入会话已失败');
          }
          try {
            final bytes = data.materialize().asUint8List();
            if (session.failAfterBytes != null &&
                session.writtenBytes >= session.failAfterBytes!) {
              throw FileSystemException('诊断正文测试注入写入失败', session.path);
            }
            final encrypted = Uint8List(bytes.length);
            session.cipher.processBytes(bytes, 0, bytes.length, encrypted, 0);
            session.file.writeFromSync(encrypted);
            session.writtenBytes += bytes.length;
            sendOk(reqId, null);
          } catch (_) {
            session.failed = true;
            rethrow;
          }
        case 'spool_close':
          final spoolId = arg! as int;
          final session = sessions.remove(spoolId);
          session?.close();
          sendOk(reqId, null);
        case 'spool_abort':
          final (spoolId, fallbackPath) = arg! as (int, String?);
          final session = sessions.remove(spoolId);
          final path = session?.path ?? fallbackPath;
          try {
            session?.close();
          } catch (_) {}
          if (path != null) {
            try {
              final file = File(path);
              if (file.existsSync()) file.deleteSync();
              file.parent.deleteSync();
            } catch (_) {}
          }
          sendOk(reqId, null);
        case 'describe_body':
          final (data, contentType, complete) =
              arg! as (TransferableTypedData, String?, bool);
          final bytes = data.materialize().asUint8List();
          sendOk(reqId, describeDiagnosticBody(bytes, contentType, complete));
        case 'redact_value':
          sendOk(reqId, DiagnosticRedactor.value(arg));
        case 'write_body_attachment':
          final (path, record, bodies) =
              arg!
                  as (
                    String,
                    Map<String, Object?>,
                    Map<String, DiagnosticBodyFile>,
                  );
          sendOk(reqId, writeBodyAttachmentSync(path, record, bodies));
        case 'prepare_record':
          final (line, input, evictedTraces, attachmentsEnabled) =
              arg! as (String?, Map<String, Object?>?, Set<String>, bool);
          final prepared = prepareLogRecordSync(
            line,
            input,
            evictedTraces,
            attachmentsEnabled,
          );
          final bytesData = TransferableTypedData.fromList([
            Uint8List.fromList(prepared.bytes),
          ]);
          final compressedData = prepared.compressed == null
              ? null
              : TransferableTypedData.fromList([
                  Uint8List.fromList(prepared.compressed!),
                ]);
          sendOk(reqId, (prepared.record, bytesData, compressedData));
        case 'shutdown':
          for (final session in sessions.values) {
            try {
              session.close();
            } catch (_) {}
          }
          sessions.clear();
          sendOk(reqId, null);
          commands.close();
      }
    } catch (error, stackTrace) {
      sendErr(reqId, error, stackTrace);
    }
  });
}

/// 常驻后台诊断 Isolate 通道，复用单一工作线程执行加密暂存、脱敏、压缩与编解码。
class DiagnosticWorker {
  DiagnosticWorker._();

  static Isolate? _isolate;
  static SendPort? _commands;
  static ReceivePort? _responses;
  static ReceivePort? _exitPort;
  static Future<SendPort>? _starting;
  static int _nextRequestId = 0;
  static final Map<int, Completer<Object?>> _pending =
      HashMap<int, Completer<Object?>>();

  /// 仅测试中校验常驻 Worker 只会按需启动一次。
  @visibleForTesting
  static int get spawnCountForTesting => _spawnCount;
  static int _spawnCount = 0;

  static Future<SendPort> _ensureStarted() {
    final existing = _commands;
    if (existing != null) return Future.value(existing);
    return _starting ??= _start();
  }

  static Future<SendPort> _start() async {
    final responses = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<SendPort>();
    Isolate? isolate;
    try {
      _spawnCount++;
      isolate = await Isolate.spawn(
        _workerEntry,
        responses.sendPort,
        onExit: exitPort.sendPort,
        debugName: 'nuist-diagnostic-worker',
      );
      _isolate = isolate;
      _responses = responses;
      _exitPort = exitPort;
      exitPort.listen((_) {
        if (!ready.isCompleted) {
          ready.completeError(const FileSystemException('诊断后台 Worker 提前退出'));
        }
        _handleExit(responses, exitPort);
      });
      responses.listen((Object? message) {
        if (message is SendPort) {
          _commands = message;
          if (!ready.isCompleted) ready.complete(message);
          return;
        }
        if (message is (int, bool, Object?)) {
          final (reqId, ok, payload) = message;
          final completer = _pending.remove(reqId);
          if (completer == null || completer.isCompleted) return;
          if (ok) {
            completer.complete(payload);
          } else {
            completer.completeError(_decodeWorkerError(payload));
          }
        }
      });
      return await ready.future;
    } catch (error) {
      _handleExit(responses, exitPort);
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      _starting = null;
    }
  }

  static Object _decodeWorkerError(Object? payload) {
    if (payload is (String, String, String?)) {
      final (kind, message, path) = payload;
      if (kind == 'fs') return FileSystemException(message, path);
      return StateError(message);
    }
    if (payload is (String, String)) {
      final (kind, message) = payload;
      if (kind == 'format') return FormatException(message);
      return StateError(message);
    }
    return StateError('$payload');
  }

  static void _handleExit(ReceivePort responses, ReceivePort exitPort) {
    if (identical(_responses, responses)) {
      _isolate = null;
      _commands = null;
      _responses = null;
      _exitPort = null;
      final pending = Map<int, Completer<Object?>>.of(_pending);
      _pending.clear();
      for (final completer in pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(const FileSystemException('诊断正文后台处理已结束'));
        }
      }
    }
    responses.close();
    exitPort.close();
  }

  static Future<T> _call<T>(String op, Object? arg) async {
    final port = await _ensureStarted();
    final reqId = ++_nextRequestId;
    final completer = Completer<Object?>();
    _pending[reqId] = completer;
    try {
      port.send((op, reqId, arg));
    } catch (error) {
      _pending.remove(reqId);
      rethrow;
    }
    final result = await completer.future;
    return result as T;
  }

  /// 打开一条加密暂存写入会话。
  static Future<void> spoolOpen(
    int spoolId,
    String path,
    Uint8List key,
    Uint8List iv, {
    int? failAfterBytes,
  }) => _call<void>('spool_open', (spoolId, path, key, iv, failAfterBytes));

  /// 向指定暂存会话写入一块字节（使用零拷贝 TransferableTypedData）。
  static Future<void> spoolWrite(int spoolId, Uint8List bytes) => _call<void>(
    'spool_write',
    (spoolId, TransferableTypedData.fromList([bytes])),
  );

  /// 结束并关闭指定暂存会话，同时擦除 Worker 侧密钥副本。
  static Future<void> spoolClose(int spoolId) =>
      _call<void>('spool_close', spoolId);

  /// 异常或取消时中止并删除临时文件。
  static Future<void> spoolAbort(int spoolId, String? path) =>
      _call<void>('spool_abort', (spoolId, path));

  /// 在后台描述 16 KiB–64 KiB 内存正文。
  static Future<Map<String, Object?>> describeBody(
    Uint8List bytes,
    String? contentType,
    bool complete,
  ) => _call<Map<String, Object?>>('describe_body', (
    TransferableTypedData.fromList([bytes]),
    contentType,
    complete,
  ));

  /// 在后台对完整交流结构做定点脱敏。
  static Future<Map<String, Object?>> redactValue(
    Map<String, Object?> value,
  ) async =>
      await _call<Object?>('redact_value', value) as Map<String, Object?>;

  /// 在后台将临时加密正文解密、再次脱敏并压缩写入附件文件。
  static Future<int> writeBodyAttachment(
    String path,
    Map<String, Object?> record,
    Map<String, DiagnosticBodyFile> bodies,
  ) => _call<int>('write_body_attachment', (path, record, bodies));

  /// 在后台准备日志记录并完成 UTF-8 编码与可选 gzip 压缩。
  static Future<PreparedLogRecord> prepareRecord(
    String? line,
    Map<String, Object?>? record,
    Set<String> evictedTraces,
    bool attachmentsEnabled,
  ) async {
    final (preparedRecord, bytesData, compressedData) =
        await _call<
          (Map<String, dynamic>?, TransferableTypedData, TransferableTypedData?)
        >('prepare_record', (line, record, evictedTraces, attachmentsEnabled));
    return PreparedLogRecord(
      preparedRecord,
      bytesData.materialize().asUint8List(),
      compressedData?.materialize().asUint8List(),
    );
  }

  /// 优雅关闭常驻 Worker，供测试清理或进程退出前调用。
  static Future<void> shutdown() async {
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
    final isolate = _isolate;
    final commands = _commands;
    final responses = _responses;
    final exitPort = _exitPort;
    if (isolate == null) return;
    if (commands != null) {
      try {
        await _call<void>('shutdown', null).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    if (identical(_isolate, isolate)) {
      _isolate = null;
      _commands = null;
      _responses = null;
      _exitPort = null;
      final pending = Map<int, Completer<Object?>>.of(_pending);
      _pending.clear();
      for (final completer in pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(const FileSystemException('诊断正文后台处理已关闭'));
        }
      }
      responses?.close();
      exitPort?.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// 供测试重置时同时清空启动计数（内部方法，供 AppLog.resetForTesting 调用）。
  static Future<void> resetForTesting() async {
    await shutdown();
    _spawnCount = 0;
  }
}
