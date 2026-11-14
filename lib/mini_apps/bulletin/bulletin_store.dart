import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/refresh/silent_refresh.dart';
import 'bulletin_models.dart';

/// 在应用文档目录中保存公告缓存和订阅状态。
class BulletinStore {
  static final _log = AppLog.logger('bulletin.store');

  /// 创建公告存储，可注入应用目录解析器。
  BulletinStore({Future<Directory?> Function()? resolveDirectory})
    : _resolveDirectory = resolveDirectory ?? _applicationDirectory;

  static const _fileName = 'announcements.json';
  final Future<Directory?> Function() _resolveDirectory;
  Future<void> _pendingSave = Future.value();

  static Future<Directory?> _applicationDirectory() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<File?> _file() async {
    try {
      final base = await _resolveDirectory();
      if (base == null) return null;
      final directory = Directory(
        '${base.path}${Platform.pathSeparator}announcements',
      );
      if (!await directory.exists()) await directory.create(recursive: true);
      return File('${directory.path}${Platform.pathSeparator}$_fileName');
    } catch (error) {
      _log.debug(
        'storage.unavailable',
        fields: {'error_type': error.runtimeType.toString()},
      );
      return null;
    }
  }

  /// 读取本地数据；不可用时返回空数据。
  Future<BulletinLocalData> read() => _log.inSpan(() async {
    try {
      await _pendingSave;
      final file = await _file();
      if (file == null || !await file.exists()) {
        return const BulletinLocalData();
      }
      return await compute(
        _decodeLocalData,
        await file.readAsString(),
        debugLabel: 'bulletin.decode_cache',
      );
    } catch (error, stackTrace) {
      _log.warning('cache.read_failed', error: error, stackTrace: stackTrace);
      return const BulletinLocalData();
    }
  });

  /// 保存本地数据；存储不可用时安静降级。
  Future<void> save(BulletinLocalData data) {
    // 后台编码耗时不定，按调用顺序落盘，避免旧快照晚完成覆盖新设置。
    return _pendingSave = _pendingSave.then(
      (_) => _log.inSpan(() async {
        try {
          final file = await _file();
          if (file == null) return;
          final encoded = await compute(
            _encodeLocalData,
            data,
            debugLabel: 'bulletin.encode_cache',
          );
          await file.writeAsString(encoded, flush: true);
        } catch (error, stackTrace) {
          SilentRefresh.degradeCurrent(reason: 'cache_write_failed');
          AppLog.reportOutcome('degraded', reason: 'cache_write_failed');
          _log.warning(
            'cache.write_failed',
            fields: {'file_kind': _fileName, 'outcome': 'memory_fallback'},
            error: error,
            stackTrace: stackTrace,
          );
        }
      }),
    );
  }
}

// 编解码与模型构造都在后台完成；存储降级和日志仍由调用方处理。
BulletinLocalData _decodeLocalData(String raw) {
  final json = jsonDecode(raw);
  return BulletinLocalData.fromJson(json is Map<String, dynamic> ? json : null);
}

String _encodeLocalData(BulletinLocalData data) => jsonEncode(data.toJson());
