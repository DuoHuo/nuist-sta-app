import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'diagnostic_worker.dart';

export 'diagnostic_worker.dart' show DiagnosticBodyFile;

Future<int> _writeBodyAttachment(
  String path,
  Map<String, Object?> record,
  Map<String, DiagnosticBodyFile> bodies,
) => DiagnosticWorker.writeBodyAttachment(path, record, bodies);

typedef _IndexLine = ({
  String line,
  Map<String, Object?>? record,
  DateTime? at,
});
typedef _IndexRead = ({
  String original,
  List<_IndexLine> lines,
  bool recovered,
});

_IndexRead _readIndex(
  List<int> bytes,
  Map<String, Object?>? Function(Map<String, Object?>)? sanitizer,
  DateTime modified,
  DateTime cutoff,
) {
  final original = utf8.decode(bytes, allowMalformed: true);
  final lines = const LineSplitter().convert(original);
  final retained = <_IndexLine>[];
  var recovered = false;
  for (var index = 0; index < lines.length; index++) {
    var line = lines[index];
    if (line.isEmpty) continue;
    if (line.contains('\uFFFD')) {
      recovered = true;
      continue;
    }
    Map<String, Object?>? record;
    try {
      final decoded = jsonDecode(line);
      if (sanitizer != null) {
        if (decoded is! Map<String, dynamic>) {
          recovered = true;
          continue;
        }
        record = sanitizer(decoded);
        if (record == null) {
          recovered = true;
          continue;
        }
        final sanitized = jsonEncode(record);
        recovered |= sanitized != line;
        line = sanitized;
      } else if (decoded is Map<String, Object?>) {
        record = decoded;
      }
    } catch (_) {
      if (sanitizer != null ||
          index == lines.length - 1 && !original.endsWith('\n')) {
        recovered = true;
        continue;
      }
    }
    final at = record?['ts'] is String
        ? DateTime.tryParse(record!['ts'] as String)
        : null;
    if (!(at ?? modified).isBefore(cutoff)) {
      retained.add((line: line, record: record, at: at));
    }
  }
  return (original: original, lines: retained, recovered: recovered);
}

Future<_IndexRead> _readIndexInBackground(
  List<int> bytes,
  Map<String, Object?>? Function(Map<String, Object?>)? sanitizer,
  DateTime modified,
  DateTime cutoff,
) => Isolate.run(() => _readIndex(bytes, sanitizer, modified, cutoff));

PreparedLogRecord _prepareRecord(
  String? line,
  Map<String, Object?>? input,
  Set<String> evictedTraces,
  bool attachmentsEnabled,
) => prepareLogRecordSync(line, input, evictedTraces, attachmentsEnabled);

Future<PreparedLogRecord> _prepareRecordInBackground(
  String? line,
  Map<String, Object?>? record,
  Set<String> evictedTraces,
  bool attachmentsEnabled,
) => DiagnosticWorker.prepareRecord(
  line,
  record,
  evictedTraces,
  attachmentsEnabled,
);

Future<({String line, bool recovered, DateTime? at})> _hydrateAttachment(
  List<int> bytes,
  Map<String, Object?>? Function(Map<String, Object?>) sanitizer,
  Map<String, Object?> reference,
) => Isolate.run(() {
  final full = jsonDecode(utf8.decode(gzip.decode(bytes)));
  if (full is! Map<String, dynamic>) {
    throw const FormatException('诊断附件结构无效');
  }
  final expanded = sanitizer(full);
  if (expanded == null) throw const FormatException('诊断附件记录无效');
  final recovered = jsonEncode(expanded) != jsonEncode(full);
  final attrs = reference['attrs'];
  final details = attrs is Map ? attrs['details'] : null;
  final storage = details is Map ? details['storage'] : null;
  final record = storage is Map
      ? RotatingLogStore._markStorage(
          Map<String, dynamic>.from(expanded),
          Map<String, Object?>.from(storage),
        )
      : expanded;
  return (
    line: jsonEncode(record),
    recovered: recovered,
    at: record['ts'] is String
        ? DateTime.tryParse(record['ts'] as String)
        : null,
  );
});

Future<int> _uncompressedLength(List<int> bytes) =>
    Isolate.run(() => gzip.decode(bytes).length);

/// 超过此规模的索引扫描放到后台 isolate；冷启动维护和轮转不再占住界面线程。
const _backgroundScanBytes = 16 * 1024;

int _indexLength(Iterable<List<String>> indexes) {
  var length = 0;
  for (final lines in indexes) {
    for (final line in lines) {
      length += line.length;
    }
  }
  return length;
}

/// 小索引同步计算（测试的 FakeAsync 不推进 isolate），大索引在后台计算。
Future<T> _scanIndex<T>(int length, T Function() scan) =>
    length > _backgroundScanBytes ? Isolate.run(scan) : Future.value(scan());

// 以下包装在顶层创建闭包，只把参数带入 isolate，不捕获存储实例及其队列。
Future<List<String>> _decodeIndexLines(List<int> bytes) => _scanIndex(
  bytes.length,
  () => const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true)),
);

Future<Set<String>> _expiredTraceGroupsAsync(
  Map<int, List<String>> indexes,
  DateTime cutoff,
) => _scanIndex(
  _indexLength(indexes.values),
  () => _expiredTraceGroups(indexes, cutoff),
);

Future<String?> _contentWithoutGroupsAsync(
  String content,
  Set<String> groups,
) => _scanIndex(content.length, () => _contentWithoutGroups(content, groups));

Future<({Set<String> groups, Map<int, String?> contents})> _rotationPlanAsync(
  Map<int, List<String>> indexes,
  int maxFiles,
) => _scanIndex(
  _indexLength(indexes.values),
  () => _rotationPlan(indexes, maxFiles),
);

Future<
  ({
    Map<String, Map<String, dynamic>> references,
    Map<String, int> lengths,
    Map<int, List<Map<String, dynamic>>> recordsByFile,
    int? unreadableIndex,
  })
>
_scanAttachmentIndexAsync(
  Map<int, List<String>> indexes,
  int maxFiles,
  bool strict,
) => _scanIndex(
  _indexLength(indexes.values),
  () => _scanAttachmentIndex(indexes, maxFiles, strict),
);

/// 过期记录所属的操作；同一操作的其余记录随之淘汰。
Set<String> _expiredTraceGroups(
  Map<int, List<String>> indexes,
  DateTime cutoff,
) {
  final groups = <String>{};
  for (final lines in indexes.values) {
    for (final line in lines) {
      try {
        final record = jsonDecode(line);
        if (record is! Map || record['ts'] is! String) continue;
        final at = DateTime.tryParse(record['ts'] as String);
        if (at == null || !at.isBefore(cutoff)) continue;
        if (RotatingLogStore._traceGroup(record) case final String group) {
          groups.add(group);
        }
      } catch (_) {
        // 无法解析的行没有时间，沿用原先“不视为过期”的处理。
      }
    }
  }
  return groups;
}

/// 移除属于 [groups] 的行，并保持原有的换行规范化。
String? _contentWithoutGroups(String content, Set<String> groups) =>
    RotatingLogStore._joinLines(
      const LineSplitter()
          .convert(content)
          .where(
            (line) =>
                groups.isEmpty ||
                !groups.contains(RotatingLogStore._traceGroupOfLine(line)),
          ),
    );

/// 轮转时淘汰最旧文件中的操作，并计算其余文件后移后的内容。
({Set<String> groups, Map<int, String?> contents}) _rotationPlan(
  Map<int, List<String>> indexes,
  int maxFiles,
) {
  final groups = <String>{
    for (final line in indexes[maxFiles - 1] ?? const <String>[])
      if (RotatingLogStore._traceGroupOfLine(line) case final String group)
        group,
  };
  final contents = <int, String?>{};
  for (var index = maxFiles - 2; index >= 0; index--) {
    contents[index + 1] = RotatingLogStore._joinLines(
      (indexes[index] ?? const <String>[]).where(
        (line) =>
            groups.isEmpty ||
            !groups.contains(RotatingLogStore._traceGroupOfLine(line)),
      ),
    );
  }
  return (groups: groups, contents: contents);
}

/// 附件维护所需的索引记录；严格模式下遇到坏行返回其文件序号。
({
  Map<String, Map<String, dynamic>> references,
  Map<String, int> lengths,
  Map<int, List<Map<String, dynamic>>> recordsByFile,
  int? unreadableIndex,
})
_scanAttachmentIndex(
  Map<int, List<String>> indexes,
  int maxFiles,
  bool strict,
) {
  final references = <String, Map<String, dynamic>>{};
  final lengths = <String, int>{};
  final recordsByFile = <int, List<Map<String, dynamic>>>{};
  for (var index = maxFiles - 1; index >= 0; index--) {
    final records = <Map<String, dynamic>>[];
    for (final line in indexes[index] ?? const <String>[]) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) continue;
        records.add(decoded);
        if (decoded['record_attachment'] case final String name) {
          references[name] = decoded;
          final length = decoded['record_attachment_bytes'];
          if (length is int && length > 0) lengths[name] = length;
        }
      } catch (_) {
        if (strict) {
          return (
            references: references,
            lengths: lengths,
            recordsByFile: recordsByFile,
            unreadableIndex: index,
          );
        }
      }
    }
    recordsByFile[index] = records;
  }
  return (
    references: references,
    lengths: lengths,
    recordsByFile: recordsByFile,
    unreadableIndex: null,
  );
}

bool _recordNeedsBackground(Object? input) {
  var remaining = 16 * 1024;
  bool visit(Object? value) {
    if (value is String) {
      remaining -= value.length;
    } else if (value is Map) {
      for (final entry in value.entries) {
        if (visit(entry.key) || visit(entry.value)) return true;
      }
    } else if (value is Iterable) {
      for (final item in value) {
        if (visit(item)) return true;
      }
    } else {
      remaining -= 8;
    }
    return remaining <= 0;
  }

  return visit(input);
}

Future<List<int>> _encodeExport(
  Map<String, Object?> metadata,
  String content,
) => Isolate.run(() => utf8.encode('${jsonEncode(metadata)}\n$content'));

Future<Map<String, Object?>?> _findRecordInContent(
  String content,
  String sessionId,
  int sequence,
) => Isolate.run(() {
  for (final line in const LineSplitter().convert(content)) {
    final record = jsonDecode(line);
    if (record is Map<String, dynamic> &&
        record['session_id'] == sessionId &&
        record['seq'] == sequence) {
      return record;
    }
  }
  return null;
});

Future<({String content, int bytes, DateTime? oldest})> _assembleSnapshot(
  List<String> contents,
) => Isolate.run(() {
  final content = contents.join();
  DateTime? oldest;
  for (final line in const LineSplitter().convert(content)) {
    final at = RotatingLogStore._recordTime(line);
    if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
  }
  return (content: content, bytes: utf8.encode(content).length, oldest: oldest);
});

/// 本地日志占用与时间范围。
class LogStoreStats {
  const LogStoreStats({
    required this.bytes,
    required this.fileCount,
    this.oldestRecordAt,
    this.exportBytes = 0,
    this.exportFileCount = 0,
    this.unreadableFileCount = 0,
    this.recoveredFileCount = 0,
  });

  final int bytes;
  final int fileCount;
  final DateTime? oldestRecordAt;
  final int exportBytes;
  final int exportFileCount;
  final int unreadableFileCount;
  final int recoveredFileCount;
}

/// 导出时取得的一致日志快照。
class LogSnapshot {
  const LogSnapshot({required this.content, required this.stats});

  final String content;
  final LogStoreStats stats;
}

/// 小体积 JSON Lines 日志存储：串行写入、按大小轮转并定期清理。
class RotatingLogStore {
  RotatingLogStore(
    this.directory, {
    this.exportDirectory,
    this.maxFileBytes = 512 * 1024,
    this.maxFiles = 4,
    this.retention = const Duration(days: 7),
    this.maxAttachmentBytes = 64 * 1024 * 1024,
    this.sanitizeRecord,
    this.flushInterval = const Duration(milliseconds: 250),
    this.flushThresholdBytes = 12 * 1024,
  });

  final Directory directory;
  final Directory? exportDirectory;
  final int maxFileBytes;
  final int maxFiles;
  final Duration retention;
  final int maxAttachmentBytes;
  final Duration? flushInterval;
  final int flushThresholdBytes;

  /// 读取旧日志时再次校验字段，避免旧版本的自由文本随诊断文件导出。
  final Map<String, Object?>? Function(Map<String, Object?>)? sanitizeRecord;

  Future<void> _queue = Future.value();
  DateTime? _nextPruneAt;
  int? _activeBytes;
  bool _directoryReady = false;
  bool _attachmentsDirReady = false;
  RandomAccessFile? _activeHandle;
  final BytesBuilder _writeBuffer = BytesBuilder(copy: false);
  Timer? _flushTimer;
  final Set<String> _unreadableFiles = {};
  final Set<String> _recoveredFiles = {};
  int? _attachmentBytes;
  bool _attachmentsNeedMaintenance = false;
  final Map<String, DateTime> _evictedTraces = {};
  Set<String>? _evictedTracesCache;
  Directory get _attachments => Directory(_path('records'));
  File get _historyFile => File(_path('evicted_traces.json'));
  File get _rewriteCommitted => File(_path('.index-rewrite.committed'));
  File get _rewritePlan => File(_path('.index-rewrite.plan'));

  /// 当前待刷盘缓冲字节数，仅供测试验证批量缓冲行为。
  @visibleForTesting
  int get pendingBufferBytes => _writeBuffer.length;

  /// 实际执行批量写文件调用的次数，仅供测试验证写入合并。
  @visibleForTesting
  int writeBatchCountForTesting = 0;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  String _path(String name) =>
      '${directory.path}${Platform.pathSeparator}$name';

  File _file(int index) =>
      File(_path(index == 0 ? 'app.log' : 'app.$index.log'));

  File get _verboseUntilFile => File(_path('verbose_until'));

  Future<void> _ensureDirectory() async {
    if (_directoryReady) return;
    await directory.create(recursive: true);
    _directoryReady = true;
  }

  Future<void> _ensureAttachmentsDirectory() async {
    if (_attachmentsDirReady) return;
    await _attachments.create(recursive: true);
    _attachmentsDirReady = true;
  }

  Set<String> _evictedTraceSet() => _evictedTraces.isEmpty
      ? const <String>{}
      : (_evictedTracesCache ??= _evictedTraces.keys.toSet());

  void _cancelFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _scheduleFlush() {
    if (_flushTimer != null || _writeBuffer.isEmpty) return;
    final delay = flushInterval;
    if (delay == null || delay <= Duration.zero) return;
    _flushTimer = Timer(delay, () {
      _flushTimer = null;
      unawaited(
        _enqueue(() => _flushBufferNow())
            .catchError((Object _, StackTrace _) {}),
      );
    });
  }

  Future<RandomAccessFile> _openActiveHandle() async {
    final existing = _activeHandle;
    if (existing != null) return existing;
    await _ensureDirectory();
    final opened = await _file(0).open(mode: FileMode.append);
    _activeHandle = opened;
    return opened;
  }

  Future<void> _closeActiveHandle() async {
    final handle = _activeHandle;
    _activeHandle = null;
    if (handle != null) {
      try {
        await handle.close();
      } catch (_) {}
    }
  }

  Future<void> _flushBufferNow({bool syncToDisk = false}) async {
    _cancelFlushTimer();
    if (_writeBuffer.isEmpty) {
      if (syncToDisk && _activeHandle != null) {
        if (!await _file(0).exists()) {
          _activeBytes = null;
          _directoryReady = false;
          await _closeActiveHandle();
          return;
        }
        try {
          await _activeHandle!.flush();
        } catch (_) {
          _activeBytes = null;
          _directoryReady = false;
          await _closeActiveHandle();
        }
      }
      return;
    }
    final bytes = _writeBuffer.takeBytes();
    // 外部清理临时目录时旧句柄可能仍指向已删除的 inode，先校验存在性再写入。
    if (_activeHandle != null && !await _file(0).exists()) {
      await _closeActiveHandle();
      _activeBytes = null;
      _directoryReady = false;
    }
    final reusedHandle = _activeHandle != null;
    try {
      final handle = await _openActiveHandle();
      await handle.writeFrom(bytes);
      writeBatchCountForTesting++;
      if (syncToDisk) await handle.flush();
    } catch (_) {
      _activeBytes = null;
      _directoryReady = false;
      await _closeActiveHandle();
      if (reusedHandle) {
        final fresh = await _openActiveHandle();
        await fresh.writeFrom(bytes);
        writeBatchCountForTesting++;
        if (syncToDisk) await fresh.flush();
        _activeBytes = await _file(0).length();
        return;
      }
      rethrow;
    }
  }

  /// 创建目录并清理过期轮转文件。
  Future<void> initialize() => _enqueue(() async {
    await _ensureDirectory();
    await _recoverRewrites();
    await _readHistory();
    await _pruneExpired();
    await _pruneExports();
  });

  /// 追加一行日志。调用方无需等待；内部会保证写入顺序。
  Future<void> append(String line, {bool immediateFlush = false}) =>
      _enqueue(() => _appendNow(line, immediateFlush: immediateFlush));

  /// 将已脱敏记录按调用顺序入队，大正文的编码和压缩交由后台执行。
  Future<void> appendRecord(
    Map<String, Object?> record, {
    bool background = false,
    Map<String, DiagnosticBodyFile>? bodyFiles,
    bool immediateFlush = false,
  }) => _enqueue(
    () => _appendNow(
      null,
      record: record,
      background: background,
      bodyFiles: bodyFiles,
      immediateFlush: immediateFlush,
    ),
  );

  Future<void> _appendNow(
    String? line, {
    Map<String, Object?>? record,
    bool background = false,
    Map<String, DiagnosticBodyFile>? bodyFiles,
    bool immediateFlush = false,
  }) async {
    await _ensureDirectory();
    if (_nextPruneAt == null || DateTime.now().isAfter(_nextPruneAt!)) {
      await _pruneExpired();
      await _pruneExports();
    }
    final active = _file(0);
    final evictedTraces = _evictedTraceSet();
    // 结构化记录复用原有 Map，不再编码后解析两次；UTF-8 与 gzip 也同次后台处理。
    final prepared =
        background ||
            (line?.length ?? 0) > 16 * 1024 ||
            record != null && _recordNeedsBackground(record)
        ? await _prepareRecordInBackground(
            line,
            record,
            evictedTraces,
            sanitizeRecord != null,
          )
        : _prepareRecord(line, record, evictedTraces, sanitizeRecord != null);
    final parsed = prepared.record;
    Map<String, dynamic>? indexRecord = parsed;
    var encoded = prepared.bytes;
    File? createdAttachment;
    bool attemptedIndexWrite = false;
    try {
      if (sanitizeRecord != null &&
          (encoded.length > 64 * 1024 || bodyFiles != null)) {
        final record = parsed!;
        final name =
            '${record['session_id']}-${record['seq'].toRadixString(16)}-'
            '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}.json.gz';
        await _ensureAttachmentsDirectory();
        final attachment = File(
          '${_attachments.path}${Platform.pathSeparator}$name',
        );
        createdAttachment = attachment;
        // 日志入口已先脱敏；附件只保存这一份脱敏原文，保留完整内容而非截断。
        final attachmentLength = bodyFiles == null
            ? encoded.length
            : await _writeBodyAttachment(
                attachment.path,
                Map<String, Object?>.from(record),
                bodyFiles,
              );
        if (bodyFiles == null) {
          await attachment.writeAsBytes(prepared.compressed!, flush: true);
        }
        final previousAttachmentBytes = _attachmentBytes;
        if (previousAttachmentBytes != null) {
          _attachmentBytes = previousAttachmentBytes + attachmentLength;
        }
        if (_attachmentBytes == null ||
            _attachmentBytes! > maxAttachmentBytes) {
          _attachmentsNeedMaintenance = true;
        }
        final attrs = record['attrs'];
        final reference = {
          ...record,
          'record_attachment': name,
          'record_attachment_bytes': attachmentLength,
          'attrs': {
            if (attrs is Map)
              for (final key in [
                'request_id',
                'service',
                'method',
                'status_code',
                'duration_ms',
                'error_type',
                'error_kind',
                'reason_code',
                'stage',
                'outcome',
              ])
                if (attrs[key] != null) key: attrs[key],
            if (attrs is Map &&
                attrs['details'] is Map &&
                (attrs['details'] as Map)['storage'] is Map)
              'details': {'storage': (attrs['details'] as Map)['storage']},
          },
        };
        indexRecord = reference;
        encoded = utf8.encode('${jsonEncode(reference)}\n');
      }
      if (encoded.length > maxFileBytes) {
        throw const FormatException('日志记录超过单文件容量限制');
      }
      final currentLength = _activeBytes ??=
          (await active.exists() ? await active.length() : 0) +
          _writeBuffer.length;
      if (currentLength > 0 && currentLength + encoded.length > maxFileBytes) {
        await _rotate();
        // 轮转可能刚淘汰仍在进行的操作；新记录必须标明之前的历史不再完整。
        if (parsed != null && _hasHistoryGap(parsed)) {
          encoded = utf8.encode(
            '${jsonEncode(_markStorage(indexRecord!, {'history_missing': true, 'reason': 'operation_history_evicted'}))}\n',
          );
        }
      }
      if (encoded.length > maxFileBytes) {
        throw const FormatException('日志索引超过单文件容量限制');
      }
      attemptedIndexWrite = true;
      _writeBuffer.add(encoded);
      _activeBytes = (_activeBytes ?? 0) + encoded.length;
      final shouldFlushNow =
          immediateFlush ||
          flushInterval == null ||
          flushInterval! <= Duration.zero ||
          _writeBuffer.length >= flushThresholdBytes ||
          bodyFiles != null ||
          _attachmentsNeedMaintenance;
      if (shouldFlushNow) {
        await _flushBufferNow();
      } else {
        _scheduleFlush();
      }
      if (_attachmentsNeedMaintenance) {
        await _maintainAttachments();
      }
    } catch (_) {
      _activeBytes = null;
      _directoryReady = false;
      _attachmentsDirReady = false;
      _attachmentsNeedMaintenance = true;
      await _closeActiveHandle();
      if (!attemptedIndexWrite && createdAttachment != null) {
        try {
          if (await createdAttachment.exists()) {
            await createdAttachment.delete();
          }
        } catch (_) {}
        _attachmentBytes = null;
      }
      rethrow;
    }
  }

  Future<void> _rotate() async {
    await _flushBufferNow();
    await _closeActiveHandle();
    final indexes = await _loadIndexes();
    // 每写满一个索引文件就轮转一次；逐行解析约 2MiB 索引不能占住界面线程。
    final plan = await _rotationPlanAsync(indexes, maxFiles);
    final groups = plan.groups;
    final previousHistory = Map<String, DateTime>.from(_evictedTraces);
    for (final group in groups) {
      _evictedTraces[group] = DateTime.now().toUtc();
    }
    _evictedTracesCache = null;
    final replacements = <File, String?>{
      _file(0): null,
      _historyFile: _historyContent(),
      for (final entry in plan.contents.entries) _file(entry.key): entry.value,
    };
    try {
      await _replaceFiles(replacements);
    } catch (_) {
      _evictedTraces
        ..clear()
        ..addAll(previousHistory);
      _evictedTracesCache = null;
      rethrow;
    }
    _activeBytes = 0;
    _attachmentsNeedMaintenance = true;
  }

  static String? _traceGroup(Map record) {
    final trace = record['trace_id'];
    return trace is String && trace.isNotEmpty
        ? '${record['session_id'] ?? ''}:$trace'
        : null;
  }

  static String? _traceGroupOfLine(String line) {
    try {
      final record = jsonDecode(line);
      return record is Map ? _traceGroup(record) : null;
    } catch (_) {
      return null;
    }
  }

  static String _recordGroup(Map record) =>
      _traceGroup(record) ?? 'record:${record['session_id']}:${record['seq']}';

  bool _hasHistoryGap(Map record) =>
      _evictedTraces.containsKey(_traceGroup(record));

  static Map<String, dynamic> _markStorage(
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

  static String? _joinLines(Iterable<String> lines) {
    final content = lines.join('\n');
    return content.isEmpty ? null : '$content\n';
  }

  String _historyContent() => jsonEncode({
    for (final entry in _evictedTraces.entries)
      entry.key: entry.value.toIso8601String(),
  });

  Future<void> _readHistory() async {
    if (!await _historyFile.exists()) return;
    try {
      final history = jsonDecode(await _historyFile.readAsString());
      if (history is! Map) throw const FormatException('操作淘汰记录无效');
      for (final entry in history.entries) {
        final at = DateTime.tryParse('${entry.value}');
        if (entry.key is String && at != null) {
          _evictedTraces[entry.key as String] = at;
        }
      }
      _evictedTracesCache = null;
    } catch (_) {
      _unreadableFiles.add(_historyFile.path);
    }
  }

  Future<Map<int, List<String>>> _loadIndexes() async {
    final indexes = <int, List<String>>{};
    for (var index = 0; index < maxFiles; index++) {
      final file = _file(index);
      try {
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.file) {
          throw FileSystemException('日志索引不是普通文件', file.path);
        }
        indexes[index] = await _decodeIndexLines(await file.readAsBytes());
      } catch (_) {
        _unreadableFiles.add(file.path);
        rethrow;
      }
    }
    return indexes;
  }

  Iterable<File> get _rewriteTargets sync* {
    for (var index = 0; index < maxFiles; index++) {
      yield _file(index);
    }
    yield _historyFile;
  }

  /// 多索引重写先备份再提交；进程中断时按提交标记恢复，不丢其它操作。
  Future<void> _recoverRewrites() async {
    final committed = await _rewriteCommitted.exists();
    Map plan = const {};
    if (await _rewritePlan.exists()) {
      final value = jsonDecode(await _rewritePlan.readAsString());
      if (value is Map) plan = value;
    }
    for (final file in _rewriteTargets) {
      final backup = File('${file.path}.rewrite.bak');
      final temporary = File('${file.path}.rewrite.tmp');
      if (!committed &&
          plan[file.uri.pathSegments.last] == false &&
          await file.exists()) {
        await file.delete();
      }
      if (await backup.exists()) {
        if (committed) {
          await backup.delete();
        } else {
          if (await file.exists()) await file.delete();
          await backup.rename(file.path);
        }
      }
      if (await temporary.exists()) await temporary.delete();
    }
    if (await _rewritePlan.exists()) await _rewritePlan.delete();
    if (committed) await _rewriteCommitted.delete();
  }

  Future<void> _replaceFiles(Map<File, String?> replacements) async {
    await _recoverRewrites();
    final installed = <File>[];
    try {
      for (final entry in replacements.entries) {
        if (entry.value != null) {
          await File('${entry.key.path}.rewrite.tmp')
              .writeAsString(entry.value!, flush: true);
        }
      }
      await _rewritePlan.writeAsString(
        jsonEncode({
          for (final file in replacements.keys)
            file.uri.pathSegments.last: await file.exists(),
        }),
        flush: true,
      );
      for (final entry in replacements.entries) {
        final file = entry.key;
        if (await file.exists()) await file.rename('${file.path}.rewrite.bak');
        installed.add(file);
        if (entry.value != null) {
          await File('${file.path}.rewrite.tmp').rename(file.path);
        }
      }
      await _rewriteCommitted.writeAsString('committed', flush: true);
    } catch (_) {
      // 本进程知道哪些原先不存在的文件已安装，也一并撤回。
      for (final file in installed) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          _unreadableFiles.add(file.path);
        }
      }
      try {
        await _recoverRewrites();
      } catch (_) {
        _unreadableFiles.add(directory.path);
      }
      rethrow;
    }
    try {
      await _recoverRewrites();
    } catch (_) {
      // 新索引已提交，备份清理失败不回滚成功写入，留给下次维护重试。
      _unreadableFiles.add(directory.path);
    }
  }

  Future<void> _pruneExpired() async {
    await _flushBufferNow();
    await _closeActiveHandle();
    _unreadableFiles.clear();
    _activeBytes = null;
    Map<int, List<String>> indexes;
    try {
      indexes = await _loadIndexes();
    } catch (_) {
      return;
    }
    final cutoff = DateTime.now().subtract(retention);
    // 冷启动和每小时维护都会扫描全部索引，逐行解析放到后台执行。
    final expiredGroups = await _expiredTraceGroupsAsync(indexes, cutoff);
    final replacements = <File, String?>{};
    for (var index = 0; index < maxFiles; index++) {
      final file = _file(index);
      try {
        final read = await _readContent(file);
        if (read == null) continue;
        final content = await _contentWithoutGroupsAsync(
          read.content,
          expiredGroups,
        );
        if ((content ?? '') != read.original) replacements[file] = content;
      } catch (_) {
        _unreadableFiles.add(file.path);
        return;
      }
    }
    final previousHistory = Map<String, DateTime>.from(_evictedTraces);
    for (final group in expiredGroups) {
      _evictedTraces[group] = DateTime.now().toUtc();
    }
    if (expiredGroups.isNotEmpty) {
      _evictedTracesCache = null;
      replacements[_historyFile] = _historyContent();
    }
    if (replacements.isNotEmpty) {
      try {
        await _replaceFiles(replacements);
      } catch (_) {
        _evictedTraces
          ..clear()
          ..addAll(previousHistory);
        _evictedTracesCache = null;
        return;
      }
    }
    _nextPruneAt = DateTime.now().add(const Duration(hours: 1));
    await _maintainAttachments();
  }

  Future<void> _maintainAttachments() async {
    await _flushBufferNow();
    await _closeActiveHandle();
    if (!await _attachments.exists()) {
      _attachmentBytes = 0;
      _attachmentsNeedMaintenance = false;
      return;
    }
    Map<int, List<String>> indexes;
    try {
      indexes = await _loadIndexes();
    } catch (_) {
      return;
    }
    final scanned = await _scanAttachmentIndexAsync(
      indexes,
      maxFiles,
      sanitizeRecord != null,
    );
    if (scanned.unreadableIndex case final int index) {
      _unreadableFiles.add(_file(index).path);
      return;
    }
    final references = scanned.references;
    final lengths = scanned.lengths;
    final recordsByFile = scanned.recordsByFile;
    final attachments = <String, File>{};
    final orphaned = <File>[];
    var bytes = 0;
    try {
      await for (final entry in _attachments.list()) {
        if (entry is! File || !entry.path.endsWith('.json.gz')) continue;
        final name = entry.uri.pathSegments.last;
        if (!references.containsKey(name)) {
          orphaned.add(entry);
        } else {
          attachments[name] = entry;
          // 旧索引缺少长度时解压计量，不能拿 gzip 体积冒充未压缩预算。
          lengths[name] ??= await _uncompressedLength(
            await entry.readAsBytes(),
          );
          bytes += lengths[name]!;
        }
      }
    } catch (_) {
      _unreadableFiles.add(_attachments.path);
      return;
    }
    // 只有全部索引都可读时才能认定孤立附件，单个删除失败不影响其他数据。
    for (final file in orphaned) {
      try {
        await file.delete();
      } catch (_) {
        _unreadableFiles.add(file.path);
      }
    }
    _attachmentBytes = bytes;
    _attachmentsNeedMaintenance = false;
    if (bytes <= maxAttachmentBytes) return;
    final groupBytes = <String, int>{};
    for (final entry in references.entries) {
      if (!attachments.containsKey(entry.key)) continue;
      final group = _recordGroup(entry.value);
      groupBytes[group] = (groupBytes[group] ?? 0) + lengths[entry.key]!;
    }
    // 后续控制器摘要不能挤掉刚记录的超限响应；保护最新正文及其后续同操作摘要。
    final newestBody = references.entries
        .where((entry) => attachments.containsKey(entry.key))
        .lastOrNull
        ?.value;
    final newestGroup = newestBody == null ? null : _recordGroup(newestBody);
    final newestAttachment = newestBody?['record_attachment'];
    bool protectRecord(Map<String, dynamic> record) {
      if (newestBody == null || _recordGroup(record) != newestGroup) {
        return false;
      }
      final sequence = record['seq'];
      final bodySequence = newestBody['seq'];
      return identical(record, newestBody) ||
          sequence is int && bodySequence is int && sequence > bodySequence;
    }

    final removeGroups = <String>{};
    for (final group in groupBytes.keys) {
      if (bytes <= maxAttachmentBytes) break;
      removeGroups.add(group);
      bytes -= groupBytes[group]!;
      // 最新一条本身超过预算仍完整保留，明确声明历史缺失与超限例外。
      if (group == newestGroup && newestAttachment is String) {
        bytes += lengths[newestAttachment] ?? 0;
      }
    }
    final previousHistory = Map<String, DateTime>.from(_evictedTraces);
    final replacements = <File, String?>{};
    final protectedNewest =
        newestBody != null && removeGroups.contains(newestGroup);
    final newestGroupCount = recordsByFile.values
        .expand((records) => records)
        .where(
          (record) =>
              _recordGroup(record) == newestGroup && !protectRecord(record),
        )
        .length;
    for (final entry in recordsByFile.entries) {
      var changed = false;
      final retained = <String>[];
      for (final record in entry.value) {
        if (!removeGroups.contains(_recordGroup(record))) {
          retained.add(jsonEncode(record));
          continue;
        }
        if (protectedNewest && protectRecord(record)) {
          final marked = identical(record, newestBody)
              ? _markStorage(record, {
                  'history_missing':
                      newestGroupCount > 0 || _hasHistoryGap(record),
                  'budget_exceeded':
                      (lengths[newestAttachment] ?? 0) > maxAttachmentBytes,
                  'budget_bytes': maxAttachmentBytes,
                  'reason': 'latest_record_retained',
                })
              : record;
          final encoded = jsonEncode(marked);
          retained.add(encoded);
          changed |= encoded != jsonEncode(record);
        } else {
          changed = true;
          if (_traceGroup(record) case final String group) {
            _evictedTraces[group] = DateTime.now().toUtc();
          }
        }
      }
      if (changed) replacements[_file(entry.key)] = _joinLines(retained);
    }
    _evictedTracesCache = null;
    if (replacements.isEmpty) {
      _attachmentBytes = bytes;
      return;
    }
    replacements[_historyFile] = _historyContent();
    try {
      await _replaceFiles(replacements);
    } catch (_) {
      _evictedTraces
        ..clear()
        ..addAll(previousHistory);
      _evictedTracesCache = null;
      _attachmentBytes = null;
      _attachmentsNeedMaintenance = true;
      return;
    }
    _activeBytes = null;
    for (final entry in attachments.entries) {
      if (removeGroups.contains(_recordGroup(references[entry.key]!)) &&
          !(protectedNewest && entry.key == newestAttachment)) {
        try {
          await entry.value.delete();
        } catch (_) {
          _unreadableFiles.add(entry.value.path);
        }
      }
    }
    _attachmentBytes = bytes;
  }

  Future<({String original, String content})?> _readContent(
    File file, {
    bool expandAttachments = false,
    bool Function(Map<String, Object?> record)? select,
  }) async {
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final modified = await file.lastModified();
      final cutoff = DateTime.now().subtract(retention);
      final sanitizer = sanitizeRecord;
      final parsed = bytes.length > 16 * 1024
          ? await _readIndexInBackground(bytes, sanitizer, modified, cutoff)
          : _readIndex(bytes, sanitizer, modified, cutoff);
      final retained = <String>[];
      var recovered = parsed.recovered;
      for (final entry in parsed.lines) {
        var line = entry.line;
        final recordAt = entry.at;
        try {
          var record = entry.record;
          if (sanitizer != null && record != null) {
            if (select != null && !select(record)) continue;
            final name = record['record_attachment'];
            if (expandAttachments && name is String) {
              final reference = record;
              try {
                final attachment = File(
                  '${_attachments.path}${Platform.pathSeparator}$name',
                );
                // 解压、旧正文重脱敏、历史缺口合并及编码都在同一后台 isolate。
                final hydrated = await _hydrateAttachment(
                  await attachment.readAsBytes(),
                  sanitizer,
                  reference,
                );
                recovered |= hydrated.recovered;
                line = hydrated.line;
                final at = hydrated.at ?? modified;
                if (!at.isBefore(cutoff)) retained.add(line);
                continue;
              } catch (_) {
                _unreadableFiles.add(name);
                record = {
                  ...reference,
                  'attrs': {
                    ...?(reference['attrs'] as Map?),
                    'details': {
                      ...?((reference['attrs'] as Map?)?['details'] is Map
                          ? (reference['attrs'] as Map)['details'] as Map
                          : null),
                      'complete': false,
                      'incomplete_reason': 'diagnostic_attachment_unavailable',
                    },
                  },
                };
              }
            }
            if (record != entry.record) line = jsonEncode(record);
          }
        } catch (_) {
          if (sanitizer != null) {
            recovered = true;
            continue;
          }
        }
        final at = recordAt ?? _recordTime(line) ?? modified;
        if (!at.isBefore(cutoff)) retained.add(line);
      }
      if (recovered) _recoveredFiles.add(file.path);
      return (
        original: parsed.original,
        content: retained.isEmpty ? '' : '${retained.join('\n')}\n',
      );
    } catch (_) {
      _unreadableFiles.add(file.path);
      return null;
    }
  }

  static DateTime? _recordTime(String line) {
    try {
      final record = jsonDecode(line);
      return record is Map && record['ts'] is String
          ? DateTime.tryParse(record['ts'] as String)
          : null;
    } catch (_) {
      return null;
    }
  }

  /// 定期维护留存期限，同时清理应用生成的导出副本。
  Future<void> maintain() => _enqueue(() async {
    await _pruneExpired();
    await _pruneExports();
  });

  /// 等待此前的写入、缓冲刷盘和维护全部结束。
  Future<void> flush() => _enqueue(() => _flushBufferNow(syncToDisk: true));

  /// 刷盘并关闭复用的底层文件句柄，供测试重置或退出前调用。
  Future<void> close() => _enqueue(() async {
    await _flushBufferNow(syncToDisk: true);
    await _closeActiveHandle();
  });

  /// 等待在途写入完成，按从旧到新的顺序生成快照。
  Future<LogSnapshot> snapshot({bool expandAttachments = true}) =>
      _enqueue(() async {
        await _flushBufferNow();
        await _pruneExpired();
        return _snapshotNow(expandAttachments: expandAttachments);
      });

  /// 精确恢复缓存引用的原始诊断，仅展开命中的附件。
  Future<Map<String, Object?>?> findRecord(String sessionId, int sequence) =>
      _enqueue(() async {
        await _flushBufferNow();
        await _pruneExpired();
        for (var index = 0; index < maxFiles; index++) {
          final content = await _readContent(
            _file(index),
            expandAttachments: true,
            select: (record) =>
                record['session_id'] == sessionId && record['seq'] == sequence,
          );
          if (content == null || content.content.isEmpty) continue;
          // 内容已水合完整附件，最终 Map 的恢复也不能再同步解析大正文。
          final record = await _findRecordInContent(
            content.content,
            sessionId,
            sequence,
          );
          if (record != null) return record;
        }
        return null;
      });

  Future<LogSnapshot> _snapshotNow({bool expandAttachments = true}) async {
    await _flushBufferNow();
    final contents = <String>[];
    for (var index = maxFiles - 1; index >= 0; index--) {
      final file = _file(index);
      try {
        final read = await _readContent(
          file,
          expandAttachments: expandAttachments,
        );
        if (read == null || read.content.isEmpty) continue;
        contents.add(read.content);
      } catch (_) {
        _unreadableFiles.add(file.path);
        // 单个轮转文件损坏时跳过，其余日志仍可导出。
      }
    }
    // 完整正文的拼接、计量和最早时间解析不能再次占住 UI isolate。
    final assembled = await _assembleSnapshot(contents);
    return LogSnapshot(
      content: assembled.content,
      stats: LogStoreStats(
        bytes: assembled.bytes,
        fileCount: contents.length,
        oldestRecordAt: assembled.oldest,
        unreadableFileCount: _unreadableFiles.length,
        recoveredFileCount: _recoveredFiles.length,
      ),
    );
  }

  /// 只统计文件大小，不构造完整的导出字符串。
  Future<LogStoreStats> stats() => _enqueue(() async {
    await _flushBufferNow();
    if (_nextPruneAt == null || DateTime.now().isAfter(_nextPruneAt!)) {
      await _pruneExpired();
      await _pruneExports();
    }
    var bytes = 0;
    var count = 0;
    for (var index = 0; index < maxFiles; index++) {
      final file = _file(index);
      try {
        if (!await file.exists()) continue;
        bytes += await file.length();
        count++;
      } catch (_) {
        _unreadableFiles.add(file.path);
      }
    }
    var exportBytes = 0;
    if (await _historyFile.exists()) bytes += await _historyFile.length();
    if (await _attachments.exists()) {
      await for (final file in _attachments.list()) {
        if (file is File) bytes += await file.length();
      }
    }
    var exportCount = 0;
    final exports = exportDirectory;
    if (exports != null && await exports.exists()) {
      await for (final entry in exports.list()) {
        if (entry is File && entry.path.endsWith('.log')) {
          exportBytes += await entry.length();
          exportCount++;
        }
      }
    }
    return LogStoreStats(
      bytes: bytes,
      fileCount: count,
      exportBytes: exportBytes,
      exportFileCount: exportCount,
      unreadableFileCount: _unreadableFiles.length,
      recoveredFileCount: _recoveredFiles.length,
    );
  });

  /// 在同一队列内生成导出文件，避免与轮转或清除互相干扰。
  Future<File> createExport(
    Map<String, Object?> metadata,
  ) => _enqueue(() async {
    final exports = exportDirectory;
    if (exports == null) throw StateError('未配置诊断日志导出目录');
    await _flushBufferNow();
    await _pruneExpired();
    final snapshot = await _snapshotNow();
    await exports.create(recursive: true);
    await _pruneExports(keep: 2);
    final file = File(
      '${exports.path}${Platform.pathSeparator}'
      'nuistpp-diagnostics-${DateTime.now().toUtc().microsecondsSinceEpoch}.log',
    );
    final bytes = await _encodeExport({
      ...metadata,
      'log_bytes': snapshot.stats.bytes,
      'log_files': snapshot.stats.fileCount,
      'unreadable_files': snapshot.stats.unreadableFileCount,
      'recovered_files': snapshot.stats.recoveredFileCount,
    }, snapshot.content);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  });

  Future<void> _pruneExports({int keep = 3}) async {
    final exports = exportDirectory;
    if (exports == null || !await exports.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    final files = await exports
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.log'))
        .cast<File>()
        .toList();
    final modified = <String, DateTime>{};
    for (final file in files) {
      modified[file.path] = await file.lastModified();
    }
    files.sort((a, b) => modified[b.path]!.compareTo(modified[a.path]!));
    var bytes = 0;
    var retained = 0;
    for (final file in files) {
      final length = await file.length();
      if (modified[file.path]!.isBefore(cutoff) ||
          retained >= keep ||
          bytes + length >
              maxAttachmentBytes * 3 + maxFileBytes * maxFiles * 3) {
        await file.delete();
      } else {
        bytes += length;
        retained++;
      }
    }
  }

  /// 清空全部日志文件，不改变详细日志开关。
  Future<void> clear() => _enqueue(() async {
    _cancelFlushTimer();
    _writeBuffer.clear();
    await _closeActiveHandle();
    _directoryReady = false;
    _attachmentsDirReady = false;
    _activeBytes = null;
    _attachmentBytes = null;
    await _recoverRewrites();
    for (var index = 0; index < maxFiles; index++) {
      final file = _file(index);
      if (await file.exists()) {
        await file.delete();
      }
      final temporary = File('${file.path}.prune.tmp');
      if (await temporary.exists()) await temporary.delete();
    }
    final exports = exportDirectory;
    if (exports != null && await exports.exists()) {
      await for (final entry in exports.list()) {
        if (entry is File && entry.path.endsWith('.log')) await entry.delete();
      }
    }
    _unreadableFiles.clear();
    _recoveredFiles.clear();
    if (await _attachments.exists()) {
      await for (final entry in _attachments.list()) {
        if (entry is File && entry.path.endsWith('.json.gz')) {
          await entry.delete();
        }
      }
    }
    if (await _historyFile.exists()) await _historyFile.delete();
    _evictedTraces.clear();
    _evictedTracesCache = null;
    _attachmentBytes = 0;
    _attachmentsNeedMaintenance = false;
    _nextPruneAt = null;
  });

  Future<DateTime?> readVerboseUntil() => _enqueue(() async {
    try {
      if (!await _verboseUntilFile.exists()) return null;
      return DateTime.tryParse((await _verboseUntilFile.readAsString()).trim());
    } catch (_) {
      return null;
    }
  });

  Future<void> writeVerboseUntil(DateTime? value) => _enqueue(() async {
    try {
      if (value == null) {
        if (await _verboseUntilFile.exists()) await _verboseUntilFile.delete();
        return;
      }
      await _ensureDirectory();
      await _verboseUntilFile.writeAsString(value.toUtc().toIso8601String());
    } catch (_) {
      // 开关持久化失败只影响下次启动，不影响当前会话。
    }
  });
}
