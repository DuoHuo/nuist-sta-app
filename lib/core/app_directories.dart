import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 应用常用目录的进程级缓存入口。
///
/// 通过 `path_provider` 查询应用目录需要跨平台通道，而进程生命周期内三类目录路径
/// 不会变化。统一在这里做进程级缓存与在途并发去重：
/// - 同一类型目录的并发调用共享同一次底层查询；
/// - 查询成功后进程内复用该 [Directory]；
/// - 底层抛异常（无平台通道、插件异常、超时等）绝不缓存失败结果，立刻释放槽位
///   供后续调用重试，并原样保留异常类型与调用堆栈。
abstract final class AppDirectories {
  static final _applicationDocuments = _DirectoryCache(
    getApplicationDocumentsDirectory,
  );
  static final _applicationSupport = _DirectoryCache(
    getApplicationSupportDirectory,
  );
  static final _temporary = _DirectoryCache(getTemporaryDirectory);

  /// 应用文档目录（对应 `getApplicationDocumentsDirectory`）。
  static Future<Directory> applicationDocuments() =>
      _applicationDocuments.get();

  /// 应用支持目录（对应 `getApplicationSupportDirectory`）。
  static Future<Directory> applicationSupport() => _applicationSupport.get();

  /// 应用临时/缓存目录（对应 `getTemporaryDirectory`）。
  static Future<Directory> temporary() => _temporary.get();

  /// 测试用：覆盖指定目录的底层解析函数，并清空对应槽位的缓存与在途状态。
  ///
  /// 未传入的槽位保持现状不变；如需还原为默认 `path_provider` 实现并清缓存，请调用
  /// [resetForTesting]。
  @visibleForTesting
  static void overrideForTesting({
    Future<Directory> Function()? applicationDocuments,
    Future<Directory> Function()? applicationSupport,
    Future<Directory> Function()? temporary,
  }) {
    if (applicationDocuments != null) {
      _applicationDocuments.override(applicationDocuments);
    }
    if (applicationSupport != null) {
      _applicationSupport.override(applicationSupport);
    }
    if (temporary != null) {
      _temporary.override(temporary);
    }
  }

  /// 测试用：清空全部目录缓存与在途请求。
  ///
  /// 默认同时清除通过 [overrideForTesting] 注入的自定义解析器；若仅想清空缓存并
  /// 保留已注入的解析器，传入 `keepOverrides: true`。切换 `path_provider` 测试通道
  /// 或 `PathProviderPlatform.instance` 前后应调用此方法避免复用旧目录。
  @visibleForTesting
  static void resetForTesting({bool keepOverrides = false}) {
    _applicationDocuments.reset(keepOverride: keepOverrides);
    _applicationSupport.reset(keepOverride: keepOverrides);
    _temporary.reset(keepOverride: keepOverrides);
  }
}

final class _DirectoryCache {
  _DirectoryCache(this._defaultLoader);

  final Future<Directory> Function() _defaultLoader;
  Future<Directory> Function()? _overrideLoader;
  Directory? _cached;
  Future<Directory>? _inFlight;
  int _generation = 0;

  Future<Directory> get() {
    final cached = _cached;
    if (cached != null) return Future<Directory>.value(cached);
    final pending = _inFlight;
    if (pending != null) return pending;

    final generation = _generation;
    final loader = _overrideLoader ?? _defaultLoader;
    late final Future<Directory> future;
    future = Future<Directory>.sync(loader).then(
      (directory) {
        if (_generation == generation) {
          _cached = directory;
          if (identical(_inFlight, future)) {
            _inFlight = null;
          }
        }
        return directory;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_generation == generation && identical(_inFlight, future)) {
          _inFlight = null;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _inFlight = future;
    return future;
  }

  void override(Future<Directory> Function() loader) {
    _generation++;
    _overrideLoader = loader;
    _cached = null;
    _inFlight = null;
  }

  void reset({bool keepOverride = false}) {
    _generation++;
    if (!keepOverride) _overrideLoader = null;
    _cached = null;
    _inFlight = null;
  }
}
