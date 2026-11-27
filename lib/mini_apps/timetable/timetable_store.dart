import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../core/app_directories.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/diagnostic_error.dart';
import '../../core/refresh/silent_refresh.dart';
import 'timetable_colors.dart';
import 'timetable_models.dart';
import 'timetable_multi_models.dart';
import 'timetable_overrides.dart';

/// 课表本地 JSON 存储：`ApplicationDocuments/timetable/`。
class TimetableStore {
  TimetableStore._();
  static final _log = AppLog.logger('timetable.store');
  static final _batchZoneKey = Object();
  static final _scheduleZoneKey = Object();
  static Future<void> _batchCommits = Future.value();
  static int _pendingWrites = 0;
  static int _stagingBatches = 0;
  static Completer<void>? _stagingIdle;
  static Directory? _cachedAppDir;
  static Future<Directory?>? _cachedAppDirFuture;

  static _TimetableWriteBatch? get _currentBatch =>
      Zone.current[_batchZoneKey] as _TimetableWriteBatch?;

  static bool get _useBackgroundIo =>
      !Platform.environment.containsKey('FLUTTER_TEST') ||
      debugPrepareBatchInBackground;

  static Future<T> _serializeWrite<T>(Future<T> Function() action) {
    _pendingWrites++;
    final result = _batchCommits.then((_) => action());
    void finish(Object? _) {
      if (_pendingWrites > 0) _pendingWrites--;
    }

    _batchCommits = result.then<void>(finish, onError: finish);
    return result;
  }

  static void _enterBatchStaging() {
    _stagingBatches++;
    _stagingIdle ??= Completer<void>();
  }

  static void _leaveBatchStaging() {
    if (_stagingBatches > 0) _stagingBatches--;
    if (_stagingBatches == 0) {
      final idle = _stagingIdle;
      _stagingIdle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }

  static Future<T> _runStandaloneWrite<T>(Future<T> Function() action) {
    if (_stagingBatches == 0) {
      return _serializeWrite(action);
    }
    return () async {
      while (_stagingBatches > 0) {
        await _stagingIdle?.future;
      }
      return await _serializeWrite(action);
    }();
  }

  /// 等待在途后台写入与批处理暂存完成（读取或批量准备前使用）。
  static Future<void> _drainPendingWrites({bool waitForStaging = true}) async {
    while (_pendingWrites > 0 || (waitForStaging && _stagingBatches > 0)) {
      if (_pendingWrites > 0) {
        await _batchCommits;
      }
      if (waitForStaging && _stagingBatches > 0) {
        await _stagingIdle?.future;
      }
    }
  }

  /// 当前作用域指向的课表 id（默认为 [kDefaultScheduleId]）。
  static String get currentScheduleId =>
      (Zone.current[_scheduleZoneKey] as String?) ?? kDefaultScheduleId;

  /// 在指定课表存储作用域内执行读写；全局文件（settings/index/sync_state）仍在根目录。
  static Future<T> withScheduleScope<T>(
    String? scheduleId,
    Future<T> Function() action,
  ) {
    final normalized = (scheduleId == null || scheduleId.trim().isEmpty)
        ? kDefaultScheduleId
        : sanitizeScheduleId(scheduleId);
    if (normalized == currentScheduleId) return action();
    return runZoned(action, zoneValues: {_scheduleZoneKey: normalized});
  }

  /// 将回调中等待完成的 JSON 保存作为一个批次提交。
  /// 回调仅准备存储数据；全部准备成功才替换文件，提交失败时恢复已替换的旧文件。
  /// 仅保证当前进程中的失败回退，不承诺进程崩溃时的多文件原子性。
  static Future<void> writeBatch(Future<void> Function() stageWrites) async {
    if (_currentBatch != null) {
      await stageWrites();
      return;
    }
    final useBg = _useBackgroundIo;
    if (useBg) {
      await _drainPendingWrites(waitForStaging: false);
    }
    final batch = _TimetableWriteBatch();
    var enteredStaging = false;
    try {
      if (useBg) {
        _enterBatchStaging();
        enteredStaging = true;
      }
      await runZoned(stageWrites, zoneValues: {_batchZoneKey: batch});
      if (!useBg) {
        await batch.commit();
      } else {
        final commitFuture = _serializeWrite(() => batch.commit());
        _leaveBatchStaging();
        enteredStaging = false;
        await commitFuture;
      }
    } on TimetablePersistenceException {
      rethrow;
    } catch (error, stackTrace) {
      _log.error(
        'batch.write_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    } finally {
      if (enteredStaging) _leaveBatchStaging();
      batch.closed = true;
    }
  }

  static const _snapshotFile = 'snapshot.json';
  static const _settingsFile = 'settings.json';
  static const _schedulesIndexFile = 'schedules_index.json';
  static const _schedulesFolder = 'schedules';

  /// 全局文件（不随课表作用域切分，始终存放在 `timetable/` 根目录）。
  static const Set<String> _globalFiles = {
    _settingsFile,
    _reminderIntroFile,
    _schedulesIndexFile,
    'sync_state.json',
  };

  /// 单个课表目录下的隔离文件清单（归档/清理时复用）。
  static const List<String> _perScheduleFiles = [
    _snapshotFile,
    _manualFile,
    _overridesFile,
    courseColorsFile,
    'schedule_events.json',
    'course_edits.json',
    'day_swaps.json',
    'exam_overrides.json',
    'sync_changes.json',
  ];

  /// 提醒说明的已读标记独立保存，不改变 settings.json 的键集合。
  static const _reminderIntroFile = 'reminder_intro_seen';

  /// 是否已经展示首次启用说明；存储不可用时按未读处理。
  static Future<bool> readReminderIntroSeen() async {
    try {
      final file = await _file(_reminderIntroFile);
      return file != null &&
          file.existsSync() &&
          file.readAsStringSync() == '1';
    } catch (error, stackTrace) {
      _log.warning(
        'reminder_intro.read_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 记录首次提醒说明已展示，写入失败不影响开关与通知功能。
  static Future<void> saveReminderIntroSeen() {
    if (!_useBackgroundIo) {
      return _saveReminderIntroSeenSync();
    }
    return _runStandaloneWrite(() async {
      try {
        final file = await _file(_reminderIntroFile);
        if (file == null) return;
        final path = file.path;
        await Isolate.run(() => File(path).writeAsStringSync('1', flush: true));
      } catch (error, stackTrace) {
        _log.warning(
          'reminder_intro.write_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  static Future<void> _saveReminderIntroSeenSync() async {
    try {
      final file = await _file(_reminderIntroFile);
      file?.writeAsStringSync('1', flush: true);
    } catch (error, stackTrace) {
      _log.warning(
        'reminder_intro.write_failed',
        error: error,
        stackTrace: stackTrace,
      );
      // 无存储时保持提醒功能可用。
    }
  }

  /// 手动课程独立存储：同步/清教务缓存/退出登录都不触碰。
  static const _manualFile = 'manual_courses.json';

  /// 测试用：指定存储目录（flutter_test 下默认无磁盘存储）。
  @visibleForTesting
  static Directory? debugDirectory;

  /// 测试用：在批次替换第 [index] 个文件前模拟故障，验证已替换文件的回退。
  @visibleForTesting
  static void Function(int index)? debugBeforeBatchReplace;

  /// widget 测试的 FakeAsync 不推进后台 IO；专门的存储回归可开启生产后台路径。
  @visibleForTesting
  static bool debugPrepareBatchInBackground = false;

  /// widget 测试默认在当前 isolate 同步批量读盘以兼容 FakeAsync；专门回归可开启后台 Isolate 读盘。
  @visibleForTesting
  static bool debugReadBatchInBackground = false;

  /// 测试观察每次批量读盘实际读取的文件名列表。
  @visibleForTesting
  static void Function(List<String> fileNames)? debugOnBatchRead;

  static Future<Directory?> _dir() async {
    try {
      final override = debugDirectory;
      if (override != null) {
        if (!override.existsSync()) override.createSync(recursive: true);
        return override;
      }
      // flutter_test 无可靠平台通道；直接退化，避免 timeout Timer 残留。
      if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
      final cached = _cachedAppDir;
      if (cached != null) return cached;
      final inFlight = _cachedAppDirFuture;
      if (inFlight != null) return await inFlight;
      final future = () async {
        try {
          final base = await AppDirectories.applicationDocuments();
          final dir = Directory(
            '${base.path}${Platform.pathSeparator}timetable',
          );
          if (!dir.existsSync()) dir.createSync(recursive: true);
          _cachedAppDir = dir;
          return dir;
        } finally {
          _cachedAppDirFuture = null;
        }
      }();
      _cachedAppDirFuture = future;
      return await future;
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      return null;
    }
  }

  static Future<File?> _file(
    String name, {
    bool forWrite = false,
    String? scheduleId,
  }) async {
    final dir = await _dir();
    if (dir == null) {
      if (forWrite) checkStorageAvailable();
      return null;
    }
    final targetId = _globalFiles.contains(name)
        ? kDefaultScheduleId
        : (scheduleId == null || scheduleId.trim().isEmpty
              ? currentScheduleId
              : sanitizeScheduleId(scheduleId));
    if (targetId == kDefaultScheduleId) {
      return File('${dir.path}${Platform.pathSeparator}$name');
    }
    final scheduleDir = Directory(
      '${dir.path}${Platform.pathSeparator}$_schedulesFolder${Platform.pathSeparator}$targetId',
    );
    if (forWrite && !scheduleDir.existsSync()) {
      try {
        scheduleDir.createSync(recursive: true);
      } catch (error, stackTrace) {
        throw TimetablePersistenceException(
          cause: error,
          causeStackTrace: stackTrace,
        );
      }
    }
    return File('${scheduleDir.path}${Platform.pathSeparator}$name');
  }

  /// 课表目录下的文件；读取无存储时返回 null，关键写入传 [forWrite] 时反馈失败。
  /// 默认无平台存储的 widget 测试仍返回 null，显式指定测试目录时按真机处理。
  static Future<File?> fileFor(
    String name, {
    bool forWrite = false,
    String? scheduleId,
  }) => _file(name, forWrite: forWrite, scheduleId: scheduleId);

  static Future<Map<String, dynamic>> _readJson(String name) =>
      _log.inSpan(() async {
        try {
          final file = await _file(name);
          if (file == null) return {};
          final staged = _currentBatch?.read(file);
          if (staged != null) return staged;
          if (Platform.environment.containsKey('FLUTTER_TEST')) {
            if (!file.existsSync()) return {};
            final decoded = jsonDecode(file.readAsStringSync());
            return decoded is Map<String, dynamic> ? decoded : {};
          }
          if (!await file.exists()) return {};
          // 解析放到后台 isolate，避免启动时阻塞主线程。
          final decoded = await compute(_decode, await file.readAsString());
          return decoded is Map<String, dynamic> ? decoded : {};
        } catch (error, stackTrace) {
          _log.warning(
            'json.read_failed',
            fields: {'file_kind': name},
            error: error,
            stackTrace: stackTrace,
          );
          return {};
        }
      });

  static Object? _decode(String raw) => jsonDecode(raw);

  static Future<void> _writeJson(String name, Map<String, dynamic> data) =>
      _log.inSpan(() => writeNamedJsonFile(name, data));

  static Future<TimetableSnapshot?> readSnapshot() async {
    final json = await _readJson(_snapshotFile);
    return parseSnapshot(json);
  }

  /// 从已解码 JSON 解析课表快照。
  static TimetableSnapshot? parseSnapshot(Map<String, dynamic> json) {
    if (json.isEmpty) return null;
    try {
      return TimetableSnapshot.fromJson(json);
    } catch (error, stackTrace) {
      _log.warning(
        'snapshot.parse_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static Future<void> saveSnapshot(TimetableSnapshot snapshot) =>
      _writeJson(_snapshotFile, snapshot.toJson());

  static Future<TimetableSettings> readSettings() async {
    final json = await _readJson(_settingsFile);
    return parseSettings(json);
  }

  /// 从已解码 JSON 解析课表设置。
  static TimetableSettings parseSettings(Map<String, dynamic> json) {
    if (json.isEmpty) return const TimetableSettings();
    try {
      return TimetableSettings.fromJson(json);
    } catch (error, stackTrace) {
      _log.warning(
        'settings.parse_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const TimetableSettings();
    }
  }

  static Future<void> saveSettings(TimetableSettings settings) =>
      _writeJson(_settingsFile, settings.toJson());

  /// settings.json 中由教务同步写入的学期元数据键。
  static const termSettingKeys = <String>{
    'termCode',
    'termStartDate',
    'maxWeeks',
    'termStartFromJwxt',
  };

  /// 原样读取 settings.json（不经 [TimetableSettings] 解析/钳制）。
  static Future<Map<String, dynamic>> readRawSettings() async {
    final file = await _file(_settingsFile);
    return file == null ? {} : _readRawSync(file);
  }

  /// 原样写回 settings.json。
  static Future<void> writeRawSettings(Map<String, dynamic> raw) =>
      writeNamedJsonFile(_settingsFile, raw);

  // settings.json 很小：同步读写、当前 isolate 解码（不走 compute）。
  // 读-改-写在一段同步代码内完成，不让出事件循环，连续修改不会互相覆盖。
  static Map<String, dynamic> _readRawSync(
    File file, {
    bool forWrite = false,
  }) => readJsonFile(file, forWrite: forWrite);

  /// 读取课表 JSON，优先读取同批次暂存值；合并保存时传 [forWrite]，读取失败不覆盖原文件。
  /// 供同目录的 [ScheduleStore] 复用；普通读取失败按空数据降级。
  static Map<String, dynamic> readJsonFile(File file, {bool forWrite = false}) {
    try {
      final batch = _currentBatch;
      final staged = batch?.read(file);
      if (staged != null) return staged;
      if (batch != null) {
        final type = FileSystemEntity.typeSync(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          batch.recordOriginalBytes(file, null);
          return {};
        }
        if (type != FileSystemEntityType.file) {
          throw const TimetablePersistenceException();
        }
        final bytes = file.readAsBytesSync();
        batch.recordOriginalBytes(file, bytes);
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) return decoded;
        throw const FormatException();
      }
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
      throw const FormatException();
    } on FormatException catch (error, stackTrace) {
      _log.warning('json.read_failed', error: error, stackTrace: stackTrace);
      _backupCorruptSync(file, forWrite: forWrite);
      return {};
    } catch (error, stackTrace) {
      _log.warning(
        'settings.raw_read_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (forWrite) throw const TimetablePersistenceException();
      return {};
    }
  }

  static void _backupCorruptSync(File file, {required bool forWrite}) {
    try {
      final batch = _currentBatch;
      if (batch != null) {
        batch.preserveCorrupt(file);
        return;
      }
      var target = File('${file.path}.corrupt');
      if (target.existsSync()) {
        target = File(
          '${file.path}.corrupt.${DateTime.now().microsecondsSinceEpoch}',
        );
      }
      file.renameSync(target.path);
    } catch (error, stackTrace) {
      _log.warning(
        'corrupt_backup.failed',
        error: error,
        stackTrace: stackTrace,
      );
      // 启动读取可以降级；保存时必须先保住原文件，不能用空数据覆盖备份失败的内容。
      if (forWrite) throw const TimetablePersistenceException();
    }
  }

  /// 原子保存课表 JSON；位于 [writeBatch] 内时只暂存，提交时统一替换文件。
  /// 供同目录的 [ScheduleStore] 复用，不绕过存储错误反馈。
  static void writeJsonFile(File file, Map<String, dynamic> raw) {
    try {
      final batch = _currentBatch;
      if (batch != null) {
        batch.stage(file, raw);
      } else {
        _writeRawAtomicSync(file, raw);
      }
    } on TimetablePersistenceException {
      rethrow;
    } catch (error, stackTrace) {
      _log.error(
        'json.write_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// 异步原子写课表 JSON：批次内仍只暂存；独立写入时在后台 Isolate 完成编码刷盘与替换。
  static Future<void> writeJsonFileAsync(File file, Map<String, dynamic> raw) {
    final batch = _currentBatch;
    if (batch != null || !_useBackgroundIo) {
      writeJsonFile(file, raw);
      return Future.value();
    }
    return _runStandaloneWrite(() => _writeFileInIsolate(file, raw));
  }

  /// 按文件名异步原子写课表 JSON：在后台写队列内解析路径，避免与并发 `writeBatch` 竞态。
  static Future<void> writeNamedJsonFile(
    String name,
    Map<String, dynamic> raw,
  ) {
    final batch = _currentBatch;
    if (batch != null || !_useBackgroundIo) {
      return () async {
        final file = await _file(name, forWrite: true);
        if (file != null) writeJsonFile(file, raw);
      }();
    }
    final scopeId = currentScheduleId;
    return _runStandaloneWrite(() async {
      final file = await _file(name, forWrite: true, scheduleId: scopeId);
      if (file == null) return;
      await _writeFileInIsolate(file, raw);
    });
  }

  static Future<void> _writeFileInIsolate(
    File file,
    Map<String, dynamic> raw,
  ) async {
    try {
      final encoded = jsonEncode(raw);
      final path = file.path;
      await Isolate.run(() => _writeAtomicInIsolate(path, encoded));
    } on TimetablePersistenceException {
      rethrow;
    } catch (error, stackTrace) {
      _log.error(
        'json.write_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// 读-改-写课表 JSON：批次内同步合并；独立写入时在后台 Isolate 读盘/备份/刷盘，避免阻塞 UI 线程。
  static Future<void> modifyJsonFile(
    File file,
    bool Function(Map<String, dynamic> raw) edit,
  ) {
    final batch = _currentBatch;
    if (batch != null || !_useBackgroundIo) {
      final raw = readJsonFile(file, forWrite: true);
      if (edit(raw)) writeJsonFile(file, raw);
      return Future.value();
    }
    return _runStandaloneWrite(() => _modifyFileInIsolate(file, edit));
  }

  /// 按文件名读-改-写课表 JSON：在后台写队列内解析路径，与并发 `writeBatch` 严格串行。
  static Future<void> modifyNamedJsonFile(
    String name,
    bool Function(Map<String, dynamic> raw) edit,
  ) {
    final batch = _currentBatch;
    if (batch != null || !_useBackgroundIo) {
      return () async {
        final file = await _file(name, forWrite: true);
        if (file == null) return;
        final raw = readJsonFile(file, forWrite: true);
        if (edit(raw)) writeJsonFile(file, raw);
      }();
    }
    final scopeId = currentScheduleId;
    return _runStandaloneWrite(() async {
      final file = await _file(name, forWrite: true, scheduleId: scopeId);
      if (file == null) return;
      await _modifyFileInIsolate(file, edit);
    });
  }

  static Future<void> _modifyFileInIsolate(
    File file,
    bool Function(Map<String, dynamic> raw) edit,
  ) async {
    try {
      final path = file.path;
      final read = await Isolate.run(() => _readForWriteInIsolate(path));
      if (read.corruptWarning) {
        _log.warning('json.read_failed');
      }
      final raw = read.raw;
      if (!edit(raw)) return;
      final encoded = jsonEncode(raw);
      await Isolate.run(() => _writeAtomicInIsolate(path, encoded));
    } on TimetablePersistenceException {
      rethrow;
    } catch (error, stackTrace) {
      _log.error(
        'json.write_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// 对原始 Map 做编辑；[edit] 返回 true 才写盘。
  static Future<void> _editRawSettings(
    bool Function(Map<String, dynamic> raw) edit,
  ) => modifyNamedJsonFile(_settingsFile, edit);

  /// 逐键比较 [previous] 与 [next]，只把变化的键写入原始 settings.json；
  /// 未变化的键（含钳制前的原值）与未知键保持不变。
  static Future<void> mergeSettingsChanges(
    TimetableSettings previous,
    TimetableSettings next,
  ) {
    final before = previous.toJson();
    final after = next.toJson();
    return _editRawSettings((raw) {
      var changed = false;
      for (final key in {...before.keys, ...after.keys}) {
        if (before.containsKey(key) == after.containsKey(key) &&
            before[key] == after[key]) {
          continue;
        }
        changed = true;
        if (after.containsKey(key)) {
          raw[key] = after[key];
        } else {
          raw.remove(key);
        }
      }
      return changed;
    });
  }

  /// 同步成功后把 [settings] 的学期四键合并进原始 settings.json：
  /// 只覆盖这四个键，其他键原样保留；与磁盘值一致时不写盘。
  static Future<void> mergeTermSettings(TimetableSettings settings) {
    final json = settings.toJson();
    return _editRawSettings((raw) {
      var changed = false;
      for (final key in termSettingKeys) {
        if (json.containsKey(key)) {
          if (!raw.containsKey(key) || raw[key] != json[key]) {
            raw[key] = json[key];
            changed = true;
          }
        } else if (raw.containsKey(key)) {
          raw.remove(key);
          changed = true;
        }
      }
      return changed;
    });
  }

  /// 仅移除学期相关键；periodHeight 原值、开关与未知键全部保留。
  /// 文件不存在或不含学期键时不写盘。
  static Future<void> removeTermSettingKeys() => _editRawSettings((raw) {
    if (!raw.keys.any(termSettingKeys.contains)) return false;
    raw.removeWhere((k, _) => termSettingKeys.contains(k));
    return true;
  });

  /// 手动课程文件版本。
  static const int manualSchemaVersion = 2;

  static Future<List<Course>> readManualCourses() async {
    final json = await _readJson(_manualFile);
    return parseManualCourses(json);
  }

  /// 从已解码 JSON 解析手动课程。
  static List<Course> parseManualCourses(Map<String, dynamic> json) {
    final list = json['courses'];
    if (list is! List) return [];
    final result = <Course>[];
    var skippedCount = 0;
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final item in list) {
      try {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('手动课程条目不是对象');
        }
        result.add(Course.fromJson(item).copyWith(source: CourseSource.manual));
      } catch (error, stackTrace) {
        skippedCount++;
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (skippedCount > 0) {
      AppLog.reportOutcome('degraded', reason: 'manual_course_parse_failed');
      SilentRefresh.degradeCurrent(reason: 'manual_course_parse_failed');
      _log.warning(
        'manual_courses.read_degraded',
        fields: {
          'file_kind': _manualFile,
          'skipped_count': skippedCount,
          'count': result.length,
          'outcome': 'degraded',
        },
        error: firstError,
        stackTrace: firstStackTrace,
      );
    }
    return result;
  }

  /// 合并写：保留文件里的未知顶层键，以及同 id 课程条目里的未知键。
  /// v2：课程新增可选 colorIndex / assignedColorIndex（0..15）；旧文件缺字段按 null 读取。
  static Future<void> saveManualCourses(List<Course> courses) =>
      modifyNamedJsonFile(_manualFile, (raw) {
        final oldById = <String, Map<String, dynamic>>{};
        final old = raw['courses'];
        if (old is List) {
          for (final item in old) {
            if (item is Map<String, dynamic>) oldById['${item['id']}'] = item;
          }
        }
        raw['schemaVersion'] = manualSchemaVersion;
        raw['courses'] = [
          for (final c in courses)
            {...?oldById[c.id], ...c.toJson()}..removeWhere(
              (k, _) =>
                  (k == 'colorIndex' && c.colorIndex == null) ||
                  (k == 'assignedColorIndex' && c.assignedColorIndex == null) ||
                  (k == 'credit' && c.credit == null),
            ),
        ];
        return true;
      });

  /// 教务课调课记录（spec §13.2 / jwxt §3.2）：同步、解绑都不触碰。
  static const _overridesFile = 'overrides.json';
  static const int overridesSchemaVersion = 1;

  /// 读取调课记录；解析不了的条目跳过（写回时原样保留）。
  static Future<List<SlotOverride>> readOverrides() async {
    final file = await _file(_overridesFile);
    if (file == null) return [];
    return parseOverrides(_readRawSync(file));
  }

  /// 从已解码 JSON 解析调课记录。
  static List<SlotOverride> parseOverrides(Map<String, dynamic> raw) {
    final list = raw['overrides'];
    if (list is! List) return [];
    return [for (final item in list) ?SlotOverride.tryParse(item)];
  }

  /// 合并写：保留文件里的未知顶层键与解析不了的条目，`overrides` 换成 [list]。
  static Future<void> saveOverrides(List<SlotOverride> list) =>
      modifyNamedJsonFile(_overridesFile, (raw) {
        final old = raw['overrides'];
        final unknown = [
          if (old is List)
            for (final item in old)
              if (SlotOverride.tryParse(item) == null) item,
        ];
        raw['schemaVersion'] = overridesSchemaVersion;
        raw['overrides'] = [for (final o in list) o.toJson(), ...unknown];
        return true;
      });

  /// 全学期配色表（[TimetableController.courseColorMap]）：
  /// `{schemaVersion: 1, scheme: <方案名，如 soft>, map: {规范化课名: 色号}}`。
  /// 只在重算配色（教务同步、手动课增删、换配色方案）后写；重启直接读，避免惰性
  /// 重建时因调课/编辑改了相邻关系而换色。同步/解绑/清教务缓存都不删它。
  static const courseColorsFile = 'course_colors.json';
  static const int courseColorsSchemaVersion = 2;

  /// 读配色表。文件不存在、JSON 坏、版本/方案名不认识、map 不是 {String: 0..15}
  /// 任一情况 → null（调用方重建并落盘）。不抛异常。
  static Future<StoredCourseColors?> readCourseColors() async {
    final file = await _file(courseColorsFile);
    if (file == null) return null;
    return parseCourseColors(_readRawSync(file));
  }

  /// 从已解码 JSON 解析全学期配色表。
  static StoredCourseColors? parseCourseColors(Map<String, dynamic> raw) {
    if (raw['schemaVersion'] != courseColorsSchemaVersion) return null;
    final schemeName = raw['scheme'];
    CoursePaletteScheme? scheme;
    for (final s in CoursePaletteScheme.values) {
      if (s.name == schemeName) scheme = s;
    }
    if (scheme == null) return null;
    final map = raw['map'];
    if (map is! Map) return null;
    final out = <String, int>{};
    for (final e in map.entries) {
      final v = e.value;
      if (e.key is! String || v is! int || v < 0 || v >= kCoursePaletteSize) {
        return null;
      }
      out[e.key as String] = v;
    }
    return StoredCourseColors(scheme, out);
  }

  /// 合并写：保留文件里的未知顶层键（含 [userColorsKey]），替换 schemaVersion /
  /// scheme / map。原子写（临时文件 + rename）。
  static Future<void> saveCourseColors(
    CoursePaletteScheme scheme,
    Map<String, int> map,
  ) => modifyNamedJsonFile(courseColorsFile, (raw) {
    raw['schemaVersion'] = courseColorsSchemaVersion;
    raw['scheme'] = scheme.name;
    raw['map'] = Map<String, int>.of(map);
    return true;
  });

  /// item 9：用户自选课程色，存在 course_colors.json 的顶层键
  /// `userColors: {课程 id: {argb: <原始 ARGB>, user: true}}`。旧文件没有这个键 → 空表，
  /// 无需迁移；深色色值显示时换算，不另存。
  static const userColorsKey = 'userColors';

  /// 读用户自选色（只认 user == true 且 argb 为 int 的项；坏项跳过）。不抛异常。
  static Future<Map<String, int>> readUserCourseColors() async {
    final file = await _file(courseColorsFile);
    if (file == null) return {};
    return parseUserCourseColors(_readRawSync(file));
  }

  /// 从已解码 JSON 解析用户自选课程色。
  static Map<String, int> parseUserCourseColors(Map<String, dynamic> raw) {
    final userRaw = raw[userColorsKey];
    if (userRaw is! Map) return {};
    final out = <String, int>{};
    for (final e in userRaw.entries) {
      final v = e.value;
      if (e.key is String &&
          v is Map &&
          v['user'] == true &&
          v['argb'] is int) {
        out[e.key as String] = (v['argb'] as int) | 0xFF000000;
      }
    }
    return out;
  }

  /// 合并写用户自选色（保留 scheme / map 等其他键），原子写。
  static Future<void> saveUserCourseColors(Map<String, int> colors) =>
      modifyNamedJsonFile(courseColorsFile, (raw) {
        raw[userColorsKey] = {
          for (final e in colors.entries)
            e.key: {'argb': e.value, 'user': true},
        };
        return true;
      });

  /// 最近成功保存的自定义色（原始 ARGB 列表，最多 6，新的在前）。
  static const recentCustomColorsKey = 'recentCustomColors';
  static const int maxRecentCustomColors = 6;

  /// 读最近自定义色；坏项跳过。不抛异常。
  static Future<List<int>> readRecentCustomColors() async {
    final file = await _file(courseColorsFile);
    if (file == null) return const [];
    final raw = _readRawSync(file)[recentCustomColorsKey];
    if (raw is! List) return const [];
    final out = <int>[];
    for (final v in raw) {
      if (v is int) {
        out.add(v | 0xFF000000);
      } else if (v is num) {
        out.add(v.toInt() | 0xFF000000);
      }
      if (out.length >= maxRecentCustomColors) break;
    }
    return out;
  }

  /// 把一次成功保存的自定义色插到最近列表前（去重，最多 [maxRecentCustomColors]）。
  static Future<void> pushRecentCustomColor(int argb) =>
      modifyNamedJsonFile(courseColorsFile, (raw) {
        final color = argb | 0xFF000000;
        final prev = <int>[];
        final existing = raw[recentCustomColorsKey];
        if (existing is List) {
          for (final v in existing) {
            final n = v is int ? v : (v is num ? v.toInt() : null);
            if (n == null) continue;
            final a = n | 0xFF000000;
            if (a == color) continue;
            prev.add(a);
          }
        }
        raw[recentCustomColorsKey] = [
          color,
          ...prev.take(maxRecentCustomColors - 1),
        ];
        return true;
      });

  /// 先写同目录临时文件再 rename，写到一半崩溃不会留下半个 JSON。
  static void _writeRawAtomicSync(File file, Map<String, dynamic> raw) {
    final tmp = File('${file.path}.tmp');
    try {
      tmp.writeAsStringSync(jsonEncode(raw), flush: true);
      tmp.renameSync(file.path);
    } catch (error, stackTrace) {
      _log.error(
        'json.write_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (error, stackTrace) {
        _log.warning(
          'temporary_cleanup.failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// 测试缺少平台存储时继续降级；真机关键保存必须向调用方反馈失败。
  static void checkStorageAvailable() {
    if (debugDirectory != null ||
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      throw const TimetablePersistenceException();
    }
  }

  /// 读取多课表索引；首次运行尚未建索引时返回 null。
  static Future<SchedulesIndex?> readSchedulesIndex() async {
    final json = await _readJson(_schedulesIndexFile);
    return parseSchedulesIndex(json);
  }

  /// 从已解码 JSON 解析多课表索引。
  static SchedulesIndex? parseSchedulesIndex(Map<String, dynamic> json) {
    if (json.isEmpty) return null;
    try {
      return SchedulesIndex.fromJson(json);
    } catch (error, stackTrace) {
      _log.warning(
        'schedules_index.parse_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 一次批量读取当前作用域所需的全部本地 JSON，避免冷启动串行多次读盘与多次 compute。
  static Future<TimetableScopeBundle> readScopeBundle({
    required String initialScheduleId,
    required bool resolvePrimaryFromIndex,
    bool readSchedulesIndex = true,
    bool includeChangeLog = false,
  }) => _log.inSpan(() async {
    final dir = await _dir();
    if (dir == null) {
      return TimetableScopeBundle.empty(initialScheduleId);
    }
    final batch = _currentBatch;
    if (batch != null) {
      // 处于 writeBatch 中时回退到单次读路径以命中暂存值。
      final idxRaw = readSchedulesIndex
          ? await _readJson(_schedulesIndexFile)
          : <String, dynamic>{};
      final idx = readSchedulesIndex ? parseSchedulesIndex(idxRaw) : null;
      final resolvedId = _resolveScopeIdFromIndex(
        initialScheduleId: initialScheduleId,
        index: idx,
        resolvePrimaryFromIndex: resolvePrimaryFromIndex,
      );
      return await withScheduleScope(resolvedId, () async {
        final fSettings = await _file(_settingsFile);
        final fSyncState = await _file('sync_state.json');
        final fSnapshot = await _file(_snapshotFile);
        final fManual = await _file(_manualFile);
        final fOverrides = await _file(_overridesFile);
        final fColors = await _file(courseColorsFile);
        final fEvents = await _file('schedule_events.json');
        final fEdits = await _file('course_edits.json');
        final fSwaps = await _file('day_swaps.json');
        final fExams = await _file('exam_overrides.json');
        final fChanges = includeChangeLog
            ? await _file('sync_changes.json')
            : null;
        final readFiles = <String>[
          if (readSchedulesIndex) _schedulesIndexFile,
          _settingsFile,
          'sync_state.json',
          _snapshotFile,
          _manualFile,
          _overridesFile,
          courseColorsFile,
          'schedule_events.json',
          'course_edits.json',
          'day_swaps.json',
          'exam_overrides.json',
          if (includeChangeLog) 'sync_changes.json',
        ];
        debugOnBatchRead?.call(readFiles);
        return TimetableScopeBundle(
          resolvedScheduleId: resolvedId,
          schedulesIndex: idxRaw,
          settings: fSettings == null ? {} : readJsonFile(fSettings),
          syncState: fSyncState == null ? {} : readJsonFile(fSyncState),
          snapshot: fSnapshot == null ? {} : await _readJson(_snapshotFile),
          manualCourses: fManual == null ? {} : await _readJson(_manualFile),
          overrides: fOverrides == null ? {} : readJsonFile(fOverrides),
          courseColors: fColors == null ? {} : readJsonFile(fColors),
          scheduleEvents: fEvents == null ? {} : readJsonFile(fEvents),
          courseEdits: fEdits == null ? {} : readJsonFile(fEdits),
          daySwaps: fSwaps == null ? {} : readJsonFile(fSwaps),
          examOverrides: fExams == null ? {} : readJsonFile(fExams),
          syncChanges: fChanges == null ? {} : readJsonFile(fChanges),
          readFiles: readFiles,
        );
      });
    }

    if (_useBackgroundIo || debugReadBatchInBackground) {
      await _drainPendingWrites();
    }
    final rootPath = dir.path;
    final runInBackground =
        !Platform.environment.containsKey('FLUTTER_TEST') ||
        debugReadBatchInBackground;
    final result = runInBackground
        ? await Isolate.run(
            () => _readScopeBundleSync(
              rootPath: rootPath,
              initialScheduleId: initialScheduleId,
              resolvePrimaryFromIndex: resolvePrimaryFromIndex,
              readSchedulesIndex: readSchedulesIndex,
              includeChangeLog: includeChangeLog,
            ),
          )
        : _readScopeBundleSync(
            rootPath: rootPath,
            initialScheduleId: initialScheduleId,
            resolvePrimaryFromIndex: resolvePrimaryFromIndex,
            readSchedulesIndex: readSchedulesIndex,
            includeChangeLog: includeChangeLog,
          );
    for (final w in result.warnings) {
      _log.warning(w.event, fields: {'file_kind': w.fileKind});
    }
    debugOnBatchRead?.call(result.bundle.readFiles);
    return result.bundle;
  });

  /// 保存多课表索引（始终在根目录，支持参与 [writeBatch]）。
  static Future<void> saveSchedulesIndex(SchedulesIndex index) =>
      _writeJson(_schedulesIndexFile, index.toJson());

  /// 将默认课表根目录中的单课表文件复制归档到 `schedules/<targetScheduleId>/`
  /// （如跨学期自动归档旧学期）。目标目录已有 `snapshot.json` 时跳过，避免覆盖已有记录。
  static Future<void> archiveDefaultToSchedule(String targetScheduleId) async {
    final target = sanitizeScheduleId(targetScheduleId);
    if (target == kDefaultScheduleId) return;
    final dir = await _dir();
    if (dir == null) return;
    final existingSnap = await _file(_snapshotFile, scheduleId: target);
    if (existingSnap != null && await existingSnap.exists()) return;
    for (final name in _perScheduleFiles) {
      final src = await _file(name, scheduleId: kDefaultScheduleId);
      if (src == null || !await src.exists()) continue;
      final dst = await _file(name, forWrite: true, scheduleId: target);
      if (dst == null) continue;
      await dst.writeAsBytes(await src.readAsBytes(), flush: true);
    }
  }

  /// 删除指定非默认课表的全部本地存储文件；默认课表禁止通过此接口删除。
  static Future<void> deleteScheduleDirectory(String scheduleId) async {
    final target = sanitizeScheduleId(scheduleId);
    if (target == kDefaultScheduleId) return;
    try {
      final dir = await _dir();
      if (dir == null) {
        checkStorageAvailable();
        return;
      }
      final targetDir = Directory(
        '${dir.path}${Platform.pathSeparator}$_schedulesFolder${Platform.pathSeparator}$target',
      );
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
    } catch (error, stackTrace) {
      _log.error(
        'schedule_dir.delete_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// 清除教务快照（保留手动课程与设置）。
  static Future<void> clearJwxtSnapshot() async {
    try {
      final file = await _file(_snapshotFile, forWrite: true);
      if (file == null) return;
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.directory) {
        throw const TimetablePersistenceException();
      }
      await file.delete();
    } catch (error, stackTrace) {
      _log.error(
        'snapshot.delete_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// 清空整个课表目录（**含手动课程**），仅用于彻底重置。
  static Future<void> clearAll() async {
    try {
      final dir = await _dir();
      if (dir == null) {
        checkStorageAvailable();
        return;
      }
      if (await dir.exists()) await dir.delete(recursive: true);
      if (debugDirectory == null) {
        _cachedAppDir = null;
        _cachedAppDirFuture = null;
      }
    } catch (error, stackTrace) {
      _log.error(
        'storage.delete_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }
}

class _TimetableWriteBatch {
  final Map<String, _PendingTimetableJson> _files = {};
  bool closed = false;

  Map<String, dynamic>? read(File file) {
    _checkOpen();
    final encoded = _files[file.path]?.encoded;
    return encoded == null ? null : jsonDecode(encoded) as Map<String, dynamic>;
  }

  void recordOriginalBytes(File file, List<int>? bytes) {
    _checkOpen();
    _files.putIfAbsent(
      file.path,
      () => _PendingTimetableJson.withOriginal(file, bytes),
    );
  }

  void stage(File file, Map<String, dynamic> raw) {
    _checkOpen();
    final encoded = jsonEncode(raw);
    final pending = _files.putIfAbsent(
      file.path,
      () => _PendingTimetableJson(file),
    );
    pending.encoded = encoded;
  }

  void preserveCorrupt(File file) {
    _checkOpen();
    _files
            .putIfAbsent(file.path, () => _PendingTimetableJson(file))
            .preserveBackup =
        true;
  }

  void _checkOpen() {
    if (closed) throw const TimetablePersistenceException();
  }

  Future<void> commit() async {
    _checkOpen();
    final files = _files.values.where((f) => f.encoded != null).toList();
    if (files.isEmpty) return;
    final useBackground =
        !Platform.environment.containsKey('FLUTTER_TEST') ||
        TimetableStore.debugPrepareBatchInBackground;
    if (useBackground && TimetableStore.debugBeforeBatchReplace == null) {
      final entries = [
        for (var index = 0; index < files.length; index++)
          (
            path: files[index].file.path,
            encoded: files[index].encoded!,
            original: files[index].original,
            preserveBackup: files[index].preserveBackup,
            index: index,
          ),
      ];
      try {
        await Isolate.run(() => _commitBatchInIsolate(entries));
        return;
      } on TimetablePersistenceException {
        rethrow;
      } catch (error, stackTrace) {
        TimetableStore._log.error(
          'batch.write_failed',
          error: error,
          stackTrace: stackTrace,
          errorKind: 'storage_write',
        );
        throw TimetablePersistenceException(
          cause: error,
          causeStackTrace: stackTrace,
        );
      }
    }
    try {
      // 刷盘留在后台 isolate；其返回后再同步校验并完成短暂的原子替换。
      // 校验与替换之间不 await，批次外更新仍不能被旧数据覆盖。
      for (var index = 0; index < files.length; index++) {
        final pending = files[index];
        pending.temporary = File(
          '${pending.file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}.$index',
        );
      }
      for (final pending in files) {
        if (pending.original == null) continue;
        final suffix = pending.preserveBackup ? 'corrupt' : 'rollback';
        var backup = File('${pending.file.path}.$suffix');
        while (FileSystemEntity.typeSync(backup.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          backup = File(
            '${pending.file.path}.$suffix.${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        pending.backup = backup;
      }
      final preparation = [
        for (final pending in files)
          (
            temporary: pending.temporary.path,
            reserved: '${pending.file.path}.tmp',
            encoded: pending.encoded!,
            backup: pending.backup?.path,
            original: pending.original,
          ),
      ];
      if (!useBackground) {
        _prepareBatchFiles(preparation);
      } else {
        await Isolate.run(() => _prepareBatchFiles(preparation));
      }
      for (final pending in files) {
        pending.backupReady = pending.backup != null;
      }
      // 准备期间其他操作可能已保存新内容，只校验原文件；不覆盖更新。
      for (final pending in files) {
        if (!listEquals(
          pending.original,
          _PendingTimetableJson.readOriginal(pending.file),
        )) {
          throw const TimetablePersistenceException();
        }
      }
      for (var index = 0; index < files.length; index++) {
        final pending = files[index];
        TimetableStore.debugBeforeBatchReplace?.call(index);
        pending.temporary.renameSync(pending.file.path);
        pending.replaced = true;
      }
    } catch (error, stackTrace) {
      for (final pending in files.reversed) {
        if (!pending.replaced) continue;
        try {
          if (pending.original == null) {
            pending.file.deleteSync();
          } else {
            pending.backup!.renameSync(pending.file.path);
          }
        } catch (rollbackError, rollbackStackTrace) {
          pending.rollbackFailed = true;
          TimetableStore._log.error(
            'batch.rollback_failed',
            error: rollbackError,
            stackTrace: rollbackStackTrace,
            errorKind: 'storage_write',
          );
        }
      }
      TimetableStore._log.error(
        'batch.write_failed',
        error: error,
        stackTrace: stackTrace,
        errorKind: 'storage_write',
      );
      throw TimetablePersistenceException(
        cause: error,
        causeStackTrace: stackTrace,
      );
    } finally {
      for (final pending in files) {
        _cleanUp(pending.temporary);
        final backup = pending.backup;
        if (backup != null &&
            !pending.rollbackFailed &&
            (!pending.preserveBackup || !pending.backupReady)) {
          _cleanUp(backup);
        }
      }
    }
  }

  static void _cleanUp(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (error, stackTrace) {
      TimetableStore._log.warning(
        'temporary_cleanup.failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

class _PendingTimetableJson {
  _PendingTimetableJson(this.file)
    : original = readOriginal(file),
      temporary = File('${file.path}.tmp');

  _PendingTimetableJson.withOriginal(this.file, this.original)
    : temporary = File('${file.path}.tmp');

  final File file;
  final List<int>? original;
  File temporary;
  String? encoded;
  File? backup;
  bool preserveBackup = false;
  bool backupReady = false;
  bool replaced = false;
  bool rollbackFailed = false;

  static List<int>? readOriginal(File file) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const TimetablePersistenceException();
    }
    return file.readAsBytesSync();
  }
}

void _prepareBatchFiles(
  List<
    ({
      String temporary,
      String reserved,
      String encoded,
      String? backup,
      List<int>? original,
    })
  >
  files,
) {
  for (final file in files) {
    // 旧版临时路径被目录占用时仍反馈存储故障，不绕开既有坏存储判定。
    if (FileSystemEntity.typeSync(file.reserved, followLinks: false) ==
        FileSystemEntityType.directory) {
      throw const FileSystemException('课表临时存储不可用');
    }
    File(file.temporary).writeAsStringSync(file.encoded, flush: true);
  }
  for (final file in files) {
    if (file.backup != null && file.original != null) {
      File(file.backup!).writeAsBytesSync(file.original!, flush: true);
    }
  }
}

void _commitBatchInIsolate(
  List<
    ({
      String path,
      String encoded,
      List<int>? original,
      bool preserveBackup,
      int index,
    })
  >
  entries,
) {
  final now = DateTime.now().microsecondsSinceEpoch;
  final states = [
    for (final entry in entries)
      _IsolateBatchEntry(
        target: File(entry.path),
        temporary: File('${entry.path}.tmp.$now.${entry.index}'),
        encoded: entry.encoded,
        original: entry.original,
        preserveBackup: entry.preserveBackup,
      ),
  ];
  try {
    for (final state in states) {
      if (state.original != null) {
        final suffix = state.preserveBackup ? 'corrupt' : 'rollback';
        var backup = File('${state.target.path}.$suffix');
        while (FileSystemEntity.typeSync(backup.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          backup = File(
            '${state.target.path}.$suffix.${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        state.backup = backup;
      }
      if (FileSystemEntity.typeSync(
            '${state.target.path}.tmp',
            followLinks: false,
          ) ==
          FileSystemEntityType.directory) {
        throw const FileSystemException('课表临时存储不可用');
      }
      state.temporary.writeAsStringSync(state.encoded, flush: true);
    }
    for (final state in states) {
      if (state.backup != null && state.original != null) {
        state.backup!.writeAsBytesSync(state.original!, flush: true);
        state.backupReady = true;
      }
    }
    for (final state in states) {
      final current = _PendingTimetableJson.readOriginal(state.target);
      if (!listEquals(state.original, current)) {
        throw const TimetablePersistenceException();
      }
    }
    for (final state in states) {
      state.temporary.renameSync(state.target.path);
      state.replaced = true;
    }
  } catch (error) {
    for (final state in states.reversed) {
      if (!state.replaced) continue;
      try {
        if (state.original == null) {
          state.target.deleteSync();
        } else {
          state.backup!.renameSync(state.target.path);
        }
      } catch (_) {
        state.rollbackFailed = true;
      }
    }
    rethrow;
  } finally {
    for (final state in states) {
      try {
        if (state.temporary.existsSync()) state.temporary.deleteSync();
      } catch (_) {}
      final backup = state.backup;
      if (backup != null &&
          !state.rollbackFailed &&
          (!state.preserveBackup || !state.backupReady)) {
        try {
          if (backup.existsSync()) backup.deleteSync();
        } catch (_) {}
      }
    }
  }
}

class _IsolateBatchEntry {
  _IsolateBatchEntry({
    required this.target,
    required this.temporary,
    required this.encoded,
    required this.original,
    required this.preserveBackup,
  });

  final File target;
  final File temporary;
  final String encoded;
  final List<int>? original;
  final bool preserveBackup;
  File? backup;
  bool backupReady = false;
  bool replaced = false;
  bool rollbackFailed = false;
}

void _writeAtomicInIsolate(String path, String encoded) {
  final tmp = File('$path.tmp');
  if (FileSystemEntity.typeSync(tmp.path, followLinks: false) ==
      FileSystemEntityType.directory) {
    throw const FileSystemException('课表临时存储不可用');
  }
  try {
    tmp.writeAsStringSync(encoded, flush: true);
    tmp.renameSync(path);
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
  }
}

({Map<String, dynamic> raw, bool corruptWarning}) _readForWriteInIsolate(
  String path,
) {
  final file = File(path);
  try {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return (raw: <String, dynamic>{}, corruptWarning: false);
    }
    if (type != FileSystemEntityType.file) {
      throw const TimetablePersistenceException();
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return (raw: decoded, corruptWarning: false);
    }
    throw const FormatException();
  } on FormatException {
    try {
      var target = File('$path.corrupt');
      if (target.existsSync()) {
        target = File('$path.corrupt.${DateTime.now().microsecondsSinceEpoch}');
      }
      file.renameSync(target.path);
    } catch (_) {
      throw const TimetablePersistenceException();
    }
    return (raw: <String, dynamic>{}, corruptWarning: true);
  } on TimetablePersistenceException {
    rethrow;
  } catch (_) {
    throw const TimetablePersistenceException();
  }
}

/// 单次批量读取本地课表作用域数据的返回包。
class TimetableScopeBundle {
  const TimetableScopeBundle({
    required this.resolvedScheduleId,
    required this.schedulesIndex,
    required this.settings,
    required this.syncState,
    required this.snapshot,
    required this.manualCourses,
    required this.overrides,
    required this.courseColors,
    required this.scheduleEvents,
    required this.courseEdits,
    required this.daySwaps,
    required this.examOverrides,
    required this.syncChanges,
    required this.readFiles,
  });

  factory TimetableScopeBundle.empty(String scheduleId) => TimetableScopeBundle(
    resolvedScheduleId: scheduleId,
    schedulesIndex: const {},
    settings: const {},
    syncState: const {},
    snapshot: const {},
    manualCourses: const {},
    overrides: const {},
    courseColors: const {},
    scheduleEvents: const {},
    courseEdits: const {},
    daySwaps: const {},
    examOverrides: const {},
    syncChanges: const {},
    readFiles: const [],
  );

  final String resolvedScheduleId;
  final Map<String, dynamic> schedulesIndex;
  final Map<String, dynamic> settings;
  final Map<String, dynamic> syncState;
  final Map<String, dynamic> snapshot;
  final Map<String, dynamic> manualCourses;
  final Map<String, dynamic> overrides;
  final Map<String, dynamic> courseColors;
  final Map<String, dynamic> scheduleEvents;
  final Map<String, dynamic> courseEdits;
  final Map<String, dynamic> daySwaps;
  final Map<String, dynamic> examOverrides;
  final Map<String, dynamic> syncChanges;
  final List<String> readFiles;
}

String _resolveScopeIdFromIndex({
  required String initialScheduleId,
  required SchedulesIndex? index,
  required bool resolvePrimaryFromIndex,
}) {
  if (index == null) return initialScheduleId;
  final validPrimary =
      index.primaryScheduleId == kDefaultScheduleId ||
      index.byId(index.primaryScheduleId) != null;
  final primaryId = validPrimary ? index.primaryScheduleId : kDefaultScheduleId;
  if (resolvePrimaryFromIndex) return primaryId;
  if (initialScheduleId != kDefaultScheduleId &&
      index.byId(initialScheduleId) == null) {
    return primaryId;
  }
  return initialScheduleId;
}

({
  TimetableScopeBundle bundle,
  List<({String event, String fileKind})> warnings,
})
_readScopeBundleSync({
  required String rootPath,
  required String initialScheduleId,
  required bool resolvePrimaryFromIndex,
  required bool readSchedulesIndex,
  required bool includeChangeLog,
}) {
  final warnings = <({String event, String fileKind})>[];
  final readFiles = <String>[];
  final sep = Platform.pathSeparator;

  Map<String, dynamic> readOne(
    String dirPath,
    String name, {
    required bool backupOnCorrupt,
  }) {
    readFiles.add(name);
    final file = File('$dirPath$sep$name');
    try {
      if (!file.existsSync()) return const {};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
      if (backupOnCorrupt) {
        throw const FormatException();
      }
      return const {};
    } on FormatException {
      warnings.add((event: 'json.read_failed', fileKind: name));
      if (backupOnCorrupt) {
        try {
          var target = File('${file.path}.corrupt');
          if (target.existsSync()) {
            target = File(
              '${file.path}.corrupt.${DateTime.now().microsecondsSinceEpoch}',
            );
          }
          file.renameSync(target.path);
        } catch (_) {
          warnings.add((event: 'corrupt_backup.failed', fileKind: name));
        }
      }
      return const {};
    } catch (_) {
      warnings.add((event: 'json.read_failed', fileKind: name));
      return const {};
    }
  }

  final idxRaw = readSchedulesIndex
      ? readOne(rootPath, 'schedules_index.json', backupOnCorrupt: false)
      : const <String, dynamic>{};
  SchedulesIndex? parsedIdx;
  if (idxRaw.isNotEmpty) {
    try {
      parsedIdx = SchedulesIndex.fromJson(idxRaw);
    } catch (_) {
      warnings.add((
        event: 'schedules_index.parse_failed',
        fileKind: 'schedules_index.json',
      ));
    }
  }
  final resolvedId = _resolveScopeIdFromIndex(
    initialScheduleId: initialScheduleId,
    index: parsedIdx,
    resolvePrimaryFromIndex: resolvePrimaryFromIndex,
  );
  final scopeDir = resolvedId == kDefaultScheduleId
      ? rootPath
      : '$rootPath${sep}schedules$sep$resolvedId';

  final settings = readOne(rootPath, 'settings.json', backupOnCorrupt: false);
  final syncState = readOne(rootPath, 'sync_state.json', backupOnCorrupt: true);
  final snapshot = readOne(scopeDir, 'snapshot.json', backupOnCorrupt: false);
  final manualCourses = readOne(
    scopeDir,
    'manual_courses.json',
    backupOnCorrupt: false,
  );
  final overrides = readOne(scopeDir, 'overrides.json', backupOnCorrupt: true);
  final courseColors = readOne(
    scopeDir,
    'course_colors.json',
    backupOnCorrupt: true,
  );
  final scheduleEvents = readOne(
    scopeDir,
    'schedule_events.json',
    backupOnCorrupt: true,
  );
  final courseEdits = readOne(
    scopeDir,
    'course_edits.json',
    backupOnCorrupt: true,
  );
  final daySwaps = readOne(scopeDir, 'day_swaps.json', backupOnCorrupt: true);
  final examOverrides = readOne(
    scopeDir,
    'exam_overrides.json',
    backupOnCorrupt: true,
  );
  final syncChanges = includeChangeLog
      ? readOne(scopeDir, 'sync_changes.json', backupOnCorrupt: true)
      : const <String, dynamic>{};

  return (
    bundle: TimetableScopeBundle(
      resolvedScheduleId: resolvedId,
      schedulesIndex: idxRaw,
      settings: settings,
      syncState: syncState,
      snapshot: snapshot,
      manualCourses: manualCourses,
      overrides: overrides,
      courseColors: courseColors,
      scheduleEvents: scheduleEvents,
      courseEdits: courseEdits,
      daySwaps: daySwaps,
      examOverrides: examOverrides,
      syncChanges: syncChanges,
      readFiles: readFiles,
    ),
    warnings: warnings,
  );
}

/// 用户编辑无法保存到本机时的安全错误，不包含路径或底层异常文本。
class TimetablePersistenceException implements Exception, DiagnosticError {
  const TimetablePersistenceException({this.cause, this.causeStackTrace});

  @override
  final Object? cause;
  @override
  final StackTrace? causeStackTrace;
  @override
  Map<String, Object?> get diagnosticContext => const {
    'stage': 'storage.write',
    'reason_code': 'timetable_persistence_failed',
  };

  @override
  String toString() => '课表保存失败，请检查设备剩余空间后重试';
}

/// [TimetableStore.readCourseColors] 的结果。
class StoredCourseColors {
  const StoredCourseColors(this.scheme, this.map);
  final CoursePaletteScheme scheme;
  final Map<String, int> map;
}
