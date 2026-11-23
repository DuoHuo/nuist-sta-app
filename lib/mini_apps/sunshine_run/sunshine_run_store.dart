import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/app_directories.dart';
import '../../core/logging/app_log.dart';
import 'sunshine_run_models.dart';

/// 本机跑步记录的读取结果，区分缺失、损坏和存储不可用。
class SunshineRunStoreReadResult {
  const SunshineRunStoreReadResult({
    this.state,
    this.warning,
    this.corrupt = false,
    this.available = true,
  });

  /// 恢复的有效记录；首次使用、损坏或读取失败时为空。
  final SunshineRunState? state;

  /// 需要向用户说明的存储降级原因。
  final String? warning;

  /// 原记录格式损坏，需要用户明确重试才允许替换。
  final bool corrupt;

  /// 是否成功访问本地存储；记录损坏不代表存储不可用。
  final bool available;
}

/// 阳光跑的本机记录存储，写入失败时保留旧记录并继续内存计算。
class SunshineRunStore {
  SunshineRunStore._();

  static final _log = AppLog.logger('sunshine_run.store');
  static Future<void> _pendingSave = Future.value();
  static const _unavailableWarning = '本地存储暂不可用，修改仅在本次使用中生效';
  static const _corruptWarning = '本地跑步记录损坏，原文件已保留，当前计算仍可使用';

  /// 测试时直接替换阳光跑目录，不追加小程序目录名。
  @visibleForTesting
  static Directory? debugDirectory;

  static Future<Directory> _directory(Directory? override) async {
    final Directory directory;
    if (override != null) {
      directory = override;
    } else {
      final base = await AppDirectories.applicationDocuments();
      directory = Directory(
        '${base.path}${Platform.pathSeparator}sunshine_run',
      );
    }
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static File _file(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}state.json');

  /// 恢复记录；首次使用没有警告，损坏记录原样保留。
  static Future<SunshineRunStoreReadResult> read() {
    final directoryOverride = debugDirectory;
    return _log.inSpan(() async {
      try {
        final directory = await _directory(directoryOverride);
        return (await _readFile(_file(directory))).result;
      } catch (error, stackTrace) {
        return _unavailable(
          error,
          stackTrace,
          event: 'storage.unavailable',
          reason: 'sunshine_run_storage_unavailable',
        );
      }
    });
  }

  static Future<_StateFileRead> _readFile(File file) async {
    final List<int> bytes;
    try {
      final type = await FileSystemEntity.type(file.path);
      if (type == FileSystemEntityType.notFound) {
        return const _StateFileRead(SunshineRunStoreReadResult());
      }
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('阳光跑记录不是普通文件', file.path);
      }
      bytes = await file.readAsBytes();
    } catch (error, stackTrace) {
      return _StateFileRead(
        _unavailable(
          error,
          stackTrace,
          event: 'state.read_failed',
          reason: 'sunshine_run_state_read_failed',
        ),
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('阳光跑记录必须是对象');
      }
      return _StateFileRead(
        SunshineRunStoreReadResult(state: SunshineRunState.fromJson(decoded)),
        bytes: bytes,
      );
    } catch (error, stackTrace) {
      AppLog.reportOutcome('degraded', reason: 'sunshine_run_state_corrupt');
      _log.warning(
        'state.corrupt',
        error: error,
        stackTrace: stackTrace,
        fields: {
          'reason_code': 'sunshine_run_state_corrupt',
          'outcome': 'memory_fallback',
        },
      );
      return _StateFileRead(
        const SunshineRunStoreReadResult(
          warning: _corruptWarning,
          corrupt: true,
        ),
        bytes: bytes,
      );
    }
  }

  static SunshineRunStoreReadResult _unavailable(
    Object error,
    StackTrace stackTrace, {
    required String event,
    required String reason,
    String? stage,
  }) {
    AppLog.reportOutcome('degraded', reason: reason);
    _log.warning(
      event,
      error: error,
      stackTrace: stackTrace,
      fields: {
        'reason_code': reason,
        'outcome': 'memory_fallback',
        'stage': ?stage,
      },
    );
    return const SunshineRunStoreReadResult(
      warning: _unavailableWarning,
      available: false,
    );
  }

  /// 按调用顺序保存；只有用户明确重试时才传入 [replaceCorrupt]。
  ///
  /// 显式重试会先备份已有文件，包括先前不可读但现在可读的有效记录；
  /// 损坏记录使用 `.corrupt`，有效记录使用 `.backup`，失败不替换原件。
  static Future<bool> save(
    SunshineRunState state, {
    bool replaceCorrupt = false,
  }) {
    final directoryOverride = debugDirectory;
    final operation = _pendingSave.then(
      (_) => _log.inSpan(
        () => _save(state, directoryOverride, replaceCorrupt: replaceCorrupt),
      ),
    );
    // 即使某次保存意外抛错，也不能让后续保存一直卡在失败的队列上。
    _pendingSave = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _unavailable(
          error,
          stackTrace,
          event: 'state.queue_failed',
          reason: 'sunshine_run_state_queue_failed',
        );
      },
    );
    return operation;
  }

  static Future<bool> _save(
    SunshineRunState state,
    Directory? directoryOverride, {
    required bool replaceCorrupt,
  }) async {
    File? temporary;
    var stage = 'directory';
    try {
      final directory = await _directory(directoryOverride);
      final file = _file(directory);
      stage = 'existing_record';
      final existing = await _readFile(file);
      if (!existing.result.available) return false;
      if (existing.result.corrupt && !replaceCorrupt) {
        AppLog.reportOutcome('degraded', reason: 'sunshine_run_state_corrupt');
        return false;
      }

      stage = 'temporary_write';
      final candidate = File('${file.path}.tmp');
      final temporaryType = await FileSystemEntity.type(
        candidate.path,
        followLinks: false,
      );
      if (temporaryType != FileSystemEntityType.notFound &&
          temporaryType != FileSystemEntityType.file) {
        throw FileSystemException('阳光跑临时记录不是普通文件', candidate.path);
      }
      temporary = candidate;
      await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);

      if (replaceCorrupt && existing.bytes != null) {
        final kind = existing.result.corrupt ? 'corrupt' : 'backup';
        stage = existing.result.corrupt ? 'corrupt_backup' : 'valid_backup';
        await _backupOriginal(file, existing.bytes!, kind: kind);
      }
      stage = 'replace_record';
      // 同目录重命名替换；不先删除目标，避免替换失败破坏旧记录。
      await temporary.rename(file.path);
      temporary = null;
      return true;
    } catch (error, stackTrace) {
      _unavailable(
        error,
        stackTrace,
        event: 'state.save_failed',
        reason: 'sunshine_run_state_save_failed',
        stage: stage,
      );
      return false;
    } finally {
      if (temporary != null) await _removeTemporary(temporary);
    }
  }

  static Future<void> _backupOriginal(
    File file,
    List<int> bytes, {
    required String kind,
  }) async {
    var backup = File('${file.path}.$kind');
    var suffix = DateTime.now().microsecondsSinceEpoch;
    while (await FileSystemEntity.type(backup.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      backup = File('${file.path}.$kind.${suffix++}');
    }
    // 独占创建防止覆盖已有备份；备份完整落盘后才允许替换原记录。
    await backup.create(exclusive: true);
    try {
      await backup.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await _removeTemporary(backup);
      rethrow;
    }
  }

  static Future<void> _removeTemporary(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error, stackTrace) {
      _log.warning(
        'state.temporary_cleanup_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'reason_code': 'sunshine_run_temporary_cleanup_failed'},
      );
    }
  }
}

class _StateFileRead {
  const _StateFileRead(this.result, {this.bytes});

  final SunshineRunStoreReadResult result;
  final List<int>? bytes;
}
