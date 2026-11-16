import 'dart:async';

import '../../core/logging/app_log.dart';
import 'bulletin_api.dart';
import 'bulletin_detail_store.dart';
import 'bulletin_models.dart';

/// 供列表预加载和详情页共用的正文缓存与请求。
class BulletinDetailRepository {
  /// 注入接口、存储和时间；未提供存储时仅保留进程内缓存。
  BulletinDetailRepository({
    BulletinApi? api,
    this._store,
    DateTime Function()? now,
  }) : api = api ?? BulletinApi(),
       _now = now ?? DateTime.now;

  /// 应用内的默认正文入口。
  static final instance = BulletinDetailRepository(
    store: BulletinDetailStore(),
  );
  static final _log = AppLog.logger('bulletin.detail_repository');
  static const _freshness = Duration(hours: 1);
  static const _memoryLimit = 8;
  static const _preloadLimit = 3;

  /// 与详情页共用的接口，附件仍在用户点击时下载。
  final BulletinApi api;
  final BulletinDetailStore? _store;
  final DateTime Function() _now;
  final _memory = <Uri, CachedBulletinDetail>{};
  final _requests = <Uri, Future<BulletinDetailDocument?>>{};
  Future<void>? _preloadTask;
  ({List<Bulletin> items, bool Function() shouldContinue})? _nextBatch;

  /// 一小时内的快照可以直接使用。
  bool isFresh(CachedBulletinDetail entry) =>
      _now().difference(entry.savedAt) < _freshness;

  /// 优先读取内存，其次读盘；并发更新时保留更新的结果。
  Future<CachedBulletinDetail?> read(Bulletin bulletin) async {
    final uri = Uri.tryParse(bulletin.url);
    if (uri == null) return null;
    final current = _memory.remove(uri);
    if (current != null &&
        _now().difference(current.savedAt) < BulletinDetailStore.retention) {
      _memory[uri] = current;
      return current;
    }
    final stored = isOfficialBulletinUri(uri) ? await _store?.read(uri) : null;
    final cached = _memory[uri] ?? stored;
    if (cached != null) _remember(uri, cached);
    return cached;
  }

  /// 拉取最新正文；同一地址的预加载和主动打开共用一次请求。
  Future<BulletinDetailDocument?> refresh(Bulletin bulletin) async {
    final uri = Uri.tryParse(bulletin.url);
    if (uri == null) return null;
    final pending = _requests[uri];
    if (pending != null) return pending;
    final request = _fetch(uri, bulletin);
    _requests[uri] = request;
    try {
      return await request;
    } finally {
      _requests.remove(uri);
    }
  }

  Future<BulletinDetailDocument?> _fetch(Uri uri, Bulletin bulletin) async {
    try {
      final document = await api.fetchDetail(bulletin);
      if (document == null || document.isEmpty) {
        _log.debug(
          'detail.unrecognized',
          fields: {
            'stage': 'response.parse',
            'reason_code': 'document_unrecognized',
            'outcome': 'degraded',
          },
        );
        return null;
      }
      _remember(uri, (document: document, savedAt: _now()));
      final store = _store;
      if (store != null && isOfficialBulletinUri(uri)) {
        unawaited(store.save(uri, document));
      }
      return document;
    } catch (error, stackTrace) {
      _log.warning(
        'detail.fetch_failed',
        fields: {'stage': 'detail.load', 'outcome': 'degraded'},
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  void _remember(Uri uri, CachedBulletinDetail entry) {
    _memory.remove(uri);
    _memory[uri] = entry;
    if (_memory.length > _memoryLimit) _memory.remove(_memory.keys.first);
  }

  /// 只顺序预读列表最前面的官网公告，离开列表后不启动后续请求。
  Future<void> preload(
    Iterable<Bulletin> items, {
    required bool Function() shouldContinue,
  }) {
    _nextBatch = (
      items: items.take(_preloadLimit).toList(growable: false),
      shouldContinue: shouldContinue,
    );
    return _preloadTask ??= Future<void>.microtask(_drainPreloads);
  }

  Future<void> _drainPreloads() async {
    try {
      while (true) {
        final batch = _nextBatch;
        if (batch == null) break;
        _nextBatch = null;
        final seen = <Uri>{};
        for (final item in batch.items) {
          if (_nextBatch != null || !batch.shouldContinue()) break;
          final uri = Uri.tryParse(item.url);
          if (uri == null || !isOfficialBulletinUri(uri) || !seen.add(uri)) {
            continue;
          }
          final cached = await read(item);
          if (_nextBatch != null || !batch.shouldContinue()) break;
          if (cached != null && isFresh(cached)) continue;
          // 遇到网络不可用时停止本轮，避免连续发出多次无用请求。
          if (await refresh(item) == null) break;
        }
      }
    } finally {
      _preloadTask = null;
    }
  }
}
