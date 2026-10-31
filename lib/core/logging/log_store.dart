import 'dart:convert';
import 'dart:io';

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
    this.sanitizeRecord,
  });

  final Directory directory;
  final Directory? exportDirectory;
  final int maxFileBytes;
  final int maxFiles;
  final Duration retention;

  /// 读取旧日志时再次校验字段，避免旧版本的自由文本随诊断文件导出。
  final Map<String, Object?>? Function(Map<String, Object?>)? sanitizeRecord;

  Future<void> _queue = Future.value();
  DateTime? _nextPruneAt;
  int? _activeBytes;
  final Set<String> _unreadableFiles = {};
  final Set<String> _recoveredFiles = {};

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

  /// 创建目录并清理过期轮转文件。
  Future<void> initialize() => _enqueue(() async {
    await directory.create(recursive: true);
    await _pruneExpired();
    await _pruneExports();
  });

  /// 追加一行日志。调用方无需等待；内部会保证写入顺序。
  Future<void> append(String line) => _enqueue(() => _appendNow(line));

  Future<void> _appendNow(String line) async {
    await directory.create(recursive: true);
    if (_nextPruneAt == null || DateTime.now().isAfter(_nextPruneAt!)) {
      await _pruneExpired();
      await _pruneExports();
    }
    final active = _file(0);
    final encoded = utf8.encode('$line\n');
    if (encoded.length > maxFileBytes) {
      throw const FormatException('日志记录超过单文件容量限制');
    }
    final currentLength = _activeBytes ??= await active.exists()
        ? await active.length()
        : 0;
    if (currentLength > 0 && currentLength + encoded.length > maxFileBytes) {
      await _rotate();
    }
    try {
      await active.writeAsBytes(encoded, mode: FileMode.append, flush: false);
      _activeBytes = (_activeBytes ?? 0) + encoded.length;
    } catch (_) {
      _activeBytes = null;
      rethrow;
    }
  }

  Future<void> _rotate() async {
    final oldest = _file(maxFiles - 1);
    if (await oldest.exists()) await oldest.delete();
    for (var index = maxFiles - 2; index >= 0; index--) {
      final source = _file(index);
      if (!await source.exists()) continue;
      final target = _file(index + 1);
      if (await target.exists()) await target.delete();
      await source.rename(target.path);
    }
    _activeBytes = 0;
  }

  Future<void> _pruneExpired() async {
    _unreadableFiles.clear();
    _activeBytes = null;
    for (var index = 0; index < maxFiles; index++) {
      final file = _file(index);
      final temporary = File('${file.path}.prune.tmp');
      try {
        final read = await _readContent(file);
        if (read == null) continue;
        if (read.content.isEmpty) {
          await file.delete();
        } else if (read.content != read.original) {
          await temporary.writeAsString(read.content, flush: true);
          await temporary.rename(file.path);
        }
      } catch (_) {
        // 清理某个文件失败时继续处理其他文件，快照仍只使用安全的有效记录。
        _unreadableFiles.add(file.path);
      } finally {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {
          _unreadableFiles.add(file.path);
        }
      }
    }
    _nextPruneAt = DateTime.now().add(const Duration(hours: 1));
  }

  Future<({String original, String content})?> _readContent(File file) async {
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final original = utf8.decode(bytes, allowMalformed: true);
      final modified = await file.lastModified();
      final cutoff = DateTime.now().subtract(retention);
      final lines = const LineSplitter().convert(original);
      final retained = <String>[];
      var recovered = false;
      for (var index = 0; index < lines.length; index++) {
        var line = lines[index];
        if (line.isEmpty) continue;
        // 截断的多字节字符与 JSON 尾行只影响这一条，前面的有效记录继续保留。
        if (line.contains('\uFFFD')) {
          recovered = true;
          continue;
        }
        try {
          final decoded = jsonDecode(line);
          if (sanitizeRecord case final sanitizer?) {
            if (decoded is! Map<String, dynamic>) {
              recovered = true;
              continue;
            }
            final record = sanitizer(decoded);
            if (record == null) {
              recovered = true;
              continue;
            }
            final sanitized = jsonEncode(record);
            recovered |= sanitized != line;
            line = sanitized;
          }
        } catch (_) {
          if (sanitizeRecord != null ||
              index == lines.length - 1 && !original.endsWith('\n')) {
            recovered = true;
            continue;
          }
        }
        final at = _recordTime(line) ?? modified;
        if (!at.isBefore(cutoff)) retained.add(line);
      }
      if (recovered) _recoveredFiles.add(file.path);
      return (
        original: original,
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

  /// 等待此前的写入和维护全部结束。
  Future<void> flush() => _enqueue(() async {});

  /// 等待在途写入完成，按从旧到新的顺序生成快照。
  Future<LogSnapshot> snapshot() => _enqueue(() async {
    await _pruneExpired();
    return _snapshotNow();
  });

  Future<LogSnapshot> _snapshotNow() async {
    final buffer = StringBuffer();
    var bytes = 0;
    var count = 0;
    DateTime? oldest;
    for (var index = maxFiles - 1; index >= 0; index--) {
      final file = _file(index);
      try {
        final read = await _readContent(file);
        if (read == null || read.content.isEmpty) continue;
        final content = read.content;
        buffer.write(content);
        bytes += utf8.encode(content).length;
        count++;
        for (final line in const LineSplitter().convert(content)) {
          final at = _recordTime(line);
          if (at != null && (oldest == null || at.isBefore(oldest))) {
            oldest = at;
          }
        }
      } catch (_) {
        _unreadableFiles.add(file.path);
        // 单个轮转文件损坏时跳过，其余日志仍可导出。
      }
    }
    return LogSnapshot(
      content: buffer.toString(),
      stats: LogStoreStats(
        bytes: bytes,
        fileCount: count,
        oldestRecordAt: oldest,
        unreadableFileCount: _unreadableFiles.length,
        recoveredFileCount: _recoveredFiles.length,
      ),
    );
  }

  /// 只统计文件大小，不构造完整的导出字符串。
  Future<LogStoreStats> stats() => _enqueue(() async {
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
    await _pruneExpired();
    final snapshot = await _snapshotNow();
    await exports.create(recursive: true);
    await _pruneExports(keep: 2);
    final file = File(
      '${exports.path}${Platform.pathSeparator}'
      'nuistpp-diagnostics-${DateTime.now().toUtc().microsecondsSinceEpoch}.log',
    );
    await file.writeAsString(
      '${jsonEncode({...metadata, 'log_bytes': snapshot.stats.bytes, 'log_files': snapshot.stats.fileCount, 'unreadable_files': snapshot.stats.unreadableFileCount, 'recovered_files': snapshot.stats.recoveredFileCount})}\n'
      '${snapshot.content}',
      flush: true,
    );
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
          bytes + length > 8 * 1024 * 1024) {
        await file.delete();
      } else {
        bytes += length;
        retained++;
      }
    }
  }

  /// 清空全部日志文件，不改变详细日志开关。
  Future<void> clear() => _enqueue(() async {
    _activeBytes = null;
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
      await directory.create(recursive: true);
      await _verboseUntilFile.writeAsString(value.toUtc().toIso8601String());
    } catch (_) {
      // 开关持久化失败只影响下次启动，不影响当前会话。
    }
  });
}
